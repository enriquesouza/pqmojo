"""Prepared statements: conn.prepare -> execute N times with equal results,
execute_args edge, prepare_named + execute_prepared by name, DEALLOCATE
path, error paths (bad SQL at PREPARE, missing statement, param-count
mismatch), and the non-blocking send_prepared/poll_result twin.

Run: pixi run mojo run -I . tests/test_stmt.mojo
"""

from tests.common import DSN, check, check_raised
from tests.fixture import setup_fixture, teardown_fixture

from pqmojo import (
    PgStmt,
    connect,
    execute,
    execute_prepared,
    execute_prepared_nonblocking,
    format_i64,
    poll_result,
    send_prepared,
)


comptime DETAILS_SQL = (
    "SELECT id, title, district FROM pqmojo_test_items "
    + "WHERE id = $1 LIMIT 1"
)


def main() raises:
    setup_fixture()
    var conn = connect(DSN)

    # resolve a fixture row id once (the suite owns its data)
    var probe = execute(
        conn,
        "SELECT id FROM pqmojo_test_items ORDER BY id LIMIT 1",
        [],
    )
    check(probe.rows() == 1, "fixture table has rows")
    var item_id = probe.col_i64(0, 0)
    probe.clear()

    # ---- prepare ONCE, execute N times: identical results every time ----
    var stmt = conn.prepare(DETAILS_SQL)
    comptime N = 25
    var first_title = String("")
    for i in range(N):
        var r = stmt.execute([format_i64(item_id)])
        check(r.rows() == 1 and r.cols() == 3, "details shape at run " + String(i))
        check(r.col_i64(0, 0) == item_id, "id round trip")
        if i == 0:
            first_title = r.col_text(0, 1)
        else:
            check(r.col_text(0, 1) == first_title,
                  "stable result across executions " + String(i))
        r.clear()
    print("[stmt] prepared once, executed", N, "times; title stable:",
          first_title)

    # ---- natively-typed variadic edge ----
    var ra = stmt.execute_args(item_id)
    check(ra.rows() == 1 and ra.col_text(0, 1) == first_title,
          "execute_args twin output")
    ra.clear()

    # auto names are unique per session
    var stmt2 = conn.prepare("SELECT 42::int8 AS v")
    check(stmt2.name != stmt.name, "unique auto statement names")
    var rr = stmt2.execute([])
    check(rr.col_i64(0, 0) == 42, "second statement independent")
    rr.clear()

    # ---- explicit names + execute_prepared by NAME (pool-facing shape) ----
    conn.prepare_named("pq_test_details", DETAILS_SQL)
    for i in range(3):
        var rn = execute_prepared(conn, "pq_test_details",
                                  [format_i64(item_id)])
        check(rn.col_text(0, 1) == first_title, "bind-by-name result " + String(i))
        rn.clear()

    # re-preparing a LIVE name raises — Postgres refuses blind re-PREPARE;
    # deliberate replacement happens only inside pool arming paths
    var dup_raise = False
    try:
        conn.prepare_named("pq_test_details", DETAILS_SQL)
    except:
        dup_raise = True
    check_raised(dup_raise, "duplicate prepare_named raises (already exists)")

    # ---- DEALLOCATE path ----
    conn.prepare_named("pq_doomed", "SELECT 7::int8 AS v")
    var doomed = PgStmt("pq_doomed", conn.handle, stmt.syms.copy())
    doomed.deallocate()
    var dead_raise = False
    try:
        var dres = execute_prepared(conn, "pq_doomed", [])
        dres.clear()
    except:
        dead_raise = True
    check_raised(dead_raise, "executing a DEALLOCATEd name raises")
    var again = False
    try:
        doomed.deallocate()   # idempotent by contract
    except:
        again = True
    check(not again, "double deallocate is a quiet no-op")

    # via conn.prepare handles directly
    var mortal = conn.prepare("SELECT 9::int8 AS v")
    mortal.deallocate()
    var post_deal = False
    try:
        var z = mortal.execute([])
        z.clear()
    except:
        post_deal = True
    check_raised(post_deal, "PgStmt refuses executes after deallocate")

    # ---- error path: bad SQL raises AT PREPARE carrying PQ message ----
    var bad_prepare = False
    try:
        var broken = conn.prepare("SELEC nope FROM wat")
        _ = broken.name
    except:
        bad_prepare = True
    check_raised(bad_prepare, "syntax error surfaces at prepare time")

    # unresolvable parameter context fails at prepare; a BARE target-list $1
    # instead resolves to text exactly like the plain exec_params path
    var amb_prepare = False
    try:
        var amb = conn.prepare("SELECT pg_typeof($1)::text")
        _ = amb.name
    except:
        amb_prepare = True
    check_raised(amb_prepare, "unresolvable parameter rejected at prepare")

    var bare = conn.prepare("SELECT $1")
    var bare_r = bare.execute(["xyz"])
    check(bare_r.col_text(0, 0) == "xyz", "bare $1 infers text (parity)")
    bare_r.clear()

    # wrong param count caught server-side at Bind time
    var count_mismatch = False
    try:
        var over = stmt.execute([format_i64(item_id), "extra"])
        over.clear()
    except:
        count_mismatch = True
    check_raised(count_mismatch, "param-count mismatch raises")

    # executing a name that was never prepared on this session
    var ghost = False
    try:
        var g = execute_prepared(conn, "pq_never_prepared", [])
        g.clear()
    except:
        ghost = True
    check_raised(ghost, "unknown statement name raises")

    # conn survived all those errors and still answers plainly
    var sane = execute(conn, "SELECT 5", [])
    check(sane.col_i64(0, 0) == 5, "conn healthy after error paths")
    sane.clear()

    # ---- non-blocking twin: send_prepared + poll_result ----
    send_prepared(conn, stmt.name, [format_i64(item_id)])
    var async_r = poll_result(conn, 5000)
    check(async_r.rows() == 1 and async_r.col_text(0, 1) == first_title,
          "send_prepared/poll_result parity")
    async_r.clear()

    var conv_r = execute_prepared_nonblocking(conn, stmt.name,
                                              [format_i64(item_id)])
    check(conv_r.col_i64(0, 0) == item_id,
          "blocking convenience built on async path")
    conv_r.clear()

    conn.close()
    teardown_fixture()
    print("TEST_STMT PASS")
