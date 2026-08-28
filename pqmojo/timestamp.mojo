# origin: alugue-mojo-api extensions/time.mojo
"""pqmojo.timestamp — Postgres TEXT timestamp decode/render.

PG renders timestamp/timestamptz TEXT cells as "YYYY-MM-DD HH:MM:SS",
optionally with "." fractional seconds (up to 6 digits read, right-padded
to microseconds) and, for timestamptz, a "+HH" / "-HH" / "+HH:MM" UTC
offset suffix. The parsers here decode that shape straight from libpq's
text buffer (byte pointer + length, no intermediate String) into Int64
microseconds since the Unix epoch; an offset is APPLIED (the result is
UTC micros), not preserved. Malformed input decodes to 0. These are the
frozen ported algorithms of the origin file — behavior is byte-for-byte
identical to it, including quirks: digit fields are never range-checked
("2024-13-40 25:70:80" decodes), separators are never validated, and any
bytes after the offset are ignored.

Two parsers share one grammar and differ ONLY in the trim set applied
before parsing:

    parse_postgres_timestamp_bytes_to_microseconds  strict: " " and "\t"
    parse_postgres_timestamp_bytes_lenient          lenient: " ", "\t",
                                                    "\n", "\r"

The two parsers route through two co-ported era derivations (both Howard
Hinnant days_from_civil spellings, each carrying a truncating-division
correction into a language whose `//` already floors). For every adjusted
year >= 0 — the whole 4-digit text domain except year 0000 Jan/Feb — the
spellings return identical days. At negative adjusted years they disagree
with each other exactly where yy % 400 == 0 (days_since_epoch_for_date
one day lower) and yy % 400 == 399 (_days_from_civil_alt one day lower;
adjusted year -1 is year 0000 Jan/Feb, the only in-format divergence); on
all other negative residues both sit one day lower but agree with each
other. A dense sweep (years -4000..4000 x 12 months x 31 days,
2,976,372 comparisons) pins 7,502 one-day mismatches — 3,720 at residue
0, 3,782 at residue 399 — so both spellings stay: the strict parser
routes through days_since_epoch_for_date (public), the lenient parser
through the private _days_from_civil_alt, exactly as the origin file
does.

render_postgres_timestamp_text is the inverse for offset-free UTC micros
("YYYY-MM-DD HH:MM:SS", zero-padded EXCEPT the year — years below 1000
render unpadded, frozen String(Int) behavior; fractional microseconds
are truncated, negative micros floor to the prior day).

parse_instant validates HUMAN date input — "DD/MM/YYYY HH:MM" (exactly
16 chars), "YYYY-MM-DDTHH:MM" or "YYYY-MM-DD HH:MM[:SS]", a trailing "Z"
tolerated, ranges enforced (month 1-12, day 1-31, hour 0-23, minute and
second 0-59) — into an InstantParse (ok flag + micros + civil fields).

unix_seconds_now is the libc time(2) wrapper.
"""

from std.ffi import external_call
from std.origin import MutAnyOrigin


comptime BytePtr = Pointer[T=Byte, mut=True, origin=MutAnyOrigin]


def unix_seconds_now() -> Int64:

    return external_call["time", Int64](Int64(0))


def _if_else_int(c: Bool, a: Int, b: Int) -> Int:

    if c:
        return a
    return b


def civil_from_days(z_in: Int64) -> Tuple[Int, Int, Int]:
    """Days-since-epoch -> (year, month, day), proleptic Gregorian."""

    var z = z_in + 719468
    var era = z // 146097
    var doe = z - era * 146097
    var yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
    var y = yoe + era * 400
    var doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
    var mp = (5 * doy + 2) // 153
    var day = doy - (153 * mp + 2) // 5 + 1
    var month = mp + Int64(_if_else_int(mp < 10, 3, -9))
    if month <= 2:
        y += 1
    return (Int(y), Int(month), Int(day))


def days_since_epoch_for_date(y: Int, m: Int, d: Int) -> Int64:
    """(year, month, day) -> days since 1970-01-01, proleptic Gregorian."""

    var yy = y
    var mm = m
    if mm <= 2:
        yy -= 1
    var era = (yy if yy >= 0 else yy - 399) // 400
    var yoe = yy - era * 400
    var mp = (mm + 9) % 12
    var doy = (153 * mp + 2) // 5 + d - 1
    var doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
    return Int64(era * 146097 + doe - 719468)


