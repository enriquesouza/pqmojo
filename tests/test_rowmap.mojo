"""Typed row mapping (query_as / FromRow) against the neutral fixture.

Matrix: every fixture type round-trips through a declared struct in BOTH
result formats; named and positional (and mixed) resolution agree; binary
and text produce identical structs field by field; query_one_as returns
absent on empty sets; a missing column raises naming the struct, the field
and the expected column; prepared statements (conn and pool checkout) map
identically to the ad-hoc path.
"""

from tests.common import DSN, check, check_raised
from tests.fixture import setup_fixture, teardown_fixture

from pqmojo import (
    ConnectionPool,
    PgConn,
    PoolConfig,
    RowColumns,
    RowPlan,
    connect,
    execute,
    map_rows_as_planned,
    query_as,
    query_as_binary,
    query_one_as,
    query_one_as_binary,
    query_prepared_as,
    resolve_row_plan,
)
from pqmojo.rowmap import FromRow


struct ItemRow(FromRow, Defaultable, Copyable, Movable):
    var id: Int64
    var owner_id: Int64
    var latitude: Float64
    var longitude: Float64
    var title: String
    var house_number: Optional[Int32]
    var amount: Optional[Float64]
    var amount_1: Float64
    var stars: Int32
    var score: Optional[Int32]
    var is_active: Bool
    var hidden: Bool
    var tags: Optional[List[Int32]]
    var gallery: Optional[List[String]]
    var tiers: List[String]

    def __init__(out self):
        self.id = 0
        self.owner_id = 0
        self.latitude = 0.0
        self.longitude = 0.0
        self.title = String("")
        self.house_number = Optional[Int32]()
        self.amount = Optional[Float64]()
        self.amount_1 = 0.0
        self.stars = 0
        self.score = Optional[Int32]()
        self.is_active = False
        self.hidden = False
        self.tags = Optional[List[Int32]]()
        self.gallery = Optional[List[String]]()
        self.tiers = List[String]()

    @staticmethod
    def row_columns() raises -> RowColumns:
        var t = RowColumns()
        t.add("id")
        t.add("owner_id")
        t.add("latitude")
        t.add("longitude")
        t.add("title")
        t.add("house_number")
        t.add("amount")
        t.add("amount_1")
        t.add("stars")
        t.add("score")
        t.add("is_active")
        t.add("hidden")
        t.add("tags")
        t.add("gallery")
        t.add("tiers")
        return t^


struct PairRow(FromRow, Defaultable, Copyable, Movable):
    var ident: Int64
    var label: String
    var pair_ids: List[Int64]

    def __init__(out self):
        self.ident = 0
        self.label = String("")
        self.pair_ids = List[Int64]()

    @staticmethod
    def row_columns() raises -> RowColumns:
        var t = RowColumns()
        t.add("")
        t.add("")
        t.add("pair_ids")
        return t^


struct MixedRow(FromRow, Defaultable, Copyable, Movable):
    var id: Int64
    var house_number: Optional[Int32]
    var title: String

    def __init__(out self):
        self.id = 0
        self.house_number = Optional[Int32]()
        self.title = String("")

    @staticmethod
    def row_columns() raises -> RowColumns:
        var t = RowColumns()
        t.add("")
        t.add("house_number")
        t.add("TiTlE")
        return t^


struct BrokenRow(FromRow, Defaultable, Copyable, Movable):
    var id: Int64
    var nope: Int64

    def __init__(out self):
        self.id = 0
        self.nope = 0

    @staticmethod
    def row_columns() raises -> RowColumns:
        var t = RowColumns()
        t.add("id")
        t.add("no_such_column")
        return t^


comptime ITEM_SQL = """select id, owner_id, latitude, longitude, title,
 house_number, amount, amount_1, stars, score, is_active, hidden, tags,
 gallery, tiers from pqmojo_test_items order by id"""


def present[T: Copyable & Movable](o: Optional[T]) -> Bool:
    if o:
        return True
    return False


