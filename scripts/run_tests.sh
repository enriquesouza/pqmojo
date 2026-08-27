#!/bin/sh
# pqmojo live-database test suite. SELECT-only; no business-table writes.
set -e
cd "$(dirname "$0")/.."
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
