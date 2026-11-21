#!/usr/bin/env bash
# test_reliability_triggers.sh - CI wrapper for the reliability loader tests (#2092).
# The hook test runner finds only .sh files, so it runs the Python suite here.
set -uo pipefail
export PYTHONDONTWRITEBYTECODE=1
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 "$SCRIPT_DIR/test_reliability_triggers.py"
