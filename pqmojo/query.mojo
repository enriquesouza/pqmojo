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

    def __init__(
        out self,
        handle: Int,
        ntuples: _PQntuples.type,
        nfields: _PQnfields.type,
        getvalue: _PQgetvalue.type,
        getisnull: _PQgetisnull.type,
        clear_fn: _PQclear.type,
    ):
        self.handle = handle
        self.ntuples = ntuples
        self.nfields = nfields
        self.getvalue = getvalue
        self.getisnull = getisnull
        self.clear_fn = clear_fn

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

    def is_null(self, row: Int, col: Int) -> Bool:
        """True when the cell is SQL NULL."""
        return self.getisnull(self.handle, Int32(row), Int32(col)) != 0

    def text(self, row: Int, col: Int) -> String:
        """Copy cell text; NULL cells scan as "" (use is_null to tell apart)."""
        if self.is_null(row, col):
            return String("")
        return text_of(
            self.getvalue(self.handle, Int32(row), Int32(col))
        )

    def text_or_null(self, row: Int, col: Int) -> Optional[String]:
        """Copy cell text; SQL NULL maps to Optional.None."""
        if self.is_null(row, col):
            return Optional[String]()
        return Optional[String](
            text_of(self.getvalue(self.handle, Int32(row), Int32(col)))
        )

    def int64(self, row: Int, col: Int) -> Int64:
        """Scan a decimal PG text value; NULL -> 0 (pair with is_null)."""
        if self.is_null(row, col):
            return 0
        return _parse_int64(CharPtr(unsafe_from_address=self.getvalue(
            self.handle, Int32(row), Int32(col)
        )))

    def int32(self, row: Int, col: Int) -> Int32:
        """Scan a decimal PG text value, truncated to Int32; NULL -> 0."""
        return Int32(self.int64(row, col))

    def float64(self, row: Int, col: Int) -> Float64:
        """Scan PG float8 output ([+-]digits[.digits][eE±d]); NULL -> 0.0."""
        if self.is_null(row, col):
            return 0.0
        return _parse_float64(CharPtr(unsafe_from_address=self.getvalue(
            self.handle, Int32(row), Int32(col)
        )))


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
    )


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


def _parse_float64(p: CharPtr) -> Float64:
    """Scan PG float8 output: [+-]digits[.digits][eE[+-]digits].

    Accumulates the mantissa EXACTLY into an Int64 (PG emits <=17 significant
    digits), tracks the decimal exponent separately and applies one power of
    ten at the end — single-rounding conversion, byte identical to Go's
    strconv.ParseFloat.
    """
    var neg = False
    var i = 0
    var c = p[unsafe_offset=i]
    if c == 45:
        neg = True
        i += 1
    elif c == 43:
        i += 1
    c = p[unsafe_offset=i]

    var mant: Int64 = 0
    var seen_digit = False
    var dec_exp: Int64 = 0
    while c >= 48 and c <= 57:
        if mant < 1000000000000000000:
            mant = mant * 10 + Int64(c - 48)
        else:
            dec_exp += 1
        seen_digit = True
        i += 1
        c = p[unsafe_offset=i]
    if c == 46:
        i += 1
        c = p[unsafe_offset=i]
        while c >= 48 and c <= 57:
            if mant < 1000000000000000000:
                mant = mant * 10 + Int64(c - 48)
                dec_exp -= 1
            seen_digit = True
            i += 1
            c = p[unsafe_offset=i]
    if not seen_digit:
        return 0.0

    var exp: Int64 = 0
    var exp_neg = False
    if c == 101 or c == 69:
        i += 1
        c = p[unsafe_offset=i]
        if c == 45:
            exp_neg = True
            i += 1
        elif c == 43:
            i += 1
        c = p[unsafe_offset=i]
        while c >= 48 and c <= 57:
            exp = exp * 10 + Int64(c - 48)
            i += 1
            c = p[unsafe_offset=i]
        if exp_neg:
            exp = -exp
    exp += dec_exp

    var v = Float64(mant)
    if exp != 0:
        var m = 1.0
        var base = 10.0
        var k = exp if exp > 0 else -exp
        while k > 0:
            if k & 1:
                m *= base
            base *= base
            k >>= 1
        v = v * m if exp > 0 else v / m
    return -v if neg else v


def _parse_span_int64(b: Span[Byte, _]) -> Int64:
    """Signed decimal parse over a byte span (array-element variant)."""
    var v: Int64 = 0
    var neg = False
    var i = 0
    if len(b) > 0 and b[0] == 45:
        neg = True
        i = 1
    elif len(b) > 0 and b[0] == 43:
        i = 1
    while i < len(b) and b[i] >= 48 and b[i] <= 57:
        v = v * 10 + Int64(b[i] - 48)
        i += 1
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
