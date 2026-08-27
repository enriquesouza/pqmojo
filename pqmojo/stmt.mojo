"""pqmojo.stmt — server-side PREPARED statements: parse/plan once per
connection, Bind/Execute on every hot call.

The libpq Parse/Bind path:

    var stmt = conn.prepare(
        "SELECT id, title FROM listing_active WHERE id = $1 LIMIT 1"
    )
    var r = stmt.execute([format_i64(listing_id)])   # or stmt.execute_args(...)
    r is an ordinary status-checked PgResult
    r.clear()
    stmt.deallocate()                                # optional early free

`conn.prepare(sql)` runs PQprepare over the extended protocol and raises
carrying the server message when the statement fails to prepare (bad SQL,
ambiguous parameters) — failure surfaces AT PREPARE time, not on the first
hot call. `execute_prepared(conn, name, params)` binds BY NAME, which is how
pool-managed plans (`pool.prepare_all` / `pool.prepare_on_acquire`) reach
their statements after checkout.

Type inference notes (honest version):

* prepare passes paramTypes=NULL/nParams=0, so the server infers each
  parameter's type from context EXACTLY as the plain text-protocol queries in
  pqmojo.query do today — `$1::int4`, `$1 = ANY(periods)`,
  `filters_array @> $1` all infer as before. BYTE-PARITY-SAFE by
  construction: bind identical literal TEXT, get identical parses. The edge
  cases behave identically too: a bare target-list parameter (`SELECT $1`)
  resolves to text just as it does over exec_params, while a genuinely
  unresolvable context (`pg_typeof($1)`) is rejected at PREPARE with
  "could not determine data type of parameter $1" — the same failure class,
  surfaced earlier and louder than a first-hot-call failure.
* Parameter count is checked server-side at Bind time; a mismatch raises
  "bind message supplies N parameters, but prepared statement requires M".
  Pass exactly what the SQL declares.

Statement naming and lifetime (honest version):

* Auto-prepared statements mint unique per-session names from a counter on
  PgConn (`pqs_auto_1`, `pqs_auto_2`, ...); `prepare_named(conn, name, sql)`
  accepts caller-chosen names (pool plans use these). Duplicate names RAISE
  — Postgres refuses re-PREPARE over a live name ("prepared statement ...
  already exists") and pqmojo stays strict; only the pool's internal
  arming path replaces deliberately (DEALLOCATE + retry), so re-running a
  registered plan is safe and idempotent.
* Prepared statements are SESSION objects: they live on one backend until
  the session ends. conn.close(), pool.close(), or server-side termination
  discards them with NO DEALLOCATE round trip needed — Postgres frees them
  implicitly. pqmojo prepares outside transaction blocks only (a PREPARE
  inside one would roll back with the transaction).
* A PgStmt is bound to the exact connection it was prepared on: executing
  after that connection closed raises. Releasing a pooled conn does NOT
  invalidate its statements — the idle socket keeps its backend session, so
  re-acquiring the SAME connection serves the prepared plan again; only
  health-replaced conns lose theirs (and pool plan integration re-prepares
  replacements automatically).
* DEALLOCATE frees server memory early; use it when replacing long-lived
  SQL. Undeallocated statements die with their session — nothing leaks.

Non-blocking callers submit with send_prepared(name, params) and poll with
the ordinary poll_result.
"""

from std.collections.span import Span
from std.ffi import c_size_t, c_ssize_t, external_call
from std.memory import Pointer

from .args import SqlArg, format_i64
from .ffi import (
    CharPtr,
    PGRES_COMMAND_OK,
    PgSymbols,
    c_free,
    c_string,
    text_of,
)
from .result import PgResult


comptime AUTO_PREFIX = "pqs_auto_"


