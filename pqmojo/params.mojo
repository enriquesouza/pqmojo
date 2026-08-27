"""pqmojo.params — param building for $N placeholders and TEXT[]/int[] literals.

SqlArg lets call sites pass native values straight into execute_args():

    var res = execute_args(
        conn,
        "SELECT id FROM listing_active WHERE filters_array @> $1 LIMIT $2",
        int_array_literal(filter_ids), window,
    )

Every argument renders to its Postgres TEXT input form at the API edge
(ints via format_i64, floats via the shortest-round-trip stdlib rendering,
bools as 't'/'f', lists as array literals) — matching the proven hot-path
convention that Postgres parses text into whatever type the statement wants.
"""

from .conn import PgConn
from .query import PgResult, execute, format_f64, format_i64


struct SqlArg(Copyable, Movable):
    """One bound parameter, already rendered to Postgres input TEXT."""

    var text: String

    @implicit
    def __init__(out self, value: StringLiteral):
        self.text = String(value)

    @implicit
    def __init__(out self, value: String):
        self.text = String(value)

    @implicit
    def __init__(out self, value: Int):
        self.text = format_i64(Int64(value))

    @implicit
    def __init__(out self, value: Int64):
        self.text = format_i64(value)

    @implicit
    def __init__(out self, value: Int32):
        self.text = format_i64(Int64(value))

    @implicit
    def __init__(out self, value: Float64):
        self.text = format_f64(value)

    @implicit
    def __init__(out self, value: Bool):
        self.text = "t" if value else "f"


def int_array_literal(vals: List[Int32]) -> String:
    """'{60,23}' — integer[] input text (the `filters_array @> $4` param)."""
    var out = String("{")
    for i in range(len(vals)):
        if i > 0:
            out += ","
        out += format_i64(Int64(vals[i]))
    return out + "}"


def i64_array_literal(vals: List[Int64]) -> String:
    """'{1,2}' — bigint[] input text."""
    var out = String("{")
    for i in range(len(vals)):
        if i > 0:
            out += ","
        out += format_i64(vals[i])
    return out + "}"


def _append_quoted(mut buf: List[UInt8], b: Span[Byte, _]):
    """Append one escaped, double-quoted array element."""
    buf.append(UInt8(34))
    for i in range(len(b)):
        var c = b[i]
        if c == 34 or c == 92:  # '"' or '\\'
            buf.append(UInt8(92))
        buf.append(c)
    buf.append(UInt8(34))


def text_array_literal(vals: List[String]) -> String:
    """'{"H","D"}' — fully-quoted, backslash-escaped text[] input text.

    Correct for plain period letters as well as embedded quotes/backslashes,
    so it absorbs both upstream builders (letter-array and generic-text).
    """
    var buf = List[UInt8](capacity=8)
    buf.append(UInt8(123))  # '{'
    for i in range(len(vals)):
        if i > 0:
            buf.append(UInt8(44))  # ','
        _append_quoted(buf, vals[i].as_bytes())
    buf.append(UInt8(125))  # '}'
    return String(unsafe_from_utf8=Span[Byte](
        unsafe_ptr=buf.unsafe_ptr(), length=len(buf)
    ))


def letter_array_literal(vals: List[UInt8]) -> String:
    """'{"H","D"}' built element-wise from bare ASCII bytes — same output as
    text_array_literal over letters, zero intermediate Strings."""
    var buf = List[UInt8](capacity=len(vals) * 3 + 2)
    buf.append(UInt8(123))
    for i in range(len(vals)):
        if i > 0:
            buf.append(UInt8(44))
        buf.append(UInt8(34))
        var c = vals[i]
        if c == 34 or c == 92:  # '"' or '\\'
            buf.append(UInt8(92))
        buf.append(c)
        buf.append(UInt8(34))
    buf.append(UInt8(125))
    return String(unsafe_from_utf8=Span[Byte](
        unsafe_ptr=buf.unsafe_ptr(), length=len(buf)
    ))


def execute_args(conn: PgConn, sql: String, *args: SqlArg) raises -> PgResult:
    """One blocking round trip with natively-typed $N args.

    Raises on SQL errors (result-status enforced), exactly like execute().
    """
    var params = List[String](capacity=len(args))
    for arg in args:
        params.append(arg.text)
    return execute(conn, sql, params^)


def row_exists_args(conn: PgConn, sql: String, *args: SqlArg) raises -> Bool:
    """row_exists with natively-typed $N args."""
    var params = List[String](capacity=len(args))
    for arg in args:
        params.append(arg.text)
    var res = execute(conn, sql, params^)
    var found = res.rows() > 0
    res.clear()
    return found


def scalar_i64_args(
    conn: PgConn, sql: String, *args: SqlArg
) raises -> Optional[Int64]:
    """scalar_i64 with natively-typed $N args."""
    var params = List[String](capacity=len(args))
    for arg in args:
        params.append(arg.text)
    var res = execute(conn, sql, params^)
    var out = Optional[Int64]()
    if res.rows() > 0:
        if res.cols() < 1:
            res.clear()
            raise Error("pqmojo: scalar_i64 needs at least one column")
        out = Optional[Int64](res.int64(0, 0))
    res.clear()
    return out^
