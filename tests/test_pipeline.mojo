"""Pipeline (OVERLAP) semantics: window round-robin, request-id identity,
completion-order collect, strict SQL-error propagation, timeout + recovery,
window-full contract, k=1 degeneration, drain/release health.

Run: pixi run mojo run -I . tests/test_pipeline.mojo
"""

from std.time import perf_counter

from tests.common import DSN, check, check_raised
from tests.fixture import setup_fixture, teardown_fixture

from pqmojo import (
    ConnectionPool,
    PgConn,
    PoolConfig,
    StmtPipeline,
    connect,
    execute,
    execute_prepared,
    format_i64,
)


comptime DETAILS_SQL = (
    "SELECT id, title, district, amount, latitude, longitude "
    + "FROM pqmojo_test_items WHERE id = $1 LIMIT 1"
)


def now_s() -> Float64:
    return Float64(perf_counter())


def one(s: String) -> List[String]:
    var l = List[String]()
    l.append(s)
    return l^


def close_all(var conns: List[PgConn]):
    for i in range(len(conns)):
        conns[i].close()


def main() raises:
    setup_fixture()
    var c0 = connect(DSN)
    var c1 = connect(DSN)
    c0.prepare_named("ov_details", DETAILS_SQL)
    c1.prepare_named("ov_details", DETAILS_SQL)

    var idr = execute(c0, "SELECT id FROM pqmojo_test_items ORDER BY id LIMIT 1", [])
    check(idr.rows() == 1, "fixture table has rows")
    var id_val = idr.col_i64(0, 0)
    idr.clear()
    var p1 = one(format_i64(id_val))

    # ---- raw-conns pipeline: request ids + value identity ----
    var conns = List[PgConn]()
    conns.append(c0^)
    conns.append(c1^)
    var pipe = StmtPipeline(conns^)
    check(pipe.slots() == 2, "window is 2 slots")

    var rid0 = pipe.submit("ov_details", p1)
    var rid1 = pipe.submit("ov_details", p1)
    check(rid0 == 0 and rid1 == 1, "request ids are pipeline-wide")
    check(pipe.in_flight() == 2, "two statements in flight")

    var raised = False
    try:
        _ = pipe.submit("ov_details", p1)
    except:
        raised = True
    check_raised(raised, "window-full submit raises")

    var first = pipe.collect(30_000)
    var second = pipe.collect(30_000)
    check(pipe.in_flight() == 0, "window drains to zero")
    check(
        (first.request_id == 0 and second.request_id == 1)
        or (first.request_id == 1 and second.request_id == 0),
        "request ids identify completions in arbitrary order",
    )
    check(first.slot != second.slot, "completions came from different slots")
    check(
        first.result.col_i64(0, 0) == id_val
        and second.result.col_i64(0, 0) == id_val,
        "row values match the requested id",
    )
    check(first.result.col_text(0, 1).byte_length() > 0, "title non-empty")
    first.result.clear()
    second.result.clear()

    # window reopened after drain: ids keep increasing (no reset mid-life)
    var rid2 = pipe.submit("ov_details", p1)
    check(rid2 == 2, "request id counter continues")
    var third = pipe.collect(30_000)
    check(third.request_id == 2, "id identity across drain cycles")
    check(third.result.col_i64(0, 0) == id_val, "third value identity")
    third.result.clear()
    close_all(pipe.drain())

    # ---- strict error propagation through collect ----
    var bad = connect(DSN)
    var one_conns = List[PgConn]()
    one_conns.append(bad^)
    var single = StmtPipeline(one_conns^)
    single.submit("ov_details_does_not_exist", p1)
    raised = False
    try:
        var boom = single.collect(30_000)
        boom.result.clear()
    except:
        raised = True
    check_raised(raised, "missing prepared statement raises at collect")
    # bookkeeping stayed consistent: drain sees nothing wedged, conn healthy
    var bad_back = single.drain()
    var still_up = execute(bad_back[0], "SELECT 5", [])
    check(still_up.col_i64(0, 0) == 5, "error-path conn reusable after drain")
    still_up.clear()
    close_all(bad_back^)

    # ---- timeout + recovery: pg_sleep beats the budget, then finishes ----
    var slow = connect(DSN)
    slow.prepare_named("ov_slow", "SELECT pg_sleep(0.4), 'slow'::text")
    slow.prepare_named("ov_seven", "SELECT 7::int8")
    var slow_conns = List[PgConn]()
    slow_conns.append(slow^)
    var slow_pipe = StmtPipeline(slow_conns^)
    _ = slow_pipe.submit("ov_slow", List[String]())
    var t0 = now_s()
    raised = False
    try:
        var early = slow_pipe.collect(120)
        early.result.clear()
    except:
        raised = True
    check_raised(raised, "short collect budget times out")
    var waited = Float64(now_s() - t0)
    check(waited >= 0.1 and waited < 0.35, "timeout respected the budget")
    var late = slow_pipe.collect(30_000)
    check(late.result.col_text(0, 1) == "slow", "recovered slow result")
    late.result.clear()
    var sane_rid = slow_pipe.submit("ov_seven", List[String]())
    var got = slow_pipe.collect(30_000)
    check(
        got.result.col_i64(0, 0) == 7 and sane_rid == 1,
        "conn healthy after timeout+recovery",
    )
    got.result.clear()
    close_all(slow_pipe.drain())

    # ---- k=1 degenerates to sequential and still works ----
    var solo = connect(DSN)
    solo.prepare_named("ov_details", DETAILS_SQL)
    var solo_conns = List[PgConn]()
    solo_conns.append(solo^)
    var seq_pipe = StmtPipeline(solo_conns^)
    for i in range(4):
        _ = seq_pipe.submit("ov_details", p1)
        var r = seq_pipe.collect(30_000)
        check(r.result.col_i64(0, 0) == id_val, "k=1 round trip")
        check(r.slot == 0, "k=1 always slot 0")
        r.result.clear()
    close_all(seq_pipe.drain())

    # ---- pool integration: plan-armed slots + release health ----
    var pool = ConnectionPool(PoolConfig(DSN, max_size=4, min_idle=1))
    pool.prepare_on_acquire([("ov_details", DETAILS_SQL)])
    var ppipe = pool.checkout_pipeline(2)
    var batch_rid = ppipe.submit("ov_details", p1)
    var batch_r = ppipe.collect(30_000)
    check(
        batch_rid == batch_r.request_id
        and batch_r.result.col_i64(0, 0) == id_val,
        "pool pipeline: plan-armed conns bind by name",
    )
    batch_r.result.clear()
    pool.release_pipeline(ppipe^)
    var st = pool.stats()
    check(st.in_use == 0, "release_pipeline returned every slot")

    # ---- pool.execute_batch: submission-ordered results ----
    var jobs = List[List[String]]()
    for i in range(9):
        jobs.append(one(format_i64(id_val)))
    var rs = pool.execute_batch("ov_details", jobs, 2)
    check(len(rs) == 9, "batch: every job answered")
    for j in range(9):
        check(rs[j].col_i64(0, 0) == id_val, "batch row identity")
        rs[j].clear()

    # empty batch is a no-op
    var empty = pool.execute_batch("ov_details", List[List[String]](), 2)
    check(len(empty) == 0, "empty batch returns empty")

    # pool still healthy after batches
    var final_conn = pool.acquire()
    var fp = execute(final_conn, "SELECT 40+2", [])
    check(fp.col_i64(0, 0) == 42, "pool conn healthy post-batch")
    fp.clear()
    pool.release(final_conn^)
    pool.close()

    # ---- overlap sanity from one thread (the bench proves the scaling) ----
    # apples-to-apples: same machinery, k=2 window vs k=1 sequential lane,
    # best of 2 reps each (short runs wobble on a loaded box)
    var bench_pool = ConnectionPool(
        PoolConfig(DSN, max_size=4, min_idle=2, health_check=False)
    )
    bench_pool.prepare_on_acquire([("ov_details", DETAILS_SQL)])
    var best_k1: Float64 = -1.0
    var best_k2: Float64 = -1.0
    comptime SAN_N = 6000
    for rep in range(2):
        var p1pipe = bench_pool.checkout_pipeline(1)
        var bt0 = now_s()
        for i in range(SAN_N):
            _ = p1pipe.submit("ov_details", p1)
            var r = p1pipe.collect(30_000)
            _ = r.result.col_i64(0, 0)
            r.result.clear()
        var k1_qps = Float64(SAN_N) / (now_s() - bt0)
        bench_pool.release_pipeline(p1pipe^)
        if best_k1 < 0 or k1_qps > best_k1:
            best_k1 = k1_qps

        var p2pipe = bench_pool.checkout_pipeline(2)
        var answered = 0
        bt0 = now_s()
        # keep the window full: prime both slots, then every collect
        # re-arms one — both sockets stay in flight for the whole loop
        _ = p2pipe.submit("ov_details", p1)
        for i in range(SAN_N):
            _ = p2pipe.submit("ov_details", p1)
            var r = p2pipe.collect(30_000)
            _ = r.result.col_i64(0, 0)
            r.result.clear()
            answered += 1
        var tail = p2pipe.collect(30_000)
        _ = tail.result.col_i64(0, 0)
        tail.result.clear()
        answered += 1
        var k2_qps = Float64(answered) / (now_s() - bt0)
        bench_pool.release_pipeline(p2pipe^)
        if best_k2 < 0 or k2_qps > best_k2:
            best_k2 = k2_qps
    print("[pipeline] overlap sanity: k=2 window =", best_k2,
          "qps vs k=1 lane =", best_k1, "qps (x", best_k2 / best_k1, ")")
    check(best_k2 > best_k1 * 1.25, "k=2 window genuinely overlaps (>=1.25x)")
    bench_pool.close()

    teardown_fixture()
    print("TEST_PIPELINE PASS")
