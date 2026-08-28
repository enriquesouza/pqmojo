"""Shared fixture table for the live-database tests.

The suite owns its data end to end: tests run against a dedicated neutral
database (pqmojo_test) and a fixture table (pqmojo_test_items) that is
CREATEd in test setup and DROPed after — never against any application
schema. Column-type coverage mirrors what real drivers must read:
int8 / int4 / float8 / numeric (incl NaN/Infinity/huge-scale) / text /
bool / int4[] / text[] / timestamp.

`setup_fixture()` is idempotent (DROP + CREATE + INSERT inside the call)
and `teardown_fixture()` drops the table; both open and close their own
connection, so a test main() can bracket its body with the two calls.
"""

from tests.common import DSN, PG_ADMIN_DSN, check

from pqmojo import connect, execute


comptime FIXTURE_TABLE = "pqmojo_test_items"

comptime CREATE_SQL = """CREATE TABLE """ + FIXTURE_TABLE + """ (
    id int8 PRIMARY KEY,
    owner_id int8,
    latitude float8,
    longitude float8,
    title text,
    note text,
    street text,
    house_number int4,
    unit text,
    phone text,
    district text,
    city text,
    region text,
    postcode text,
    tier text,
    amount numeric,
    amount_1 numeric,
    amount_2 numeric,
    amount_3 numeric,
    amount_4 numeric,
    amount_5 numeric,
    amount_6 numeric,
    seen_at timestamp,
    tags int4[],
    gallery text[],
    tiers text[],
    stars int4,
    score int4,
    is_active bool,
    hidden bool
)"""


def ensure_database() raises:
    """Create the pqmojo_test database when missing (no-op otherwise)."""
    var admin = connect(PG_ADMIN_DSN)
    var hit = execute(
        admin,
        "SELECT 1 FROM pg_database WHERE datname = 'pqmojo_test'",
        [],
    )
    var have = hit.rows() == 1
    hit.clear()
    if not have:
        execute(admin, "CREATE DATABASE pqmojo_test", [])
    admin.close()


def setup_fixture() raises:
    ensure_database()
    var conn = connect(DSN)
    execute(conn, "DROP TABLE IF EXISTS " + FIXTURE_TABLE, [])
    execute(conn, CREATE_SQL, [])
    for i in range(24):
        var r = execute(conn, insert_sql(i), [])
        r.clear()
    var counted = execute(
        conn, "SELECT count(*)::int8 FROM " + FIXTURE_TABLE, []
    )
    check(counted.col_i64(0, 0) == 24, "fixture rows inserted")
    counted.clear()
    conn.close()


def teardown_fixture() raises:
    var conn = connect(DSN)
    execute(conn, "DROP TABLE IF EXISTS " + FIXTURE_TABLE, [])
    conn.close()


def numeric_at(row: Int, slot: Int) -> String:
    var pool = List[String]()
    pool.append("1234.56")
    pool.append("-987.65")
    pool.append("0")
    pool.append("0.00")
    pool.append("1.10")
    pool.append("79.2")
    pool.append("0.000001234")
    pool.append("1e-130")
    pool.append("-0.001")
    pool.append("999999999999999999999999.99")
    pool.append("123456789012345678901234567890")
    pool.append("7.0000000000000000000000001")
    pool.append("1234567890.123456789")
    pool.append("70.000000000000000000000000")
    pool.append("'NaN'")
    pool.append("'Infinity'")
    pool.append("'-Infinity'")
    pool.append("1e+40")
    return pool[(row * 7 + slot * 3) % len(pool)]


