"""Pipeline STRESS: 10k submit/collect cycles through a k=2 window with
per-cycle value verification (zero lost completions, zero double-touch),
plus a fork()ed fleet hammering pipelines in separate processes.

Single-threaded by design (see pqmojo.pipeline docstring): the invariants
under stress are (a) every submitted request id is answered EXACTLY once,
(b) values match requests through the id mapping, (c) conns released via
release_pipeline stay healthy for the next checkout, (d) the whole thing
survives fork per the pool contract.

Run: pixi run mojo run -I . tests/test_pipeline_stress.mojo
"""

from std.ffi import c_size_t, external_call
from std.memory import Pointer
from std.time import perf_counter

from tests.common import DSN, check

from pqmojo import ConnectionPool, PoolConfig, execute, format_i64

from pqmojo.ffi import CharPtr


comptime CYCLES = 10_000
comptime WORKERS = 6
comptime FLEET_ITER = 300


def one(s: String) -> List[String]:
    var l = List[String]()
    l.append(s)
    return l^


def _scratch(n: Int) -> Int:
    var p = external_call["malloc", CharPtr](c_size_t(n))
    return Int(p)


def hammer(dsn: String, iters: Int) raises -> Int:
    """One forked worker: own pool, own pipeline, windowed submit/collect."""
    var failures = 0
    var pool = ConnectionPool(
        PoolConfig(dsn, max_size=3, min_idle=1)
    )
    pool.prepare_on_acquire([
        ("ov_id", "SELECT $1::int8 AS v"),
    ])
    var pipe = pool.checkout_pipeline(2)
    var next_submit = 0
    var answered = 0
    # prime the window, then rotate: collect + resubmit keeps 2 in flight
    _ = pipe.submit("ov_id", one(format_i64(Int64(next_submit))))
    next_submit += 1
    for i in range(iters):
        try:
            _ = pipe.submit("ov_id", one(format_i64(Int64(next_submit))))
            next_submit += 1
            var r = pipe.collect(30_000)
            if r.result.col_i64(0, 0) != Int64(r.request_id):
                failures += 1   # value/request mismatch = lost or swapped
            r.result.clear()
            answered += 1
        except:
            failures += 1
    # drain the window: one more collect answers the priming submit
    try:
        var tail = pipe.collect(30_000)
        if tail.result.col_i64(0, 0) != Int64(tail.request_id):
            failures += 1
        tail.result.clear()
        answered += 1
    except:
        failures += 1
    if answered != iters + 1:
        failures += 1           # a completion was lost
    if pipe.in_flight() != 0:
        failures += 1           # bookkeeping says something is still out
    pool.release_pipeline(pipe^)
    # released conns must be healthy for the next checkout
    var again = pool.acquire()
    var p = execute(again, "SELECT 1", [])
    var ok = p.col_i64(0, 0) == 1
    p.clear()
    pool.release(again^)
    if not ok:
        failures += 1
    var st = pool.stats()
    if st.in_use != 0:
        failures += 1
    pool.close()
    if failures == 0:
        return 0
    return 100 + failures


def run_fleet(count: Int, iters: Int, status_addr: Int) raises -> Int:
    var kids = List[Int]()
    var status = Pointer[Int32, MutAnyOrigin](unsafe_from_address=status_addr)
    var bad = 0
    for w in range(count):
        var pid = external_call["fork", Int32]()
        check(pid >= 0, "fork succeeded")
        if pid == 0:
            var rc = hammer(DSN, iters)
            _ = external_call["_exit", NoneType](rc & 0xFF)
        kids.append(Int(pid))
    for j in range(count):
        _ = external_call["waitpid", Int32](kids[len(kids) - count + j], status, 0)
        var code = (status[unsafe_offset=0] >> 8) & 0xFF
        if code != 0:
            bad += 1
            print("[stress] pipeline worker exited", code)
    return bad


def main() raises:
    var pool = ConnectionPool(
        PoolConfig(DSN, max_size=3, min_idle=1)
    )
    pool.prepare_on_acquire([
        ("ov_id", "SELECT $1::int8 AS v"),
    ])

    # ---- 10k windowed submit/collect cycles, every value verified ----
    var pipe = pool.checkout_pipeline(2)
    var t0 = Float64(perf_counter())
    var next_submit = 0
    var answered = 0
    _ = pipe.submit("ov_id", one(format_i64(Int64(next_submit))))
    next_submit += 1
    for i in range(CYCLES):
        _ = pipe.submit("ov_id", one(format_i64(Int64(next_submit))))
        next_submit += 1
        var r = pipe.collect(30_000)
        # request_id n carried param n: any loss or swap breaks equality
        if r.result.col_i64(0, 0) != Int64(r.request_id):
            raise Error(
                "FAIL: request " + String(r.request_id)
                + " returned the wrong row (lost/swapped completion)"
            )
        r.result.clear()
        answered += 1
    var tail = pipe.collect(30_000)
    if tail.result.col_i64(0, 0) != Int64(tail.request_id):
        raise Error("FAIL: tail completion mismatch")
    tail.result.clear()
    answered += 1
    var dt = Float64(perf_counter()) - t0
    check(answered == CYCLES + 1, "every submission answered exactly once")
    check(pipe.in_flight() == 0, "bookkeeping clean after 10k cycles")
    print("[stress]", CYCLES + 1, "windowed submit/collect cycles through",
          "k=2: zero lost completions,", Float64(answered) / dt, "qps")
    pool.release_pipeline(pipe^)

    # ---- forked fleet: pipelines in separate post-fork workers ----
    var status_addr = _scratch(4)
    var bad = run_fleet(WORKERS, FLEET_ITER, status_addr)
    check(bad == 0, "fleet of pipeline workers completed flawlessly")
    print("[stress]", WORKERS, "x", FLEET_ITER,
          "pipeline cycles across processes: zero failures")

    pool.close()
    print("TEST_PIPELINE_STRESS PASS")
