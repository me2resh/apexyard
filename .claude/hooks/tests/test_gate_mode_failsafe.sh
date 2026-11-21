#!/bin/bash
set -euo pipefail
# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../../.." && pwd)
TMP=$(mktemp -d)
trap 'chmod -R u+rwX "$TMP"; rm -rf "$TMP"' EXIT
mkdir -p "$TMP/.claude/hooks"
git -C "$TMP" init -q
# Register the fixture gate in test code only.
sed 's/# Opted-in gate names go here. No production gate is opted in yet./fixture-new) return 0 ;;/' \
  "$ROOT/.claude/hooks/_lib-gate-mode.sh" > "$TMP/.claude/hooks/_lib-gate-mode.sh"
failures=0
check() {
  local label="$1" expected="$2" warnings="$3" rc=0
  (cd "$TMP"
    . "$TMP/.claude/hooks/_lib-gate-mode.sh"
    if [ "$label" != 'missing reader' ]; then
      # shellcheck source=/dev/null
      . "$ROOT/.claude/hooks/_lib-read-config.sh"
    fi
    if [ "$label" = 'failed reader' ]; then
      config_get() { printf 'observe\n'; return 1; }
    fi
    gate_mode_resolve fixture-new observe
  ) > "$TMP/out" 2> "$TMP/err" || rc=$?
  if [ "$rc" = 0 ] && [ "$(cat "$TMP/out")" = "$expected" ] &&
    [ "$(wc -l < "$TMP/err" | tr -d ' ')" = "$warnings" ] &&
    { [ "$warnings" = 0 ] || grep -q '^WARN:' "$TMP/err"; }; then
    echo "PASS: $label"
  else
    echo "FAIL: $label (status=$rc, mode=$(cat "$TMP/out"))"
    cat "$TMP/err"
    failures=$((failures + 1))
  fi
}
printf '{}\n' > "$TMP/.claude/project-config.defaults.json"
printf '{broken\n' > "$TMP/.claude/project-config.json"
check 'broken override JSON' enforce 1
printf '{}\n' > "$TMP/.claude/project-config.json"
printf '{broken\n' > "$TMP/.claude/project-config.defaults.json"
check 'broken defaults JSON' enforce 1
printf '{}\n' > "$TMP/.claude/project-config.defaults.json"
chmod 000 "$TMP/.claude/project-config.json"
check 'unreadable config' enforce 1
chmod 600 "$TMP/.claude/project-config.json"
check 'missing reader' enforce 1
check 'failed reader' enforce 1
check 'missing key with observe default' observe 0
printf '{"gates":{"fixture-new":{"mode":"observe"}}}\n' > "$TMP/.claude/project-config.json"
check 'valid observe value' observe 0
[ "$failures" = 0 ]
