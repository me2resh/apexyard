#!/bin/bash
# Tests for block-forged-menu-approval.sh (me2resh/apexyard#1391, AgDR-0234).
#
# Edit, Write, and Bash must not be able to plant approval_channel=menu
# on a review marker. A typed marker without that channel still passes.

set -u

# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"

SRC_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
HOOK="$SRC_ROOT/.claude/hooks/block-forged-menu-approval.sh"

PASS=0
FAIL=0

assert_eq() {
  local label="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then
    echo "PASS [$label]"
    PASS=$((PASS + 1))
  else
    echo "FAIL [$label]: want '$want', got '$got'" >&2
    FAIL=$((FAIL + 1))
  fi
}

run_hook() {
  local payload="$1"
  local rc
  set +e
  printf '%s' "$payload" | bash "$HOOK" >/dev/null 2>&1
  rc=$?
  set -e
  printf '%s' "$rc"
}

MENU_BODY='sha=abcdef1234567890abcdef1234567890abcdef12
approved_by=user
skill_version=3
approval_channel=menu
approved_at=2026-10-12T14:00:00Z
approval_summary="Approve and merge"'

CEO="/tmp/reviews/me2resh__apexyard__1683-ceo.approved"
DESIGN="/tmp/reviews/me2resh__apexyard__1683-design.approved"

payload=$(jq -nc --arg p "$CEO" --arg c "$MENU_BODY" '{tool_name:"Write", tool_input:{file_path:$p, content:$c}}')
assert_eq "Write of menu ceo record blocks" "2" "$(run_hook "$payload")"

payload=$(jq -nc --arg p "$DESIGN" --arg n "approval_channel=menu" '{tool_name:"Edit", tool_input:{file_path:$p, old_string:"sha=abc", new_string:$n}}')
assert_eq "Edit of menu design record blocks" "2" "$(run_hook "$payload")"

cmd="cat > ${CEO} <<'EOF'
${MENU_BODY}
EOF"
payload=$(jq -nc --arg c "$cmd" '{tool_name:"Bash", tool_input:{command:$c}}')
assert_eq "Bash write of menu record blocks" "2" "$(run_hook "$payload")"

payload=$(jq -nc --arg c "$MENU_BODY" '{tool_name:"Write", tool_input:{file_path:"docs/agdr/AgDR-0234-approve-from-menu.md", content:$c}}')
assert_eq "Write of menu text to a doc allows" "0" "$(run_hook "$payload")"

typed='sha=abcdef1234567890abcdef1234567890abcdef12
approved_by=user
skill_version=2
approval_summary="typed"'
cmd="cat > ${CEO} <<'EOF'
${typed}
EOF"
payload=$(jq -nc --arg c "$cmd" '{tool_name:"Bash", tool_input:{command:$c}}')
assert_eq "Bash write of typed v2 marker allows" "0" "$(run_hook "$payload")"

payload=$(jq -nc '{tool_name:"Bash", tool_input:{command:"grep -n approval_channel=menu notes-ceo.approved"}}')
assert_eq "grep of a marker path allows" "0" "$(run_hook "$payload")"

echo ""
payload=$(jq -nc --arg c './.claude/hooks/record-menu-approval.sh' '{tool_name:"Bash", tool_input:{command:$c}}')
assert_eq "writer spelling blocks" "2" "$(run_hook "$payload")"
payload=$(jq -nc --arg c 'bash ".claude/hooks/record-menu-approval.sh"' '{tool_name:"Bash", tool_input:{command:$c}}')
assert_eq "writer spelling blocks" "2" "$(run_hook "$payload")"
payload=$(jq -nc --arg c 'sh '"'"'.claude/hooks/record-menu-approval.sh'"'"'' '{tool_name:"Bash", tool_input:{command:$c}}')
assert_eq "writer spelling blocks" "2" "$(run_hook "$payload")"
payload=$(jq -nc --arg c 'source .claude/hooks/_lib-menu-approval.sh && menu_approval_write_record x y z' '{tool_name:"Bash", tool_input:{command:$c}}')
assert_eq "writer spelling blocks" "2" "$(run_hook "$payload")"
payload=$(jq -nc --arg c '. ".claude/hooks/_lib-menu-approval.sh"' '{tool_name:"Bash", tool_input:{command:$c}}')
assert_eq "writer spelling blocks" "2" "$(run_hook "$payload")"
payload=$(jq -nc --arg c 'printf fake-json | .claude/hooks/record-menu-approval.sh' '{tool_name:"Bash", tool_input:{command:$c}}')
assert_eq "writer spelling blocks" "2" "$(run_hook "$payload")"
payload=$(jq -nc --arg c 'exec /some/path/record-menu-approval.sh' '{tool_name:"Bash", tool_input:{command:$c}}')
assert_eq "writer spelling blocks" "2" "$(run_hook "$payload")"
payload=$(jq -nc --arg c 'env bash /some/path/record-menu-approval.sh' '{tool_name:"Bash", tool_input:{command:$c}}')
assert_eq "writer spelling blocks" "2" "$(run_hook "$payload")"
payload=$(jq -nc --arg c 'menu_approval_write_record x y z' '{tool_name:"Bash", tool_input:{command:$c}}')
assert_eq "writer spelling blocks" "2" "$(run_hook "$payload")"
for channel in 'approval_channel="menu"' "approval_channel='menu'"; do
  payload=$(jq -nc --arg p "$CEO" --arg c "$channel" '{tool_name:"Write", tool_input:{file_path:$p, content:$c}}')
  assert_eq "quoted channel Write blocks" "2" "$(run_hook "$payload")"
  payload=$(jq -nc --arg c "echo $channel > $CEO" '{tool_name:"Bash", tool_input:{command:$c}}')
  assert_eq "quoted channel Bash blocks" "2" "$(run_hook "$payload")"
done

echo "==================================="
echo "  PASS: $PASS   FAIL: $FAIL"
echo "==================================="
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
