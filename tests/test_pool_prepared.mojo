"""Pool x prepared statements: rolling checkout plans cover warm, grown,
and health-replaced conns; prepare_all is a point-in-time fan-out; bad SQL
is rejected loudly at registration without poisoning the pool.

Run: pixi run mojo run -I . tests/test_pool_prepared.mojo
"""

from tests.common import DSN, check, check_raised

from pqmojo import (
    ConnectionPool,
    PgConn,
    PoolConfig,
    connect,
    execute,
    execute_prepared,
    format_i64,
)




def build_plan() -> List[Tuple[String, String]]:
    """The canonical two-statement hot plan."""
    var out = List[Tuple[String, String]]()
    out.append((
        "pq_pool_details",
        "SELECT id, title, neighborhood FROM listing_active "
        + "WHERE id = $1 LIMIT 1",
    ))
    out.append((
        "pq_pool_count",
        "SELECT count(*)::int8 FROM listing_active WHERE price IS NOT NULL",
    ))
    return out^


def backend_pid(conn: PgConn) raises -> Int64:
    var r = execute(conn, "SELECT pg_backend_pid()", [])
    var pid = r.col_i64(0, 0)
    r.clear()
    return pid


def main() raises:
    var probe_conn = connect(DSN)
    var idr = execute(probe_conn,
                      "SELECT id FROM listing_active ORDER BY id LIMIT 1", [])
    var listing_id = idr.col_i64(0, 0)
    idr.clear()

    # ---- rolling plan: warm conns are armed immediately ----
    var pool = ConnectionPool(PoolConfig(DSN, max_size=4, min_idle=2))
    var plan = build_plan()
    pool.prepare_on_acquire(plan)

    var served = 0
    for i in range(6):
        var c = pool.acquire()
        var r = execute_prepared(c, "pq_pool_details", [format_i64(listing_id)])
        check(r.rows() == 1, "armed details row at checkout " + String(i))
        var rc = execute_prepared(c, "pq_pool_count", [])
        check(rc.rows() == 1 and rc.col_i64(0, 0) >= 0,
              "armed count row at checkout " + String(i))
        if rc.col_i64(0, 0) > 0:
            served += 1
        rc.clear()
        r.clear()
        pool.release(c^)
    _ = served
    print("[poolprep] 6 checkouts served two prepared statements each")

    # ---- health-replaced conns self-prepare through the same epoch marker --
    var victim = pool.acquire()
    var victim_pid = backend_pid(victim)
    pool.release(victim^)

    var hitman = connect(DSN)
    var hit = execute(hitman, "SELECT pg_terminate_backend($1)",
                      [format_i64(victim_pid)])
    hit.clear()
    hitman.close()

    var survivor = pool.acquire()
    var s_ok = execute_prepared(survivor, "pq_pool_details",
                                [format_i64(listing_id)])
    check(s_ok.rows() == 1, "post-stale conn still serves prepared plan")
    s_ok.clear()
    pool.release(survivor^)
    print("[poolprep] terminated backend replaced WITH its plan")

    # ---- bad SQL rejected loudly at registration; pool unpoisoned ----
    var bad_plan = False
    try:
        pool.prepare_on_acquire([
            ("pq_broken", "SELEC nada FROM nowhere"),
        ])
    except:
        bad_plan = True
    check_raised(bad_plan, "bad SQL in prepare_on_acquire raises")
    var still = pool.acquire()
    var guard = execute_prepared(still, "pq_pool_count", [])
    check(guard.rows() == 1, "pool still serves the good plan after reject")
    guard.clear()
    pool.release(still^)

    # ---- prepare_all: point-in-time fan-out count ----
    var p2 = ConnectionPool(PoolConfig(DSN, max_size=4, min_idle=2,
                                       health_check=False))
    var n = p2.prepare_all(build_plan())
    check(n == 2, "prepare_all covered every idle conn")
    print("[poolprep] prepare_all fanned out across", n, "idle conns")
    var c2 = p2.acquire()
    var ok2 = execute_prepared(c2, "pq_pool_details", [format_i64(listing_id)])
    check(ok2.rows() == 1, "prepare_all statement binds by name")
    ok2.clear()
    p2.release(c2^)
    p2.close()

    probe_conn.close()
    pool.close()
    print("TEST_POOL_PREPARED PASS")
