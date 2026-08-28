"""BINARY result format (fmt=1): every bin_* reader against hand-crafted
values, NULL handling, exhaustive numeric bit-exactness (dual-parse text
strtod vs binary reader over EVERY distinct numeric value in the fixture
table plus synthetic edge values), int4[]/text[] with UTF8 and NULL
elements vs the text-path splitter, pipeline submit_binary, and the
30-column hot-shape SELECT compared column-by-column (binary read vs text
read) for 20 fixture rows.

Run: pixi run test
"""

from std.memory import bitcast

from tests.common import DSN, check
from tests.fixture import setup_fixture, teardown_fixture

from pqmojo import (
    PgConn,
    StmtPipeline,
    connect,
    execute,
    execute_binary,
    format_i64,
    split_postgres_int32_array,
    split_postgres_text_array,
)


comptime NEARBY_SQL = """select
 id, owner_id, latitude, longitude, title, NULL::text AS note,
        street, house_number, unit, NULL::text AS phone, NULL::text AS district,
        NULL::text AS city, NULL::text AS region, NULL::text AS postcode, tier, amount_1::float8,
        amount_2::float8, amount_3::float8, amount_4::float8, amount_5::float8,
        amount_6::float8, seen_at, tags, gallery, stars,
        NULL::text AS source_link, NULL::text AS origin, score::int4,
 null::text as client_info,
 ($1::float8 * 0 + $2::float8 * 0) as distance
from
 pqmojo_test_items
where
 is_active
 and NOT hidden
order by score DESC NULLS LAST,
 id
limit $3"""


def f64_bits(x: Float64) -> UInt64:
    return bitcast[src_dtype=DType.float64, src_width=1, dtype=DType.uint64](
        Scalar[DType.float64](x)
    )


def bits_eq(a: Float64, b: Float64) -> Bool:
    """Bit-identical Float64 comparison."""
    return f64_bits(a) == f64_bits(b)


def bits_eq_or_nan(a: Float64, b: Float64) -> Bool:
    if a != a and b != b:
        return True
    return f64_bits(a) == f64_bits(b)


def i32_list(vals: List[Int]) -> List[Int32]:
    var out = List[Int32](capacity=len(vals))
    for v in vals:
        out.append(Int32(v))
    return out^


def str_list(vals: List[String]) -> List[String]:
    var out = List[String](capacity=len(vals))
    for v in vals:
        out.append(v)
    return out^


def digits_at(s: String, off: Int, n: Int) raises -> Int:
    var b = s.as_bytes()
    var v = 0
    for i in range(n):
        var c = b[off + i]
        if c < 48 or c > 57:
            raise Error("pqmojo test: bad digit in timestamp text")
        v = v * 10 + Int(c - 48)
    return v


def days_from_civil(y_in: Int, m: Int, d: Int) -> Int:
    var y = y_in
    if m <= 2:
        y -= 1
    var era = y // 400
    if y < 0 and y % 400 != 0:
        era -= 1
    var yoe = y - era * 400
    var mp = m + 9
    if m > 2:
        mp = m - 3
    var doy = (153 * mp + 2) // 5 + d - 1
    var doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
    return era * 146097 + doe - 719468


