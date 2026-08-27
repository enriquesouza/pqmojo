# pqmojo

**libpq for Mojo — zero Python, runtime dlopen, text protocol.**

The tokio-postgres/deadpool-postgres analog for Mojo 1.0: connection
pooling, parameterized queries, **server-side prepared statements**, typed
row scanning, a non-blocking execution path, and **single-thread OVERLAP**
(K connections multiplexed through one poll(2) window — the v0.4.0 piece
that closes the async-runtime RPS gap) over libpq's C API. libpq is
**never linked at build time** — the dylib is probed at runtime via
`dlopen` (Homebrew, postgresql@16/@17/@14, system paths) and symbols are
bound with `dlsym`; everything crosses the boundary as the TEXT protocol.

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

## Prepared statements — parse/plan ONCE per connection

The biggest DB-side lever over plain `exec_params`: hot queries go through
libpq's Parse/Bind extended protocol so Postgres parses and plans them one
time per connection instead of on every request.

```mojo
var stmt = conn.prepare(
    "SELECT id, title FROM listing_active WHERE id = $1 LIMIT 1"
)
var r = stmt.execute_args(listing_id)   # or stmt.execute(["12345"])
r.clear()
stmt.deallocate()                       # optional; sessions free anyway
```

Prefer pool-integrated form (deadpool StatementCache shape): register a
plan ONCE per worker and every connection this pool ever serves — warm,
grown past min_idle, or health-replaced after a stale ping — self-prepares
before checkout. Call sites then bind BY NAME on whatever conn they get:

```mojo
pool.prepare_on_acquire([("details", DETAILS_SQL), ("count", COUNT_SQL)])
...
var r = execute_prepared(pool.acquire(), "details", [format_i64(listing_id)])
```

`pool.prepare_all(plan)` is the point-in-time variant: one-shot fan-out
across all conns idle right now (post-fork lazy-warmup helper; no rolling
coverage). The non-blocking twin is `send_prepared(conn, name, params)` +
`poll_result(conn, budget)`.

### Wire-level efficiency notes (honest version)

* Prepared execution still binds EVERY parameter as TEXT
  (paramFormats=NULL, resultFormat=0) — identical formatting rules to plain
  exec_params. BYTE-PARITY-SAFE by construction: consumers binding the same
  literal text get identical parses; which param types are inferred stays a
  server-side decision exactly like today (`$1::int4`, `$1 = ANY(periods)`,
  `filters_array @> $1`). A bare target-list `$1` resolves to text on both
  paths; genuinely unresolvable contexts (`pg_typeof($1)`) now fail loudly
  AT PREPARE instead of on the first hot call.
* Statements are SESSION-local: `conn.close()` / server termination frees
  them implicitly — no DEALLOCATE round trip is ever required on close.
  Releasing a pooled conn does NOT invalidate its statements (the socket
  keeps its backend); only health-replaced conns lose theirs, and the pool
  re-prepares replacements automatically via epoch markers.
* Duplicate names raise ("prepared statement ... already exists") —
  Postgres refuses blind re-PREPARE; deliberate replacement happens inside
  the pool arming paths (internal DEALLOCATE + retry keeps them idempotent).

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

## Overlap: K connections multiplexed from ONE thread (v0.4.0)

GO and RUST multiplex concurrent DB ops through async runtimes. Mojo has
no async runtime — but overlap does not need one. It needs K sockets with
queries in flight and a readiness-driven collector: while Postgres works
on query A, the wire is busy with query B, and the aggregate leaves
single-conn RTT behind. `pqmojo.pipeline` is that collector.

```mojo
from pqmojo import ConnectionPool, PoolConfig

# once per worker, after fork:
var pool = ConnectionPool(PoolConfig(dsn, max_size=8))
pool.prepare_on_acquire([("details", DETAILS_SQL)])

# per request — a k=2 window keeps TWO sockets in flight:
var pipe = pool.checkout_pipeline(2)
var a = pipe.submit("details", one(id_a))    # request id 0, in flight
var b = pipe.submit("details", one(id_b))    # request id 1, in flight
var first = pipe.collect()                   # WHICHEVER finishes first
var second = pipe.collect()
first.result.col_text(0, 1)                  # status-checked PgResult
first.result.clear()                         # house style: explicit clear
second.result.clear()
pool.release_pipeline(pipe^)
```

or the whole-overlap one-liner (M jobs round-robined through k conns,
results back in SUBMISSION order):

```mojo
var rs = pool.execute_batch("details", jobs, 2)
```

