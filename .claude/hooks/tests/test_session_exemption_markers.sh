#!/bin/bash
# Concurrent session regression tests for #1532.
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)
. "$HERE/tests/_test-session-isolation.sh"
. "$HERE/_lib-session-markers.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
PASS=0 FAIL=0
check() {
  if "$@"; then PASS=$((PASS+1)); else echo "FAIL: $*"; FAIL=$((FAIL+1)); fi
}
git -C "$TMP" init -q
mkdir -p "$TMP/.claude/session"
: > "$TMP/.apexyard-fork"
cp "$HERE/../project-config.defaults.json" "$TMP/.claude/"
create='{"tool_name":"Bash","tool_input":{"command":"gh issue create --title test"}}'
edit='{"tool_name":"Edit","tool_input":{"file_path":"src/code.sh"}}'
gate() {
  local sid="$1" hook="$2" payload="$3" expected="$4" rc
  (cd "$TMP" && printf '%s' "$payload" | CLAUDE_CODE_SESSION_ID="$sid" bash "$HERE/$hook") >"$TMP/out" 2>"$TMP/err"
  rc=$?
  [ "$rc" = "$expected" ]
}
for spec in 'active-bootstrap setup clear-bootstrap-marker.sh' 'active-issue-skill bug clear-issue-skill-marker.sh'; do
  set -- $spec
  name="$1" skill="$2" clear="$3"
  printf '%s\n' "$skill" > "$TMP/.claude/session/$name.A"
  check gate A require-skill-for-issue-create.sh "$create" 0
  check gate B require-skill-for-issue-create.sh "$create" 2
  if [ "$name" = active-bootstrap ]; then
    check gate A require-active-ticket.sh "$edit" 0
    check gate B require-active-ticket.sh "$edit" 2
  fi
  printf '%s\n' "$skill" > "$TMP/.claude/session/$name.B"
  (cd "$TMP" && CLAUDE_CODE_SESSION_ID=B bash "$HERE/$clear")
  check test ! -f "$TMP/.claude/session/$name.B"
  check test -f "$TMP/.claude/session/$name.A"
  printf '%s\n' "$skill" > "$TMP/.claude/session/$name"
  check gate '' require-skill-for-issue-create.sh "$create" 2
  check gate B require-skill-for-issue-create.sh "$create" 2
  if [ "$name" = active-bootstrap ]; then check gate '' require-active-ticket.sh "$edit" 2; fi
  # Reset the notice claim, then check repeated readers emit one notice.
  rmdir "$TMP/.claude/session/$name.restart-notice"
  { active_bootstrap_marker_path "$TMP" A; active_issue_skill_marker_path "$TMP" A;
    active_bootstrap_marker_path "$TMP" B; active_issue_skill_marker_path "$TMP" B; } > /dev/null 2>"$TMP/notice"
  check test "$(grep -c "ignored legacy $name marker" "$TMP/notice")" = 1
  rm -f "$TMP/.claude/session/$name" "$TMP/.claude/session/$name.A"
done
# Adapter ids use the same isolation and sanitization rules.
printf 'setup\n' > "$TMP/.claude/session/active-bootstrap.adapter_A"
export APEXYARD_SESSION_ID='adapter/A'
check gate '' require-active-ticket.sh "$edit" 0
export APEXYARD_SESSION_ID=adapter_B
check gate '' require-active-ticket.sh "$edit" 2
printf 'setup\n' > "$TMP/.claude/session/active-bootstrap"
check gate '' require-active-ticket.sh "$edit" 2
export APEXYARD_SESSION_ID='adapter/A'
check gate B require-active-ticket.sh "$edit" 2
check gate adapter_A require-active-ticket.sh "$edit" 0
printf 'bug\n' > "$TMP/.claude/session/active-issue-skill.adapter_A"
check gate '' require-skill-for-issue-create.sh "$create" 0
export APEXYARD_SESSION_ID=adapter_B
check gate '' require-skill-for-issue-create.sh "$create" 2
printf 'bug\n' > "$TMP/.claude/session/active-issue-skill"
check gate '' require-skill-for-issue-create.sh "$create" 2
check gate adapter_A require-skill-for-issue-create.sh "$create" 0
export APEXYARD_SESSION_ID=adapter_A
check gate B require-skill-for-issue-create.sh "$create" 2
rm -f "$TMP/.claude/session/active-issue-skill" "$TMP/.claude/session/active-issue-skill.adapter_A"
unset APEXYARD_SESSION_ID
check gate '' require-active-ticket.sh "$edit" 2
rm -f "$TMP/.claude/session/active-bootstrap" "$TMP/.claude/session/active-bootstrap.adapter_A"
schema='{"tool_name":"Bash","tool_input":{"command":"gh issue create --title \"[Feature] test\" --body \"invalid\""}}'
printf 'request-apexyard-feature\n' > "$TMP/.claude/session/active-issue-skill.A"
check gate A validate-issue-structure.sh "$schema" 0
check gate B validate-issue-structure.sh "$schema" 2
check gate '' validate-issue-structure.sh "$schema" 2
rm -f "$TMP/.claude/session/active-issue-skill.A"
role='{"tool_name":"Edit","tool_input":{"file_path":"src/auth/login.ts"}}'
check gate A detect-role-trigger.sh "$role" 0
check grep -q 'ROLE TRIGGER' "$TMP/err"
check gate B detect-role-trigger.sh "$role" 0
check grep -q 'ROLE TRIGGER' "$TMP/err"
check gate A detect-role-trigger.sh "$role" 0
check test ! -s "$TMP/err"
check test "$(find "$TMP/.claude/session/role-fired" -name 'B__*' | wc -l | tr -d ' ')" != 0
find "$TMP/.claude/session/role-fired" -name 'B__*' -exec touch -t 202001010000 {} \;
check gate A detect-role-trigger.sh "$role" 0
check test "$(find "$TMP/.claude/session/role-fired" -name 'B__*' | wc -l | tr -d ' ')" = 0
check gate '' detect-role-trigger.sh "$role" 0
check grep -q 'ROLE TRIGGER' "$TMP/err"
# /scaffold must set marker_home before mkdir for the session dir (Hakim #1770).
scaffold_skill="$HERE/../skills/scaffold/SKILL.md"
scaffold_block=$(awk '/^```bash$/{p=1;next} p&&/^```$/{exit} p' "$scaffold_skill")
mkdir_line=$(printf '%s\n' "$scaffold_block" | grep -n 'mkdir -p "$marker_home/.claude/session"' | head -1 | cut -d: -f1)
home_line=$(printf '%s\n' "$scaffold_block" | grep -n 'marker_home="$(git rev-parse --show-toplevel)"' | head -1 | cut -d: -f1)
check test -n "$mkdir_line"
check test -n "$home_line"
check test "$home_line" -lt "$mkdir_line"
echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
