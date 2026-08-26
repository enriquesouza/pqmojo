"""pqmojo.pgarray — Postgres TEXT-array literal splitting.

PG renders arrays as "{23,60}" or "{\"fotos/a.jpg\",\"b\\\"c.png\"}". The
splitter honors double-quoted elements and backslash escapes (PG writes \\"
and \\\\ inside quotes; a backslash consumes the next byte everywhere).
Unquoted NULL tokens are dropped; a quoted "NULL" survives as text.
"""

from std.collections.span import Span


def split_postgres_text_array(text: String) -> List[String]:
    """Split a PG array literal into unescaped element strings, in order.

    A non-array input (anything not starting with '{') yields an empty list.
    """
    var out = List[String]()
    var b = text.as_bytes()
    var n = len(b)
    if n < 2 or b[0] != 123:  # '{'
        return out^
    var i = 1
    while i < n and b[i] != 125:  # '}'
        var cur = List[UInt8]()
        var quoted = False
        if b[i] == 34:  # '"': quoted element
            quoted = True
            i += 1
            while i < n and b[i] != 34:
                if b[i] == 92 and i + 1 < n:  # '\\'
                    i += 1
                cur.append(b[i])
                i += 1
            if i < n:
                i += 1  # closing quote
        else:
            while i < n and b[i] != 44 and b[i] != 125:  # ',' '}'
                if b[i] == 92 and i + 1 < n:
                    i += 1
                cur.append(b[i])
                i += 1
        var is_null_token = False
        if not quoted and len(cur) == 4:
            is_null_token = (
                cur[0] == 78
                and cur[1] == 85
                and cur[2] == 76
                and cur[3] == 76
            )
        if quoted or (len(cur) > 0 and not is_null_token):
            out.append(String(unsafe_from_utf8=Span(
                unsafe_ptr=cur.unsafe_ptr(), length=len(cur)
            )))
        if i < n and b[i] == 44:  # ','
            i += 1
        else:
            break
    return out^


def split_postgres_int32_array(text: String) -> List[Int32]:
    """Split a PG int-array literal into Int32 elements, order preserved.

    Elements that do not start with a digit or sign are skipped (matches how
    NULL array cells and empty strings were always treated upstream). A NULL
    column never reaches here — check PgResult.is_null first.
    """
    var out = List[Int32]()
    var elems = split_postgres_text_array(text)
    for i in range(len(elems)):
        var sb = elems[i].as_bytes()
        if len(sb) == 0:
            continue
        var first = sb[0]
        if (first < 48 or first > 57) and first != 45 and first != 43:
            continue
        out.append(Int32(_parse_span_int64(sb)))
    return out^


def _parse_span_int64(b: Span[Byte, _]) -> Int64:
    """Signed decimal parse over a byte span."""
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
