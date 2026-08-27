"""Non-blocking path: send_query/poll_result basics, timeout + recovery,
and genuine two-connection overlap from one thread.

Run: pixi run mojo run -I . tests/test_async.mojo
"""

from std.time import perf_counter

from tests.common import DSN, check, check_raised

from pqmojo import connect, execute, poll_result, send_query


def now_s() -> Float64:
    return Float64(perf_counter())


def main() raises:
    var conn = connect(DSN)

    # ---- basics: submit then wait ----
    send_query(conn, "SELECT $1::int8 AS v", [String("123")])
    var r = poll_result(conn, 5000)
    check(r.rows() == 1 and r.col_i64(0, 0) == 123, "send/poll round trip")
    check(r.status() == 2, "tuples ok through async path")
    r.clear()

    # submissions are strictly one-in-flight per libpq connection: complete
    # each round trip before the next submit
    for i in range(2):
        send_query(conn, "SELECT $1::int8", [String(String(i * 10 + 10))])
        var got = poll_result(conn, 5000)
        check(got.col_i64(0, 0) == Int64(i * 10 + 10), "ordered result")
        got.clear()
    # connection is clean again
    var c1 = execute(conn, "SELECT 30", [])
    check(c1.col_i64(0, 0) == 30, "conn reusable after pipeline drain")
    c1.clear()

    # ---- timeout raises; conn stays coherent and can finish the query ----
    var t0 = now_s()
    send_query(conn, "SELECT pg_sleep(0.35), 'late'::text", [])
    var raised = False
    try:
        var early = poll_result(conn, 100)
        early.clear()
    except:
        raised = True
    check_raised(raised, "short poll times out")
    print("[async] timeout after", Float64(now_s() - t0), "s (expected ~0.1)")
    t0 = now_s()
    var late = poll_result(conn, 5000)   # same statement finishes
    var waited = Float64(now_s() - t0)
    check(late.col_text(0, 1) == "late", "recovered result text")
    late.clear()
    print("[async] recovery poll waited only", waited,
          "s of new time (rest was already done)")
    var sane = execute(conn, "SELECT 7", [])
    check(sane.col_i64(0, 0) == 7, "post-recovery sanity select")
    sane.clear()

    # ---- blocking convenience built on the nonblocking path ----
    var other = connect(DSN)

    # ---- overlap proof: two conns, one thread ----
    var overlap_start = now_s()
    send_query(other, "SELECT pg_sleep(0.25), 'slow'::text", [])
    send_query(conn, "SELECT 'fast'::text", [])
    var fast_t = -1.0
    var rf = poll_result(conn, 5000)
    fast_t = now_s() - overlap_start
    check(rf.col_text(0, 0) == "fast", "fast query finished first")
    rf.clear()
    var rs = poll_result(other, 5000)
    var slow_t = now_s() - overlap_start
    check(rs.col_text(0, 1) == "slow", "slow query completed")
    rs.clear()
    check(fast_t < 0.20 and slow_t >= 0.24,
          "overlap: fast returned while slow was still sleeping")
    print("[async] overlap timings: fast =", fast_t, "s, total =", slow_t, "s")

    # error propagation through the strict path
    send_query(conn, "SELECT 1/0", [])
    var err_raised = False
    try:
        var bad = poll_result(conn, 5000)
        bad.clear()
    except:
        err_raised = True
    check_raised(err_raised, "async SQL error surfaces at poll")
    var after_err = execute(conn, "SELECT 5", [])
    check(after_err.col_i64(0, 0) == 5, "conn healthy after async error")
    after_err.clear()

    other.close()
    conn.close()
    print("TEST_ASYNC PASS")
