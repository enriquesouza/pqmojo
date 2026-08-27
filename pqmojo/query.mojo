"""pqmojo.query — parameterized execution over TEXT protocol and scanners.

exec_params binds every parameter as TEXT (paramTypes=NULL, paramLengths=NULL,
paramFormats=NULL, resultFormat=0), exactly like the proven hot path: Postgres
parses the text into whatever column type the statement wants. Results stay
PG text until an accessor scans them.

Float params format through the stdlib's shortest-round-trip rendering
(String(f64)); hand-rolled digit emission drifts ~1e-11 degrees and shifts
every geo distance — never re-implement it.
"""

from std.collections.span import Span
from std.ffi import c_size_t, c_ssize_t, external_call

from .conn import PgConn
from .ffi import (
    CharPtr,
    PGRES_COMMAND_OK,
    PGRES_EMPTY_QUERY,
    PGRES_TUPLES_OK,
    _FnResultErrorMessage,
    _FnResultStatus,
    _PQclear,
    _PQgetisnull,
    _PQgetvalue,
    _PQnfields,
    _PQntuples,
    c_free,
    c_string,
    text_of,
)


struct PgResult(Movable):
    """Owning PQresult handle with explicit, destructor-free clear().

    Holds the dlsym-bound accessors so reads take only the result. Call
    clear() exactly once when done — there is no __del__.
    """

    var handle: Int
    var ntuples: _PQntuples.type
    var nfields: _PQnfields.type
    var getvalue: _PQgetvalue.type
    var getisnull: _PQgetisnull.type
    var clear_fn: _PQclear.type
    var status_fn: _FnResultStatus
    var errmsg_fn: _FnResultErrorMessage

    def __init__(
        out self,
        handle: Int,
        ntuples: _PQntuples.type,
        nfields: _PQnfields.type,
        getvalue: _PQgetvalue.type,
        getisnull: _PQgetisnull.type,
        clear_fn: _PQclear.type,
        status_fn: _FnResultStatus,
        errmsg_fn: _FnResultErrorMessage,
    ):
        self.handle = handle
        self.ntuples = ntuples
        self.nfields = nfields
        self.getvalue = getvalue
        self.getisnull = getisnull
        self.clear_fn = clear_fn
        self.status_fn = status_fn
        self.errmsg_fn = errmsg_fn

    def clear(mut self):
        """PQclear; idempotent — a cleared result carries handle 0."""
        if self.handle != 0:
            self.clear_fn(self.handle)
            self.handle = 0

    def rows(self) -> Int:
        """Number of tuples in the result set."""
        return Int(self.ntuples(self.handle))

    def cols(self) -> Int:
        """Number of fields per row."""
        return Int(self.nfields(self.handle))

    def status(self) -> Int32:
        """PGRES_* code of this result (2 = tuples ok, 1 = command ok)."""
        return self.status_fn(self.handle)

    def error_message(self) -> String:
        """Server/libpq error text attached to a failed result ("" if none)."""
        return text_of(self.errmsg_fn(self.handle))

    def check_ok(self) raises:
        """Raise carrying the server message unless the statement succeeded.

        Empty-query results count as success; anything else that is not
        COMMAND_OK/TUPLES_OK raises. Idempotent.
        """
        var st = self.status()
        if st == PGRES_COMMAND_OK or st == PGRES_TUPLES_OK:
            return
        if st == PGRES_EMPTY_QUERY:
            return
        var msg = self.error_message()
        if msg.byte_length() == 0:
            msg = String("PQresultStatus " + String(st))
        raise Error("pqmojo: " + _first_line(msg))

    def is_null(self, row: Int, col: Int) -> Bool:
        """True when the cell is SQL NULL."""
        return self.getisnull(self.handle, Int32(row), Int32(col)) != 0

    def col_text(self, row: Int, col: Int) -> String:
        """Copy cell text; NULL cells scan as "" (use is_null to tell apart)."""
        if self.is_null(row, col):
            return String("")
        return text_of(
            self.getvalue(self.handle, Int32(row), Int32(col))
        )

    def col_nullable_text(self, row: Int, col: Int) -> Optional[String]:
        """Copy cell text; SQL NULL maps to Optional.None."""
        if self.is_null(row, col):
            return Optional[String]()
        return Optional[String](
            text_of(self.getvalue(self.handle, Int32(row), Int32(col)))
        )

    def col_i64(self, row: Int, col: Int) -> Int64:
        """Scan a decimal PG text value zero-copy; NULL -> 0 (pair with
        is_null)."""
        if self.is_null(row, col):
            return 0
        return _parse_int64(CharPtr(unsafe_from_address=self.getvalue(
            self.handle, Int32(row), Int32(col)
        )))

    def col_nullable_i64(self, row: Int, col: Int) -> Optional[Int64]:
        """Decimal scan; SQL NULL maps to Optional.None."""
        if self.is_null(row, col):
            return Optional[Int64]()
        return Optional[Int64](self.col_i64(row, col))

    def col_f64(self, row: Int, col: Int) -> Float64:
        """Scan any PG numeric text through libc strtod, ZERO COPY.

        strtod runs directly on libpq's internal buffer (NUL-terminated per
        PQgetvalue contract) — no String allocation, and byte-exact rounding
        on 17-digit inputs where hand-rolled mantissa/exponent scanners drift
        by an ulp. NULL -> 0.0 (pair with is_null).
        """
        if self.is_null(row, col):
            return 0.0
        var p = CharPtr(unsafe_from_address=self.getvalue(
            self.handle, Int32(row), Int32(col)
        ))
        return external_call["strtod", Float64](p, 0)

    def col_nullable_f64(self, row: Int, col: Int) -> Optional[Float64]:
        """strtod scan; SQL NULL maps to Optional.None."""
        if self.is_null(row, col):
            return Optional[Float64]()
        return Optional[Float64](self.col_f64(row, col))

    def col_bool(self, row: Int, col: Int) -> Bool:
        """PG boolean 't'/'f' read as one byte, ZERO COPY; NULL -> False."""
        if self.is_null(row, col):
            return False
        var p = CharPtr(unsafe_from_address=self.getvalue(
            self.handle, Int32(row), Int32(col)
        ))
        return p[unsafe_offset=0] == 116  # 't'

    def col_nullable_bool(self, row: Int, col: Int) -> Optional[Bool]:
        """'t'/'f' scan; SQL NULL maps to Optional.None."""
        if self.is_null(row, col):
            return Optional[Bool]()
        return Optional[Bool](self.col_bool(row, col))

    def text(self, row: Int, col: Int) -> String:
        """Copy cell text; NULL cells scan as "" (use is_null to tell apart).

        Legacy alias of col_text.
        """
        return self.col_text(row, col)

    def text_or_null(self, row: Int, col: Int) -> Optional[String]:
        """Copy cell text; SQL NULL maps to Optional.None.

        Legacy alias of col_nullable_text.
        """
        if self.is_null(row, col):
            return Optional[String]()
        return Optional[String](
            text_of(self.getvalue(self.handle, Int32(row), Int32(col)))
        )

    def int64(self, row: Int, col: Int) -> Int64:
        """Scan a decimal PG text value; NULL -> 0 (pair with is_null).

        Legacy alias of col_i64.
        """
        return self.col_i64(row, col)

    def int32(self, row: Int, col: Int) -> Int32:
        """Scan a decimal PG text value, truncated to Int32; NULL -> 0."""
        return Int32(self.col_i64(row, col))

    def float64(self, row: Int, col: Int) -> Float64:
        """Scan PG numeric output through libc strtod; NULL -> 0.0.

        Was a hand-rolled mantissa/exponent scanner that drifted by an ulp on
        17-digit inputs; now byte-identical to Go's strconv.ParseFloat
        because strtod IS the reference implementation.
        """
        return self.col_f64(row, col)