def timestamp_text_to_micros(s: String) raises -> Int64:
    """PG ISO timestamp text (YYYY-MM-DD HH:MM:SS[.ffffff]) as int8 micros
    since 2000-01-01 — the binary timestamp wire value."""
    var b = s.as_bytes()
    var n = s.byte_length()
    if n < 19:
        raise Error("pqmojo test: timestamp text too short: " + s)
    var y = digits_at(s, 0, 4)
    if (
        b[4] != 45 or b[7] != 45 or b[10] != 32
        or b[13] != 58 or b[16] != 58
    ):
        raise Error("pqmojo test: unexpected timestamp layout: " + s)
    var mo = digits_at(s, 5, 2)
    var d = digits_at(s, 8, 2)
    var h = digits_at(s, 11, 2)
    var mi = digits_at(s, 14, 2)
    var sec = digits_at(s, 17, 2)
    var frac_micros = 0
    if n > 20 and b[19] == 46:
        var ndigits = 0
        var scale = 0
        var cursor = 20
        while cursor < n and b[cursor] >= 48 and b[cursor] <= 57:
            if ndigits < 6:
                scale = scale * 10 + Int(b[cursor] - 48)
                ndigits += 1
            cursor += 1
        while ndigits < 6:
            scale *= 10
            ndigits += 1
        frac_micros = scale
    var days = days_from_civil(y, mo, d) - days_from_civil(2000, 1, 1)
    var secs = Int64(days) * Int64(86400) + Int64(h * 3600 + mi * 60 + sec)
    return secs * Int64(1000000) + Int64(frac_micros)


def arrays_equal_i32(a: List[Int32], b: List[Int32]) -> Bool:
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if a[i] != b[i]:
            return False
    return True


def arrays_equal_text(a: List[String], b: List[String]) -> Bool:
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if a[i] != b[i]:
            return False
    return True


def test_scalar_bit_patterns(conn: PgConn) raises:
    var r = execute_binary(conn, """
        SELECT 1::int8, (-1)::int4, 3.14::float8, true::bool, false::bool,
               'héllo'::text, 1234.56::numeric
    """, [])
    check(r.bin_i64(0, 0) == 1, "bin_i64 1")
    check(r.bin_i32(0, 1) == -1, "bin_i32 -1")
    check(r.bin_f64(0, 2) == 3.14, "bin_f64 3.14")
    check(r.bin_bool(0, 3), "bin_bool true")
    check(not r.bin_bool(0, 4), "bin_bool false")
    check(r.bin_text(0, 5) == "héllo", "bin_text utf8")
    check(r.bin_text(0, 5).byte_length() == 6, "bin_text utf8 byte length")
    check(r.bin_numeric_to_f64(0, 6) == 1234.56, "bin_numeric 1234.56")
    r.clear()

    r = execute_binary(conn, """
        SELECT 9223372036854775807::int8,
               (-9223372036854775808)::int8,
               2147483647::int4, (-2147483648)::int4,
               'Infinity'::float8, '-Infinity'::float8, 'NaN'::float8,
               0::int8, -0.0::float8
    """, [])
    check(r.bin_i64(0, 0) == 9223372036854775807, "bin_i64 max")
    check(r.bin_i64(0, 1) == -9223372036854775808, "bin_i64 min")
    check(r.bin_i32(0, 2) == 2147483647, "bin_i32 max")
    check(r.bin_i32(0, 3) == -2147483648, "bin_i32 min")
    var pinf = r.bin_f64(0, 4)
    check(pinf > 0 and pinf == pinf and pinf + pinf == pinf, "bin_f64 +inf")
    check(r.bin_f64(0, 5) < 0, "bin_f64 -inf")
    check(r.bin_f64(0, 6) != r.bin_f64(0, 6), "bin_f64 nan")
    check(r.bin_i64(0, 7) == 0, "bin_i64 zero")
    check(f64_bits(r.bin_f64(0, 8)) == f64_bits(-0.0), "bin_f64 -0.0 bits")
    r.clear()

    var rt = execute(conn, """
        SELECT 'Infinity'::float8, '-Infinity'::float8, 'NaN'::float8,
               3.14::float8
    """, [])
    var rb = execute_binary(conn, """
        SELECT 'Infinity'::float8, '-Infinity'::float8, 'NaN'::float8,
               3.14::float8
    """, [])
    for c in range(4):
        check(
            bits_eq_or_nan(rt.col_f64(0, c), rb.bin_f64(0, c)),
            "float8 special bit parity col " + String(c),
        )
    rt.clear()
    rb.clear()