def _first_line(s: String) -> String:
    """First line of a multi-line PG error message, ERROR: prefix dropped."""
    var b = s.as_bytes()
    var n = 0
    while n < len(b) and b[n] != 10 and b[n] != 13:
        n += 1
    var line = String(unsafe_from_utf8=Span[Byte](
        unsafe_ptr=b.unsafe_ptr(), length=n
    ))
    comptime ERR_PREFIX = "ERROR:  "
    if line.find(ERR_PREFIX) == 0:
        return String(line[byte=8:])
    return line


def _wrap(addr: Int, syms: PgSymbols) -> PgResult:
    """Package a raw PQresult pointer with this connection's bound accessors."""
    return PgResult(
        addr,
        syms.ntuples,
        syms.nfields,
        syms.getvalue,
        syms.getisnull,
        syms.clear,
        syms.result_status,
        syms.result_error_message,
    )


def prepare_on(
    handle: Int, syms: PgSymbols, name: String, sql: String
) raises:
    """PREPARE `sql` under `name` on this session; strict on failure.

    The low-level core shared by conn.prepare / prepare_named / the pool's
    plan runner. PQprepare completes the extended-protocol handshake
    synchronously; anything but COMMAND_OK raises carrying the server's
    message first line, so bad SQL dies here instead of on a hot call later.
    """
    if handle == 0:
        raise Error("pqmojo: cannot prepare on a closed connection")
    var name_buf = c_string(name)
    var sql_buf = c_string(sql)
    var res = syms.prepare_fn(handle, name_buf, sql_buf, Int32(0), Int(0))
    c_free(sql_buf)
    c_free(name_buf)
    if res == 0:
        raise Error("pqmojo: PQprepare failed: "
                    + text_of(syms.error_message(handle)))
    var r = _wrap(res, syms)
    var ok = r.status() == PGRES_COMMAND_OK
    var msg = r.error_message()
    r.clear()
    if not ok:
        raise Error("pqmojo: prepare failed: " + _first_line(msg))


def prepare_or_replace_on(
    mut handle: Int, mut syms: PgSymbols, name: String, sql: String
) raises:
    """PREPARE that survives its own name being live on this session.

    First attempt verbatim; on ANY failure run DEALLOCATE and try once more,
    so an existing statement is replaced deliberately while genuine bad SQL
    still surfaces carrying the server's message (from the second attempt).
    The pool's arming/fan-out paths use this to stay idempotent across
    retries; direct conn.prepare / conn.prepare_named remain strictly
    fail-on-duplicate."""
    if handle == 0:
        raise Error("pqmojo: cannot prepare on a closed connection")
    var first_failed = False
    try:
        prepare_on(handle, syms, name, sql)
    except:
        first_failed = True
    if first_failed:
        var buf = c_string("DEALLOCATE " + _quote_ident(name))
        var res = syms.exec_params(
            handle, buf, Int32(0), Int(0),
            Int(0), Int(0), Int(0), Int32(0)
        )
        c_free(buf)
        if res != 0:
            var dr = _wrap(res, syms)
            dr.clear()
        prepare_on(handle, syms, name, sql)


