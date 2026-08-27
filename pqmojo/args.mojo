"""pqmojo.args — leaf param formatting: scalar renderers and SqlArg.

Sits at the BOTTOM of the dependency graph so both the conn-facing query
layer and prepared statements can share one param convention: every value
renders to its Postgres TEXT input form at the API edge (ints via
format_i64, floats via the shortest-round-trip stdlib rendering, bools as
't'/'f') and Postgres parses text into whatever type the statement wants.
Float formatting is String(f64) itself; hand-rolled digit emission drifts
~1e-11 degrees and shifts every geo distance — never re-implement it.
"""

from std.collections.span import Span


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