def exec_params(
    conn: PgConn, sql: String, params: List[String]
) raises -> PgResult:
    """Run one parameterized statement; all params bind as TEXT.

    Raises carrying PQerrorMessage when libpq returns no result. The returned
    PgResult owns its handle — clear() it explicitly.
    """
    var sql_buf = c_string(sql)
    var n = len(params)

    if n == 0:
        var res0 = conn.syms.exec_params(
            conn.handle, sql_buf, Int32(0), Int(0),
            Int(0), Int(0), Int(0), Int32(0)
        )
        c_free(sql_buf)
        if res0 == 0:
            raise Error("pqmojo: PQexecParams failed: "
                        + text_of(conn.syms.error_message(conn.handle)))
        return PgResult(
            res0,
            conn.syms.ntuples,
            conn.syms.nfields,
            conn.syms.getvalue,
            conn.syms.getisnull,
            conn.syms.clear,
            conn.syms.result_status,
            conn.syms.result_error_message,
        )

    var addr_arr = Int(0)
    var bufs = List[CharPtr]()
    if n > 0:
        addr_arr = Int(external_call["malloc", CharPtr](c_size_t(n * 8)))
        var slots = Pointer[Int64, MutAnyOrigin](
            unsafe_from_address=addr_arr
        )
        for i in range(n):
            var b = c_string(params[i])
            bufs.append(b)
            slots[unsafe_offset=i] = Int64(Int(b))

    var res = conn.syms.exec_params(
        conn.handle, sql_buf, Int32(n), Int(0),
        addr_arr, Int(0), Int(0), Int32(0)
    )
    for i in range(len(bufs)):
        c_free(bufs[i])
    if addr_arr != 0:
        _ = external_call["free", c_ssize_t](
            CharPtr(unsafe_from_address=addr_arr)
        )
    c_free(sql_buf)

    if res == 0:
        raise Error("pqmojo: PQexecParams failed: "
                    + text_of(conn.syms.error_message(conn.handle)))

    return PgResult(
        res,
        conn.syms.ntuples,
        conn.syms.nfields,
        conn.syms.getvalue,
        conn.syms.getisnull,
        conn.syms.clear,
        conn.syms.result_status,
        conn.syms.result_error_message,
    )


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
    comptime SKIP: Int = 8
    if line.find(ERR_PREFIX) == 0:
        return String(line[byte=SKIP:])
    return line


