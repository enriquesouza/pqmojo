# pqmojo

**libpq for Mojo — zero Python, runtime dlopen, text protocol.**

A generic libpq C-FFI client for Mojo 1.0: the tokio-postgres/deadpool analog.
libpq is **never linked at build time** — the dylib is probed at runtime via
`dlopen` (Homebrew, postgresql@16/@17/@14, system paths), symbols are bound
with `dlsym`, and everything crosses the boundary as the TEXT protocol.

Generalized from a production nearby-search hot path serving ~30k `SELECT 1`
round trips/sec per connection.

## Install

```bash
pixi add pqmojo
```

## Quick start

```mojo
from pqmojo import PgResult, connect, exec_params, format_f64
from pqmojo import split_postgres_text_array

def main() raises:
    var conn = connect("postgres://user@localhost/mydb")
    var r = exec_params(
        conn,
        "SELECT id, title, price FROM listing_active WHERE lat = $1 LIMIT $2",
        List[String](format_f64(-23.56), "3"),
    )
    for row in range(r.rows()):
        print(r.int64(row, 0), r.text(row, 1), r.float64(row, 2))
    r.clear()
    conn.close()
```

## API surface

| Signature | Notes |
|---|---|
| `connect(conninfo: String) raises -> PgConn` | probes dylib paths, raises carrying `PQerrorMessage` on bad status |
| `PgConn.close()` | `PQfinish`, idempotent |
| `PgConn.parameter_status(name: String) -> String` | cached startup parameter (`server_version`, ...), `""` if absent |
| `exec_params(conn: PgConn, sql: String, params: List[String]) raises -> PgResult` | all params bind as TEXT; raises with `PQerrorMessage` when libpq returns no result |
| `PgResult.clear()` | explicit `PQclear`; owning handle, **no destructor** — call it exactly once |
| `PgResult.rows() -> Int` / `cols() -> Int` | dimensions |
| `PgResult.is_null(row: Int, col: Int) -> Bool` | SQL NULL test per cell |
| `PgResult.text(row, col) -> String` | copies; NULL scans as `""` |
| `PgResult.text_or_null(row, col) -> Optional[String]` | NULL maps to `Optional.None` |
| `PgResult.int32/int64/float64(row, col)` | hand-rolled scanners, single-rounding float parse (Go `strconv.ParseFloat`-identical); NULL → `0` |
| `format_i64(v: Int64) -> String` | decimal param rendering |
| `format_f64(v: Float64) -> String` | shortest-round-trip param text — stdlib `String(v)`, do not hand-roll |
| `split_postgres_text_array(s: String) -> List[String]` | `{"a","b\"c"}` → `["a", 'b"c']`; drops unquoted NULL tokens |
| `split_postgres_int32_array(s: String) -> List[Int32]` | `{23,60}` → `[23, 60]` |

## Fork contract

Each worker process MUST own its connection: call `connect()` **after**
fork, once per worker, never in the parent. A `PQconn` opened pre-fork shares
one socket across children and corrupts the wire protocol. `PgConn` is not
`Copyable` by design, so ownership cannot silently spread — the constraint is
structural, not documentary.

## Threading

Single-threaded event-loop safe. libpq's blocking calls are used exactly as
designed for one thread per connection; there is no GIL in play and no global
mutable state anywhere — the loaded symbol table rides on each connection,
so concurrent conns share nothing.

## Why TEXT protocol

Every parameter binds as TEXT and every result is scanned from PG text with
hand-rolled int64/float64 parsers. Postgres parses `$1` into whatever column
type the statement wants; the client side stays allocation-light and the
float parser produces byte-identical results to Go's `strconv.ParseFloat`.

## License

MIT
