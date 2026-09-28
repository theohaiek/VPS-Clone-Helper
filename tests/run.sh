#!/usr/bin/env bash
# Runs every test. Usage: bash tests/run.sh   (PY=/path/to/python to pick an interpreter)
set -euo pipefail
cd "$(dirname "$0")/.."
PY=${PY:-$(command -v python3 || command -v python)}
export PYTHONUTF8=1
for t in tests/test_*.py; do echo "== $t"; "$PY" "$t"; done
for t in tests/test_*.sh; do echo "== $t"; PY="$PY" bash "$t"; done
echo "all tests passed"