def test_null_handling(conn: PgConn) raises:
    var r = execute_binary(conn, """
        SELECT NULL::int8, NULL::int4, NULL::float8, NULL::bool, NULL::text,
               NULL::numeric, NULL::int4[], NULL::text[]
    """, [])
    check(r.bin_i64(0, 0) == 0, "null bin_i64 -> 0")
    check(r.bin_i32(0, 1) == 0, "null bin_i32 -> 0")
    check(r.bin_f64(0, 2) == 0.0, "null bin_f64 -> 0")
    check(not r.bin_bool(0, 3), "null bin_bool -> False")
    check(r.bin_text(0, 4) == "", "null bin_text -> empty")
    check(r.bin_numeric_to_f64(0, 5) == 0.0, "null bin_numeric -> 0")
    check(len(r.bin_i4_array(0, 6)) == 0, "null bin_i4_array -> empty")
    check(len(r.bin_text_array(0, 7)) == 0, "null bin_text_array -> empty")
    check(len(r.bin_bytes(0, 0)) == 0, "null bin_bytes -> empty span")
    for c in range(8):
        check(r.is_null(0, c), "null flag col " + String(c))
    r.clear()


def test_bin_bytes_view(conn: PgConn) raises:
    var r = execute_binary(conn, "SELECT 'héllo'::text, ''::text", [])
    var b = r.bin_bytes(0, 0)
    check(len(b) == 6, "bin_bytes length 6 for héllo")
    check(
        b[0] == 104 and b[1] == 195 and b[2] == 169 and b[5] == 111,
        "bin_bytes raw UTF8 content",
    )
    var e = r.bin_bytes(0, 1)
    check(len(e) == 0, "bin_bytes empty value")
    check(not r.is_null(0, 1), "empty text is not null")
    r.clear()


def test_arrays_vs_text_path(conn: PgConn) raises:
    var r = execute_binary(conn, """
        SELECT ARRAY[1,2,3]::int4[], ARRAY[-1,2,-3]::int4[],
               ARRAY[1,NULL,3]::int4[], ARRAY[]::int4[],
               ARRAY['a','bé']::text[],
               ARRAY['a','x,y','q"q','b\\c','']::text[],
               ARRAY['x',NULL,'z']::text[], ARRAY[]::text[]
    """, [])
    check(
        arrays_equal_i32(r.bin_i4_array(0, 0), i32_list([1, 2, 3])),
        "bin_i4_array basic",
    )
    check(
        arrays_equal_i32(
            r.bin_i4_array(0, 1), i32_list([-1, 2, -3])
        ),
        "bin_i4_array negatives",
    )
    check(
        arrays_equal_i32(r.bin_i4_array(0, 2), i32_list([1, 3])),
        "bin_i4_array NULL element dropped",
    )
    check(len(r.bin_i4_array(0, 3)) == 0, "bin_i4_array empty")
    check(
        arrays_equal_text(
            r.bin_text_array(0, 4), str_list(["a", "bé"])
        ),
        "bin_text_array utf8",
    )
    check(
        arrays_equal_text(
            r.bin_text_array(0, 5),
            str_list(["a", "x,y", "q\"q", "b\\c", ""]),
        ),
        "bin_text_array commas quotes backslash empty",
    )
    check(
        arrays_equal_text(
            r.bin_text_array(0, 6), str_list(["x", "z"])
        ),
        "bin_text_array NULL element dropped",
    )
    check(len(r.bin_text_array(0, 7)) == 0, "bin_text_array empty")

    var rt = execute(conn, """
        SELECT ARRAY[1,2,3]::int4[], ARRAY[-1,2,-3]::int4[],
               ARRAY[1,NULL,3]::int4[], ARRAY[]::int4[],
               ARRAY['a','bé']::text[],
               ARRAY['a','x,y','q"q','b\\c','']::text[],
               ARRAY['x',NULL,'z']::text[], ARRAY[]::text[]
    """, [])
    for c in range(8):
        var text_ok: Bool
        if c < 4:
            text_ok = arrays_equal_i32(
                r.bin_i4_array(0, c),
                split_postgres_int32_array(rt.col_text(0, c)),
            )
        else:
            text_ok = arrays_equal_text(
                r.bin_text_array(0, c),
                split_postgres_text_array(rt.col_text(0, c)),
            )
        check(text_ok, "array binary vs text-split parity col " + String(c))
    rt.clear()
    r.clear()


