#!/bin/bash
# Empty registry lists must be safe under macOS Bash 3.2 with set -u.

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

check_hook() {
  local label="$1" registry="$2" content="$3" expected_rc="$4" leak_content="${5:-}"
  local sandbox output rc expected_path
  sandbox=$(mktemp -d) || exit 1
  mkdir -p "$sandbox/.claude/hooks"
  cp "$HOOK_SOURCE" "$sandbox/.claude/hooks/check-private-refs-staged.sh"
  cp "$PARSER_SOURCE" "$sandbox/.claude/hooks/_lib-registry-parser.sh"
  cp "$MATCH_SOURCE" "$sandbox/.claude/hooks/_lib-private-refs-match.sh"
  cp "$VIS_SOURCE" "$sandbox/.claude/hooks/_lib-leak-remote-visibility.sh"
  printf '%s\n' "$registry" > "$sandbox/apexyard.projects.yaml"
  printf '%s\n' "$content" > "$sandbox/a-clean.md"
  expected_path='a-clean.md'
  if [ -n "$leak_content" ]; then
    printf '%s\n' "$leak_content" > "$sandbox/z-leak.md"
    expected_path='z-leak.md'
  fi
  git -C "$sandbox" init -q
  git -C "$sandbox" add -- apexyard.projects.yaml a-clean.md
  if [ -n "$leak_content" ]; then
    git -C "$sandbox" add -- z-leak.md
  fi

  output=$(cd "$sandbox" && /bin/bash .claude/hooks/check-private-refs-staged.sh 2>&1)
  rc=$?
  if [ "$rc" -eq "$expected_rc" ] \
    && { [ "$expected_rc" -ne 0 ] || [ -z "$output" ]; } \
    && { [ "$expected_rc" -ne 2 ] || { printf '%s' "$output" | grep -qF "File: $expected_path" \
      && ! printf '%s' "$output" | grep -qF "$leak_content"; }; }; then
    printf '  ok   %s\n' "$label"
    PASS=$((PASS + 1))
  else
    printf '  FAIL %s: exit=%s, output=%s\n' "$label" "$rc" "$output" >&2
    FAIL=$((FAIL + 1))
  fi
  rm -rf "$sandbox"
}

echo '== Staged private references with empty registry lists =='

check_hook 'clean staged file passes without workspace entries' \
  'projects:
  - name: silver-comet
    repo: example-org/silver-comet' \
  'A clean note.' 0

check_hook 'a later leak blocks without workspace entries' \
  'projects:
  - name: silver-comet
    repo: example-org/silver-comet' \
  'A clean note.' 2 'See example-org/silver-comet#7.'

check_hook 'repo leak blocks when the name list is empty' \
  'projects:
  - id: blue-orbit
    repo: example-org/blue-orbit' \
  'A clean note.' 2 'See example-org/blue-orbit#7.'

check_hook 'workspace leak blocks when the repo list is empty' \
  'projects:
  - name: green-kite
    workspace: workspace/amber-valley' \
  'A clean note.' 2 'See workspace/amber-valley/readme.md.'

printf 'Passed: %s\nFailed: %s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
