# Changelog

## v0.7.0 — 2026-08-28

PG TEXT timestamp decode/render moves into the library: the frozen
verbatim port of the origin application's time module, with the single
`origin: alugue-mojo-api extensions/time.mojo` attribution line at file
top (the ecosystem's one-allowed-mention convention). Pure text/format
mechanics — no DB, no I/O, DB-free tests.

### Added

* `pqmojo.timestamp` module, exported at package root:
  - `parse_postgres_timestamp_bytes_to_microseconds(ptr, n) -> Int64` —
    strict PG TEXT decode "YYYY-MM-DD HH:MM:SS[.ffffff][(+|-)HH[:MM]]"
    straight off libpq's text buffer (byte pointer + length, no
    intermediate String) into UTC micros; the offset is APPLIED, not
    preserved; trims ONLY " " and "\\t"; 0 on malformed. Frozen quirks
    pinned by tests: digit fields never range-checked, separators never
    validated, bytes after the offset ignored.
  - `parse_postgres_timestamp_bytes_lenient(ptr, n) -> Int64` — identical
    grammar; the trim set extends to " ", "\\t", "\\n", "\\r" at both
    ends (the only behavioral difference).
  - `render_postgres_timestamp_text(micros) -> String` — the inverse for
    offset-free UTC micros, "YYYY-MM-DD HH:MM:SS": fractional micros
    truncated, negative micros floor to the prior day, the year NOT
    zero-padded below 1000 (frozen String(Int) behavior).
  - `parse_instant(raw) -> InstantParse` — human-input validation:
    "DD/MM/YYYY HH:MM" (exactly 16 chars, day-first), "YYYY-MM-DD
    [T| ]HH:MM[:SS]", trailing "Z" tolerated, ranges enforced (month
    1-12, day 1-31, hour 0-23, minute/second 0-59); returns ok flag +
    micros + civil fields.
  - `unix_seconds_now() -> Int64` — the libc time(2) wrapper.
  - Calendar primitives `days_since_epoch_for_date` / `civil_from_days`
    / `is_leap` / `day_count_in_month` (Howard Hinnant).
* `tests/test_timestamp.mojo` — DB-free, 99 checks: round-trips
  (offset-free text, +00, +05:30, -08), fractional padding (".5" ->
  500000) and the 6-digit cap, strict-vs-lenient trim difference,
  malformed->0 matrix, parse_instant accept/reject matrix, leap years
  (1900/2000/2024), a calendar round-trip sweep over all 1,460,970 CE
  dates 1..4000, and the calendar-twin verdict sweep below.

### Calendar-twin verdict — both era spellings stay

The strict parser routes through the public `days_since_epoch_for_date`,
the lenient parser through the private co-ported era spelling
`_days_from_civil_alt` — exactly as the origin file ships them. A dense
sweep (years -4000..4000 x 12 months x 31 days, 2,976,372 comparisons,
pinned in the suite) proves the two spellings return IDENTICAL days for
every adjusted year >= 0, and at negative adjusted years diverge ONLY
where yy % 400 == 0 (public spelling one day lower; 3,720 cases) or
yy % 400 == 399 (private spelling one day lower; 3,782 cases) — 7,502
one-day mismatches total, the only in-format one being year 0000
Jan/Feb. Divergence proven, so the twin is kept, not collapsed.

### Renamed vs the origin application

No business terms on the library surface. Renames: the nearby-variant
parser -> `parse_postgres_timestamp_bytes_lenient` (its real property is
the lenient trim set), `seconds_since_epoch_now` -> `unix_seconds_now`,
`render_microseconds_as_timestamp_text` -> `render_postgres_timestamp_text`,
private `_days_from_civil_nearby` -> `_days_from_civil_alt`. Application
consumers re-point in their own wave.

## v0.6.0 — 2026-08-27

Typed row mapping: the `db:`-tag half of Rust sqlx's `FromRow`, for Mojo
1.0's no-proc-macros reality. A row struct declares its column mapping
ONCE (name -> field, target type incl. `Optional[T]` for nullable) and
`query_as[T]` builds `List[T]` from any result — the declaration-site
table is exactly what a codegen emits from `# db "column_name"` trailing
comments (same grammar mojoserde-gen records).

### Added