`submit()` returns a pipeline-wide request id; `collect()` returns a
`PipelineResult` (request_id, slot, status-checked PgResult) in COMPLETION
order — the id is the join key. Window contract: one in-flight statement
per conn (libpq's rule, made structural), `submit()` raises when all k
slots are busy, `collect()` raises on SQL errors or when its budget
expires (queries stay in flight; collect again or release — wedged conns
close and pool health checks reseal their slots).

Measured on the details-shaped point lookup (`WHERE id = $1`), one Mojo
thread, M-series local socket, best of 3:

| path | qps | vs 1-conn sequential |
|---|---|---|
| `execute_prepared`, 1 conn | 37.6k | 1.00x |
| `StmtPipeline` k=1 (sanity) | 35.7k | 0.95x |
| **`StmtPipeline` k=2** | **67.4k** | **1.79x** |
| `StmtPipeline` k=3 | 90.4k | 2.40x |
| `StmtPipeline` k=4 | 109.2k | 2.90x |
| `pool.execute_batch` k=2 | 63.4k | 1.69x |

### Threading model of overlap (honest version)

This is a **single-thread multiplexer, not a worker thread**. Every libpq
call runs on the owning thread, one connection at a time — libpq's
thread-safety rule holds trivially and no shared state exists. The
async-gate alternative (a background C-callback thread driving the socket
and flagging a Mojo-visible completion) was prototyped and evaluated: the
pthread mechanism itself works from Mojo (a pure-C thread body executes
and joins cleanly), but no *useful* C body is sourceable from shippable
binaries — libpq exports no poll/service loop (only connect-phase
`PQconnectPoll`/`PQresetPoll`), and producing one would mean runtime `cc`
invocation or hand-encoded JIT shellcode, both unacceptable in a driver.
The window delivers the same aggregate-RPS lever with zero cross-thread
risk to libpq.

### mojoflask route-worker recipe

```mojo
# after fork, once per worker process:
var pool = ConnectionPool(PoolConfig(DSN, max_size=4))
pool.prepare_on_acquire([("details", DETAILS_SQL)])

# inside a route handler (the worker's own thread):
var pipe = pool.checkout_pipeline(2)          # 2 plan-armed conns
var rid = pipe.submit("details", one(listing_id))
var more = pipe.submit("details", one(other_id))
var r0 = pipe.collect()                       # completion order
var r1 = pipe.collect()
# ... r0.result / r1.result; match with .request_id if order matters ...
r0.result.clear(); r1.result.clear()
pool.release_pipeline(pipe^)
```

Sizing: k=2 per route worker is the sweet spot for point lookups (1.8x
aggregate for one extra socket); k=4 approaches the local loopback
ceiling (~110k qps here). The window covers exactly the DB leg — for
compute-between-queries on a single conn, use `send_query`/`poll_result`.

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
  launched from Mojo does not enter the Mojo runtime and never executes a
  MOJO body. v0.4.0 refinement: the thread mechanism itself is sound — a
  pure-C body executes and joins cleanly — but no useful C body (a
  libpq poll/service loop) exists in any shippable binary, so pqmojo
  cannot spawn helper threads itself. Concurrency = fork + pool +
  **pipeline windows** (single-thread K-conn overlap), or host-provided
  threads.
* A connection opened pre-fork shares one socket across children and
  corrupts the wire protocol — `PgConn` is not Copyable precisely so this
  failure cannot happen silently.

## macOS GSS note

On macOS, a forked worker's first `PQconnectdb` can die inside libpq's GSS
credential probe. The pool appends `gssencmode=disable` to DSNs unless yours
already sets it (opt out via `macos_gss_safe=False`). Raw `connect()` stays
untouched.

## Benchmark sanity (M-series local socket, dev DB)

* details-shaped point lookup
  (`SELECT id, title, neighborhood, price, latitude, longitude FROM
  listing_active WHERE id = $1 LIMIT 1`), 10k iterations/rep averaged,
  best of 3:
  | path | us/op |
  |---|---|
  | plain `exec_params` (Parse+Plan every call) | **52.9** |
  | prepared Bind/Execute | **28.0** |
  | delta | **-47.0%** |
* OVERLAP scaling, same query, one thread (v0.4.0, best of 3):
  `StmtPipeline` k=2 **67.4k qps (1.79x)**, k=3 90.4k (2.40x), k=4 109.2k
  (2.90x) vs 37.6k single-conn sequential — see the Overlap section
* pooled `acquire+release` hot loop: **~50-80 ns/op** (health_check off;
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
