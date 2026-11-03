#!/bin/bash
# GH-1900: real patch envelopes reach every existing edit check.
# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/live/.claude/hooks" "$TMP/live/src"
cp -R "$ROOT/." "$TMP/live/.claude/hooks/"
export CLAUDE_PROJECT_DIR="$TMP/live" CLAUDE_CODE_SESSION_ID=gh1900
export APEXYARD_OPS_PIN_DIR="$TMP/pins"
mkdir -p "$TMP/pins"
printf '%s\n' "$TMP/live" > "$TMP/pins/ops-root-gh1900"
touch "$TMP/live/.apexyard-fork"
git init -q "$TMP/live"
PASS=0 FAIL=0
check() {
  local want="$1" label="$2" rc=0
  shift 2
  "$@" > "$TMP/check" 2>&1 || rc=$?
  if [ "$1" = run_patch ]; then cp "$TMP/check" "$TMP/out"; fi
  if [ "$rc" = "$want" ]; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1)); printf 'FAIL %s expected=%s actual=%s\n' "$label" "$want" "$rc"; cat "$TMP/check"
  fi
}
patch() {
  jq -cn --arg cwd "$TMP/live" --arg command "$1" \
    '{session_id:"gh1900",tool_name:"apply_patch",cwd:$cwd,tool_input:{command:$command}}'
}
run_patch() {
  local input
  input=$(patch "$1")
  (cd "$TMP/live" && bash .claude/hooks/block-protected-target-writes.sh <<<"$input")
}
run_wildcard() {
  local input
  input=$(patch "$1")
  (cd "$TMP/live" && bash .claude/hooks/dispatch-bash.sh --shell-alias-only <<<"$input")
}
# Instrument each configured edit handler, retaining the matcher groups.
jq '.hooks.PreToolUse |= map(if ((.matcher // "") | test("Edit|Write")) then
  .hooks |= map(.command = "jq -r .tool_input.file_path >> targets.log") else . end)' \
  "$ROOT/../settings.json" > "$TMP/live/.claude/settings.json"
gates=$(jq '[.hooks.PreToolUse[] | select((.matcher // "") | test("Edit|Write")) | .hooks[]] | length' "$ROOT/../settings.json")
check 0 'one target' run_patch $'*** Begin Patch\n*** Add File: docs/one.md\n+hi\n*** End Patch'
check 0 'several targets and move' run_patch $'*** Begin Patch\n*** Add File: docs/a.md\n+x\n*** Update File: docs/b.md\n*** Move to: docs/c.md\n@@\n-a\n+b\n*** Delete File: docs/d.md\n*** End Patch'
check 0 'every edit handler sees every target' test "$(wc -l < "$TMP/live/targets.log" | tr -d ' ')" = "$((5*gates))"
check 0 'move destination extracted' grep -qx 'docs/c.md' "$TMP/live/targets.log"
check 0 'wildcard routes patch through edit checks' run_wildcard $'*** Begin Patch\n*** Add File: docs/wildcard.md\n+hi\n*** End Patch'
check 0 'wildcard target reached edit checks' grep -qx 'docs/wildcard.md' "$TMP/live/targets.log"
for invalid in '' $'*** Begin Patch\n*** End Patch' $'*** Begin Patch\n*** Add File: a' $'*** Add File: a\n*** End Patch' $'*** Begin Patch\n*** Add File:\n*** Add File: a\n*** End Patch'; do
  check 2 'malformed or targetless patch' run_patch "$invalid"
  check 0 'clear malformed diagnostic' grep -q 'malformed envelope or no targets' "$TMP/out"
done
cp "$ROOT/../settings.json" "$TMP/live/.claude/settings.json"
check 2 'later protected target denies whole call' run_patch $'*** Begin Patch\n*** Add File: docs/ok.md\n+ok\n*** Delete File: .claude/hooks/x.sh\n*** End Patch'
check 0 'later target keeps protected message' grep -q 'the edit target is live hook state' "$TMP/out"
check 2 'protected move destination denies whole call' run_patch $'*** Begin Patch\n*** Update File: docs/ok.md\n*** Move to: .claude/hooks/x.sh\n@@\n-a\n+b\n*** End Patch'
check 0 'destination keeps protected message' grep -q 'the edit target is live hook state' "$TMP/out"
check 2 'protected denial preserved' run_patch $'*** Begin Patch\n*** Update File: .claude/hooks/x.sh\n@@\n-a\n+b\n*** End Patch'
check 0 'original protected message' grep -q 'the edit target is live hook state' "$TMP/out"
check 2 'active-ticket denial preserved' run_patch $'*** Begin Patch\n*** Add File: src/app.sh\n+echo hi\n*** End Patch'
check 0 'original active-ticket message' grep -q 'No active ticket set for this session' "$TMP/out"
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
