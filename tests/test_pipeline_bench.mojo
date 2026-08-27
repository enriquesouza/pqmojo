"""BENCH: OVERLAP scaling — aggregate qps on the details-shaped prepared
point lookup as the pipeline window grows, one thread, best-of-3.

  seq      : execute_prepared back-to-back on ONE conn (the v0.3.0 ceiling)
  pipe k=N : StmtPipeline window of N conns kept in flight (submit rotates,
             collect re-arms)
  batch    : pool.execute_batch of M=64 jobs through a k=2 window

Gate: pipe k=2 must clear 1.6x seq (the mission's overlap target).

Run: pixi run mojo run -I . tests/test_pipeline_bench.mojo
"""

from std.time import perf_counter

from tests.common import DSN, check

from pqmojo import ConnectionPool, PoolConfig, execute, execute_prepared, format_i64


comptime ITERS = 8_000
comptime REPS = 3
comptime BATCH_JOBS = 64
comptime DETAILS_SQL = (
    "SELECT id, title, neighborhood, price, latitude, longitude "
    + "FROM listing_active WHERE id = $1 LIMIT 1"
)


def one(s: String) -> List[String]:
    var l = List[String]()
    l.append(s)
    return l^


def now_s() -> Float64:
    return Float64(perf_counter())


def windowed_qps(
    mut pool: ConnectionPool, k: Int, params: List[String], iters: Int
) raises -> Float64:
    """Steady-state windowed throughput: prime k sockets, then rotate
    collect + refill so all k stay in flight; drain the tail at the end."""
    var pipe = pool.checkout_pipeline(k)
    for i in range(k):
        _ = pipe.submit("ov_details", params)
    var t0 = now_s()
    var answered = 0
    for i in range(iters):
        var r = pipe.collect(60_000)
        _ = r.result.col_i64(0, 0)
        r.result.clear()
        answered += 1
        _ = pipe.submit("ov_details", params)
    while pipe.in_flight() > 0:
        var r = pipe.collect(60_000)
        _ = r.result.col_i64(0, 0)
        r.result.clear()
        answered += 1
    var qps = Float64(answered) / (now_s() - t0)
    pool.release_pipeline(pipe^)   # conns back to the pool for the next rep
    return qps


def main() raises:
    var pool = ConnectionPool(
        PoolConfig(DSN, max_size=8, min_idle=2, health_check=False)
    )
    pool.prepare_on_acquire([("ov_details", DETAILS_SQL)])

    var idr = execute(pool.acquire(), "SELECT id FROM listing_active ORDER BY id LIMIT 1", [])
    var id_val = idr.col_i64(0, 0)
    idr.clear()
    var params = one(format_i64(id_val))

    # warm the prepared plans + caches on every pipeline conn this bench
    # will see (health_check off; pool grows on first checkout)
    var w = pool.checkout_pipeline(4)
    for i in range(4):
        _ = w.submit("ov_details", params)
    for i in range(4):
        var r = w.collect(60_000)
        _ = r.result.col_i64(0, 0)
        r.result.clear()
    pool.release_pipeline(w^)

    var best_seq: Float64 = -1.0
    var best_k1: Float64 = -1.0
    var best_k2: Float64 = -1.0
    var best_k3: Float64 = -1.0
    var best_k4: Float64 = -1.0
    var best_batch: Float64 = -1.0

    var conn = pool.acquire()
    for rep in range(REPS):
        var t0 = now_s()
        for _ in range(ITERS):
            var r = execute_prepared(conn, "ov_details", params)
            _ = r.col_i64(0, 0)
            r.clear()
        var seq_qps = Float64(ITERS) / (now_s() - t0)
        if best_seq < 0 or seq_qps > best_seq:
            best_seq = seq_qps

        var k1 = windowed_qps(pool, 1, params, ITERS)
        if best_k1 < 0 or k1 > best_k1:
            best_k1 = k1

        var k2 = windowed_qps(pool, 2, params, ITERS)
        if best_k2 < 0 or k2 > best_k2:
            best_k2 = k2

        var k3 = windowed_qps(pool, 3, params, ITERS // 2)
        if best_k3 < 0 or k3 > best_k3:
            best_k3 = k3

        var k4 = windowed_qps(pool, 4, params, ITERS // 2)
        if best_k4 < 0 or k4 > best_k4:
            best_k4 = k4

        var jobs = List[List[String]]()
        for j in range(BATCH_JOBS):
            jobs.append(one(format_i64(id_val)))
        var t1 = now_s()
        var n_batches = 20
        for b in range(n_batches):
            var rs = pool.execute_batch("ov_details", jobs, 2)
            if len(rs) != BATCH_JOBS:
                raise Error("batch came back short")
            for j in range(len(rs)):
                rs[j].clear()
        var batch_qps = Float64(n_batches * BATCH_JOBS) / (now_s() - t1)
        if best_batch < 0 or batch_qps > best_batch:
            best_batch = batch_qps

        print("[bench] rep", rep, ": seq =", seq_qps, " k2 =", k2,
              " k3 =", k3, " k4 =", k4, " batch(k2) =", batch_qps)
    pool.release(conn^)

    print("[bench] OVERLAP SCALING — details-shaped point lookup, 1 thread,")
    print("[bench] best of", REPS, "(local socket, prepared Bind/Execute):")
    print("[bench]   seq 1 conn          :", best_seq, "qps   (1.00x)")
    print("[bench]   pipe k=1 (sanity)   :", best_k1, "qps   (",
          best_k1 / best_seq, "x )")
    print("[bench]   pipe k=2            :", best_k2, "qps   (",
          best_k2 / best_seq, "x )")
    print("[bench]   pipe k=3            :", best_k3, "qps   (",
          best_k3 / best_seq, "x )")
    print("[bench]   pipe k=4            :", best_k4, "qps   (",
          best_k4 / best_seq, "x )")
    print("[bench]   execute_batch k=2   :", best_batch, "qps   (",
          best_batch / best_seq, "x )")

    check(best_k2 >= best_seq * 1.6,
          "pipe k=2 must clear the 1.6x overlap target")
    check(best_k1 <= best_seq * 1.35,
          "k=1 degenerates to sequential (no magic overlap)")
    check(best_k4 > best_k2,
          "bigger windows scale toward the server ceiling")
    pool.close()
    print("TEST_PIPELINE_BENCH PASS")
