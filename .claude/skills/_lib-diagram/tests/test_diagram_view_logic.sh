#!/usr/bin/env bash
# Covers .claude/skills/_lib-diagram/view.html and tests/test_view_logic.js.
# Run pure graph functions from the inline template without a browser.
set -euo pipefail
export PYTHONDONTWRITEBYTECODE=1
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! command -v node >/dev/null 2>&1; then
  if [ "${CI:-false}" = "true" ]; then
    echo "FAIL: node is required for diagram logic tests in CI." >&2
    exit 1
  fi
  echo "NOTE: node is unavailable. Diagram logic tests require node locally."
  exit 0
fi
node "$SCRIPT_DIR/test_view_logic.js"
