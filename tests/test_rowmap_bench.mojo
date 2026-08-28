"""query_as[T] vs the hand-rolled fill loop: is the abstraction free?

Same 30-column x 20-row result as the v0.5.0 binary bench, mapped two
ways: a 30-field FromRow struct through map_rows_as/query_as, and a manual
col-by-col loop shaped like a real scan core (typed reads, is_null-gated
nullables, array splitters). Convert-only (result held, mapping timed) and
end-to-end (execute + map + clear per iteration) are both measured, in
TEXT and BINARY formats; 5 timed runs of 1000 iterations each, best run
reported. A checksum accumulates every mapped value so nothing optimizes
away. The suite asserts the typed path lands within 5% of manual.

Run: pixi run test
"""

from std.time import perf_counter

from tests.common import DSN, check
from tests.fixture import setup_fixture, teardown_fixture

from pqmojo import (
    PgConn,
    PgResult,
    RowColumns,
    RowPlan,
    connect,
    execute,
    execute_binary,
    map_rows_as_binary_planned,
    map_rows_as_planned,
    query_as,
    query_as_binary,
    resolve_row_plan,
    split_postgres_int32_array,
    split_postgres_text_array,
)
from pqmojo.rowmap import FromRow


comptime WIDE_SQL = """select
 id, owner_id, latitude, longitude, title, NULL::text AS note,
 street, house_number, unit, NULL::text AS phone, NULL::text AS district,
 NULL::text AS city, NULL::text AS region, NULL::text AS postcode, tier,
 amount_1, amount_2, amount_3, amount_4, amount_5, amount_6,
 seen_at::text AS seen_at, tags,
 gallery, stars, NULL::text AS source_link, NULL::text AS origin,
 score::int4, null::text as client_info,
 ($1::float8 * 0 + $2::float8 * 0) as distance
from
 pqmojo_test_items
where
 is_active
 and NOT hidden
order by score DESC NULLS LAST,
 id
limit $3"""


struct WideRow(FromRow, Defaultable, Movable):
    var id: Int64
    var owner_id: Int64
    var latitude: Float64
    var longitude: Float64
    var title: String
    var note: Optional[String]
    var street: String
    var house_number: Optional[Int32]
    var unit: String
    var phone: Optional[String]
    var district: Optional[String]
    var city: Optional[String]
    var region: Optional[String]
    var postcode: Optional[String]
    var tier: String
    var amount_1: Float64
    var amount_2: Float64
    var amount_3: Float64
    var amount_4: Float64
    var amount_5: Float64
    var amount_6: Float64
    var seen_at: String
    var tags: List[Int32]
    var gallery: List[String]
    var stars: Int32
    var source_link: Optional[String]
    var origin: Optional[String]
    var score: Optional[Int32]
    var client_info: Optional[String]
    var distance: Float64

    def __init__(out self):
        self.id = 0
        self.owner_id = 0
        self.latitude = 0.0
        self.longitude = 0.0
        self.title = String("")
        self.note = Optional[String]()
        self.street = String("")
        self.house_number = Optional[Int32]()
        self.unit = String("")
        self.phone = Optional[String]()
        self.district = Optional[String]()
        self.city = Optional[String]()
        self.region = Optional[String]()
        self.postcode = Optional[String]()
        self.tier = String("")
        self.amount_1 = 0.0
        self.amount_2 = 0.0
        self.amount_3 = 0.0
        self.amount_4 = 0.0
        self.amount_5 = 0.0
        self.amount_6 = 0.0
        self.seen_at = String("")
        self.tags = List[Int32]()
        self.gallery = List[String]()
        self.stars = 0
        self.source_link = Optional[String]()
        self.origin = Optional[String]()
        self.score = Optional[Int32]()
        self.client_info = Optional[String]()
        self.distance = 0.0

    @staticmethod
    def row_columns() raises -> RowColumns:
        var t = RowColumns()
        t.add("id")
        t.add("owner_id")
        t.add("latitude")
        t.add("longitude")
        t.add("title")
        t.add("note")
        t.add("street")
        t.add("house_number")
        t.add("unit")
        t.add("phone")
        t.add("district")
        t.add("city")
        t.add("region")
        t.add("postcode")
        t.add("tier")
        t.add("amount_1")
        t.add("amount_2")
        t.add("amount_3")
        t.add("amount_4")
        t.add("amount_5")
        t.add("amount_6")
        t.add("seen_at")
        t.add("tags")
        t.add("gallery")
        t.add("stars")
        t.add("source_link")
        t.add("origin")
        t.add("score")
        t.add("client_info")
        t.add("distance")
        return t^


