#!/bin/bash
# A Latin-1 byte on a staged line must not hide any private registry token.

set -u

# Isolate from live Claude Code session pin/cache (me2resh/apexyard#1549).
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"


ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
HOOK_SOURCE=${HOOK_SOURCE:-$ROOT/.claude/hooks/check-private-refs-staged.sh}
PARSER_SOURCE="$ROOT/.claude/hooks/_lib-registry-parser.sh"
MATCH_SOURCE="$ROOT/.claude/hooks/_lib-private-refs-match.sh"
VIS_SOURCE="$ROOT/.claude/hooks/_lib-leak-remote-visibility.sh"

PASS=0
FAIL=0

check_non_utf8_leak() {
  local label="$1" identifier="$2"
  local sandbox output rc
  sandbox=$(mktemp -d) || exit 1
  mkdir -p "$sandbox/.claude/hooks"
  cp "$HOOK_SOURCE" "$sandbox/.claude/hooks/check-private-refs-staged.sh"
  cp "$PARSER_SOURCE" "$sandbox/.claude/hooks/_lib-registry-parser.sh"
  cp "$MATCH_SOURCE" "$sandbox/.claude/hooks/_lib-private-refs-match.sh"
  cp "$VIS_SOURCE" "$sandbox/.claude/hooks/_lib-leak-remote-visibility.sh"
  cat > "$sandbox/apexyard.projects.yaml" <<'YAML'
projects:
  - name: amber-lantern
    repo: sample-org/blue-orbit
    workspace: workspace/green-kite
YAML
  printf '%s\xe9\n' "$identifier" > "$sandbox/notes.md"
  git -C "$sandbox" init -q
  git -C "$sandbox" add -- notes.md

  output=$(cd "$sandbox" && LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8 \
    /bin/bash .claude/hooks/check-private-refs-staged.sh 2>&1)
  rc=$?
  if [ "$rc" -eq 2 ] \
    && printf '%s' "$output" | grep -qF 'File: notes.md' \
    && ! printf '%s' "$output" | grep -qF "$identifier"; then
    printf '  ok   %s\n' "$label"
    PASS=$((PASS + 1))
  else
    printf '  FAIL %s: exit=%s, output=%s\n' "$label" "$rc" "$output" >&2
    FAIL=$((FAIL + 1))
  fi
  rm -rf "$sandbox"
}

echo '== Non-UTF-8 staged private references (#1436) =='

check_non_utf8_leak 'name on the same line as a Latin-1 byte blocks' 'amber-lantern'
check_non_utf8_leak 'repo on the same line as a Latin-1 byte blocks' 'sample-org/blue-orbit'
check_non_utf8_leak 'workspace on the same line as a Latin-1 byte blocks' 'workspace/green-kite'

printf 'Passed: %s\nFailed: %s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