def floats_agree(a: Float64, b: Float64) -> Bool:
    """NaN/Inf-aware equality: compare rendered forms (both formats decode
    specials through identical paths, so identical bit patterns render
    identically)."""
    return String(a) == String(b)


def check_item_row(row: ItemRow, idx: Int, label: String) raises:
    check(row.id == Int64(idx), label + " id")
    check(row.owner_id == Int64(900 + (idx * 11) % 500), label + " owner_id")
    check(row.title == "Item " + String(idx), label + " title")
    if idx % 5 == 3:
        check(not present(row.house_number), label + " house_number null")
    else:
        check(present(row.house_number), label + " house_number present")
        check(
            Int(row.house_number.value()) == 100 + (idx * 13) % 800,
            label + " house_number value",
        )
    if idx % 3 == 0:
        check(not present(row.amount), label + " amount null")
    else:
        check(present(row.amount), label + " amount present")
        check(
            floats_agree(row.amount.value(), Float64(10 + idx)),
            label + " amount value",
        )
    check(Int(row.stars) == idx % 6, label + " stars")
    if idx % 4 == 1:
        check(not present(row.score), label + " score null")
    else:
        check(present(row.score), label + " score present")
        check(Int(row.score.value()) == (idx * 17) % 90, label + " score value")
    check(row.is_active, label + " is_active")
    check(not row.hidden, label + " hidden")
    var k = idx % 8
    if k == 1:
        check(not present(row.tags), label + " tags null")
    else:
        check(present(row.tags), label + " tags present")
    if k == 1:
        check(not present(row.gallery), label + " gallery null")
    else:
        check(present(row.gallery), label + " gallery present")
    check(len(row.tiers) > 0, label + " tiers nonempty")


def test_round_trip_text(conn: PgConn) raises:
    var rows = query_as[ItemRow](conn, ITEM_SQL, [])
    check(len(rows) == 24, "text row count")
    for i in range(len(rows)):
        check_item_row(rows[i], i, "text[" + String(i) + "]")
    var total = 0
    for i in range(len(rows)):
        total += Int(rows[i].id)
    check(total == 276, "text id sum")


def test_binary_equals_text(conn: PgConn) raises:
    var text_rows = query_as[ItemRow](conn, ITEM_SQL, [])
    var bin_rows = query_as_binary[ItemRow](conn, ITEM_SQL, [])
    check(len(text_rows) == len(bin_rows), "bin/text row count")
    for i in range(len(text_rows)):
        var tag = "row" + String(i)
        check(text_rows[i].id == bin_rows[i].id, tag + " id")
        check(text_rows[i].owner_id == bin_rows[i].owner_id, tag + " owner_id")
        check(floats_agree(text_rows[i].latitude, bin_rows[i].latitude), tag + " latitude")
        check(floats_agree(text_rows[i].longitude, bin_rows[i].longitude), tag + " longitude")
        check(text_rows[i].title == bin_rows[i].title, tag + " title")
        check(present(text_rows[i].house_number) == present(bin_rows[i].house_number), tag + " house_number opt")
        if text_rows[i].house_number:
            check(
                text_rows[i].house_number.value() == bin_rows[i].house_number.value(),
                tag + " house_number val",
            )
        check(present(text_rows[i].amount) == present(bin_rows[i].amount), tag + " amount opt")
        if text_rows[i].amount:
            check(floats_agree(text_rows[i].amount.value(), bin_rows[i].amount.value()), tag + " amount val")
        check(floats_agree(text_rows[i].amount_1, bin_rows[i].amount_1), tag + " amount_1 numeric")
        check(text_rows[i].stars == bin_rows[i].stars, tag + " stars")
        check(present(text_rows[i].score) == present(bin_rows[i].score), tag + " score opt")
        if text_rows[i].score:
            check(text_rows[i].score.value() == bin_rows[i].score.value(), tag + " score val")
        check(text_rows[i].is_active == bin_rows[i].is_active, tag + " is_active")
        check(text_rows[i].hidden == bin_rows[i].hidden, tag + " hidden")
        check(present(text_rows[i].tags) == present(bin_rows[i].tags), tag + " tags opt")
        if text_rows[i].tags:
            check(len(text_rows[i].tags.value()) == len(bin_rows[i].tags.value()), tag + " tags len")
            for j in range(len(text_rows[i].tags.value())):
                check(
                    text_rows[i].tags.value()[j] == bin_rows[i].tags.value()[j],
                    tag + " tags val",
                )
        check(present(text_rows[i].gallery) == present(bin_rows[i].gallery), tag + " gallery opt")
        if text_rows[i].gallery:
            check(
                len(text_rows[i].gallery.value()) == len(bin_rows[i].gallery.value()),
                tag + " gallery len",
            )
            for j in range(len(text_rows[i].gallery.value())):
                check(
                    text_rows[i].gallery.value()[j] == bin_rows[i].gallery.value()[j],
                    tag + " gallery val",
                )
        check(len(text_rows[i].tiers) == len(bin_rows[i].tiers), tag + " tiers len")
        for j in range(len(text_rows[i].tiers)):
            check(text_rows[i].tiers[j] == bin_rows[i].tiers[j], tag + " tiers val")


