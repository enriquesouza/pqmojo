"""BINARY vs TEXT recv+convert CPU on the api's real 30-column nearby SELECT.

Two measurements, 20 real rows x 30 columns, 1000 iterations each:

1. convert-only — both result sets fetched ONCE, then the client-side
   conversion loop (col_* text scanners vs bin_* readers) is what's timed.
   This isolates the parse cost v0.5.0 exists to remove.
2. end-to-end — full prepared Bind/Execute round trip + convert + clear,
   text through execute_prepared, binary through StmtPipeline.submit_binary
   + collect (the shipped paths).

Checksums are printed so nothing can be optimized away.

Run: pixi run test
"""

from std.time import perf_counter

from tests.common import DSN, check

from pqmojo import (
    PgConn,
    PgResult,
    StmtPipeline,
    connect,
    execute,
    execute_binary,
    execute_prepared,
    split_postgres_int32_array,
    split_postgres_text_array,
)


comptime NEARBY_SQL = """select
 id, advertiser_id, latitude, longitude, title, NULL::text AS description,
        street, house_number, complement, NULL::text AS contact_phone, NULL::text AS neighborhood,
        NULL::text AS city, NULL::text AS state, NULL::text AS zip_code, period, daily_price::float8,
        weekly_price::float8, monthly_price::float8, yearly_price::float8, hourly_price::float8,
        period_price::float8, data_anuncio, filters_array, photos_array, review_rate,
        NULL::text AS source_url, NULL::text AS source, quality_score::int4,
 null::text as client_info,
 ($1::float8 * 0 + $2::float8 * 0) as distance
from
 listing_active
where
 is_active
 and NOT provider_hidden
order by quality_score DESC NULLS LAST,
 id
limit $3"""

comptime ROWS: Int = 20
comptime ITERATIONS: Int = 1000
comptime WARMUP: Int = 50


def convert_text(r: PgResult, mut acc: Float64) raises:
    """The api's text-path conversion of one 30-col row, mirrored."""
    for row in range(r.rows()):
        acc += Float64(r.col_i64(row, 0))
        acc += Float64(r.col_i64(row, 1))
        acc += Float64(r.int32(row, 7))
        acc += Float64(r.int32(row, 24))
        acc += Float64(r.int32(row, 27))
        for c in range(2, 4):
            acc += r.col_f64(row, c)
        for c in range(15, 21):
            acc += r.col_f64(row, c)
        acc += r.col_f64(row, 29)
        for c in range(4, 29):
            if c == 7 or (c >= 15 and c <= 20) or c == 24 or c == 27:
                continue
            acc += Float64(r.col_text(row, c).byte_length())
        var filters = split_postgres_int32_array(r.col_text(row, 22))
        for i in range(len(filters)):
            acc += Float64(filters[i])
        var photos = split_postgres_text_array(r.col_text(row, 23))
        for i in range(len(photos)):
            acc += Float64(photos[i].byte_length())


def convert_binary(r: PgResult, mut acc: Float64) raises:
    """The binary-path conversion of one 30-col row: same cells, bin_*."""
    for row in range(r.rows()):
        acc += Float64(r.bin_i64(row, 0))
        acc += Float64(r.bin_i64(row, 1))
        acc += Float64(r.bin_i32(row, 7))
        acc += Float64(r.bin_i32(row, 24))
        acc += Float64(r.bin_i32(row, 27))
        for c in range(2, 4):
            acc += r.bin_f64(row, c)
        for c in range(15, 21):
            acc += r.bin_f64(row, c)
        acc += r.bin_f64(row, 29)
        for c in range(4, 29):
            if c == 7 or (c >= 15 and c <= 20) or c == 24 or c == 27:
                continue
            acc += Float64(r.bin_text(row, c).byte_length())
        var filters = r.bin_i4_array(row, 22)
        for i in range(len(filters)):
            acc += Float64(filters[i])
        var photos = r.bin_text_array(row, 23)
        for i in range(len(photos)):
            acc += Float64(photos[i].byte_length())


