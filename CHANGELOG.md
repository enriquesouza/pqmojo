# Changelog

## v0.3.0 — 2026-08-27

Server-side prepared statements: the Parse-once/Bind-many extended-protocol
path for hot queries, integrated with the pool deadpool-StatementCache
style. **47% faster** details-shaped point lookup vs plain exec_params
(52.9 -> 28.0 us/op, 10k iters averaged, local socket).

### Added

* **PgStmt** (`pqmojo.stmt`): `conn.prepare(sql) raises -> PgStmt` runs
  PQprepare synchronously and fails AT PREPARE with the server message
  (bad SQL, unresolvable parameter contexts); auto-names are minted from a
  per-session counter (`pqs_auto_N`) via `PgConn.stmt_seq`.
  `stmt.execute(params)` / `stmt.execute_args(*args: SqlArg)` are strict
  Bind+Execute round trips reusing the ordinary PgResult scanners;
  `stmt.deallocate()` is an optional early free (idempotent). Bound to its
  exact connection — using it after close raises.
* **`prepare_named(conn, name, sql)`** and module-level
  `prepare_on(handle, syms, name, sql)` + `execute_prepared_on(...)` cores;
  `execute_prepared(conn, name, params)` (strict) binds BY NAME on any
  checked-out conn.
* **Pool plan integration**: `pool.prepare_on_acquire([(name, sql), ...])`
  registers a rolling checkout plan AND arms every conn idle right now;
  freshly-grown and health-replaced conns self-prepare during acquire via
  epoch markers on PgConn (`prepared_epoch` vs `pool.plan_epoch`) —
  replacements can never be served planless.
  `pool.prepare_all(plan) -> Int` is the point-in-time fan-out warmup over
  idle conns (registers nothing). Bad SQL dies loudly at registration on a
  short-lived probe connection; duplicate names never wedge the pool
  because arming replaces deliberately (internal DEALLOCATE + retry).
* **Non-blocking prepared path**: `send_prepared(conn, name, params)`
  submits Bind by name through PQsendQueryPrepared (same drain-first,
  one-in-flight contract); completes with ordinary `poll_result`;
  `execute_prepared_nonblocking` bundles both.
* Module layout enabling all of this without import cycles:
  `pqmojo.result` now hosts PgResult (+ `_parse_int64`, `_first_line`),
  `pqmojo.args` hosts `format_i64/format_f64` + SqlArg; query.mojo and
  params.mojo re-export them unchanged so every pre-v0.3 import path keeps
  resolving. PgSymbols gained prepare/exec_prepared/send_query_prepared —
  positional external initializers must add them.

### Honest notes

* Postgres REFUSES re-PREPARE over a live statement name ("already
  exists") at protocol level too; direct duplicates raise, replacement is
  only inside pool arming. DEALLOCATE has no IF EXISTS.
* Prepared statements are session-local: freed implicitly at conn close /
  server termination; no DEALLOCATE-on-close pass exists or is needed.
* Pool fan-outs report generic errors when they fail mid-run (Mojo
  exceptions carry no catchable value); the probe validation pass at
  registration surfaces exact server messages instead.
* tests/test_prepared_stress hardens the fleet harness beyond v0.2.x:
  raw wait-status decoding catches signal-killed children that the
  old `(status >> 8) & 0xFF` check silently accepted, and workers boot
  exclusively through their own gss-safe pools because a post-fork RAW
  connect() rides libpq's GSS probe whose Heimdal/xpc state gets forked
  children SIGKILLed on this macOS.

## v0.2.0 — 2026-08-27

The deadpool-postgres release: pools, typed columns, arrays, strict errors,
and libpq's non-blocking path. Zero Python, still runtime-dlopen, still
TEXT protocol.

### Added

* **ConnectionPool** (`PoolConfig`, `pool.acquire(timeout_ms=-1)`,
  `pool.release(conn^)`, `pool.stats()`, `pool.close()`):
  max_size hard cap with condvar-queued acquirers and deadlines,
  min_idle warmup at construction, health-check ping on reused sockets
  ("SELECT 1") with transparent stale replacement, pthread mutex/condvar
  guarding shared bookkeeping, ownership-transfer checkout
  (`release(conn^)` makes later use a compile error). Absorbs the api's
  lazy one-conn-per-worker scaffolding.
* **Non-blocking execution** (`pqmojo.asyncq`): `send_query(conn, sql,
  params)` submits parameterized TEXT without blocking;
  `poll_result(conn, timeout_ms)` drives PQconsumeInput/PQisBusy with a
  poll(2)-based deadline and returns the status-checked owning PgResult.
  Timeout leaves the statement in flight (documented recovery contract).
  Most call sites keep plain `execute()`.
* **Typed row helpers** on `PgResult`: `col_i64`, `col_f64`,
  `col_bool`, `col_text` plus `col_nullable_i64/f64/bool/text`
  (Optional[T]). `col_f64` scans floats through **libc strtod directly on
  libpq's buffer** — zero-copy and byte-exact on 17-digit shortest-repr
  inputs where v0.1's hand-rolled scanner drifted by an ulp;
  `float64()` now routes through the same strtod path.
* **Strict one-call helpers**: `execute(conn, sql[, params])`,
  `row_exists(...)`, `scalar_i64(...)` — raise carrying the server error
  text instead of masquerading as "zero rows". Legacy `exec_params` keeps
  its lenient behavior for compat; `PgResult.status()/error_message()/
  check_ok()` are public either way.
* **Param builders** absorbing consumer boilerplate:
  `int_array_literal(List[Int32])` ('{60,7501}'),
  `i64_array_literal(List[Int64])`,
  `text_array_literal(List[String])` (quoted + backslash-escaped),
  `letter_array_literal(List[UInt8])` ('{"H","D"}'), plus a variadic
  `execute_args(conn, sql, *args: SqlArg)` edge with implicit conversions
  from Int/Int64/Int32/Float64/Bool/String/StringLiteral.
* **gssencmode absorption**: pools append `gssencmode=disable` unless the
  DSN pins it (macOS forked-worker GSS crash workaround, ported from the
  api's pq_connect wrapper); opt out with `macos_gss_safe=False`.
  Raw `connect()` behavior unchanged.
* `tests/` live-database suite (`pixi run test`; SELECT-only):
  core execute/nulls/errors, typed-scan parity incl. strtod fixtures,
  send/poll incl. timeout+recovery+two-socket overlap, pool semantics
  (warmup/reuse/stale-replacement/saturation-timeout/close), forked-fleet
  stress (8×120 + 16-way burst, zero failures), ns-scale acquire/release
  benchmark (~50 ns/op health-off).

### Fixed / changed

* `float64()` result scan is now ulp-exact via strtod (see above).
* Symbol table extended (send/consume/busy/socket/result-status bindings);
  `PgSymbols` struct fields appended — positional external initializers
  must be updated.
* Documented platform limit: raw `pthread_create()` callbacks launched
  from Mojo never enter the Mojo runtime (bodies do not run); concurrency
  story remains fork-per-worker + host threads sharing the pool by
  address.

## v0.1.0 — generic libpq C-FFI client

Initial surface: connect/close, exec_params over TEXT protocol, hand-rolled
int64/float64 scanners, TEXT-array splitters, param formatters, fork
contract documentation.