def test_positional_and_mixed(conn: PgConn) raises:
    var sql = String(
        "select id, title, array[id, owner_id]::int8[] as pair_ids "
        + "from pqmojo_test_items where id < 4 order by id"
    )
    var rows = query_as[PairRow](conn, sql, [])
    check(len(rows) == 4, "positional row count")
    for i in range(len(rows)):
        check(rows[i].ident == Int64(i), "positional ident")
        check(rows[i].label == "Item " + String(i), "positional label")
        check(len(rows[i].pair_ids) == 2, "pair_ids len")
        check(rows[i].pair_ids[0] == Int64(i), "pair_ids[0]")
        check(
            Int(rows[i].pair_ids[1]) == 900 + (i * 11) % 500,
            "pair_ids[1]",
        )
    var bin_rows = query_as_binary[PairRow](conn, sql, [])
    check(len(bin_rows) == 4, "positional binary row count")
    for i in range(len(bin_rows)):
        check(bin_rows[i].ident == rows[i].ident, "bin positional ident")
        check(bin_rows[i].label == rows[i].label, "bin positional label")
        check(
            len(bin_rows[i].pair_ids) == len(rows[i].pair_ids),
            "bin pair_ids len",
        )
        check(
            bin_rows[i].pair_ids[1] == rows[i].pair_ids[1],
            "bin pair_ids[1]",
        )
    var mixed = query_as[MixedRow](
        conn,
        "select id, house_number, title from pqmojo_test_items where id = 3",
        [],
    )
    check(len(mixed) == 1, "mixed row count")
    check(mixed[0].id == 3, "mixed positional id")
    check(mixed[0].title == "Item 3", "mixed case-folded name")
    check(not present(mixed[0].house_number), "mixed named null (3 % 5 == 3)")


def test_query_one_as(conn: PgConn) raises:
    var found = query_one_as[ItemRow](
        conn, "select * from pqmojo_test_items where id = 7", []
    )
    check(present(found), "query_one_as found")
    check(found.value().id == 7, "query_one_as id")
    check(found.value().title == "Item 7", "query_one_as title")
    check(found.value().is_active, "query_one_as bool")
    var missing = query_one_as[ItemRow](
        conn, "select * from pqmojo_test_items where id = 99999", []
    )
    check(not missing, "query_one_as absent on empty set")
    var found_bin = query_one_as_binary[ItemRow](
        conn, "select * from pqmojo_test_items where id = 7", []
    )
    check(present(found_bin), "query_one_as_binary found")
    check(found_bin.value().id == 7, "query_one_as_binary id")
    check(
        floats_agree(found_bin.value().amount_1, found.value().amount_1),
        "query_one_as_binary numeric",
    )
    var missing_bin = query_one_as_binary[ItemRow](
        conn, "select * from pqmojo_test_items where id = 99999", []
    )
    check(not missing_bin, "query_one_as_binary absent")


