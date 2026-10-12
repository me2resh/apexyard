#!/bin/bash
# Tests for record-menu-approval.sh (me2resh/apexyard#1391, AgDR-0234).
#
# The hook writes a menu record only when the harness payload names the
# repo, the PR, and the full head SHA, and the selected option is the
# exact approve label.

set -u

# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"

SRC_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
HOOK="$SRC_ROOT/.claude/hooks/record-menu-approval.sh"
# shellcheck source=/dev/null
. "$SRC_ROOT/.claude/hooks/_lib-review-markers.sh"
# shellcheck source=/dev/null
. "$SRC_ROOT/.claude/hooks/_lib-menu-approval.sh"

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

SHA="abcdef1234567890abcdef1234567890abcdef12"
REPO="me2resh/apexyard"
PR="1683"

make_sb() {
  local sb
  sb=$(mktemp -d)
  : > "$sb/.apexyard-fork"
  : > "$sb/onboarding.yaml"
  : > "$sb/apexyard.projects.yaml"
  mkdir -p "$sb/.claude/session/reviews"
  (
    cd "$sb" || exit 1
    git init -q
    git config user.email "t@t"
    git config user.name "t"
    git add onboarding.yaml
    git commit -q -m init
  )
  printf '%s' "$sb"
}

run_hook() {
  local sb="$1" payload="$2"
  ( cd "$sb" && bash "$HOOK" >/dev/null 2>"$sb/hook.err" <<< "$payload" )
}

payload_for() {
  local question="$1" answer="$2"
  jq -nc --arg q "$question" --arg a "$answer" '{
    tool_name:"AskUserQuestion",
    tool_input:{questions:[{question:$q, options:[{label:"Approve and merge"},{label:"Not yet"}]}]},
    tool_response:{answers:{($q):$a}}
  }'
}

Q="Approve and merge ${REPO}#${PR} at ${SHA}?"

sb=$(make_sb)
run_hook "$sb" "$(payload_for "$Q" "Approve and merge")"
marker=$(review_marker_path "$REPO" "$PR" ceo "$sb")
if [ -f "$marker" ]; then
  assert_eq "approve option writes a file" "yes" "yes"
else
  assert_eq "approve option writes a file" "yes" "no"
fi
got_sha=$(menu_approval_record_sha "$marker" 2>/dev/null || true)
assert_eq "hook record sha" "$SHA" "$got_sha"
assert_eq "channel" "menu" "$(menu_approval_field "$marker" approval_channel)"
assert_eq "approved_by" "user" "$(menu_approval_field "$marker" approved_by)"
assert_eq "skill_version" "3" "$(menu_approval_field "$marker" skill_version)"
assert_eq "summary" "Approve and merge" "$(menu_approval_field "$marker" approval_summary)"
rm -rf "$sb"

sb=$(make_sb)
run_hook "$sb" "$(payload_for "$Q" "Not yet")"
marker=$(review_marker_path "$REPO" "$PR" ceo "$sb")
if [ -f "$marker" ]; then
  assert_eq "Not yet writes nothing" "absent" "present"
else
  assert_eq "Not yet writes nothing" "absent" "absent"
fi
rm -rf "$sb"

sb=$(make_sb)
run_hook "$sb" "$(payload_for "Approve and merge ${REPO}#${PR}?" "Approve and merge")"
marker=$(review_marker_path "$REPO" "$PR" ceo "$sb")
if [ -f "$marker" ]; then
  assert_eq "question without sha writes nothing" "absent" "present"
else
  assert_eq "question without sha writes nothing" "absent" "absent"
fi
rm -rf "$sb"

sb=$(make_sb)
run_hook "$sb" "$(payload_for "Ship it?" "Approve and merge")"
count=$(find "$sb/.claude/session/reviews" -type f 2>/dev/null | wc -l | tr -d ' ')
assert_eq "unshaped question writes nothing" "0" "$count"
rm -rf "$sb"

DQ="Approve design review for ${REPO}#${PR} at ${SHA}?"
sb=$(make_sb)
run_hook "$sb" "$(jq -nc --arg q "$DQ" '{
  tool_name:"AskUserQuestion",
  tool_input:{questions:[{question:$q}]},
  tool_response:{answers:{($q):"Approve design review"}}
}')"
dmarker=$(review_marker_path "$REPO" "$PR" design "$sb")
cmarker=$(review_marker_path "$REPO" "$PR" ceo "$sb")
assert_eq "design menu sha" "$SHA" "$(menu_approval_record_sha "$dmarker" 2>/dev/null || true)"
if [ -f "$cmarker" ]; then
  assert_eq "design menu does not write ceo" "absent" "present"
else
  assert_eq "design menu does not write ceo" "absent" "absent"
fi
rm -rf "$sb"

AQ="Approve architecture review for ${REPO}#${PR} at ${SHA}?"
sb=$(make_sb)
run_hook "$sb" "$(jq -nc --arg q "$AQ" '{
  tool_name:"AskUserQuestion",
  tool_input:{questions:[{question:$q}]},
  tool_response:{answers:{($q):"Approve architecture review"}}
}')"
amarker=$(review_marker_path "$REPO" "$PR" architecture "$sb")
assert_eq "architecture menu sha" "$SHA" "$(menu_approval_record_sha "$amarker" 2>/dev/null || true)"
rm -rf "$sb"

echo ""
# A timeout must not turn an approve-shaped answer into approval.
for response_form in object string answer; do
  sb=$(make_sb)
  payload=$(payload_for "$Q" "Approve and merge" | jq --arg form "$response_form" '
    .tool_response.afkTimeoutMs = 0 |
    if $form == "string" then .tool_response |= tojson
    elif $form == "answer" then
      .tool_response = {answers: [{question: .tool_input.questions[0].question, answer: "Approve and merge", afkTimeoutMs: 1}]}
    else . end')
  run_hook "$sb" "$payload"
  marker=$(review_marker_path "$REPO" "$PR" ceo "$sb")
  assert_eq "timeout writes nothing ($response_form)" "absent" "$(if [ -f "$marker" ]; then echo present; else echo absent; fi)"
  rm -rf "$sb"
done

echo "==================================="
echo "  PASS: $PASS   FAIL: $FAIL"
echo "==================================="
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