def test_numeric_synthetic(conn: PgConn) raises:
    var sql = """
        SELECT v::text, v FROM (VALUES (1234.56::numeric),
            (-987.65), (0), (0.00), (1.10), (79.2), (0.000001234), (1e-130),
            (-0.001), (999999999999999999999999.99),
            (123456789012345678901234567890),
            (7.0000000000000000000000001), (1234567890.123456789),
            (70.000000000000000000000000), ('NaN'), ('Infinity'),
            ('-Infinity'),
            (10000000000000000000000000000000000000000.000000000000000000)
        ) AS t(v) ORDER BY 2
    """
    var rt = execute(conn, sql, [])
    var rb = execute_binary(conn, sql, [])
    check(rt.rows() == rb.rows(), "numeric synthetic row counts")
    var n = 0
    for row in range(rt.rows()):
        var from_text = rt.col_f64(row, 0)
        var from_binary = rb.bin_numeric_to_f64(row, 1)
        check(
            bits_eq_or_nan(from_text, from_binary),
            "numeric bit-exactness synthetic row " + String(row)
            + " value=" + rt.col_text(row, 0),
        )
        n += 1
    rt.clear()
    rb.clear()
    print("numeric synthetic dual-parse verified:", n, "values")


def test_numeric_exhaustive_fixture(conn: PgConn) raises:
    var sql = """
        SELECT d::text, d FROM (
            SELECT amount_1 AS d FROM pqmojo_test_items
            UNION SELECT amount_2 FROM pqmojo_test_items
            UNION SELECT amount_3 FROM pqmojo_test_items
            UNION SELECT amount_4 FROM pqmojo_test_items
            UNION SELECT amount_5 FROM pqmojo_test_items
            UNION SELECT amount_6 FROM pqmojo_test_items
        ) t WHERE d IS NOT NULL ORDER BY 1
    """
    var rt = execute(conn, sql, [])
    var rb = execute_binary(conn, sql, [])
    check(rt.rows() == rb.rows(), "numeric fixture row counts")
    var n = 0
    for row in range(rt.rows()):
        check(not rb.is_null(row, 1), "fixture numeric no unexpected null")
        var from_text = rt.col_f64(row, 0)
        var from_binary = rb.bin_numeric_to_f64(row, 1)
        check(
            bits_eq(from_text, from_binary),
            "numeric bit-exactness fixture row " + String(row)
            + " value=" + rt.col_text(row, 0),
        )
        n += 1
    rt.clear()
    rb.clear()
    print(
        "numeric FIXTURE dual-parse verified:", n,
        "distinct values, ALL bit-identical to strtod",
    )


def test_strict_errors(conn: PgConn) raises:
    var raised = False
    try:
        var r = execute_binary(conn, "SELECT 1/0", [])
        _ = r
    except:
        raised = True
    check(raised, "execute_binary strict on SQL error")

    raised = False
    var closed = connect(DSN)
    closed.close()
    try:
        var r2 = closed.execute_binary("SELECT 1", [])
        _ = r2
    except:
        raised = True
    check(raised, "execute_binary raises on closed conn")


def test_pipeline_binary(conn: PgConn) raises:
    var other = connect(DSN)
    other.prepare_named("pqb_test_binary", "SELECT $1::int8, $2::text")
    var conns = List[PgConn](capacity=1)
    conns.append(other^)
    var pipe = StmtPipeline(conns^)
    var rid = pipe.submit_binary(
        "pqb_test_binary", str_list([format_i64(42), "ok"])
    )
    var pr = pipe.collect()
    check(pr.request_id == rid, "pipeline binary request id")
    check(pr.result.bin_i64(0, 0) == 42, "pipeline binary i64")
    check(pr.result.bin_text(0, 1) == "ok", "pipeline binary text")
    pr.result.clear()
    var drained = pipe.drain()
    for c in range(len(drained)):
        drained[c].close()
    print("pipeline submit_binary + collect verified")


