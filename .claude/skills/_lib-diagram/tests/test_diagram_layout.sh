#!/usr/bin/env bash
# Run the diagram layout tests without network access.
set -euo pipefail
export PYTHONDONTWRITEBYTECODE=1
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! command -v python3 >/dev/null 2>&1 || ! python3 -c 'import sys; sys.exit(sys.version_info < (3, 9))'; then
  echo "FAIL: Python 3.9 or later is required for diagram tests." >&2
  exit 1
fi
python3 -m unittest discover -s "$SCRIPT_DIR" -p 'test_layout.py' -v
