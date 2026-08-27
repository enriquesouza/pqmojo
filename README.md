# pqmojo

**libpq for Mojo — zero Python, runtime dlopen, text protocol.**

The tokio-postgres/deadpool-postgres analog for Mojo 1.0: connection
pooling, parameterized queries, typed row scanning, and a non-blocking
execution path over libpq's C API. libpq is **never linked at build time**
— the dylib is probed at runtime via `dlopen` (Homebrew,
postgresql@16/@17/@14, system paths) and symbols are bound with `dlsym`;
everything crosses the boundary as the TEXT protocol.

Generalized from a production nearby-search hot path serving ~30k `SELECT 1`
round trips/sec per connection.

## Install

```bash
pixi add pqmojo
```

## Quick start (the deadpool shape)

```mojo
from pqmojo import ConnectionPool, PoolConfig, execute

def main() raises:
    # Build AFTER fork if your host forks workers (see Threading model).
    var pool = ConnectionPool(
        PoolConfig("postgres://user@localhost/mydb", max_size=8)
    )
    var conn = pool.acquire()          # blocks up to acquire_timeout_ms
    var r = execute(
        conn,
        "SELECT id, title, price FROM listing_active \
         WHERE filters_array @> $1 ORDER BY geom <=> point LIMIT $2",
        ["{60,7501}", "10"],
    )
    for row in range(r.rows()):
        print(r.col_i64(row, 0), r.col_text(row, 1), r.col_f64(row, 2))
    r.clear()
    pool.release(conn^)
```

`acquire()` returns a healthy connection: reused sockets get a `"SELECT 1"`
health ping first, and a stale one is transparently replaced within the
same budget. Saturated pools queue callers on a condvar until deadline —
oversubscription degrades to waiting, not errors.

Ownership is explicit and structural: `release(conn^)` MOVES the conn back.
Handing over `conn^` makes later use of that value a compile error wherever
the compiler can see it — the same trick that keeps `PgConn`
non-`Copyable`. There are no destructors in this library by design;
`PgResult.clear()` and forgetting `release()` follow the exact house rules.

## Typed columns — kill your parsing boilerplate

| Call | Reads | NULL |
|---|---|---|
| `col_i64(row, col)` | decimal int text, zero-copy | `0` (+ `is_null`) |
| `col_f64(row, col)` | **libc strtod on libpq's own buffer** — zero-copy, ulp-exact incl. 17-digit shortest-repr inputs | `0.0` |
| `col_bool(row, col)` | single byte `'t'/'f'` | `False` |
| `col_text(row, col)` | copied String | `""` |
| `col_nullable_i64/f64/text/bool(...)` | same scans as `Optional[T]` | `Optional.None` |

`scalar_i64(conn, sql, params) -> Optional[Int64]` and
`row_exists(conn, sql, params) -> Bool` compress the dominant one-liner
call sites ("does this exist?", "what's the current epoch?"). Both raise on
SQL errors instead of pretending an error is "no rows".

Legacy accessors (`text`, `text_or_null`, `int32`, `int64`, `float64`)
remain and alias the same implementations.

## Parameters and arrays

Bind TEXT params directly (`execute(conn, sql, List[String](...)`), or pass
native values through the variadic edge:

```mojo
from pqmojo import execute_args, int_array_literal, letter_array_literal

var res = execute_args(
    conn,
    "SELECT id FROM listing_active WHERE filters_array @> $1 AND $2 = ANY(periods)",
    int_array_literal(filter_ids),      # '{60,7501}' int[] input text
    letter_array_literal([72, 68]),     # '{"H","D"}' quoted text[] input
)
```

Builders ship for `int[]`, `bigint[]`, quoted-escaped `text[]`, and period
letters; Postgres parses TEXT into whatever column type the statement wants
(exactly how pgx feeds Go). Raw strings stay welcome — sometimes comptime
SQL plus a `List[String]` reads best; the builders exist so nobody has to
hand-write `{"H","D"}` concatenation again.

Simple blocking helpers:

```mojo
execute(conn, sql[, params])            # strict: raises with server message
row_exists(conn, sql[, params])         # any row?
scalar_i64(conn, sql[, params])         # Optional[Int64], None when absent
```

## Non-blocking execution (overlap I/O on your own scheduler)

libpq's non-blocking API without the ceremony:

```mojo
from pqmojo import send_query, poll_result

send_query(conn, sql, params)       # submits, returns immediately
... overlap other work / other sockets ...
var res = poll_result(conn, 30_000) # poll(2)-driven wait, status-checked
```

One connection carries ONE in-flight statement: poll before re-sending.
On timeout the query keeps running server-side; call `poll_result` again
with a fresh budget or close the connection. Most call sites should keep
plain `execute()` — this path exists so host event loops can drive many
sockets from one thread.

## What you get from `exec_params` (legacy-compatible)

The v0.1 surface is untouched: `connect`, `exec_params`,
`split_postgres_text_array`, `split_postgres_int32_array`,
`format_i64/format_f64`, and the lenient error behavior of
`exec_params` itself (empty-looking results on SQL errors). New code should
prefer `execute()` which ENFORCES result status and raises carrying the
server's message — `check_ok()` / `status()` / `error_message()` are
public on `PgResult` either way.

## Threading model (honest version)

* Mojo has **no green threads**, no async runtime thread pool.
* mojoflask-style hosts: prepare → fork → N single-threaded poll loops.
  For those, build the pool AFTER fork, once per worker; every mutation of
  shared state rides a pthread mutex/condvar pair in malloc'd memory, so
  *threads inside a worker* (Swift/GCD embedders included) share the pool
  by passing its address — the identical pattern as mojoka states.
* Verified platform limitation (v0.2.0): a raw `pthread_create()` callback
  launched from Mojo does not enter the Mojo runtime and never executes its
  body, so pqmojo cannot spawn helper threads itself. Concurrency =
  fork + pool, or host-provided threads.
* A connection opened pre-fork shares one socket across children and
  corrupts the wire protocol — `PgConn` is not Copyable precisely so this
  failure cannot happen silently.

## macOS GSS note

On macOS, a forked worker's first `PQconnectdb` can die inside libpq's GSS
credential probe. The pool appends `gssencmode=disable` to DSNs unless yours
already sets it (opt out via `macos_gss_safe=False`). Raw `connect()` stays
untouched.

## Benchmark sanity (M-series local socket, dev DB)

* pooled `acquire+release` hot loop: **~50 ns/op** (health_check off;
  bookkeeping only)
* with health ping: bounded below by one `SELECT 1` RTT
* hot-path cell reads (`col_i64`, `col_bool`, `col_f64`) are zero-copy over
  libpq's internal buffers — allocation happens only at API edges like
  `col_text`

## Why TEXT protocol

Every parameter binds as TEXT and every result is scanned from PG text with
libc `strtod` for floats (byte-exact vs Go's `strconv.ParseFloat`, fixing
the ulp drift of v0.1's hand-rolled scanner) and hand-rolled integer
scanning. Postgres parses `$N` into whatever column type the statement
wants; the client stays allocation-light.

## License

MIT
