"""test_core — connections, strict execute, legacy compat, NULL handling.

Run: pixi run mojo run -I . tests/test_core.mojo
"""

from tests.common import DSN, check, check_raised
from tests.fixture import setup_fixture, teardown_fixture

from pqmojo import (
    connect,
    exec_params,
    execute,
    format_f64,
    format_i64,
    split_postgres_int32_array,
)


def main() raises:
    setup_fixture()
    var conn = connect(DSN)
    print("[core] server_version =", conn.parameter_status("server_version"))
    check(conn.parameter_status("server_version").byte_length() > 0,
          "server_version")

    # strict blocking one-call path
    var r = execute(conn, "SELECT 41 + 1 AS v, 'pq'::text AS tag")
    check(r.status() == 2, "PGRES_TUPLES_OK")
    check(r.rows() == 1 and r.cols() == 2, "shape")
    check(r.col_i64(0, 0) == 42, "col_i64")
    check(r.col_text(0, 1) == "pq", "col_text")
    r.clear()

    # params
    r = execute(
        conn,
        "SELECT $1::int4, $2::float8, $3::text",
        [
            format_i64(Int64(-7)),
            format_f64(2.5),
            String("h\u00e3"),
        ],
    )
    check(r.int32(0, 0) == -7, "int param")
    check(r.float64(0, 1) == 2.5, "float param")
    check(r.text(0, 2) == "hã", "utf8 param")
    r.clear()

    # strict path RAISES on SQL errors
    var raised = False
    try:
        var bad = execute(conn, "SELECT 1/0", List[String]())
        bad.clear()
    except:
        raised = True
    check_raised(raised, "execute raises on division by zero")

    # legacy lenient path stays lenient (documented behavior split)
    var soft = exec_params(conn, "SELECT 1/0", List[String]())
    check(soft.rows() == 0, "lenient error result has no rows")
    check(soft.status() != 2, "lenient status flags failure")
    soft.clear()

    # NULL semantics untouched
    r = execute(conn, "SELECT NULL::text, 'x'::text, NULL::int4")
    check(
        r.is_null(0, 0) and not r.is_null(0, 1) and r.is_null(0, 2),
        "is_null flags",
    )
    check(not r.text_or_null(0, 0), "NULL->None")
    check(r.text_or_null(0, 1).value() == "x", "some text")
    check(not r.col_nullable_i64(0, 2), "NULL int64 -> None")
    r.clear()

    # splitters unchanged
    var ints = split_postgres_int32_array("{60,7501,22}")
    check(ints[0] == 60 and ints[2] == 22 and len(ints) == 3, "int split")

    r = execute(conn,
                "SELECT tags FROM pqmojo_test_items "
                + "WHERE tags IS NOT NULL ORDER BY id LIMIT 1")
    var ids = split_postgres_int32_array(r.text(0, 0))
    check(len(ids) > 0, "fixture array column splits")
    r.clear()

    conn.close()
    teardown_fixture()
    print("TEST_CORE PASS")