* `FromRow` trait + `RowColumns` — the declaration-site table: one entry
  per field in order; non-empty entries name columns (PQfnumber,
  case-insensitive, resolved ONCE per result), an empty entry resolves
  positionally. A missing column raises naming the struct, field, expected
  column and the result's actual columns.
* `RowValue` protocol + stdlib conformances — field types drive the
  readers: Int64/Int32/Float64/Bool/String, List[Int32]/List[Int64]/
  List[String], Optional of any of those. TEXT mode reuses the col_*
  scanners (lenient, identical semantics); BINARY mode routes by column
  type OID — a Float64 field over a numeric column runs the bit-identical
  numeric rebuild, over float8 the bitcast; OIDs a field type cannot read
  raise naming the column instead of reinterpreting wire bytes.
* `query_as[T]` / `query_as_binary[T]` — List[T], result cleared inside.
* `query_one_as[T]` / `query_one_as_binary[T]` — Optional[T],
  ErrNoRows semantics (None on empty set, raises on SQL errors).
* `query_prepared_as[T]` — conn and pool-checkout twins.
* `map_rows_as[T]` / `map_rows_as_binary[T]` — map a caller-held PgResult
  (poll_result, pipelines, custom prepared wrappers).
* `RowPlan` + `resolve_row_plan[T]` + `map_rows_as_planned[T]` /
  `map_rows_as_binary_planned[T]` — resolve once per STATEMENT, reuse
  across same-shape results; mismatched results raise.
* `PgResult.bin_int64_array` int8[] binary reader + the
  `decode_i8_array` wire decoder beneath it.
* Bench: query_as vs the api-shaped hand-rolled scan core (both build
  List[T]) on the 30-col x 20-row real-shape SELECT — +1.6..+3.3% across
  convert-only and end-to-end, TEXT and BINARY (README table).

### Internal

* `PgSymbols` gained three dlsym-bound accessors (`column_index` =
  PQfnumber, `column_type` = PQftype, `column_name` = PQfname);
  construction stays internal to `open_libpq`. No existing export's name
  or behavior changed; `PgResult`'s shape is untouched.


## v0.5.4 — 2026-08-28

Array binary readers renamed to spell the Mojo element type (public-surface
naming wave; zero decoding changes, both old names still callable):

### Added

* `PgResult.bin_int32_array` — canonical name for the int4[] reader
  (previously only `bin_i4_array`).
* `PgResult.bin_int64_array` — canonical name for the int8[] reader
  (previously only `bin_i8_array`); README binary coverage matrix now lists
  the int8[] row.

### Deprecated

* `PgResult.bin_i4_array` — deprecated alias of `bin_int32_array`.
* `PgResult.bin_i8_array` — deprecated alias of `bin_int64_array`. Both
  aliases are kept so mid-wave consumers keep compiling; they delegate
  one-for-one and will be removed in a future breaking wave.

## v0.5.3 — 2026-08-28 (entry added retroactively at v0.5.4 time)

* `split_postgres_int64_array` — bigint[] text-splitter twin of
  `split_postgres_int32_array`, exported at package root.

## v0.5.2 — 2026-08-27


PUBLIC API NAMING scrub (doc/test-only; zero library-code behavior changes,
no API surface changes — `bin_numeric_to_f64` etc. are already generic).

### Changed

* **Neutral fixture database**: the live suite no longer reads any
  application schema. Tests run against a dedicated `pqmojo_test` database
  (unix-socket peer auth) and a suite-owned `pqmojo_test_items` table that
  `tests/fixture.mojo` CREATEs in setup and DROPs after teardown —
  `setup_fixture()` / `teardown_fixture()` bracket each affected main().
* **Column-type coverage preserved exactly**: the fixture table carries
  int8 / int4 / float8 / numeric (incl NaN, ±Infinity, 1e-130, 1e40,
  17-significant-digit and 30-digit values) / text / bool / int4[] /
  text[] / timestamp; the 30-column hot-shape SELECT keeps every column
  position and type of the old query (id/owner int8, house_number/stars/
  score int4, lat/lon float8, amount_1..amount_6 numeric::float8, seen_at
  timestamp, tags int4[], gallery text[]), so binary-vs-text parity, the
  exhaustive numeric dual-parse, NULL handling and array readers exercise
  the identical code paths as before.
