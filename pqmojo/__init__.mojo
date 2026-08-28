"""pqmojo — a serious libpq C-FFI driver for Mojo 1.0.

libpq for Mojo: zero Python, runtime dlopen, text protocol. The tokio-
postgres/deadpool analog for Mojo — connection pooling, parameterized
queries, server-side prepared statements, typed row scanning, and a
non-blocking execution path, with libpq loaded at RUNTIME (never linked at
build time) by probing candidate dylib paths.

Quickstart:

    from pqmojo import ConnectionPool, PoolConfig, execute

    var pool = ConnectionPool(PoolConfig("postgres://user@localhost/app"))
    var conn = pool.acquire()
    var res = execute(conn,
        "SELECT id, name FROM items WHERE tags @> $1 LIMIT $2",
        List[String](int_array_literal(tag_ids), "10"),
    )
    for row in range(res.rows()):
        print(res.col_i64(row, 0), res.col_text(row, 1))
    res.clear()
    pool.release(conn^)

Hot call sites parse/plan ONCE per connection instead of every request —
register a plan on the pool (deadpool StatementCache style) or own
statements directly:

    pool.prepare_on_acquire([("details", DETAILS_SQL)])
    var r2 = execute_prepared(pool.acquire(), "details",
                              List[String](format_i64(item_id)))

or through a handle:

    var stmt = conn.prepare(DETAILS_SQL)
    var r3 = stmt.execute_args(item_id)
    stmt.deallocate()                      # optional; sessions free anyway

Blocking one-liners stay the default; overlap-hungry callers use the
non-blocking pair instead:

    send_query(conn, sql, params)          # returns immediately
    var res = poll_result(conn, 30_000)    # readiness-driven wait

Public API:

    -- connections --
    connect(conninfo) raises -> PgConn     open after fork; raises with PQerrorMessage
    PgConn.close()                         PQfinish, idempotent (session dies,
                                           its prepared statements die with it)
    PgConn.parameter_status(name)          cached startup parameter, "" if absent

    -- pooling --
    PoolConfig(url, max_size=8, min_idle=1, acquire_timeout_ms=2000,
               health_check=True, macos_gss_safe=True)
    ConnectionPool(cfg)                    warm min_idle conns; build AFTER fork
    pool.acquire(timeout_ms=-1)            blocking-with-deadline checkout
    pool.release(conn^)                    move back; close() first => PQfinish
    pool.stats()                           PoolStats(idle, in_use, total_open)
    pool.close()                           retire the whole pool
    pool.prepare_on_acquire([(name, sql), ...])   rolling checkout plan: every
                                           warm/grown/replaced conn self-prepares
    pool.prepare_all([(name, sql), ...]) -> Int   one-shot fan-out over idle conns

    -- overlap (K conns multiplexed from ONE thread) --
    pool.checkout_pipeline(k=2)            StmtPipeline of k plan-armed conns
    pipe.submit(name, params) -> rid       Bind/Execute in flight, round robin
    pipe.collect(timeout_ms=30_000)        PipelineResult (request_id, slot,
                                           status-checked PgResult); completion
                                           order, poll(2) across ALL in-flight
    pipe.execute_batch(name, jobs[, ms])   M jobs through the window ->
                                           List[PgResult] submission-ordered
    pool.execute_batch(name, jobs, k=2)    checkout+batch+release one-liner
    pool.release_pipeline(pipe^)           drain + return; wedged conns close

    -- execution --
    exec_params(conn, sql, params)         legacy lenient path (no status check)
    execute(conn, sql[, params])           STRICT: raises carrying server error text
    execute_args(conn, sql, *args)         SqlArg variadic: ints/floats/bools/strings
                                           and array literals bind inline
    exec_params_binary(conn, sql, params)  BINARY (fmt=1) results; params still TEXT
    execute_binary(conn, sql, params)      strict BINARY execution (conn twin:
                                           conn.execute_binary(sql, params))
    row_exists(conn, sql[, params])        any row? strict on SQL errors
    scalar_i64(conn, sql[, params])        Optional[Int64]; None on zero rows

    -- typed rows (declare a struct once; sqlx FromRow pattern) --
    FromRow / RowColumns                  declaration-site column table: one
                                           entry per field, by name ("" =
                                           positional); the shape a codegen
                                           emits from `# db "col"` tags
    query_as[T](conn, sql[, params])      TEXT rows -> List[T]; result
                                           cleared inside
    query_as_binary[T](conn, sql[, params])  BINARY twin: same struct, same
                                           values, OID-routed decoders
    query_one_as[T](conn, sql[, params])  Optional[T]; None on zero rows
                                           (ErrNoRows semantics)
    query_one_as_binary[T](conn, sql[, params])  BINARY twin
    query_prepared_as[T](conn|pool, name, params)  prepared-statement twin
    map_rows_as[T](res, conn)             List[T] from a caller-held TEXT
    map_rows_as_binary[T](res, conn)      ... or BINARY PgResult
    resolve_row_plan[T](res, conn)        RowPlan: indexes resolved ONCE,
                                           reused across same-shape results
    map_rows_as_planned[T](res, conn, plan)   planned twins: zero
    map_rows_as_binary_planned[T](...)        re-resolution hot path
    Optional[T] fields read NULL -> absent; field types drive the readers:
    Int64/Int32/Float64/Bool/String, List[Int32]/List[Int64]/List[String],
    Optional of any of those

    -- prepared statements (Parse once, Bind many) --
    conn.prepare(sql) raises -> PgStmt     auto-named per-session statement;
                                           bad SQL raises AT PREPARE time
    conn.prepare_named(name, sql)          caller-chosen name (replaces silently)
    prepare_on(handle, syms, name, sql)    low-level core used by pools
    PgStmt.execute(params) / execute_args(*args)   strict Bind+Execute round trip
    PgStmt.deallocate()                    early free; optional (implicit at close)
    execute_prepared(conn, name, params)   Bind by NAME on any pooled conn; strict
    send_prepared(conn, name, params)      non-blocking submit; poll_result to finish

    -- async-friendly (one conn = one in-flight query) --
    send_query(conn, sql, params)          submit without waiting
    poll_result(conn, timeout_ms)          poll(2)-driven completion wait
    send_prepared_binary(conn, name, params)   non-blocking BINARY submit
                                           (pipe.submit_binary rides this)

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
    PgResult.bin_i64/bin_i32/bin_f64/bin_bool   BINARY (fmt=1) cells, BE
                                           bitcast; NULL -> zero value
    PgResult.bin_text                      raw UTF8 materialization
    PgResult.bin_bytes                     zero-copy Span over wire bytes
    PgResult.bin_numeric_to_f64            numeric -> Float64, bit-identical
                                           to the text path's strtod
    PgResult.bin_int32_array/bin_int64_array/bin_text_array  1-D arrays, NULL elements dropped
    split_postgres_text_array              "{\\"a\\",b}" -> ["a", "b"]
    split_postgres_int32_array             "{23,60}" -> [23, 60]
    split_postgres_int64_array             "{23,60}" -> [23, 60] (bigint)

    -- timestamps (PG TEXT decode/render, pqmojo.timestamp) --
    parse_postgres_timestamp_bytes_to_microseconds(ptr, n) -> Int64
                                           "YYYY-MM-DD HH:MM:SS[.ffffff]
                                           [(+|-)HH[:MM]]" -> micros (UTC,
                                           offset applied); strict trim
                                           (" "/tab); 0 on malformed
    parse_postgres_timestamp_bytes_lenient(ptr, n) -> Int64
                                           same grammar, trim set adds
                                           newline + carriage return
    render_postgres_timestamp_text(micros) -> String
                                           "YYYY-MM-DD HH:MM:SS" (secs
                                           resolution, zero-padded)
    parse_instant(raw) -> InstantParse     human-input validation:
                                           DD/MM/YYYY HH:MM (16 chars),
                                           YYYY-MM-DD[T| ]HH:MM[:SS], "Z"
                                           tolerated, ranges enforced
    unix_seconds_now() -> Int64            libc time(2), Unix epoch secs
    days_since_epoch_for_date / civil_from_days / is_leap /
    day_count_in_month                     Hinnant calendar primitives

    -- param building --
    format_i64/format_f64                  scalars (f64 = shortest round trip)
    int_array_literal/i64_array_literal    '{60,23}' style int[] input text
    text_array_literal/letter_array_literal  '{"H","D"}' quoted text[] input text

!!! warning "FORK CONTRACT"

    Create every PgConn AFTER fork, once per worker process, including pool
    construction. A connection opened pre-fork shares one socket across
    children and corrupts the wire protocol.
"""
from .args import SqlArg, format_f64, format_i64
from .asyncq import (
    execute_prepared_nonblocking,
    poll_result,
    send_prepared,
    send_prepared_binary,
    send_query,
)
from .conn import PgConn, close_conn, connect
from .ffi import PgSymbols, libpq_candidates, open_libpq
from .params import (
    execute_args,
    i64_array_literal,
    int_array_literal,
    letter_array_literal,
    row_exists_args,
    scalar_i64_args,
    text_array_literal,
)
from .pgarray import split_postgres_int32_array, split_postgres_int64_array, split_postgres_text_array
from .pipeline import PipelineResult, StmtPipeline
from .pool import ConnectionPool, PoolConfig, PoolStats, gss_safe_dsn
from .query import (
    PgResult,
    exec_params,
    exec_params_binary,
    execute,
    execute_binary,
    execute_prepared,
    row_exists,
    scalar_i64,
)
from .rowmap import (
    FromRow,
    RowColumns,
    RowPlan,
    RowValue,
    map_rows_as,
    map_rows_as_binary,
    map_rows_as_binary_planned,
    map_rows_as_planned,
    query_as,
    query_as_binary,
    query_one_as,
    query_one_as_binary,
    query_prepared_as,
    resolve_row_plan,
)
from .stmt import PgStmt, execute_prepared_on, prepare_on
from .timestamp import (
    InstantParse,
    civil_from_days,
    day_count_in_month,
    days_since_epoch_for_date,
    is_leap,
    parse_instant,
    parse_postgres_timestamp_bytes_lenient,
    parse_postgres_timestamp_bytes_to_microseconds,
    render_postgres_timestamp_text,
    unix_seconds_now,
)