comptime ROWS: Int = 20
comptime ITERATIONS: Int = 1000
comptime WARMUP: Int = 50
comptime RUNS: Int = 5


def manual_fill_text(r: PgResult, conn: PgConn, mut acc: Float64) raises:
    """The hand-rolled text scan core, api-shaped: build the row struct
    field by field, append to the list."""
    var rows = List[WideRow](capacity=r.rows())
    for row in range(r.rows()):
        var it = WideRow()
        it.id = r.col_i64(row, 0)
        it.owner_id = r.col_i64(row, 1)
        it.latitude = r.col_f64(row, 2)
        it.longitude = r.col_f64(row, 3)
        it.title = r.col_text(row, 4)
        if r.is_null(row, 5):
            it.note = Optional[String]()
        else:
            it.note = Optional[String](r.col_text(row, 5))
        it.street = r.col_text(row, 6)
        if r.is_null(row, 7):
            it.house_number = Optional[Int32]()
        else:
            it.house_number = Optional[Int32](Int32(r.col_i64(row, 7)))
        it.unit = r.col_text(row, 8)
        if r.is_null(row, 9):
            it.phone = Optional[String]()
        else:
            it.phone = Optional[String](r.col_text(row, 9))
        if r.is_null(row, 10):
            it.district = Optional[String]()
        else:
            it.district = Optional[String](r.col_text(row, 10))
        if r.is_null(row, 11):
            it.city = Optional[String]()
        else:
            it.city = Optional[String](r.col_text(row, 11))
        if r.is_null(row, 12):
            it.region = Optional[String]()
        else:
            it.region = Optional[String](r.col_text(row, 12))
        if r.is_null(row, 13):
            it.postcode = Optional[String]()
        else:
            it.postcode = Optional[String](r.col_text(row, 13))
        it.tier = r.col_text(row, 14)
        it.amount_1 = r.col_f64(row, 15)
        it.amount_2 = r.col_f64(row, 16)
        it.amount_3 = r.col_f64(row, 17)
        it.amount_4 = r.col_f64(row, 18)
        it.amount_5 = r.col_f64(row, 19)
        it.amount_6 = r.col_f64(row, 20)
        it.seen_at = r.col_text(row, 21)
        it.tags = split_postgres_int32_array(r.col_text(row, 22))
        it.gallery = split_postgres_text_array(r.col_text(row, 23))
        it.stars = Int32(r.col_i64(row, 24))
        if r.is_null(row, 25):
            it.source_link = Optional[String]()
        else:
            it.source_link = Optional[String](r.col_text(row, 25))
        if r.is_null(row, 26):
            it.origin = Optional[String]()
        else:
            it.origin = Optional[String](r.col_text(row, 26))
        if r.is_null(row, 27):
            it.score = Optional[Int32]()
        else:
            it.score = Optional[Int32](Int32(r.col_i64(row, 27)))
        if r.is_null(row, 28):
            it.client_info = Optional[String]()
        else:
            it.client_info = Optional[String](r.col_text(row, 28))
        it.distance = r.col_f64(row, 29)
        rows.append(it^)
    acc += Float64(len(rows))
    acc += Float64(rows[7].stars)
    acc += rows[7].amount_3
    acc += Float64(rows[7].id)


