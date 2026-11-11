#!/bin/bash
# Tests for the opt-in gate plugins (me2resh/apexyard#1922, AgDR-0295).
#
# 1. Mod off: the committed settings enable neither plugin, and no hook
#    names either plugin. So with the plugins off or missing, every gate
#    runs exactly as before.
# 2. The approval pane stays behind the hooks: it registers no tool hook and
#    no settings hook, and its source has no file-write or merge call.
# 3. The question that the pane asks is one that the unchanged AgDR-0234
#    menu hook records for the approve label only.

set -u

# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"

SRC_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
PLUGIN="$SRC_ROOT/plugins/apexyard-gate"
HOOK="$SRC_ROOT/.claude/hooks/record-menu-approval.sh"
# shellcheck source=/dev/null
. "$SRC_ROOT/.claude/hooks/_lib-review-markers.sh"
# shellcheck source=/dev/null
. "$SRC_ROOT/.claude/hooks/_lib-menu-approval.sh"

PASS=0
FAIL=0

check() {
  local label="$1"
  shift
  if "$@"; then
    echo "PASS [$label]"
    PASS=$((PASS + 1))
  else
    echo "FAIL [$label]" >&2
    FAIL=$((FAIL + 1))
  fi
}

absent() { ! "$@"; }

# --- 1. Mod off ---------------------------------------------------------
check "settings.json does not enable apexyard-gate" absent grep -q 'apexyard-gate' "$SRC_ROOT/.claude/settings.json"
check "settings.json does not enable apexyard-status" absent grep -q 'apexyard-status' "$SRC_ROOT/.claude/settings.json"
check "no hook names apexyard-gate" absent grep -rlq --exclude-dir=tests 'apexyard-gate' "$SRC_ROOT/.claude/hooks"
check "marketplace lists apexyard-gate" grep -q '"./plugins/apexyard-gate"' "$SRC_ROOT/.claude-plugin/marketplace.json"

# --- 2. Behind the hooks ------------------------------------------------
check "hooks.json names only a module" test "$(jq -c 'keys' "$PLUGIN/hooks/hooks.json")" = '["modules"]'
check "plugin.json declares no settings hooks" test "$(jq 'has("hooks")' "$PLUGIN/.claude-plugin/plugin.json")" = false
SOURCES=("$PLUGIN/hooks/register.tsx" "$PLUGIN/hooks/approve.ts")
check "no tool or classic hook" absent grep -Eq "on\\(['\"](tool|classic)\\." "${SOURCES[@]}"
check "no file write call" absent grep -Eq '\$\.fs\.(write|append|remove|rename|mkdir|copy)' "${SOURCES[@]}"
check "no merge command" absent grep -Eq "'merge'|pr merge" "${SOURCES[@]}"
check "no direct question tool call" absent grep -Eq "tool\\.call" "${SOURCES[@]}"

# --- 3. The pane's question through the unchanged menu hook -------------
SHA="abcdef1234567890abcdef1234567890abcdef12"
REPO="me2resh/apexyard"
PR="1922"
# The same string approvalQuestion() builds (approve.test.ts checks it).
Q="Approve and merge ${REPO}#${PR} at ${SHA}?"

make_sb() {
  local sb
  sb=$(mktemp -d)
  : > "$sb/.apexyard-fork"
  : > "$sb/onboarding.yaml"
  : > "$sb/apexyard.projects.yaml"
  mkdir -p "$sb/.claude/session/reviews"
  (cd "$sb" && git init -q && git config user.email t@t && git config user.name t && git add onboarding.yaml && git commit -q -m init)
  printf '%s' "$sb"
}

# The payload shape of a $.ui.ask call with a header and two options.
payload() {
  jq -nc --arg q "$Q" --arg a "$1" '{
    tool_name:"AskUserQuestion",
    tool_input:{questions:[{question:$q, header:"Merge", multiSelect:false,
      options:[{label:"Approve and merge", description:""},{label:"Not yet", description:""}]}]},
    tool_response:{questions:[{question:$q}], answers:{($q):$a}}
  }'
}

run_case() {
  local answer="$1" want="$2" sb marker got
  sb=$(make_sb)
  (cd "$sb" && bash "$HOOK" >/dev/null 2>&1 <<< "$(payload "$answer")")
  marker=$(review_marker_path "$REPO" "$PR" ceo "$sb")
  got=$(menu_approval_record_sha "$marker" 2>/dev/null || true)
  check "answer '$answer' -> record '${want:-none}'" test "$got" = "$want"
  rm -rf "$sb"
}

run_case "Approve and merge" "$SHA"
run_case "Not yet" ""
run_case "approve" ""
run_case "" ""

echo "==================================="
echo "  PASS: $PASS   FAIL: $FAIL"
echo "==================================="
[ "$FAIL" -eq 0 ]
