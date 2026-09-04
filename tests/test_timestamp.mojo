"""PG TEXT timestamp decode/render: strict + lenient parsers, round-trips,
offsets, fractional seconds, trim-set difference, malformed-input zeros,
parse_instant accept/reject matrix, and the Hinnant calendar sweep.

DB-free (no fixture). Run: pixi run mojo run -I . tests/test_timestamp.mojo
"""

from std.origin import MutAnyOrigin

from tests.common import check

from pqmojo import (
    civil_from_days,
    day_count_in_month,
    days_since_epoch_for_date,
    is_leap,
    parse_instant,
    parse_postgres_timestamp_bytes_lenient,
    parse_postgres_timestamp_bytes_to_microseconds,
    render_date_text,
    render_hhmm_text,
    render_postgres_timestamp_text,
    unix_seconds_now,
)

from pqmojo.timestamp import _days_from_civil_alt


comptime BytePtr = Pointer[T=Byte, mut=True, origin=MutAnyOrigin]


def parse_strict(s: String) -> Int64:
    var b = s.as_bytes()
    var p = BytePtr(unsafe_from_address=Int(b.unsafe_ptr()))
    return parse_postgres_timestamp_bytes_to_microseconds(p, len(b))


def parse_lenient(s: String) -> Int64:
    var b = s.as_bytes()
    var p = BytePtr(unsafe_from_address=Int(b.unsafe_ptr()))
    return parse_postgres_timestamp_bytes_lenient(p, len(b))


def two(n: Int) -> String:
    if n < 10:
        return "0" + String(n)
    return String(n)


def pg_text(y: Int, m: Int, d: Int) -> String:
    var ys = String(y)
    while ys.byte_length() < 4:
        ys = "0" + ys
    return ys + "-" + two(m) + "-" + two(d) + " 00:00:00"


