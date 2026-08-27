"""pqmojo — a serious libpq C-FFI driver for Mojo 1.0.

libpq for Mojo: zero Python, runtime dlopen, text protocol. The tokio-
postgres/deadpool analog for Mojo — connection pooling, parameterized
queries, typed row scanning, and a non-blocking execution path, with libpq
loaded at RUNTIME (never linked at build time) by probing candidate dylib
paths.

Quickstart:

    from pqmojo import ConnectionPool, PoolConfig, execute

    var pool = ConnectionPool(PoolConfig("postgres://user@localhost/app"))
    var conn = pool.acquire()
    var res = execute(conn,
        "SELECT id, title FROM listing_active WHERE filters_array @> $1 LIMIT $2",
        List[String](int_array_literal(filter_ids), "10"),
    )
    for row in range(res.rows()):
        print(res.col_i64(row, 0), res.col_text(row, 1))
    res.clear()
    pool.release(conn^)

Blocking one-liners stay the default; overlap-hungry callers use the
non-blocking pair instead:

    send_query(conn, sql, params)          # returns immediately
    var res = poll_result(conn, 30_000)    # readiness-driven wait

Public API:

    -- connections --
    connect(conninfo) raises -> PgConn     open after fork; raises with PQerrorMessage
    PgConn.close()                         PQfinish, idempotent
    PgConn.parameter_status(name)          cached startup parameter, "" if absent

    -- pooling --
    PoolConfig(url, max_size=8, min_idle=1, acquire_timeout_ms=2000,
               health_check=True, macos_gss_safe=True)
    ConnectionPool(cfg)                    warm min_idle conns; build AFTER fork
    pool.acquire(timeout_ms=-1)            blocking-with-deadline checkout
    pool.release(conn^)                    move back; close() first => PQfinish
    pool.stats()                           PoolStats(idle, in_use, total_open)
    pool.close()                           retire the whole pool

    -- execution --
    exec_params(conn, sql, params)         legacy lenient path (no status check)
    execute(conn, sql[, params])           STRICT: raises carrying server error text
    execute_args(conn, sql, *args)         SqlArg variadic: ints/floats/bools/strings
                                           and array literals bind inline
    row_exists(conn, sql[, params])        any row? strict on SQL errors
    scalar_i64(conn, sql[, params])        Optional[Int64]; None on zero rows

    -- async-friendly (one conn = one in-flight query) --
    send_query(conn, sql, params)          submit without waiting
    poll_result(conn, timeout_ms)          poll(2)-driven completion wait

    -- results (zero-copy unless noted) --
    PgResult.clear()                       explicit PQclear, destructor-free
    PgResult.rows()/cols()                 dimensions as Int
    PgResult.status()/error_message()      PGRES_* code + attached server text
    PgResult.check_ok()                    raise unless statement succeeded
    PgResult.is_null(row, col)             SQL NULL test per cell
    PgResult.col_text / col_nullable_text  copies at this edge only
    PgResult.col_i64 / col_nullable_i64    decimal scan, zero-copy
    PgResult.col_f64 / col_nullable_f64    libc strtod, zero-copy, ulp-exact
    PgResult.col_bool / col_nullable_bool  't'/'f' single byte read
    PgResult.text/text_or_null/int32/int64/float64   legacy aliases
    split_postgres_text_array              "{\\"a\\",b}" -> ["a", "b"]
    split_postgres_int32_array             "{23,60}" -> [23, 60]

    -- param building --
    format_i64/format_f64                  scalars (f64 = shortest round trip)
    int_array_literal/i64_array_literal    '{60,23}' style int[] input text
    text_array_literal/letter_array_literal  '{"H","D"}' quoted text[] input text

!!! warning "FORK CONTRACT"

    Create every PgConn AFTER fork, once per worker process, including pool
    construction. A connection opened pre-fork shares one socket across
    children and corrupts the wire protocol.
"""
from .asyncq import poll_result, send_query
from .conn import PgConn, close_conn, connect
from .ffi import PgSymbols, libpq_candidates, open_libpq
from .params import (
    SqlArg,
    execute_args,
    i64_array_literal,
    int_array_literal,
    letter_array_literal,
    row_exists_args,
    scalar_i64_args,
    text_array_literal,
)
from .pgarray import split_postgres_int32_array, split_postgres_text_array
from .pool import ConnectionPool, PoolConfig, PoolStats, gss_safe_dsn
from .query import (
    PgResult,
    exec_params,
    execute,
    format_f64,
    format_i64,
    row_exists,
    scalar_i64,
)