def test_missing_column_error(conn: PgConn) raises:
    var raised = False
    try:
        var rows = query_as[BrokenRow](
            conn, "select id from pqmojo_test_items where id = 1", []
        )
        check(len(rows) == 0, "unreachable")
    except e:
        raised = True
        var msg = repr(e)
        check(msg.find("BrokenRow") >= 0, "error names the struct")
        check(msg.find("nope") >= 0, "error names the field")
        check(msg.find("no_such_column") >= 0, "error names the column")
        check(msg.find("id") >= 0, "error lists available columns")
    check_raised(raised, "missing column raises")
    var raised_bin = False
    try:
        var rows = query_as_binary[BrokenRow](
            conn, "select id from pqmojo_test_items where id = 1", []
        )
        check(len(rows) == 0, "unreachable")
    except:
        raised_bin = True
    check_raised(raised_bin, "missing column raises in binary")


def test_binary_type_mismatch_error(conn: PgConn) raises:
    var raised = False
    try:
        var rows = query_as_binary[ItemRow](
            conn,
            "select id, owner_id, latitude, longitude, title, seen_at "
            + "as house_number, amount, amount_1, stars, score, "
            + "is_active, hidden, tags, gallery, tiers "
            + "from pqmojo_test_items where id = 1",
            [],
        )
        check(len(rows) == 0, "unreachable")
    except e:
        raised = True
        var msg = repr(e)
        check(msg.find("type OID") >= 0, "mismatch names the OID")
    check_raised(raised, "binary timestamp into Int32 field raises")


def test_prepared(mut conn: PgConn) raises:
    conn.prepare_named("rowmap_item", ITEM_SQL)
    var rows = query_prepared_as[ItemRow](conn, "rowmap_item", [])
    check(len(rows) == 24, "prepared conn row count")
    check_item_row(rows[9], 9, "prepared")
    var pool = ConnectionPool(PoolConfig(DSN, max_size=2, min_idle=1))
    pool.prepare_all([("rowmap_pool", "select * from pqmojo_test_items where id = $1")])
    var params_one = List[String]()
    params_one.append("5")
    var one = query_prepared_as[ItemRow](pool, "rowmap_pool", params_one)
    check(len(one) == 1, "prepared pool row count")
    check(one[0].id == 5, "prepared pool id")
    check(one[0].title == "Item 5", "prepared pool title")
    var params_none = List[String]()
    params_none.append("424242")
    var none = query_prepared_as[ItemRow](pool, "rowmap_pool", params_none)
    check(len(none) == 0, "prepared pool empty")
    pool.close()


def test_row_plan(conn: PgConn) raises:
    var res = execute(conn, ITEM_SQL, [])
    var plan = resolve_row_plan[ItemRow](res, conn)
    var first = map_rows_as_planned[ItemRow](res, conn, plan)
    check(len(first) == 24, "planned row count")
    var second = map_rows_as_planned[ItemRow](res, conn, plan)
    check(len(second) == 24, "planned reuse row count")
    check_item_row(second[11], 11, "planned")
    res.clear()
    var narrow = execute(conn, "select id from pqmojo_test_items limit 1", [])
    var refused = False
    try:
        var bad = map_rows_as_planned[ItemRow](narrow, conn, plan)
        check(len(bad) == 0, "unreachable")
    except:
        refused = True
    check_raised(refused, "plan mismatch raises")
    narrow.clear()


def main() raises:
    setup_fixture()
    var conn = connect(DSN)
    test_round_trip_text(conn)
    test_binary_equals_text(conn)
    test_positional_and_mixed(conn)
    test_query_one_as(conn)
    test_missing_column_error(conn)
    test_binary_type_mismatch_error(conn)
    test_prepared(conn)
    test_row_plan(conn)
    conn.close()
    teardown_fixture()
    print("TEST_ROWMAP PASS")