def execute(conn: PgConn, sql: String) raises -> PgResult:
    """One blocking round trip, no params; raises on SQL errors.

    Like exec_params but enforces result status: a statement the server
    rejects raises carrying the server's message instead of returning an
    empty-looking PgResult.
    """
    var res = exec_params(conn, sql, List[String]())
    res.check_ok()
    return res^


def execute(conn: PgConn, sql: String, params: List[String]) raises -> PgResult:
    """execute with TEXT params; raises on SQL errors."""
    var res = exec_params(conn, sql, params)
    res.check_ok()
    return res^


def row_exists(conn: PgConn, sql: String, params: List[String]) raises -> Bool:
    """True when the SELECT yields at least one row (EXISTS-shaped checks).

    Raises on SQL errors (unlike hand-rolled rows()>0 checks that silently
    treat failures as false). Clears the result internally.
    """
    var res = execute(conn, sql, params)
    var found = res.rows() > 0
    res.clear()
    return found


def row_exists(conn: PgConn, sql: String) raises -> Bool:
    """row_exists without params."""
    return row_exists(conn, sql, List[String]())


def scalar_i64(
    conn: PgConn, sql: String, params: List[String]
) raises -> Optional[Int64]:
    """First cell of the first row as Int64; Optional.None on zero rows.

    Raises when zero columns come back or the server rejects the statement.
    """
    var res = execute(conn, sql, params)
    var out = Optional[Int64]()
    if res.rows() > 0:
        if res.cols() < 1:
            res.clear()
            raise Error("pqmojo: scalar_i64 needs at least one column")
        out = Optional[Int64](res.int64(0, 0))
    res.clear()
    return out^


def scalar_i64(conn: PgConn, sql: String) raises -> Optional[Int64]:
    """scalar_i64 without params."""
    return scalar_i64(conn, sql, List[String]())


def _parse_int64(p: CharPtr) -> Int64:
    """Signed decimal scan over a NUL-terminated PG text value."""
    var v: Int64 = 0
    var neg = False
    var i = 0
    var c = p[unsafe_offset=i]
    if c == 45:  # '-'
        neg = True
        i += 1
        c = p[unsafe_offset=i]
    while c >= 48 and c <= 57:
        v = v * 10 + Int64(c - 48)
        i += 1
        c = p[unsafe_offset=i]
    return -v if neg else v


def format_f64(v: Float64) -> String:
    """Shortest round-trip decimal text for a float param — String(v) itself.

    Hand-rolled digit emission was tried once and drifted the query point;
    the stdlib rendering is exact and runs once per call. Do not replace.
    """
    return String(v)


def format_i64(v: Int64) -> String:
    """Decimal rendering of an Int64 param; digits least-significant first,
    reversed at the end."""
    if v == 0:
        return String("0")
    var neg = v < 0
    var x = -v if neg else v
    var digits = List[UInt8]()
    while x > 0:
        digits.append(UInt8(48 + x % 10))
        x //= 10
    var out = List[UInt8](capacity=len(digits) + 1)
    if neg:
        out.append(45)
    var j = len(digits) - 1
    while j >= 0:
        out.append(digits[j])
        j -= 1
    return String(unsafe_from_utf8=Span(
        unsafe_ptr=out.unsafe_ptr(), length=len(out)
    ))