def main() raises:
    var checks = 0

    # ---- strict parse: canonical PG text, value pinned against an
    # independent model of the algorithm (datetime-derived ground truth
    # for CE dates) ----
    check(
        parse_strict("2024-01-02 03:04:05") == 1704164645000000,
        "strict canonical 2024-01-02 03:04:05",
    )
    checks += 1
    check(
        parse_strict("2023-12-31 23:59:59") == 1704067199000000,
        "strict year-end second",
    )
    checks += 1
    check(
        parse_strict("2024-02-29 12:34:56") == 1709210096000000,
        "strict leap day",
    )
    checks += 1
    check(
        parse_strict("1999-12-31 00:00:00") == 946598400000000,
        "strict 1999-12-31",
    )
    checks += 1
    check(
        parse_strict("  \t2024-01-02 03:04:05 \t") == 1704164645000000,
        "strict trims space+tab both ends",
    )
    checks += 1
    check(
        parse_strict("1970-01-01 00:00:00") == 0,
        "strict epoch zero",
    )
    checks += 1

    # ---- round-trips: render(parse(x)) == x for offset-free text ----
    var rt_inputs = List[String]()
    rt_inputs.append("2024-01-02 03:04:05")
    rt_inputs.append("2023-12-31 23:59:59")
    rt_inputs.append("2024-02-29 12:34:56")
    rt_inputs.append("1999-12-31 00:00:00")
    rt_inputs.append("1970-01-01 00:00:00")
    for i in range(len(rt_inputs)):
        var x = rt_inputs[i]
        check(
            render_postgres_timestamp_text(parse_strict(x)) == x,
            "round-trip " + x,
        )
        checks += 1

    # fractional seconds: right-padded to micros, capped at 6 digits
    check(
        parse_strict("2024-06-01 12:00:00.5") == 1717243200500000,
        "fraction .5 -> 500000",
    )
    checks += 1
    check(
        parse_strict("2024-06-01 12:00:00.123456") == 1717243200123456,
        "fraction .123456",
    )
    checks += 1
    check(
        parse_strict("2024-06-01 12:00:00.000001") == 1717243200000001,
        "fraction .000001",
    )
    checks += 1
    check(
        parse_strict("2024-06-01 12:00:00.1234567") == 1717243200123456,
        "fraction capped at 6 digits",
    )
    checks += 1
    check(
        render_postgres_timestamp_text(parse_strict("2024-06-01 12:00:00.5"))
        == "2024-06-01 12:00:00",
        "render truncates fractional micros",
    )
    checks += 1

    # ---- offsets are applied (result is UTC micros) ----
    check(
        parse_strict("2024-01-02 03:04:05+00") == 1704164645000000,
        "offset +00 identity",
    )
    checks += 1
    check(
        render_postgres_timestamp_text(parse_strict("2024-01-02 03:04:05+00"))
        == "2024-01-02 03:04:05",
        "round-trip with +00",
    )
    checks += 1
    check(
        parse_strict("2024-01-02 03:04:05+05:30") == 1704144845000000,
        "offset +05:30 applied",
    )
    checks += 1
    check(
        render_postgres_timestamp_text(parse_strict("2024-01-02 03:04:05+05:30"))
        == "2024-01-01 21:34:05",
        "render UTC shift for +05:30",
    )
    checks += 1
    check(
        parse_strict("2024-01-02 03:04:05-08") == 1704193445000000,
        "offset -08 (hours only) applied",
    )
    checks += 1
    check(
        render_postgres_timestamp_text(parse_strict("2024-01-02 03:04:05-08"))
        == "2024-01-02 11:04:05",
        "render UTC shift for -08",
    )
    checks += 1
    check(
        parse_strict("2024-01-02 03:04:05+05") == 1704146645000000,
        "offset +05 (no minutes)",
    )
    checks += 1

    # ---- strict-vs-lenient trim sets: newline/CR accepted by lenient only ----
    check(parse_strict("\n2024-01-02 03:04:05") == 0, "strict rejects leading newline")
    checks += 1
    check(
        parse_strict("2024-01-02 03:04:05\r\n") == 1704164645000000,
        "frozen quirk: strict sees trailing CRLF as junk AFTER secs, ignored",
    )
    checks += 1
    check(
        parse_strict("2024-01-02 03:04:05 junk") == 1704164645000000,
        "strict ignores trailing junk after the (absent) offset",
    )
    checks += 1
    check(
        parse_lenient("\n2024-01-02 03:04:05\r\n") == 1704164645000000,
        "lenient accepts newline+CR trim",
    )
    checks += 1
    check(
        parse_lenient("\t 2024-01-02 03:04:05 \n") == 1704164645000000,
        "lenient accepts mixed trim set",
    )
    checks += 1
    check(
        parse_lenient("2024-01-02 03:04:05") == parse_strict("2024-01-02 03:04:05"),
        "lenient == strict on untrimmed input",
    )
    checks += 1
    check(parse_lenient("\nshort") == 0, "lenient still demands 19 bytes")
    checks += 1

    # ---- malformed input decodes to 0 (strict) ----
    var zeros = List[String]()
    zeros.append("")
    zeros.append("x")
    zeros.append("2024-01-02")
    zeros.append("2024-01-02 03:04")
    zeros.append("2024-01-02 03:04:0")
    zeros.append("2024-01-02 03:04:5X")
    zeros.append("garbage, all of it!!")
    zeros.append("202X-01-02 03:04:05")
    zeros.append("2024-0X-02 03:04:05")
    zeros.append("2024-01-02 03:04:+5")
    for i in range(len(zeros)):
        check(parse_strict(zeros[i]) == 0, "malformed -> 0: '" + zeros[i] + "'")
        checks += 1

    # frozen port quirks, pinned so they cannot drift silently: digit
    # fields are never range-checked, separators never validated, bytes
    # after the offset are ignored
    check(
        parse_strict("2024-13-40 25:70:80") == 1739153480000000,
        "frozen quirk: fields not range-checked",
    )
    checks += 1
    check(
        parse_strict("2024/01/02 03:04:05") == 1704164645000000,
        "frozen quirk: separators not validated",
    )
    checks += 1
    check(
        parse_strict("2024-01-02 03:04:05junk") == 1704164645000000,
        "frozen quirk: trailing junk ignored",
    )
    checks += 1

    # ---- the co-ported era spellings (strict vs lenient routing) ----
    # Probe verdict (full sweep -4000..4000 x m x d, 2,976,372 comparisons):
    # the two days_from_civil spellings DIVERGE at negative adjusted years
    # (7,502 one-day mismatches); inside the 4-digit parse domain the only
    # divergence is year 0000 Jan/Feb (adjusted year -1), where lenient is
    # one day LOWER than strict. Pinned through the public parsers:
    check(
        parse_strict("0000-01-02 03:04:05") == -62167121755000000,
        "strict year-0000 Jan uses days_since_epoch_for_date",
    )
    checks += 1
    check(
        parse_lenient("0000-01-02 03:04:05") == -62167208155000000,
        "lenient year-0000 Jan one day lower (private twin)",
    )
    checks += 1
    check(
        parse_lenient("0000-01-02 03:04:05") - parse_strict("0000-01-02 03:04:05")
        == -86_400_000_000,
        "twin divergence is exactly one day",
    )
    checks += 1
    check(
        parse_strict("0000-03-01 00:00:00") == parse_lenient("0000-03-01 00:00:00"),
        "twins agree from year-0000 March on",
    )
    checks += 1

    # twins agree across ALL valid days of sample years (every adjusted
    # year >= 0), through the public parsers
    var sample_years = List[Int]()
    sample_years.append(1900)
    sample_years.append(1970)
    sample_years.append(1999)
    sample_years.append(2000)
    sample_years.append(2024)
    var twin_cases = 0
    var twin_bad = 0
    for yi in range(len(sample_years)):
        var y = sample_years[yi]
        for m in range(1, 13):
            var dmax = day_count_in_month(y, m)
            for d in range(1, dmax + 1):
                twin_cases += 1
                if parse_strict(pg_text(y, m, d)) != parse_lenient(pg_text(y, m, d)):
                    twin_bad += 1
    check(twin_bad == 0, "twins agree on " + String(twin_cases) + " sample-year days")
    checks += 1

    # ---- calendar-twin VERDICT sweep: dense years -4000..4000 x 12 months
    # x 31 days, days_since_epoch_for_date (strict routing) vs the
    # co-ported _days_from_civil_alt (lenient routing). Pinned verdict:
    # identical for every adjusted year >= 0; at negative adjusted years
    # they differ ONLY where yy % 400 == 0 (public spelling one day lower)
    # or yy % 400 == 399 (alt spelling one day lower) — 7,502 one-day
    # mismatches total; on every other negative residue the two agree with
    # each other. Divergence proven => both spellings stay, exactly as the
    # origin file ships them. ----
    var dense = 0
    var dense_bad = 0
    var dense_nonneg_bad = 0
    var dense_not_one_day = 0
    var dense_outside_residues = 0
    var dense_res0_public_low = 0
    var dense_res399_alt_low = 0
    for y in range(-4000, 4001):
        for m in range(1, 13):
            var yy = y - (1 if m <= 2 else 0)
            for d in range(1, 32):
                var a = days_since_epoch_for_date(y, m, d)
                var b = _days_from_civil_alt(Int64(y), m, d)
                dense += 1
                if a != b:
                    dense_bad += 1
                    if yy >= 0:
                        dense_nonneg_bad += 1
                    if a - b != -1 and a - b != 1:
                        dense_not_one_day += 1
                    if yy % 400 == 0:
                        if a == b - 1:
                            dense_res0_public_low += 1
                        else:
                            dense_outside_residues += 1
                    elif yy % 400 == 399:
                        if b == a - 1:
                            dense_res399_alt_low += 1
                        else:
                            dense_outside_residues += 1
                    else:
                        dense_outside_residues += 1
    check(dense == 2_976_372, "dense twin sweep size")
    checks += 1
    check(
        dense_bad == 7_502
        and dense_nonneg_bad == 0
        and dense_not_one_day == 0
        and dense_outside_residues == 0,
        "twin verdict: 7,502 one-day mismatches, only negative yy at residues {0,399}",
    )
    checks += 1
    check(
        dense_res0_public_low == 3_720 and dense_res399_alt_low == 3_782,
        "twin verdict split: 3,720 residue-0 (public low) + 3,782 residue-399 (alt low)",
    )
    checks += 1

    # ---- calendar primitives ----
    check(days_since_epoch_for_date(1970, 1, 1) == 0, "epoch anchor")
    checks += 1
    check(days_since_epoch_for_date(2024, 1, 2) == 19724, "2024-01-02 anchor")
    checks += 1
    check(days_since_epoch_for_date(2000, 3, 1) == 11017, "2000-03-01 anchor")
    checks += 1
    check(days_since_epoch_for_date(1900, 3, 1) == -25508, "1900-03-01 anchor")
    checks += 1
    check(civil_from_days(0) == (1970, 1, 1), "civil(0) epoch")
    checks += 1
    check(civil_from_days(19724) == (2024, 1, 2), "civil(19724)")
    checks += 1
    check(not is_leap(1900), "1900 not leap")
    checks += 1
    check(is_leap(2000), "2000 leap")
    checks += 1
    check(is_leap(2024), "2024 leap")
    checks += 1
    check(not is_leap(2023), "2023 not leap")
    checks += 1
    check(day_count_in_month(1900, 2) == 28, "Feb 1900")
    checks += 1
    check(day_count_in_month(2000, 2) == 29, "Feb 2000")
    checks += 1
    check(day_count_in_month(2024, 2) == 29, "Feb 2024")
    checks += 1
    check(day_count_in_month(2023, 2) == 28, "Feb 2023")
    checks += 1
    check(day_count_in_month(2024, 4) == 30, "Apr 30")
    checks += 1
    check(day_count_in_month(2024, 12) == 31, "Dec 31")
    checks += 1

    # dense round-trip sweep: every valid CE date 1..4000 through
    # days_since_epoch_for_date -> civil_from_days (1,460,970 dates)
    var sweep_cases = 0
    var sweep_bad = 0
    var first_bad = ""
    for y in range(1, 4001):
        for m in range(1, 13):
            var dmax = day_count_in_month(y, m)
            for d in range(1, dmax + 1):
                var c = civil_from_days(days_since_epoch_for_date(y, m, d))
                sweep_cases += 1
                if c[0] != y or c[1] != m or c[2] != d:
                    sweep_bad += 1
                    if sweep_bad == 1:
                        first_bad = (
                            String(y) + "-" + String(m) + "-" + String(d)
                        )
    check(
        sweep_bad == 0,
        "calendar round-trip sweep 1..4000 ("
        + String(sweep_cases)
        + " dates), first bad: "
        + first_bad,
    )
    checks += 1

    # ---- render corner values ----
    check(render_postgres_timestamp_text(0) == "1970-01-01 00:00:00", "render(0)")
    checks += 1
    check(
        render_postgres_timestamp_text(1704164645000000) == "2024-01-02 03:04:05",
        "render canonical",
    )
    checks += 1
    check(
        render_postgres_timestamp_text(-1) == "1969-12-31 23:59:59",
        "render(-1) floors to prior day",
    )
    checks += 1
    check(
        render_postgres_timestamp_text(1) == "1970-01-01 00:00:00",
        "render(1) truncates sub-second",
    )
    checks += 1
    # frozen quirk: the renderer does NOT zero-pad the year (String(Int))
    check(
        parse_strict("0999-01-23 04:56:07") == -30639841433000000,
        "parse 4-digit year 0999",
    )
    checks += 1
    check(
        render_postgres_timestamp_text(-30639841433000000) == "999-01-23 04:56:07",
        "frozen quirk: render leaves years < 1000 unpadded",
    )
    checks += 1

    # ---- parse_instant accept matrix ----
    var ip = parse_instant("02/01/2024 03:04")
    check(ip.ok, "accept DD/MM/YYYY HH:MM")
    checks += 1
    check(
        ip.year == 2024
        and ip.month == 1
        and ip.day == 2
        and ip.hour == 3
        and ip.minute == 4
        and ip.second == 0,
        "DD/MM/YYYY field order is day-first",
    )
    checks += 1
    check(ip.micros == 1704164640000000, "DD/MM/YYYY micros (03:04, day-first)")
    checks += 1

    ip = parse_instant("2024-01-02T03:04")
    check(ip.ok and ip.micros == 1704164640000000, "accept YYYY-MM-DDTHH:MM")
    checks += 1
    ip = parse_instant("2024-01-02 03:04")
    check(ip.ok and ip.micros == 1704164640000000, "accept YYYY-MM-DD HH:MM (space)")
    checks += 1
    ip = parse_instant("2024-01-02T03:04:05")
    check(
        ip.ok
        and ip.micros == 1704164645000000
        and ip.second == 5
        and ip.year == 2024
        and ip.month == 1
        and ip.day == 2
        and ip.hour == 3
        and ip.minute == 4,
        "accept YYYY-MM-DDTHH:MM:SS + fields",
    )
    checks += 1
    ip = parse_instant("2024-01-02T03:04:05Z")
    check(
        ip.ok and ip.micros == 1704164645000000,
        "accept trailing Z on seconds form",
    )
    checks += 1
    ip = parse_instant("2024-01-02T03:04Z")
    check(ip.ok and ip.micros == 1704164640000000, "accept trailing Z on minutes form")
    checks += 1
    ip = parse_instant("  2024-01-02T03:04:05\t")
    check(ip.ok and ip.micros == 1704164645000000, "accept surrounding whitespace")
    checks += 1

    # ---- parse_instant reject matrix ----
    var rejects = List[String]()
    rejects.append("")
    rejects.append("Z")
    rejects.append("02/01/2024 03:4")
    rejects.append("02/01/2024 03:04:05")
    rejects.append("2024-01-02T03:4")
    rejects.append("2024-01-02T03:04:5")
    rejects.append("2024-13-02T03:04")
    rejects.append("2024-00-02T03:04")
    rejects.append("2024-01-32T03:04")
    rejects.append("2024-01-00T03:04")
    rejects.append("2024-01-02T24:04")
    rejects.append("2024-01-02T03:60")
    rejects.append("2024-01-02T03:04:60")
    rejects.append("2024-01-02X03:04")
    rejects.append("24:00 2024-01-02")
    for i in range(len(rejects)):
        var rp = parse_instant(rejects[i])
        check(
            not rp.ok and rp.micros == 0,
            "reject: '" + rejects[i] + "'",
        )
        checks += 1

    # ---- unix_seconds_now ----
    check(unix_seconds_now() > 1_700_000_000, "unix_seconds_now plausible")
    checks += 1

    # ---- render_date_text: zero-padded YYYY-MM-DD ----
    check(render_date_text(2026, 9, 1) == "2026-09-01", "date 2026-9-1")
    checks += 1
    check(render_date_text(2026, 12, 31) == "2026-12-31", "date 2026-12-31")
    checks += 1
    check(render_date_text(999, 1, 2) == "999-01-02", "date short year")
    checks += 1
    check(render_date_text(2026, 2, 29) == "2026-02-29", "date feb29 form")
    checks += 1

    # ---- render_hhmm_text: zero-padded HH:MM ----
    check(render_hhmm_text(0) == "00:00", "hhmm midnight")
    checks += 1
    check(render_hhmm_text(60) == "01:00", "hhmm 60")
    checks += 1
    check(render_hhmm_text(1439) == "23:59", "hhmm 1439")
    checks += 1
    check(render_hhmm_text(1440) == "24:00", "hhmm 1440 (end-of-day law)")
    checks += 1
    check(render_hhmm_text(605) == "10:05", "hhmm 605")
    checks += 1

    print(
        "test_timestamp: "
        + String(checks)
        + " checks passed (calendar round-trip sweep: "
        + String(sweep_cases)
        + " dates, twin verdict sweep: "
        + String(dense)
        + " comparisons ("
        + String(dense_bad)
        + " one-day divergences), twin sample sweep: "
        + String(twin_cases)
        + " days)"
    )


