#!/bin/sh
# pqmojo live-database test suite. The suite owns its data: a dedicated
# pqmojo_test database plus a pqmojo_test_items fixture table that each
# affected test CREATEs in setup and DROPs after (tests/fixture.mojo).
# No application schema is ever read or written.
set -e
cd "$(dirname "$0")/.."

# First-run convenience: create the neutral fixture database when missing
# (peer-auth local socket; every later run is a no-op).
psql -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='pqmojo_test'" \
    | grep -q 1 || psql -d postgres -c "CREATE DATABASE pqmojo_test"
TMPBIN="${TMPDIR:-/tmp}/pqmojo_test_bin"
failed=0
for t in tests/test_*.mojo; do
    echo "=== building $t"
    pixi run mojo build -I . "$t" -o "$TMPBIN" >/dev/null 2>&1 || {
        echo "BUILD FAIL: $t"; exit 1; }
    echo "=== running  $t"
    "$TMPBIN" || { echo "TEST FAIL: $t"; failed=1; }
done
if [ "$failed" -ne 0 ]; then
    echo "SUITE FAILED"
    exit 1
fi
echo "ALL PQMOJO TESTS PASSED"
