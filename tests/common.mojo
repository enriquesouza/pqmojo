"""Shared test constants/helpers. Tests run against a DEDICATED neutral
database (pqmojo_test) and own their data via tests/fixture.mojo: the
fixture table is CREATEd in test setup and DROPed after — the suite never
touches any application schema.
"""

comptime DSN = "postgres:///pqmojo_test"
comptime PG_ADMIN_DSN = "postgres:///postgres"


def check(cond: Bool, label: String) raises:
    if not cond:
        raise Error("FAIL: " + label)


def check_raised(raised: Bool, label: String) raises:
    if not raised:
        raise Error("FAIL (no raise): " + label)
