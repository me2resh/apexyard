#!/usr/bin/env bash
# Every ORBIT record that the framework ships must pass records-lint.
# A fork that syncs upstream lints the whole docs/orbit tree once (#1742).
# One shipped record that fails makes the fork's first sync PR red.
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)

if [ ! -d "$root/docs/orbit" ]; then
  echo "PASS: no shipped docs/orbit tree"
  exit 0
fi

# Hook-test runners do not install the ORBIT CLI. Stub its schema check:
# the records-lint workflow runs the real CLI. The format rules this test
# guards (sentence length and the rest) live in records-lint.sh itself.
sb=$(mktemp -d)
trap 'rm -rf "$sb"' EXIT
printf '#!/bin/sh\nexit 0\n' > "$sb/orbit"
chmod +x "$sb/orbit"

out=$(ORBIT_BIN="$sb/orbit" bash "$root/.claude/skills/orbit/lib/records-lint.sh" \
  --orbit-root "$root/docs/orbit" --repo me2resh/apexyard --all 2>&1)
rc=$?
if [ "$rc" -eq 0 ]; then
  echo "PASS: every shipped ORBIT record passes records-lint"
  exit 0
fi
echo "FAIL: shipped ORBIT records fail records-lint (rc=$rc)"
printf '%s\n' "$out" | grep -E 'FAIL' | head -20
exit 1
