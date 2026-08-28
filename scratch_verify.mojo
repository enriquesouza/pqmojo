"""Verify_scratch — end-to-end proof of pqmojo against a live database.

Not part of the published package: run with `pixi run verify`.
"""

from std.time import perf_counter

from pqmojo import (
    PgConn,
    connect,
    exec_params,
    format_f64,
    format_i64,
    split_postgres_int32_array,
    split_postgres_text_array,
)
from pqmojo.ffi import c_free, c_string


comptime DSN = "postgres:///pqmojo_test"


def main() raises:
    var conn = connect(DSN)
    print("connected; server_version =",
          conn.parameter_status("server_version"))

    var r = exec_params(
        conn,
        "SELECT id, title FROM pqmojo_test_items ORDER BY id LIMIT 3",
        List[String](),
    )
    print("pqmojo_test_items sample:", r.rows(), "rows")
    for i in range(r.rows()):
        print(" ", r.int64(i, 0), r.text(i, 1))
    r.clear()

    r = exec_params(conn, "SELECT NULL::text, 'x'", List[String]())
    var maybe = r.text_or_null(0, 0)
    if not maybe:
        print("null cell -> Optional.None ok")
    else:
        raise Error("NULL::text did not map to None")
    if r.is_null(0, 0) and not r.is_null(0, 1):
        print("is_null flags ok; text col =", r.text(0, 1))
    else:
        raise Error("is_null flags wrong")
    if r.text(0, 0) == "":
        print("text() on null scans as empty string ok")
    r.clear()

    r = exec_params(
        conn,
        "SELECT tags FROM pqmojo_test_items "
        + "WHERE tags IS NOT NULL ORDER BY id LIMIT 1",
        List[String](),
    )
    var raw = r.text(0, 0)
    var elems = split_postgres_text_array(raw)
    var ids = split_postgres_int32_array(raw)
    print("tags raw:", raw)
    print("split text:", elems)
    print("split int32:", ids)
    if len(ids) == 0 or len(ids) != len(elems) or ids[0] != Int32(60):
        raise Error("int32 array split wrong")

    var esc = split_postgres_text_array("{\"a\",\"b\\\"c\",NULL,\"NULL\"}")
    print("escape check:", esc)
    if len(esc) != 3 or esc[0] != "a" or esc[1] != "b\"c" or esc[2] != "NULL":
        raise Error("array escape handling wrong")
    r.clear()

    r = exec_params(
        conn,
        "SELECT $1::float8, $2::int4, $3::text",
        [
            format_f64(-23.5612345),
            format_i64(Int64(-42)),
            String("héllo \"q\""),
        ],
    )
    var f = r.float64(0, 0)
    var iv = r.int32(0, 1)
    var s = r.text(0, 2)
    print("param round trip:", f, iv, s)
    if f != -23.5612345 or iv != -42 or s != "héllo \"q\"":
        raise Error("param round trip mismatch")
    r.clear()

    comptime OPS = 200
    var t0 = perf_counter()
    for _ in range(OPS):
        var p = exec_params(conn, "SELECT 1", List[String]())
        if p.rows() != 1 or p.int32(0, 0) != 1:
            p.clear()
            raise Error("SELECT 1 returned wrong shape")
        p.clear()
    var dt = Float64(perf_counter() - t0)
    var ops_sec = Float64(OPS) / dt
    print("SELECT 1 (exec_params):", OPS, "ops in", dt, "s ->",
          Int64(ops_sec), "ops/sec")

    var sql1 = c_string("SELECT 1")
    var t2 = perf_counter()
    for _ in range(OPS):
        var q = conn.syms.exec_params(
            conn.handle, sql1, Int32(0), 0, 0, 0, 0, 0
        )
        conn.syms.clear(q)
    c_free(sql1)
    var dt2 = Float64(perf_counter() - t2)

    var sock = connect("postgres:///pqmojo_test")
    var t3 = perf_counter()
    for _ in range(OPS):
        var p = exec_params(sock, "SELECT 1", List[String]())
        p.clear()
    var dt3 = Float64(perf_counter() - t3)
    print("SELECT 1 (unix socket):", OPS, "ops in", dt3, "s ->",
          Int64(Float64(OPS) / dt3), "ops/sec")
    sock.close()
    print("SELECT 1 (bare ceiling):", OPS, "ops in", dt2, "s ->",
          Int64(Float64(OPS) / dt2), "ops/sec")

    conn.close()
    print("VERIFY OK")
