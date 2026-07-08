#!/usr/bin/env bash
# Fast validation without launching Godot: engine-pin gate, JSON syntax,
# Python compile, and the static data validator.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

echo "== engine-pin gate =="
if ! grep -q 'PackedStringArray("4.2", "GL Compatibility")' project.godot; then
  echo "project.godot config/features drifted from the pinned 4.2 / GL Compatibility tag" >&2
  exit 1
fi
echo "  project pinned to Godot 4.2 GL Compatibility"

echo "== JSON syntax =="
for f in data/units.json data/terrains.json data/generals.json data/campaigns.json data/techs.json data/conquest.json data/help.json data/scenarios/*.json; do
  python3 -c "import json,sys; json.load(open(sys.argv[1], encoding='utf-8'))" "$f"
done
echo "  all JSON parses"

echo "== Python compile =="
python3 -m py_compile tools/*.py
echo "  tools compile"

echo "== data validator =="
python3 tools/validate_data.py

echo "== balance gate =="
python3 tools/balance_report.py --check

echo "validate_fast: OK"