* **Docstrings/README/scratch**: SQL examples moved to a neutral
  `items(id, tags int4[], attrs numeric, name text)` schema; benchmark
  narratives describe shapes and types, not the originating product.

## v0.5.0 — 2026-08-27

BINARY result format (fmt=1) for prepared-statement-shaped hot paths: the
server stops encoding text and the client stops parsing it. On the api's
real 30-column nearby SELECT (20 rows), client convert CPU drops **7.21 ->
1.31 us/row (5.51x)** and full end-to-end (prepared exec + convert + clear)
drops **21.90 -> 6.89 us/row (3.18x)** — the miss-path CPU lever.

### Added

* **Binary execution** — same TEXT params on the way in, only the
  resultFormat flag flips (zero breakage: every existing export, function
  and byte behavior untouched):
  `conn.execute_binary(sql, params)` /
  `execute_binary(conn, sql, params)` (strict),
  `exec_params_binary` (lenient), `pipe.submit_binary(name, params)` on the
  pipeline window, `send_prepared_binary(conn, name, params)` +
  `poll_result` for the non-blocking pair.
* **Typed binary readers on PgResult** (new `pqmojo.binary` decoding core):
  `bin_i64` / `bin_i32` (BE two's-complement bitcast), `bin_f64` (8-byte BE
  IEEE754 bitcast — bit-identical to the text path's strtod), `bin_bool`,
  `bin_text` (raw UTF8, no unescaping), `bin_bytes` (zero-copy Span over
  the wire bytes), `bin_numeric_to_f64` (base-10000 groups -> exact decimal
  string -> libc strtod), `bin_i4_array` / `bin_text_array` (1-D, NULL
  elements dropped, UTF8-safe length-prefixed elements). NULLs short-circuit
  to the same zero values the text readers use. Decoders are strict: a
  length that contradicts the layout raises instead of reinterpreting
  garbage.
* **numeric bit-exactness, proven exhaustively**: every DISTINCT
  daily/weekly/monthly/yearly/hourly/period price in the live fixture DB
  (474 numeric values) plus 18 synthetic edge values (negatives, zero,
  trailing zeros, 1e-130/-0.001/1e40, 17-significant-digit values, NaN,
  ±Infinity) dual-parsed text-strtod vs binary reader — ALL bit-identical
  Float64.
* **Wire verification**: numeric wire layout (ndigits:int16, weight:int16,
  sign:uint16 — 0x0000/0x4000/0xC000/0xD000/0xF000 — dscale:uint16,
  base-10000 int16 digit groups) and array layout (ndim/flags/elemtype/
  [nelems/lbound], length-prefixed elements) confirmed byte-for-byte against
  the server before implementation.
* **Round-trip parity**: the api's real 30-column nearby SELECT compared
  column-by-column (binary readers vs text readers) for 20 real rows — 600
  cells, including the int8/int4/float8/text/NULL columns, filters_array
  (int4[]) and photos_array (text[]) vs the text splitters, and data_anuncio
  timestamps read as int8 micros matched against the ISO text rendering.
* **`tests/test_binary.mojo`** (bit patterns, NULL handling per reader,
  bin_bytes UTF8 view, arrays vs text splitters, synthetic + exhaustive
  live numeric dual-parse, strict-error contracts, pipeline submit_binary,
  30-col round trip), **`tests/test_binary_bench.mojo`** (convert-only and
  end-to-end text-vs-binary tables, checksum-guarded). Suite: 14/14 green.
* Bench honesty note: for the nearby row shape BINARY is ~13% LARGER on the
  wire (866 vs 764 B/row — short numeric text vs fixed-width float8); the
  win is CPU, not bytes.

### Coverage (fmt=1 readers)

int8, int4, float8, bool, text/varchar/bpchar, numeric, int4[], text[],
plus type-agnostic raw `bin_bytes`. Still text-only (no binary reader):
int2, float4, oid, json/jsonb, uuid, bytea, date/time/timestamp/timestamptz
(timestamp binary = int8 micros since 2000-01-01, readable via `bin_i64`),
and other exotic types — cast those columns in SQL or read raw bytes.

## v0.4.0 — 2026-08-27

OVERLAP: K connections multiplexed through ONE thread — the capability that
closes MOJO's last structural RPS gap vs GO/RUST async runtimes. Aggregate
throughput on the details-shaped point lookup scales **1.79x (k=2),
2.40x (k=3), 2.90x (k=4)** over the single-conn sequential ceiling
(37.6k -> 109.2k qps, one thread, best of 3, local socket), with ZERO
cross-thread libpq risk.

### Added

* **StmtPipeline** (`pqmojo.pipeline`): a window of K plan-armed conns
  driven as one readiness-multiplexed unit.
  `pipe.submit(name, params) -> request_id` Bind/Executes (PQsendQueryPrepared)
  on the next free slot round-robin; `pipe.collect(timeout_ms=30_000)`
  poll(2)s ALL in-flight fds AT ONCE, PQconsumeInputs every ready socket,
  and returns the first completed result as a `PipelineResult`
  (request_id, slot, status-checked PgResult) in completion order — the
  request id is the deterministic join key (per-conn results arrive in
  submission order by protocol). `pipe.execute_batch(name, jobs)` runs M
  jobs through the window and returns submission-ordered results.
  `pipe.slots() / pipe.in_flight()` for observability; `pipe.drain()`
  recycles fully-drained conns and CLOSES any conn with a query still
  running server-side.
* **Pool integration**: `pool.checkout_pipeline(k=2, timeout_ms=-1)`
  acquires k health-checked, plan-armed conns into one window (k clamped
  to [1, min(k, max_size, 64)]); `pool.release_pipeline(pipe^)` drains and
  returns every conn (closed slots self-heal via the acquire health
  check); `pool.execute_batch(name, jobs, k=2)` is the checkout+batch+
  release one-liner. On mid-batch failure the pipeline is drained before
  the error re-surfaces generically.
* **Tests**: `tests/test_pipeline.mojo` (window round-robin, request-id
  identity across drain cycles, window-full + nothing-in-flight contracts,
  strict SQL-error propagation, timeout + recovery, k=1 degeneration,
  release health, k=2-vs-k=1 overlap sanity >=1.25x),
  `tests/test_pipeline_stress.mojo` (10,001 windowed submit/collect cycles
  with per-cycle value verification — zero lost completions, 63-65k qps —
  plus a 6x300 fork()-ed fleet, zero failures),
  `tests/test_pipeline_bench.mojo` (the scaling table above; gates: k=2
  >= 1.6x seq, k=4 > k=2, k=1 <= 1.35x seq).

### Design decision (evaluated empirically, honest version)

* The async-gate alternative (option a: a pthread worker whose pure-C body
  drives libpq socket polling and flags a Mojo-visible completion) was
  probed on this toolchain. Probe: `pthread_create` from Mojo with a C
  body (`strlen` as start routine) executes and joins cleanly (rc=0,
  correct exit value) — the v0.2.0 "threads never run" finding applies
  ONLY to Mojo bodies. But no USEFUL C body is sourceable: libpq exports
  no poll/service loop (`nm -gU`: only connect-phase PQconnectPoll /
  PQresetPoll, PQisthreadsafe, PQregisterThreadLock), no single-argument
  libc function implements "poll fd until PQconsumeInput-able", and
  producing one would require runtime `cc` invocation or hand-encoded
  arm64 JIT shellcode (MAP_JIT + W^X toggles) — both rejected for a
  driver. Option (b), the single-thread poll-many window, delivers the
  same aggregate-RPS lever (GO/RUST's effective DB concurrency) with no
  shared state and no cross-thread libpq access. Where option (a) would
  additionally win — Mojo compute on the SAME thread while ONE query runs
  — the existing `send_query`/`poll_result` pair already serves.

### Honest notes

* `collect()` completion order is arbitrary by nature; callers matching
  results to requests use `request_id`. `execute_batch` reorders into
  submission order internally.
* The pollfd scratch assumes darwin's 8-byte `struct pollfd` (this
  library targets osx-arm64; revisit the stride for other platforms).
* `pool.execute_batch` mid-batch failures re-raise a generic message
  (Mojo exceptions carry no catchable value); drive `StmtPipeline`
  submit/collect directly when the exact server message matters.
* Window conns come from `pool.acquire()`, so they carry the fork
  contract and the prepared-plan top-up; a pipeline is ONE worker
  thread's object — not thread-safe, not Copyable, like everything else
  here.

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
