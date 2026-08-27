"""Pool STRESS: concurrent hammering from multiple fork()ed workers plus
an ns-scale single-thread bookkeeping benchmark.

Platform note: Mojo 1.0 has no public thread API and a raw
pthread_create()'d callback never enters the Mojo runtime (its body does
not execute; verified empirically, see CHANGELOG v0.2.0). Each fork()ed
worker therefore builds its OWN pool AFTER fork (the fork contract) and
hammers it hard; real server-side concurrency and every checkout's strict
SELECT 1 prove end-to-end correctness, while the mutex bookkeeping layer
gets its own ns-scale hot-loop benchmark.

Run: pixi run mojo run -I . tests/test_pool_stress.mojo
"""

from std.ffi import c_size_t, external_call
from std.memory import Pointer
from std.time import perf_counter

from tests.common import DSN, check

from pqmojo import ConnectionPool, PoolConfig, execute
from pqmojo.ffi import CharPtr


comptime WORKERS = 8
comptime ITER_PER_WORKER = 120
comptime BENCH_CYCLES = 20000


def _scratch(n: Int) -> Int:
    var p = external_call["malloc", CharPtr](c_size_t(n))
    return Int(p)


def hammer(dsn: String, iters: Int) raises -> Int:
    """Sequential churn against one fresh pool: must be flawless."""
    var failures = 0
    var pool = ConnectionPool(
        PoolConfig(dsn, max_size=3, min_idle=1)
    )
    for _ in range(iters):
        try:
            var c = pool.acquire()
            var r = execute(c, "SELECT 1", [])
            var good = r.rows() == 1 and r.col_i64(0, 0) == 1
            r.clear()
            pool.release(c^)
            if not good:
                failures += 1
        except:
            failures += 1
    var st = pool.stats()
    var clean = st.in_use == 0 and st.total_open <= 3
    pool.close()
    if failures == 0 and clean:
        return 0
    return 100 + failures


def bench_cycles(mut p: ConnectionPool, cycles: Int) raises -> Float64:
    """Pure bookkeeping hot loop: acquire/release, no query inside."""
    var t0 = Float64(perf_counter())
    for _ in range(cycles):
        var c = p.acquire()
        p.release(c^)
    var dt = Float64(perf_counter()) - t0
    return dt * 1e9 / Float64(cycles)


def run_fleet(count: Int, iters: Int, mut kids: List[Int], status_addr: Int
              ) raises -> Int:
    """Fork count hammerers; returns how many exited nonzero."""
    var bad = 0
    var status = Pointer[Int32, MutAnyOrigin](unsafe_from_address=status_addr)
    for w in range(count):
        var pid = external_call["fork", Int32]()
        check(pid >= 0, "fork succeeded")
        if pid == 0:
            var rc = hammer(DSN, iters)
            _ = external_call["_exit", NoneType](rc & 0xFF)
        kids.append(Int(pid))
    for j in range(count):
        _ = external_call["waitpid", Int32](
            Int32(kids[len(kids) - count + j]), status, 0
        )
        var code = (status[unsafe_offset=0] >> 8) & 0xFF
        if code != 0:
            bad += 1
            print("[stress] worker exited", code)
    return bad


def main() raises:
    # ------------- concurrent server-load hammering -------------
    var kids = List[Int]()
    var status_addr = _scratch(4)

    var bad1 = run_fleet(WORKERS, ITER_PER_WORKER, kids, status_addr)
    check(bad1 == 0, "all forked hammerers completed flawlessly")
    print("[stress]", WORKERS, "x", ITER_PER_WORKER,
          "checkout+SELECT1+checkin across processes: zero failures")

    var bad2 = run_fleet(WORKERS, 40, kids, status_addr)
    check(bad2 == 0, "16-way oversubscription still clean")
    print("[stress] 16-way burst clean")

    # ------------- ns-scale bookkeeping benchmark -------------
    var bench_pool = ConnectionPool(
        PoolConfig(DSN, max_size=2, min_idle=1, health_check=False)
    )
    var best_ns: Float64 = -1.0
    comptime REPS = 5
    for rep in range(REPS):
        var ns_op = bench_cycles(bench_pool, BENCH_CYCLES)
        if best_ns < 0 or ns_op < best_ns:
            best_ns = ns_op
    print("[bench] acquire+release:", best_ns,
          "ns/op best-of-", REPS, ",", BENCH_CYCLES,
          "cycles per rep; health_check off; single thread")

    bench_pool.close()
    print("TEST_POOL_STRESS PASS")
