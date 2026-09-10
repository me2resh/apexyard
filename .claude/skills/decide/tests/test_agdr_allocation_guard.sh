#!/bin/bash
# Static regression checks for the shared AgDR allocation procedure.
set -u
skill="$(cd "$(dirname "$0")/.." && pwd)/SKILL.md"
pass=0
fail=0
check() {
  if grep -qF -- "$1" "$skill"; then pass=$((pass+1)); else echo "FAIL: $2"; fail=$((fail+1)); fi
}
check 'git rev-parse --path-format=absolute --git-common-dir' 'uses shared Git directory'
check 'reservation_dir=' 'uses a durable reservation directory'
check 'set -C' 'creates reservations without overwriting an existing one'
check 'Do not delete a reservation' 'keeps reservations after writing'
echo "AgDR allocation guard: PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
