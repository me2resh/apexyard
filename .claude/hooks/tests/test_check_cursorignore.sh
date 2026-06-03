#!/bin/bash
# Smoke tests for .claude/hooks/check-cursorignore.sh
set -u

HOOK_SRC="$(cd "$(dirname "$0")/.." && pwd)/check-cursorignore.sh"
LIB_SRC="$(cd "$(dirname "$0")/.." && pwd)/_lib-ops-root.sh"
PASS=0
FAIL=0

if [ ! -f "$HOOK_SRC" ]; then
  echo "FAIL: hook not found at $HOOK_SRC" >&2
  exit 1
fi

build_fork() {
  local fk="$1"
  mkdir -p "$fk/.claude/hooks"
  : > "$fk/onboarding.yaml"
  : > "$fk/apexyard.projects.yaml"
  cp "$HOOK_SRC" "$fk/.claude/hooks/check-cursorignore.sh"
  chmod +x "$fk/.claude/hooks/check-cursorignore.sh"
  cp "$LIB_SRC" "$fk/.claude/hooks/_lib-ops-root.sh"
}

assert_silent() {
  local out
  out=$(cd "$1" && bash .claude/hooks/check-cursorignore.sh 2>&1)
  if [ -n "$out" ]; then
    echo "FAIL: expected silent, got: $out" >&2
    FAIL=$((FAIL + 1))
    return
  fi
  PASS=$((PASS + 1))
}

assert_warns() {
  local out
  out=$(cd "$1" && bash .claude/hooks/check-cursorignore.sh 2>&1)
  if ! echo "$out" | grep -q 'workspace/'; then
    echo "FAIL: expected workspace/ warning, got: $out" >&2
    FAIL=$((FAIL + 1))
    return
  fi
  PASS=$((PASS + 1))
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# 1. Valid .cursorignore → silent
fk="$TMP/fork-ok"
build_fork "$fk"
printf '%s\n' 'workspace/' '!workspace/README.md' > "$fk/.cursorignore"
assert_silent "$fk"

# 2. Missing .cursorignore → warn
fk="$TMP/fork-missing"
build_fork "$fk"
assert_warns "$fk"

# 3. .cursorignore without workspace/ → warn
fk="$TMP/fork-bad"
build_fork "$fk"
echo '**/node_modules/' > "$fk/.cursorignore"
assert_warns "$fk"

echo "check-cursorignore: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
