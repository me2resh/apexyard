#!/usr/bin/env bash
# Exit 0 only when npm ci exits 0 and the gate exits non-zero.
set -euo pipefail
install_code=0
npm ci --ignore-scripts || install_code=$?
printf 'npm_ci=%s\n' "$install_code"
if [ "$install_code" -ne 0 ]; then
  printf 'npm ci failed\n' >&2
  exit 1
fi
if "$@"; then
  gate_code=0
else
  gate_code=$?
fi
printf 'gate_exit=%s\n' "$gate_code"
if [ "$gate_code" -eq 0 ]; then
  printf 'expected the gate to fail\n' >&2
  exit 1
fi
printf 'gate failed as expected\n'