def bench_convert_only(conn: PgConn) raises -> Float64:
    var params: List[String] = ["0", "0", String(ROWS)]
    var rt = execute(conn, NEARBY_SQL, params)
    var rb = execute_binary(conn, NEARBY_SQL, params)
    check(rt.rows() == ROWS and rb.rows() == ROWS, "bench fetched 20 rows")

    var warm = 0.0
    for _ in range(WARMUP):
        convert_text(rt, warm)
        convert_binary(rb, warm)

    var acc = 0.0
    var t0 = perf_counter()
    for _ in range(ITERATIONS):
        convert_text(rt, acc)
    var text_ms = (perf_counter() - t0) * 1000.0

    t0 = perf_counter()
    for _ in range(ITERATIONS):
        convert_binary(rb, acc)
    var bin_ms = (perf_counter() - t0) * 1000.0

    var text_bytes = 0
    var bin_bytes = 0
    for row in range(rt.rows()):
        for c in range(30):
            text_bytes += rt.col_text(row, c).byte_length()
            bin_bytes += len(rb.bin_bytes(row, c))

    rt.clear()
    rb.clear()

    var per_row_text = text_ms * 1000.0 / Float64(ITERATIONS * ROWS)
    var per_row_bin = bin_ms * 1000.0 / Float64(ITERATIONS * ROWS)
    print("[convert-only] text   :", text_ms, "ms total |",
          per_row_text, "us/row")
    print("[convert-only] binary :", bin_ms, "ms total |",
          per_row_bin, "us/row")
    print("[convert-only] speedup:", text_ms / bin_ms, "x")
    print("[wire bytes/row] text :", Float64(text_bytes) / Float64(ROWS),
          "| binary:", Float64(bin_bytes) / Float64(ROWS))
    return acc


def bench_end_to_end(mut conn: PgConn) raises -> Float64:
    conn.prepare_named("pqb_bench_text", NEARBY_SQL)
    var params: List[String] = ["0", "0", String(ROWS)]

    var warm = 0.0
    for _ in range(WARMUP):
        var wr = execute_prepared(conn, "pqb_bench_text", params)
        convert_text(wr, warm)
        wr.clear()

    var acc = 0.0
    var t0 = perf_counter()
    for _ in range(ITERATIONS):
        var r = execute_prepared(conn, "pqb_bench_text", params)
        convert_text(r, acc)
        r.clear()
    var text_ms = (perf_counter() - t0) * 1000.0

    var other = connect(DSN)
    other.prepare_named("pqb_bench_bin", NEARBY_SQL)
    var conns = List[PgConn](capacity=1)
    conns.append(other^)
    var pipe = StmtPipeline(conns^)
    for _ in range(WARMUP):
        var rid = pipe.submit_binary("pqb_bench_bin", params)
        var wpr = pipe.collect()
        check(wpr.request_id == rid, "warmup request id")
        convert_binary(wpr.result, warm)
        wpr.result.clear()

    t0 = perf_counter()
    for _ in range(ITERATIONS):
        var rid = pipe.submit_binary("pqb_bench_bin", params)
        var pr = pipe.collect()
        check(pr.request_id == rid, "request id")
        convert_binary(pr.result, acc)
        pr.result.clear()
    var bin_ms = (perf_counter() - t0) * 1000.0

    var drained = pipe.drain()
    for c in range(len(drained)):
        drained[c].close()

    var per_row_text = text_ms * 1000.0 / Float64(ITERATIONS * ROWS)
    var per_row_bin = bin_ms * 1000.0 / Float64(ITERATIONS * ROWS)
    print("[end-to-end]   text   :", text_ms, "ms total |",
          per_row_text, "us/row")
    print("[end-to-end]   binary :", bin_ms, "ms total |",
          per_row_bin, "us/row")
    print("[end-to-end]   speedup:", text_ms / bin_ms, "x")
    return acc


def main() raises:
    var conn = connect(DSN)
    var c1 = bench_convert_only(conn)
    var c2 = bench_end_to_end(conn)
    conn.close()
    print("checksums (kept alive):", c1, c2)
    print("TEST_BINARY_BENCH PASS")