def test_nearby_round_trip(conn: PgConn) raises:
    var params = str_list(["0", "0", "20"])
    var rt = execute(conn, NEARBY_SQL, params)
    var rb = execute_binary(conn, NEARBY_SQL, params)
    check(rt.cols() == 30, "nearby 30 columns")
    check(rt.rows() == rb.rows(), "nearby row counts")
    var rows = rt.rows()
    var cells = 0
    for row in range(rows):
        for c in range(30):
            check(
                rt.is_null(row, c) == rb.is_null(row, c),
                "nearby null parity row " + String(row) + " col " + String(c),
            )
            cells += 1
        check(rb.bin_i64(row, 0) == rt.col_i64(row, 0),
              "nearby id row " + String(row))
        check(rb.bin_i64(row, 1) == rt.col_i64(row, 1),
              "nearby advertiser_id row " + String(row))
        check(
            bits_eq(rb.bin_f64(row, 2), rt.col_f64(row, 2)),
            "nearby latitude row " + String(row),
        )
        check(
            bits_eq(rb.bin_f64(row, 3), rt.col_f64(row, 3)),
            "nearby longitude row " + String(row),
        )
        check(rb.bin_text(row, 4) == rt.col_text(row, 4),
              "nearby title row " + String(row))
        for c in range(5, 14):
            if c == 7:
                continue
            check(
                rb.bin_text(row, c) == rt.col_text(row, c),
                "nearby text col " + String(c) + " row " + String(row),
            )
        check(
            rb.bin_i32(row, 7) == rt.int32(row, 7),
            "nearby house_number row " + String(row),
        )
        check(rb.bin_text(row, 14) == rt.col_text(row, 14),
              "nearby period row " + String(row))
        for c in range(15, 21):
            check(
                bits_eq(rb.bin_f64(row, c), rt.col_f64(row, c)),
                "nearby amount col " + String(c) + " row " + String(row),
            )
        if not rb.is_null(row, 21):
            var micros = rb.bin_i64(row, 21)
            var from_text = timestamp_text_to_micros(rt.col_text(row, 21))
            check(
                micros == from_text,
                "nearby seen_at micros row " + String(row) + " text="
                + rt.col_text(row, 21),
            )
        check(
            arrays_equal_i32(
                rb.bin_i4_array(row, 22),
                split_postgres_int32_array(rt.col_text(row, 22)),
            ),
            "nearby filters_array row " + String(row),
        )
        check(
            arrays_equal_text(
                rb.bin_text_array(row, 23),
                split_postgres_text_array(rt.col_text(row, 23)),
            ),
            "nearby photos_array row " + String(row),
        )
        check(
            rb.bin_i32(row, 24) == rt.int32(row, 24),
            "nearby review_rate row " + String(row),
        )
        check(
            rb.bin_i32(row, 27) == rt.int32(row, 27),
            "nearby quality_score row " + String(row),
        )
        check(
            bits_eq_or_nan(rb.bin_f64(row, 29), rt.col_f64(row, 29)),
            "nearby distance row " + String(row),
        )
    rt.clear()
    rb.clear()
    print(
        "nearby 30-col round trip verified:", rows, "rows,", cells,
        "cells, every column binary-read == text-read",
    )


def main() raises:
    setup_fixture()
    var conn = connect(DSN)
    test_scalar_bit_patterns(conn)
    test_null_handling(conn)
    test_bin_bytes_view(conn)
    test_arrays_vs_text_path(conn)
    test_numeric_synthetic(conn)
    test_numeric_exhaustive_fixture(conn)
    test_strict_errors(conn)
    test_pipeline_binary(conn)
    test_nearby_round_trip(conn)
    conn.close()
    teardown_fixture()
    print("TEST_BINARY PASS")