def execute_prepared_on(
    handle: Int, syms: PgSymbols, name: String, params: List[String]
) raises -> PgResult:
    """Bind + Execute prepared statement `name`; strict status-checked.

    Parameter values ride TEXT exactly like exec_params (paramFormats=NULL,
    resultFormat=0), so binding semantics are byte-identical to the plain
    query paths. Raises carrying the server message when the statement is
    missing ("prepared statement ... does not exist") or any execution error
    occurs. All of pqmojo's typed column scanners apply unchanged.
    """
    if handle == 0:
        raise Error("pqmojo: cannot execute on a closed connection")
    var name_buf = c_string(name)
    var n = len(params)

    if n == 0:
        var res0 = syms.exec_prepared(
            handle, name_buf, Int32(0), Int(0),
            Int(0), Int(0), Int32(0)
        )
        c_free(name_buf)
        if res0 == 0:
            raise Error("pqmojo: PQexecPrepared failed: "
                        + text_of(syms.error_message(handle)))
        var r0 = _wrap(res0, syms)
        r0.check_ok()
        return r0^

    var addr_arr = Int(external_call["malloc", CharPtr](c_size_t(n * 8)))
    var slots = Pointer[Int64, MutAnyOrigin](unsafe_from_address=addr_arr)
    var bufs = List[CharPtr]()
    for i in range(n):
        var b = c_string(params[i])
        bufs.append(b)
        slots[unsafe_offset=i] = Int64(Int(b))

    var res = syms.exec_prepared(
        handle, name_buf, Int32(n), addr_arr,
        Int(0), Int(0), Int32(0)
    )
    for i in range(len(bufs)):
        c_free(bufs[i])
    _ = external_call["free", c_ssize_t](CharPtr(unsafe_from_address=addr_arr))
    c_free(name_buf)

    if res == 0:
        raise Error("pqmojo: PQexecPrepared failed: "
                    + text_of(syms.error_message(handle)))
    var r = _wrap(res, syms)
    r.check_ok()
    return r^


struct PgStmt(Movable):
    """One prepared statement living on ONE connection's session.

    Carries the statement name plus copies of that connection's bound symbol
    table so execute needs nothing else. Movable, not Copyable — like
    PgResult/PgConn there is exactly one owner. No destructor: let the
    session end discard it (implicit on conn close) or call deallocate().
    """

    var name: String
    var conn_handle: Int
    var syms: PgSymbols

    def __init__(out self, name: String, conn_handle: Int, syms: PgSymbols):
        self.name = String(name)
        self.conn_handle = conn_handle
        self.syms = syms.copy()

    def execute(self, params: List[String]) raises -> PgResult:
        """Strict Bind+Execute of THIS statement with TEXT params."""
        if self.conn_handle == 0:
            raise Error("pqmojo: prepared statement used after close/"
                        "deallocate")
        return execute_prepared_on(
            self.conn_handle, self.syms, self.name, params
        )

    def execute_args(self, *args: SqlArg) raises -> PgResult:
        """execute with natively-typed $N args — same renderings as the
        conn-level execute_args."""
        if self.conn_handle == 0:
            raise Error("pqmojo: prepared statement used after close/"
                        "deallocate")
        var params = List[String](capacity=len(args))
        for arg in args:
            params.append(arg.text)
        return execute_prepared_on(
            self.conn_handle, self.syms, self.name, params^
        )

    def deallocate(mut self) raises:
        """DEALLOCATE this statement now; afterwards the handle refuses
        executes. Statements left undeallocated die with their session at
        conn close — this is an early-free optimization, not a requirement.
        Idempotent: deallocating twice succeeds quietly.
        """
        if self.conn_handle == 0:
            return
        var buf = c_string("DEALLOCATE " + _quote_ident(self.name))
        var res = self.syms.exec_params(
            self.conn_handle, buf, Int32(0), Int(0),
            Int(0), Int(0), Int(0), Int32(0)
        )
        c_free(buf)
        self.conn_handle = 0
        if res == 0:
            raise Error("pqmojo: DEALLOCATE failed: PQexec returned null")
        var r = _wrap(res, self.syms)
        var ok = r.status() == PGRES_COMMAND_OK
        var msg = r.error_message()
        r.clear()
        if not ok:
            raise Error("pqmojo: DEALLOCATE failed: " + _first_line(msg))


def _quote_ident(name: String) -> String:
    """Double-quoted SQL identifier, embedded quotes doubled."""
    var buf = List[UInt8]()
    buf.append(UInt8(34))
    var b = name.as_bytes()
    for i in range(len(b)):
        if b[i] == 34:  # '"'
            buf.append(UInt8(34))
        buf.append(b[i])
    buf.append(UInt8(34))
    return String(unsafe_from_utf8=Span[Byte](
        unsafe_ptr=buf.unsafe_ptr(), length=len(buf)
    ))
