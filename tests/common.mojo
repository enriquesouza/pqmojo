"""Shared test constants/helpers. Tests run against the LIVE dev database;
SELECT-only: never INSERT into business tables."""

comptime DSN = "postgres://postgres@localhost/alugue_skinny_clean"


def check(cond: Bool, label: String) raises:
    if not cond:
        raise Error("FAIL: " + label)


def check_raised(raised: Bool, label: String) raises:
    if not raised:
        raise Error("FAIL (no raise): " + label)
