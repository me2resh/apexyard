#!/usr/bin/env bash
# Security regressions for #1388. All mutations occur in disposable clones.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd -P)"
python3 "$ROOT/.claude/hooks/tests/test_write_rule_excludes.py" "$ROOT"
