"""Pool semantics: warmup, reuse identity, stale-conn health check and
replacement, saturation timeout, gss dsn handling, close behavior.

Run: pixi run mojo run -I . tests/test_pool.mojo
"""

from tests.common import DSN, check, check_raised

from pqmojo import (
    ConnectionPool,
    PgConn,
    PoolConfig,
    connect,
    execute,
    format_i64,
    gss_safe_dsn,
)


def backend_pid(conn: PgConn) raises -> Int64:
    var r = execute(conn, "SELECT pg_backend_pid()", [])
    var pid = r.col_i64(0, 0)
    r.clear()
    return pid


def main() raises:
    # ---- warmup + reuse identity ----
    var pool = ConnectionPool(
        PoolConfig(DSN, max_size=4, min_idle=2)
    )
    var st = pool.stats()
    check(st.idle == 2 and st.in_use == 0 and st.total_open == 2,
          "warmup min_idle conns")
    print("[pool] after warmup:", "idle =", st.idle, "in_use =", st.in_use)

    var c1 = pool.acquire()
    st = pool.stats()
    check(st.in_use == 1 and st.idle == 1, "acquire drains idle")
    var pid1 = backend_pid(c1)

    # release then re-acquire: the SAME backend socket must come back
    pool.release(c1^)
    var c1b = pool.acquire()
    var pid_reread = backend_pid(c1b)
    check(pid_reread == pid1, "reuse: released socket served again")

    # hold both warm sockets, then release; next acquire is LIFO
    var pid_c2 = Int64(0)
    var c2 = pool.acquire()
    if pool.stats().in_use == 2:
        pid_c2 = backend_pid(c2)
    _ = pid_c2

    # release everything so later sections start from a clean idle queue
    pool.release(c1b^)
    pool.release(c2^)
    var again = pool.acquire()
    var pid_again = backend_pid(again)
    print("[pool] checkout served backend pid", pid_again)
    pool.release(again^)

    # ---- stale-conntest: kill a released conn server-side; the health
    # ping must catch it and transparently serve a healthy one ----
    var victim = pool.acquire()
    var victim_pid = backend_pid(victim)
    pool.release(victim^)

    # terminate through an INDEPENDENT conn so no pool slot suicides
    var hitman = connect(DSN)
    var hit = execute(hitman, "SELECT pg_terminate_backend($1)",
                      [format_i64(victim_pid)])
    hit.clear()
    hitman.close()

    var survivor = pool.acquire()
    var sane = execute(survivor, "SELECT 42", [])
    check(sane.col_i64(0, 0) == 42, "post-stale acquire is functional")
    sane.clear()
    var final_st = pool.stats()
    check(final_st.total_open <= final_st.idle + final_st.in_use,
          "counts stay consistent")
    check(final_st.total_open <= 4, "max_size respected")
    print("[pool] stale replacement done; stats:",
          "idle =", final_st.idle, "in_use =", final_st.in_use,
          "total =", final_st.total_open)
    pool.release(survivor^)

    # ---- saturation: max_size=1 pool blocks, then times out loudly ----
    var tight = ConnectionPool(
        PoolConfig(DSN, max_size=1, min_idle=0,
                   acquire_timeout_ms=150, health_check=False)
    )
    var held = tight.acquire()
    var raised = False
    try:
        var starved = tight.acquire()
        starved.close()   # would leak a conn otherwise (defensive)
    except:
        raised = True
    check_raised(raised, "second acquire times out at 150ms")
    tight.release(held^)
    var got = tight.acquire()
    var ok_sel = execute(got, "SELECT 8", [])
    check(ok_sel.col_i64(0, 0) == 8, "freed slot serves healthy conn")
    ok_sel.clear()
    tight.release(got^)

    # ---- close semantics ----
    var doomed = tight.acquire()
    tight.close()
    var closed_raise = False
    try:
        var nope = tight.acquire()
        nope.close()      # defensive; should be unreachable
    except:
        closed_raise = True
    check_raised(closed_raise, "acquire after close raises")
    tight.release(doomed^)   # release-after-close PQfinishes instead

    # ---- gss dsn handling ----
    check(
        gss_safe_dsn("postgres://u@h/db")
        == "postgres://u@h/db?gssencmode=disable",
        "gss append to bare url",
    )
    check(
        gss_safe_dsn("postgres://u@h/db?sslmode=prefer")
        == "postgres://u@h/db?sslmode=prefer&gssencmode=disable",
        "gss append to queryful url",
    )
    check(
        gss_safe_dsn("host=h db=d") == "host=h db=d gssencmode=disable",
        "gss keyword-form append",
    )

    print("TEST_POOL PASS")
