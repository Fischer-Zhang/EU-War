#!/usr/bin/env bash
# Full validation: fast checks plus the headless GDScript test suite.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

"$SCRIPT_DIR/validate_fast.sh"

echo "== headless GDScript tests =="
bash "$PROJECT_DIR/tests/run_all.sh"

echo "validate: OK"