def insert_sql(row: Int) -> String:
    """One deterministic INSERT; every nullable pattern is a pure function
    of the row index."""
    var k = row % 8
    var score = String("NULL")
    if row % 4 != 1:
        score = String((row * 17) % 90)
    var house = String("NULL")
    if row % 5 != 3:
        house = String(100 + (row * 13) % 800)
    var amount = String("NULL")
    if row % 3 != 0:
        amount = String(10 + row)
    var amounts = List[String](capacity=6)
    for slot in range(6):
        amounts.append(numeric_at(row, slot))
    var lat = String("-23.5505")
    var lon = String("-46.6333")
    if (row * 5) % 8 == 2:
        lat = "55"
    elif (row * 5) % 8 == 3:
        lat = "-0"
    elif (row * 5) % 8 == 4:
        lat = "1e-7"
    elif (row * 5) % 8 == 5:
        lat = "2.5e21"
    elif (row * 5) % 8 == 6:
        lat = "10.125"
    elif (row * 5) % 8 == 7:
        lat = "-80.25"
    elif (row * 5) % 8 == 0:
        lat = "-23.5505"
    else:
        lat = "-46.6333"
    var lon_idx = (row * 5 + 1) % 8
    if lon_idx == 0:
        lon = "-23.5505"
    elif lon_idx == 1:
        lon = "-46.6333"
    elif lon_idx == 2:
        lon = "55"
    elif lon_idx == 3:
        lon = "-0"
    elif lon_idx == 4:
        lon = "1e-7"
    elif lon_idx == 5:
        lon = "2.5e21"
    elif lon_idx == 6:
        lon = "10.125"
    else:
        lon = "-80.25"
    var stamps = List[String]()
    stamps.append("'2024-03-15 10:30:00.123456'")
    stamps.append("'2025-01-01 00:00:00'")
    stamps.append("'2023-07-04 18:59:59.999999'")
    stamps.append("'2026-08-14 17:51:07.875448'")
    stamps.append("'2020-02-29 12:00:00'")
    stamps.append("'2025-12-31 23:59:59.000001'")
    stamps.append("'2024-06-30 06:15:30.5'")
    stamps.append("'2021-11-11 11:11:11'")
    var tags = List[String]()
    tags.append("ARRAY[12,44,7]")
    tags.append("NULL")
    tags.append("ARRAY[60,5986,6060,7300,5993]")
    tags.append("ARRAY[1]")
    tags.append("ARRAY[3,1,2]")
    tags.append("ARRAY[7502,25,60,7349]")
    tags.append("ARRAY[]::int4[]")
    tags.append("ARRAY[9,9,9]")
    var gallery = List[String]()
    gallery.append("ARRAY['img/seed-a/001.png','img/seed-a/002.png']")
    gallery.append("NULL")
    gallery.append("ARRAY['a','x,y','q\"q','b\\\\c','']")
    gallery.append("ARRAY['logo.svg']")
    gallery.append("ARRAY['e','d',NULL,'b','a']")
    gallery.append("ARRAY['img/seed-f/01.jpg','img/seed-f/02.jpg']")
    gallery.append("ARRAY['x',NULL,'z']")
    gallery.append("ARRAY[]::text[]")
    var tiers = List[String]()
    tiers.append("ARRAY['A','B']")
    tiers.append("ARRAY['B']")
    tiers.append("ARRAY['C','D','E']")
    tiers.append("ARRAY['A']")
    tiers.append("ARRAY['B','B']")
    tiers.append("ARRAY['D']")
    tiers.append("ARRAY['E','F']")
    tiers.append("ARRAY['A','C']")
    var out = String("INSERT INTO " + FIXTURE_TABLE + " VALUES (")
    out += String(row) + ", "
    out += String(900 + (row * 11) % 500) + ", "
    out += lat + ", " + lon + ", "
    out += "'Item " + String(row) + "', "
    out += "'Note for item " + String(row) + "', "
    out += "'Street " + String(row) + "', "
    out += house + ", "
    out += "'Unit " + String(row) + "', "
    out += "'+1-555-01" + String(10 + row) + "', "
    out += "'Old Town', 'Port Ellery', 'NB', 'NB-4410', "
    out += "'A', "
    out += amount + ", "
    out += amounts[0] + ", " + amounts[1] + ", " + amounts[2] + ", "
    out += amounts[3] + ", " + amounts[4] + ", " + amounts[5] + ", "
    out += stamps[k] + ", "
    out += tags[k] + ", "
    out += gallery[k] + ", "
    out += tiers[k] + ", "
    out += String(row % 6) + ", "
    out += score + ", "
    out += "true, false)"
    return out
