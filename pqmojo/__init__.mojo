"""pqmojo — a generic libpq C-FFI client for Mojo 1.0.

libpq for Mojo: zero Python, runtime dlopen, text protocol. The tokio-
postgres/deadpool analog for Mojo — connection + parameterized queries +
result scanning over the C API, with libpq loaded at RUNTIME (never linked
at build time) by probing candidate dylib paths.

Public API:

    connect(conninfo) raises -> PgConn     open after fork; raises with PQerrorMessage
    PgConn.close()                         PQfinish, idempotent
    PgConn.parameter_status(name)          cached startup parameter, "" if absent
    exec_params(conn, sql, params)         TEXT params in, owning PgResult out
    PgResult.clear()                       explicit PQclear, destructor-free
    PgResult.rows()/cols()                 dimensions as Int
    PgResult.text/text_or_null             cell copies; NULL -> "" / Optional.None
    PgResult.int32/int64/float64           hand-rolled scanners; NULL -> 0
    PgResult.is_null(row, col)             SQL NULL test per cell
    format_i64/format_f64                  param formatting (f64 = shortest round trip)
    split_postgres_text_array              "{\\"a\\",b}" -> ["a", "b"]
    split_postgres_int32_array             "{23,60}" -> [23, 60]

!!! warning "FORK CONTRACT"

    Create every PgConn AFTER fork, once per worker process. A connection
    opened pre-fork shares one socket across children and corrupts the wire
    protocol. PgConn is not Copyable so ownership can never silently spread.
"""
from .conn import PgConn, close_conn, connect
from .ffi import PgSymbols, libpq_candidates, open_libpq
from .pgarray import split_postgres_int32_array, split_postgres_text_array
from .query import (
    PgResult,
    exec_params,
    format_f64,
    format_i64,
)
