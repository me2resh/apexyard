#!/usr/bin/env bash
# Exit 0 when the gate fails. Exit 1 when the gate passes.
set -euo pipefail
if "$@"; then
  printf 'expected the gate to fail\n' >&2
  exit 1
fi
printf 'gate failed as expected\n'
