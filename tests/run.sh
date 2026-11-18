#!/bin/bash
# Run from the repo root: bash tests/run.sh
cd "$(dirname "$0")/.." || exit 1
status=0
for t in tests/*_test.lua; do
    lua "$t" || status=1
done
exit $status