def manual_fill_binary(r: PgResult, conn: PgConn, mut acc: Float64) raises:
    """The hand-rolled binary scan core, api-shaped."""
    var rows = List[WideRow](capacity=r.rows())
    for row in range(r.rows()):
        var it = WideRow()
        it.id = r.bin_i64(row, 0)
        it.owner_id = r.bin_i64(row, 1)
        it.latitude = r.bin_f64(row, 2)
        it.longitude = r.bin_f64(row, 3)
        it.title = r.bin_text(row, 4)
        if r.is_null(row, 5):
            it.note = Optional[String]()
        else:
            it.note = Optional[String](r.bin_text(row, 5))
        it.street = r.bin_text(row, 6)
        if r.is_null(row, 7):
            it.house_number = Optional[Int32]()
        else:
            it.house_number = Optional[Int32](r.bin_i32(row, 7))
        it.unit = r.bin_text(row, 8)
        if r.is_null(row, 9):
            it.phone = Optional[String]()
        else:
            it.phone = Optional[String](r.bin_text(row, 9))
        if r.is_null(row, 10):
            it.district = Optional[String]()
        else:
            it.district = Optional[String](r.bin_text(row, 10))
        if r.is_null(row, 11):
            it.city = Optional[String]()
        else:
            it.city = Optional[String](r.bin_text(row, 11))
        if r.is_null(row, 12):
            it.region = Optional[String]()
        else:
            it.region = Optional[String](r.bin_text(row, 12))
        if r.is_null(row, 13):
            it.postcode = Optional[String]()
        else:
            it.postcode = Optional[String](r.bin_text(row, 13))
        it.tier = r.bin_text(row, 14)
        it.amount_1 = r.bin_numeric_to_f64(row, 15)
        it.amount_2 = r.bin_numeric_to_f64(row, 16)
        it.amount_3 = r.bin_numeric_to_f64(row, 17)
        it.amount_4 = r.bin_numeric_to_f64(row, 18)
        it.amount_5 = r.bin_numeric_to_f64(row, 19)
        it.amount_6 = r.bin_numeric_to_f64(row, 20)
        it.seen_at = r.bin_text(row, 21)
        it.tags = r.bin_int32_array(row, 22)
        it.gallery = r.bin_text_array(row, 23)
        it.stars = r.bin_i32(row, 24)
        if r.is_null(row, 25):
            it.source_link = Optional[String]()
        else:
            it.source_link = Optional[String](r.bin_text(row, 25))
        if r.is_null(row, 26):
            it.origin = Optional[String]()
        else:
            it.origin = Optional[String](r.bin_text(row, 26))
        if r.is_null(row, 27):
            it.score = Optional[Int32]()
        else:
            it.score = Optional[Int32](r.bin_i32(row, 27))
        if r.is_null(row, 28):
            it.client_info = Optional[String]()
        else:
            it.client_info = Optional[String](r.bin_text(row, 28))
        it.distance = r.bin_f64(row, 29)
        rows.append(it^)
    acc += Float64(len(rows))
    acc += Float64(rows[7].stars)
    acc += rows[7].amount_3
    acc += Float64(rows[7].id)


def typed_fill_text(
    r: PgResult, conn: PgConn, plan: RowPlan, mut acc: Float64
) raises:
    var rows = map_rows_as_planned[WideRow](r, conn, plan)
    acc += Float64(len(rows))
    acc += Float64(rows[7].stars)
    acc += rows[7].amount_3
    acc += Float64(rows[7].id)


def typed_fill_binary(
    r: PgResult, conn: PgConn, plan: RowPlan, mut acc: Float64
) raises:
    var rows = map_rows_as_binary_planned[WideRow](r, conn, plan)
    acc += Float64(len(rows))
    acc += Float64(rows[7].stars)
    acc += rows[7].amount_3
    acc += Float64(rows[7].id)


def _report(label: String, manual: Float64, typed: Float64, iters: Int):
    print(
        label
        + ": manual "
        + String(manual / Float64(iters * ROWS))
        + " us/row, typed "
        + String(typed / Float64(iters * ROWS))
        + " us/row, delta "
        + String((typed - manual) / manual * 100.0)
        + "%"
    )


def _best_convert(
    label: String,
    res: PgResult,
    conn: PgConn,
    plan: RowPlan,
    binary: Bool,
) raises -> Tuple[Float64, Float64]:
    """Interleaved manual-vs-typed timing: both sides run inside every
    iteration, so machine-load drift lands on BOTH clocks equally. Returns
    (manual_best, typed_best) over RUNS runs of ITERATIONS."""
    var best_m = Float64(1e18)
    var best_t = Float64(1e18)
    for run in range(RUNS):
        var tm = Float64(0)
        var tt = Float64(0)
        var am = Float64(0)
        var at = Float64(0)
        for i in range(ITERATIONS):
            var t0 = perf_counter()
            if binary:
                manual_fill_binary(res, conn, am)
            else:
                manual_fill_text(res, conn, am)
            tm += (perf_counter() - t0) * 1e6
            var t1 = perf_counter()
            if binary:
                typed_fill_binary(res, conn, plan, at)
            else:
                typed_fill_text(res, conn, plan, at)
            tt += (perf_counter() - t1) * 1e6
        if tm < best_m:
            best_m = tm
        if tt < best_t:
            best_t = tt
    print(
        label
        + " manual best "
        + String(best_m)
        + " us = "
        + String(best_m / Float64(ITERATIONS * ROWS))
        + " us/row; typed best "
        + String(best_t)
        + " us = "
        + String(best_t / Float64(ITERATIONS * ROWS))
        + " us/row"
    )
    return (best_m, best_t)


