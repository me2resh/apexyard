#!/bin/bash
set -u
# The shared helper is checked separately.
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"
export PYTHONDONTWRITEBYTECODE=1
test_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/token_cost"
if python3 -I -m unittest discover -s "$test_dir" -p 'test_token_cost.py' -v; then
  echo "PASS: token-cost tests"
else
  echo "FAIL: token-cost tests"
  exit 1
fi
