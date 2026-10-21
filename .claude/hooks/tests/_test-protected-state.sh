#!/bin/bash
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
export ROOT
TMP=$(mktemp -d)
TMP=$(cd "$TMP" && pwd -P)
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" CLAUDE_PROJECT_DIR="$TMP/live" CLAUDE_CODE_SESSION_ID=d17
export APEXYARD_OPS_PIN_DIR="$HOME/.claude/apexyard"
mkdir -p "$HOME/.claude" "$APEXYARD_OPS_PIN_DIR" "$TMP/live/.claude/hooks" "$TMP/scratch/.claude/hooks"
mkdir -p "$TMP/live/.git" "$TMP/scratch/.git"
touch "$TMP/live/.apexyard-fork" "$TMP/live/.claude/hooks/x.sh"
printf '%s\n' "$TMP/live" > "$APEXYARD_OPS_PIN_DIR/ops-root-d17"
printf '{}\n' > "$TMP/live/.claude/settings.json"
PASS=0 FAIL=0
check() {
  local want="$1" label="$2" rc=0
  shift 2
  "$@" > "$TMP/out" 2> "$TMP/err" || rc=$?
  if [ "$rc" = "$want" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); printf 'FAIL %s expected=%s actual=%s\n' "$label" "$want" "$rc"; cat "$TMP/err"; fi
}
finish() { printf '%s passed, %s failed\n' "$PASS" "$FAIL"; [ "$FAIL" = 0 ]; }