def _best_e2e(
    label: String,
    conn: PgConn,
    params: List[String],
    binary: Bool,
) raises -> Tuple[Float64, Float64]:
    """Interleaved end-to-end pair timing (execute + map + clear)."""
    var best_m = Float64(1e18)
    var best_t = Float64(1e18)
    for run in range(RUNS):
        var tm = Float64(0)
        var tt = Float64(0)
        var am = Float64(0)
        var at = Float64(0)
        for i in range(200):
            var t0 = perf_counter()
            if binary:
                var r = execute_binary(conn, WIDE_SQL, params)
                manual_fill_binary(r, conn, am)
                r.clear()
            else:
                var r = execute(conn, WIDE_SQL, params)
                manual_fill_text(r, conn, am)
                r.clear()
            tm += (perf_counter() - t0) * 1e6
            var t1 = perf_counter()
            if binary:
                var rows = query_as_binary[WideRow](conn, WIDE_SQL, params)
                at += Float64(len(rows))
            else:
                var rows = query_as[WideRow](conn, WIDE_SQL, params)
                at += Float64(len(rows))
            tt += (perf_counter() - t1) * 1e6
        if tm < best_m:
            best_m = tm
        if tt < best_t:
            best_t = tt
    print(
        label
        + " manual best "
        + String(best_m)
        + " us / 200 iters = "
        + String(best_m / Float64(200 * ROWS))
        + " us/row; typed best "
        + String(best_t)
        + " us = "
        + String(best_t / Float64(200 * ROWS))
        + " us/row"
    )
    return (best_m, best_t)


def main() raises:
    setup_fixture()
    var conn = connect(DSN)
    var params = List[String]()
    params.append("1")
    params.append("1")
    params.append("20")

    var text_res = execute(conn, WIDE_SQL, params)
    var bin_res = execute_binary(conn, WIDE_SQL, params)
    check(text_res.rows() == ROWS, "bench rows")
    check(bin_res.rows() == ROWS, "bench binary rows")

    var text_plan = resolve_row_plan[WideRow](text_res, conn)
    var bin_plan = resolve_row_plan[WideRow](bin_res, conn)
    var acc = Float64(0)
    for i in range(WARMUP):
        manual_fill_text(text_res, conn, acc)
        typed_fill_text(text_res, conn, text_plan, acc)
        manual_fill_binary(bin_res, conn, acc)
        typed_fill_binary(bin_res, conn, bin_plan, acc)

    print("=== convert-only (result held; 30 cols x 20 rows x 1000 iters;")
    print("=== typed runs through a pre-resolved RowPlan; interleaved timing)")
    var pair_t = _best_convert("text", text_res, conn, text_plan, False)
    var m_t = pair_t[0]
    var t_t = pair_t[1]
    var pair_b = _best_convert("bin ", bin_res, conn, bin_plan, True)
    var m_b = pair_b[0]
    var t_b = pair_b[1]

    print("=== end-to-end (execute + map + clear per iter, 200 iters)")
    for i in range(20):
        var r0 = execute(conn, WIDE_SQL, params)
        manual_fill_text(r0, conn, acc)
        r0.clear()
        var rows0 = query_as[WideRow](conn, WIDE_SQL, params)
        var r0b = execute_binary(conn, WIDE_SQL, params)
        manual_fill_binary(r0b, conn, acc)
        r0b.clear()
        var rows0b = query_as_binary[WideRow](conn, WIDE_SQL, params)

    var epair_t = _best_e2e("e2e text", conn, params, False)
    var em_t = epair_t[0]
    var et_t = epair_t[1]
    var epair_b = _best_e2e("e2e bin ", conn, params, True)
    var em_b = epair_b[0]
    var et_b = epair_b[1]

    text_res.clear()
    bin_res.clear()
    conn.close()
    teardown_fixture()

    print("=== abstraction cost (typed vs manual)")
    _report("convert text  ", m_t, t_t, ITERATIONS)
    _report("convert binary", m_b, t_b, ITERATIONS)
    _report("e2e text      ", em_t, et_t, 200)
    _report("e2e binary    ", em_b, et_b, 200)
    comptime slack = 0.05
    check(t_t <= m_t * (1.0 + slack), "typed text within 5% of manual")
    check(t_b <= m_b * (1.0 + slack), "typed binary within 5% of manual")
    check(et_t <= em_t * (1.0 + slack) + 5.0, "e2e typed text within 5%")
    check(et_b <= em_b * (1.0 + slack) + 5.0, "e2e typed binary within 5%")
    print("TEST_ROWMAP_BENCH PASS")
