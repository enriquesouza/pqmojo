"""Typed row helpers: col_* family, strtod parity, scalar_i64, row_exists,
execute_args with SqlArg, and array literal builders verified server-side.

Run: pixi run mojo run -I . tests/test_types.mojo
"""

from tests.common import DSN, check
from tests.fixture import setup_fixture, teardown_fixture

from pqmojo import (
    connect,
    execute,
    execute_args,
    format_i64,
    i64_array_literal,
    int_array_literal,
    letter_array_literal,
    row_exists,
    row_exists_args,
    scalar_i64,
    scalar_i64_args,
    text_array_literal,
)


def make_i32(vals: List[Int]) -> List[Int32]:
    var out = List[Int32]()
    for v in vals:
        out.append(Int32(v))
    return out^


def make_i64(vals: List[Int]) -> List[Int64]:
    var out = List[Int64]()
    for v in vals:
        out.append(Int64(v))
    return out^


def make_u8(vals: List[Int]) -> List[UInt8]:
    var out = List[UInt8]()
    for v in vals:
        out.append(UInt8(v))
    return out^


def str_list(vals: List[String]) -> List[String]:
    var out = List[String]()
    for s in vals:
        out.append(s)
    return out^


def main() raises:
    setup_fixture()
    var conn = connect(DSN)

    # ---- f64 through libc strtod must be bit-exact on nasty inputs ----
    var r = execute(conn, """
        SELECT (-46.888797400000044::float8)::text
             , (-23.5612345::float8)::text
             , (0.1::float8)::text
             , (1e308::float8)::text
    """)
    check(r.col_f64(0, 0) == -46.888797400000044, "strtod 17 digits exact")
    check(r.float64(0, 1) == -23.5612345, "float64 alias exact")
    check(r.col_f64(0, 2) == 0.1, "0.1 exact")
    check(r.col_f64(0, 3) == 1e308, "1e308 exponent form")
    r.clear()

    # denormal-smallest exponent notation
    r = execute(conn, "SELECT ('2.2250738585072014e-308'::float8)::text")
    check(r.col_f64(0, 0) == 2.2250738585072014e-308, "denormal exponent")
    r.clear()

    # NULL numeric cells scan to zero / None consistently
    r = execute(conn, "SELECT NULL::float8, NULL::int8, true, false")
    check(
        r.col_f64(0, 0) == 0.0 and not r.col_nullable_f64(0, 0),
        "null f64 -> 0/None",
    )
    check(
        r.col_i64(0, 1) == 0 and not r.col_nullable_i64(0, 1),
        "null i64 -> 0/None",
    )
    check(r.col_bool(0, 2), "true reads t")
    check(r.col_nullable_bool(0, 2).value(), "nullable true is Some(true)")
    check(not r.col_bool(0, 3), "false reads f")
    r.clear()

    # large ints round trip through the decimal scanner
    r = execute(conn, "SELECT 9007199254740993::int8, -42::int8")
    check(r.col_i64(0, 0) == 9007199254740993, "i64 beyond float53")
    check(r.int32(0, 1) == -42, "negative int32 view")
    r.clear()

    # ---- scalar_i64 present and absent ----
    var epoch = scalar_i64(
        conn, "SELECT id FROM pqmojo_test_items WHERE id = $1",
        [format_i64(1)],
    )
    var have_epoch = True
    if not epoch:
        have_epoch = False
    check(have_epoch, "fixture row 1 present")

    var missing = scalar_i64(
        conn, "SELECT id FROM pqmojo_test_items WHERE id = $1",
        [format_i64(999999999)],
    )
    check(not missing, "zero rows -> None")

    var raised = False
    try:
        var boom = scalar_i64(conn, "SELECT 1/0", [])
        _ = boom
    except:
        raised = True
    check(raised, "scalar_i64 raises on SQL error")

    # ---- row_exists ----
    check(row_exists(conn, "SELECT 1"), "row_exists basic")
    check(not row_exists(conn, "SELECT 1 WHERE 1 = 0"), "row_exists empty")
    check(
        row_exists(conn,
                   "SELECT 1 FROM pqmojo_test_items WHERE id = $1",
                   [format_i64(1)]),
        "row_exists params",
    )

    # ---- SqlArg variadic binding: mixed native types inline ----
    r = execute_args(
        conn,
        "SELECT $1::int8, $2::float8, $3::bool, $4::text",
        Int64(77), Float64(-1.25), True, String("lit"),
    )
    check(r.col_i64(0, 0) == 77, "SqlArg Int64")
    check(r.col_f64(0, 1) == -1.25, "SqlArg Float64")
    check(r.col_bool(0, 2), "SqlArg Bool")
    check(r.col_text(0, 3) == "lit", "SqlArg String")
    r.clear()

    var found = row_exists_args(
        conn, "SELECT 1 WHERE $1::int8 > $2::int8", 10, 3)
    check(found, "row_exists_args Int literals")

    var maybe = scalar_i64_args(conn, "SELECT $1::int8 * 2", 21)
    check(maybe.value() == 42, "scalar_i64_args")

    # ---- array literal builders vs the SERVER's parser ----
    r = execute_args(
        conn,
        "SELECT '{60,7501}'::int[] @> $1::int[] AS contained",
        int_array_literal(make_i32([60, 7501])),
    )
    check(r.col_bool(0, 0), "int_array_literal contained")
    r.clear()

    r = execute_args(
        conn,
        "SELECT NOT ('{60}'::int[] @> $1::int[]) AS disjoint",
        int_array_literal(make_i32([7502])),
    )
    check(r.col_bool(0, 0), "int_array_literal disjoint case")
    r.clear()

    # bigint[]
    r = execute_args(
        conn,
        "SELECT cardinality($1::bigint[]) AS n",
        i64_array_literal(make_i64([9007199254740993, 4, 5])),
    )
    check(r.col_i64(0, 0) == 3, "i64_array_literal cardinality")
    r.clear()

    # text[] letters via the letter builder ('H','D')
    r = execute_args(
        conn,
        "SELECT 'H' = ANY($1::text[]) AND 'D' = ANY($1::text[]) "
        + "AND NOT ('X' = ANY($1::text[])) AS letters_ok",
        letter_array_literal(make_u8([72, 68])),
    )
    check(r.col_bool(0, 0), "letter_array_literal ANY membership")
    r.clear()

    # builder OUTPUT itself matches PG canonical input expectations
    check(letter_array_literal(make_u8([72, 68])) == "{\"H\",\"D\"}",
          "letter builder output shape")

    # quoted generic text builder incl. escaping
    r = execute_args(
        conn,
        "SELECT 'a\"b' = ANY($1::text[]) AND 'c\\d' = ANY($1::text[])"
        + " AS quoted_ok",
        text_array_literal(str_list(["a\"b", "c\\d"])),
    )
    check(r.col_bool(0, 0), "text_array_literal escaping")
    r.clear()

    conn.close()
    teardown_fixture()
    print("TEST_TYPES PASS")