def _days_from_civil_alt(y_in: Int64, m: Int, d: Int) -> Int64:
    """The co-ported era derivation: same days_from_civil algorithm with a
    `y // 400` + negative-remainder-correction era spelling. Identical to
    days_since_epoch_for_date for every adjusted year >= 0; one day
    LOWER at negative adjusted years whose 400-remainder is 0 (under Mojo
    floor division the correction double-subtracts there). Kept because
    the lenient parser below is bound to it, verbatim."""

    var y = y_in
    if m <= 2:
        y -= 1
    var era = y // 400
    if y < 0 and y % 400 != 0:
        era -= 1
    var yoe = y - era * 400
    var mp = (m + 9) % 12
    var doy = Int64((153 * mp + 2) // 5 + d - 1)
    var doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
    return era * 146097 + doe - 719468


def is_leap(y: Int) -> Bool:
    """Proleptic-Gregorian leap test."""

    if y % 4 != 0:
        return False
    if y % 100 != 0:
        return True
    return y % 400 == 0


def day_count_in_month(y: Int, m: Int) -> Int:
    """Day count of month m in year y (leap-aware for February)."""

    if m == 2:
        return 29 if is_leap(y) else 28
    if m == 4 or m == 6 or m == 9 or m == 11:
        return 30
    return 31


def _digits_at(ptr: BytePtr, pos: Int, k: Int) -> Int64:

    if k <= 0:
        return 0
    var v: Int64 = 0
    var i = 0
    while i < k:
        var c = Int(ptr[pos + i])
        if c < 48 or c > 57:
            return -1
        v = v * 10 + Int64(c - 48)
        i += 1
    return v


def parse_postgres_timestamp_bytes_to_microseconds(ptr_in: BytePtr, n: Int) -> Int64:
    """Strict PG timestamp decode: trims ONLY " " and "\\t" at both ends,
    then parses "YYYY-MM-DD HH:MM:SS[.ffffff][(+|-)HH[:MM]]" into Int64
    microseconds since the Unix epoch (offset applied). 0 on malformed
    input or anything shorter than 19 significant bytes."""

    var s = 0
    var e = n
    while s < e and (Int(ptr_in[s]) == 32 or Int(ptr_in[s]) == 9):
        s += 1
    while e > s and (Int(ptr_in[e - 1]) == 32 or Int(ptr_in[e - 1]) == 9):
        e -= 1
    var p = ptr_in + s
    var nn = e - s
    if nn < 19:
        return 0
    var y = _digits_at(p, 0, 4)
    var mo = _digits_at(p, 5, 2)
    var d = _digits_at(p, 8, 2)
    var hh = _digits_at(p, 11, 2)
    var mi = _digits_at(p, 14, 2)
    var ss = _digits_at(p, 17, 2)
    if y < 0 or mo < 0 or d < 0 or hh < 0 or mi < 0 or ss < 0:
        return 0
    var micros: Int64 = 0
    var pos = 19
    if pos < nn and Int(p[pos]) == 46:
        pos += 1
        var k = 0
        while pos + k < nn and Int(p[pos + k]) >= 48 and Int(p[pos + k]) <= 57 and k < 6:
            k += 1
        micros = _digits_at(p, pos, k)
        if micros < 0:
            return 0
        var pad = k
        while pad < 6:
            micros *= 10
            pad += 1
        pos += k
    var offset_secs: Int64 = 0
    if pos < nn and (Int(p[pos]) == 43 or Int(p[pos]) == 45):
        var sign: Int64 = 1
        if Int(p[pos]) == 45:
            sign = -1
        pos += 1
        var oh = _digits_at(p, pos, 2)
        if oh < 0:
            return 0
        pos += 2
        var om: Int64 = 0
        if pos < nn and Int(p[pos]) == 58:
            om = _digits_at(p, pos + 1, 2)
            if om < 0:
                return 0
        offset_secs = sign * (oh * 3600 + om * 60)
    var days = days_since_epoch_for_date(Int(y), Int(mo), Int(d))
    var secs = days * 86400 + hh * 3600 + mi * 60 + ss - offset_secs
    return secs * 1_000_000 + micros


def _trim_space_tab_newline_carriage_return_range(ptr: BytePtr, n: Int) -> Tuple[Int, Int]:

    var s = 0
    var e = n
    while s < e:
        var c = Int(ptr[s])
        if c == 32 or c == 9 or c == 10 or c == 13:
            s += 1
        else:
            break
    while e > s:
        var c = Int(ptr[e - 1])
        if c == 32 or c == 9 or c == 10 or c == 13:
            e -= 1
        else:
            break
    return (s, e)


def parse_postgres_timestamp_bytes_lenient(ptr_in: BytePtr, n: Int) -> Int64:
    """Lenient PG timestamp decode: IDENTICAL grammar and result to the
    strict parser, but the trim set is " ", "\\t", "\\n", "\\r" at both
    ends (newlines and carriage returns are accepted around the
    timestamp). Routes through the _days_from_civil_alt era spelling, so
    year 0000 Jan/Feb decodes one day lower than the strict parser."""

    var te = _trim_space_tab_newline_carriage_return_range(ptr_in, n)
    var p = ptr_in + te[0]
    var nn = te[1] - te[0]
    if nn < 19:
        return 0
    var y = _digits_at(p, 0, 4)
    var mo = _digits_at(p, 5, 2)
    var d = _digits_at(p, 8, 2)
    var hh = _digits_at(p, 11, 2)
    var mi = _digits_at(p, 14, 2)
    var ss = _digits_at(p, 17, 2)
    if y < 0 or mo < 0 or d < 0 or hh < 0 or mi < 0 or ss < 0:
        return 0
    var micros: Int64 = 0
    var pos = 19
    if pos < nn and Int(p[pos]) == 46:
        pos += 1
        var k = 0
        while pos + k < nn and Int(p[pos + k]) >= 48 and Int(p[pos + k]) <= 57 and k < 6:
            k += 1
        micros = _digits_at(p, pos, k)
        if micros < 0:
            return 0
        var pad = k
        while pad < 6:
            micros *= 10
            pad += 1
        pos += k
    var offset_secs: Int64 = 0
    if pos < nn and (Int(p[pos]) == 43 or Int(p[pos]) == 45):
        var sign: Int64 = 1
        if Int(p[pos]) == 45:
            sign = -1
        pos += 1
        var oh = _digits_at(p, pos, 2)
        if oh < 0:
            return 0
        pos += 2
        var om: Int64 = 0
        if pos < nn and Int(p[pos]) == 58:
            om = _digits_at(p, pos + 1, 2)
            if om < 0:
                return 0
        offset_secs = sign * (oh * 3600 + om * 60)
    var days = _days_from_civil_alt(y, Int(mo), Int(d))
    var secs = days * 86400 + hh * 3600 + mi * 60 + ss - offset_secs
    return secs * 1_000_000 + micros


@fieldwise_init
struct InstantParse(Copyable, ImplicitlyCopyable):
    """parse_instant outcome: ok=False means rejected; otherwise micros
    (UTC, seconds resolution) plus the parsed civil fields."""

    var ok: Bool
    var micros: Int64
    var year: Int
    var month: Int
    var day: Int
    var hour: Int
    var minute: Int
    var second: Int


def _trimmed(s: String) -> String:

    var text_bytes = s.as_bytes()
    var start = 0
    var end = len(text_bytes)
    while start < end:
        var c = Int(text_bytes[start])
        if c == 32 or c == 9 or c == 10 or c == 13 or c == 11 or c == 12:
            start += 1
        else:
            break
    while end > start:
        var c2 = Int(text_bytes[end - 1])
        if c2 == 32 or c2 == 9 or c2 == 10 or c2 == 13 or c2 == 11 or c2 == 12:
            end -= 1
        else:
            break
    return String(unsafe_from_utf8=Span[Byte](
        unsafe_ptr=BytePtr(unsafe_from_address=Int(text_bytes.unsafe_ptr())) + start,
        length=end - start,
    ))


def _instant_digits_at(ptr: BytePtr, pos: Int, k: Int) -> Int:

    if k <= 0:
        return -1
    var v = 0
    var i = 0
    while i < k:
        var c = Int(ptr[pos + i])
        if c < 48 or c > 57:
            return -1
        v = v * 10 + c - 48
        i += 1
    return v


def parse_instant(raw: String) -> InstantParse:
    """Human-input date validation: "DD/MM/YYYY HH:MM" (exactly 16 chars,
    day-first), "YYYY-MM-DDTHH:MM", "YYYY-MM-DD HH:MM" or with ":SS"
    (19 chars); a trailing "Z" is tolerated and surrounding whitespace
    (" \\t\\n\\r\\x0b\\x0c") is trimmed. Ranges enforced: month 1-12,
    day 1-31, hour 0-23, minute/second 0-59. Rejected input returns
    ok=False with every field zero."""

    var bad = InstantParse(
        ok=False, micros=0, year=0, month=0, day=0, hour=0, minute=0, second=0
    )
    var s = _trimmed(raw)
    if s == "":
        return bad
    var b = s.as_bytes()
    var p = BytePtr(unsafe_from_address=Int(b.unsafe_ptr()))
    var n = len(b)
    if n > 0 and Int(p[n - 1]) == 90:
        n -= 1
    var y = 0
    var mo = 0
    var d = 0
    var hh = 0
    var mi = 0
    var ss = 0
    if n >= 16 and Int(p[2]) == 47 and Int(p[5]) == 47:
        d = _instant_digits_at(p, 0, 2)
        mo = _instant_digits_at(p, 3, 2)
        y = _instant_digits_at(p, 6, 4)
        hh = _instant_digits_at(p, 11, 2)
        mi = _instant_digits_at(p, 14, 2)
        if n != 16:
            return bad
    elif n >= 16 and Int(p[4]) == 45 and Int(p[7]) == 45:
        y = _instant_digits_at(p, 0, 4)
        mo = _instant_digits_at(p, 5, 2)
        d = _instant_digits_at(p, 8, 2)
        if Int(p[10]) != 84 and Int(p[10]) != 32:
            return bad
        hh = _instant_digits_at(p, 11, 2)
        mi = _instant_digits_at(p, 14, 2)
        if Int(p[13]) != 58:
            return bad
        if n == 19:
            if Int(p[16]) != 58:
                return bad
            ss = _instant_digits_at(p, 17, 2)
        elif n == 16:
            ss = 0
        else:
            return bad
    else:
        return bad
    if y < 0 or mo < 1 or mo > 12 or d < 1 or d > 31:
        return bad
    if hh < 0 or hh > 23 or mi < 0 or mi > 59 or ss < 0 or ss > 59:
        return bad
    var days = days_since_epoch_for_date(y, mo, d)
    var secs = days * 86400 + Int64(hh * 3600 + mi * 60 + ss)
    return InstantParse(
        ok=True, micros=secs * 1_000_000, year=y, month=mo, day=d,
        hour=hh, minute=mi, second=ss,
    )


def render_postgres_timestamp_text(micros: Int64) -> String:
    """Microseconds since the Unix epoch -> "YYYY-MM-DD HH:MM:SS"
    (zero-padded, space-separated PG-style text). Fractional microseconds
    are truncated; negative micros floor to the prior day
    (Mojo floor division) — micros=-1 renders "1969-12-31 23:59:59"."""

    var days = Int(micros // 86_400_000_000)
    var rem = micros - Int64(days) * 86_400_000_000
    var secs = Int(rem // 1_000_000)
    var civ = civil_from_days(Int64(days))
    var hh = secs // 3600
    var mm = (secs % 3600) // 60
    var ss = secs % 60
    var out = String(civ[0]) + "-"
    if civ[1] < 10:
        out += "0"
    out += String(civ[1]) + "-"
    if civ[2] < 10:
        out += "0"
    out += String(civ[2]) + " "
    if hh < 10:
        out += "0"
    out += String(hh) + ":"
    if mm < 10:
        out += "0"
    out += String(mm) + ":"
    if ss < 10:
        out += "0"
    out += String(ss)
    return out
