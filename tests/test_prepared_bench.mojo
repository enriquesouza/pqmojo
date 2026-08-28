"""BENCH: prepared (Parse once, Bind/Execute) vs plain exec_params round
trips on the details-shaped hot query, 10k iterations per rep averaged,
best-of-3. Results must be IDENTICAL across both paths.

Run: pixi run mojo run -I . tests/test_prepared_bench.mojo
"""

from std.time import perf_counter

from tests.common import DSN, check
from tests.fixture import setup_fixture, teardown_fixture

from pqmojo import connect, execute, execute_prepared, format_i64


comptime ITERS = 10_000
comptime REPS = 3


def now_s() -> Float64:
    return Float64(perf_counter())


def main() raises:
    setup_fixture()
    var conn = connect(DSN)

    var idr = execute(conn,
                      "SELECT id FROM pqmojo_test_items ORDER BY id LIMIT 1",
                      [])
    check(idr.rows() == 1, "fixture table has rows")
    var item_id = idr.col_i64(0, 0)
    idr.clear()
    var id_text = format_i64(item_id)

    comptime DETAILS_SQL = (
        "SELECT id, title, district, amount, latitude, longitude "
        + "FROM pqmojo_test_items WHERE id = $1 LIMIT 1"
    )
    var stmt = conn.prepare(DETAILS_SQL)
    var first = stmt.execute([id_text])
    var ref_title = first.col_text(0, 1)
    first.clear()

    # sanity: identical result via the plain path before timing anything
    var plain_first = execute(conn, DETAILS_SQL, [id_text])
    check(plain_first.col_text(0, 1) == ref_title,
          "plain and prepared outputs match")
    plain_first.clear()

    var best_plain_us: Float64 = -1.0
    var best_prep_us: Float64 = -1.0

    for rep in range(REPS):
        # warm both engines once so first-touch costs don't skew rep 0
        var w1 = execute(conn, DETAILS_SQL, [id_text])
        w1.clear()
        var w2 = stmt.execute([id_text])
        w2.clear()

        var t0 = now_s()
        for _ in range(ITERS):
            var rp = execute(conn, DETAILS_SQL, [id_text])
            _ = rp.col_i64(0, 0)
            rp.clear()
        var plain_us = (now_s() - t0) * 1e6 / Float64(ITERS)

        t0 = now_s()
        for _ in range(ITERS):
            var rs = stmt.execute([id_text])
            _ = rs.col_i64(0, 0)
            rs.clear()
        var prep_us = (now_s() - t0) * 1e6 / Float64(ITERS)

        if best_plain_us < 0 or plain_us < best_plain_us:
            best_plain_us = plain_us
        if best_prep_us < 0 or prep_us < best_prep_us:
            best_prep_us = prep_us
        print("[bench] rep", rep, ": plain =", plain_us, "us/op  prepared =",
              prep_us, "us/op")

    var saved = best_plain_us - best_prep_us
    var pct = saved / best_plain_us * 100.0
    print("[bench] details-shaped point lookup,", ITERS, "iters/rep,",
          "best of", REPS, "(local socket):")
    print("[bench]   plain exec_params:", best_plain_us, "us/op")
    print("[bench]   prepared execute :", best_prep_us, "us/op")
    print("[bench]   delta             : -", saved, "us/op (-", pct, "%)")

    check(best_prep_us <= best_plain_us * 3.0 + 200.0,
          "prepared path is not pathologically slower than plain")
    conn.close()
    print("TEST_PREPARED_BENCH PASS")
