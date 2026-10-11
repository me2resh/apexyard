#!/bin/bash
# Tests for review-agent detection by harness agent type
# (me2resh/apexyard#1649, AgDR-0145 amendment).
#
# Covers: the live-captured payload fixtures, review_caller_class, the
# per-review marker set, and block-reviewer-repo-mutation.sh. The orchestrator
# and build agents are never blocked; review agents are.
set -u

# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"

SRC_ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
HOOKS="$SRC_ROOT/.claude/hooks"
FIX="$HOOKS/tests/fixtures/pretooluse-payloads"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/apexyard-review-detect.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/.claude/session" "$TMP/.claude/hooks"
touch "$TMP/.apexyard-fork"
git -C "$TMP" init -q
for f in block-reviewer-repo-mutation.sh _lib-strip-heredoc.sh _lib-path-resolve.sh \
         _lib-review-markers.sh clear-active-reviewer-marker.sh _lib-ops-root.sh; do
  [ -f "$HOOKS/$f" ] && cp "$HOOKS/$f" "$TMP/.claude/hooks/"
done

# shellcheck disable=SC1091
. "$HOOKS/_lib-review-markers.sh"

PASS=0
FAIL=0
check() {
  if [ "$2" = ok ]; then echo "PASS: $1"; PASS=$((PASS + 1)); else echo "FAIL: $1 ($3)" >&2; FAIL=$((FAIL + 1)); fi
}
expect_eq() { # name got want
  if [ "$2" = "$3" ]; then check "$1" ok; else check "$1" no "got '$2' want '$3'"; fi
}

SID=sess-A
export CLAUDE_CODE_SESSION_ID="$SID"

# --- 1. Fixtures: the harness-set fields, captured live ---------------------
expect_eq "fixture: main thread has no agent_type" \
  "$(jq -r '.agent_type // "none"' "$FIX/bash-main-thread.json")" none
expect_eq "fixture: main thread has no agent_id" \
  "$(jq -r '.agent_id // "none"' "$FIX/bash-main-thread.json")" none
expect_eq "fixture: reviewer agent_type" \
  "$(jq -r '.agent_type' "$FIX/bash-code-reviewer.json")" code-reviewer
expect_eq "fixture: general-purpose agent_type" \
  "$(jq -r '.agent_type' "$FIX/bash-general-purpose.json")" general-purpose
expect_eq "fixture: PostToolUse carries agent_type" \
  "$(jq -r '.agent_type' "$FIX/posttooluse-bash-general-purpose.json")" general-purpose

# --- 2. review_caller_class -------------------------------------------------
expect_eq "class: main thread" "$(review_caller_class "$(cat "$FIX/bash-main-thread.json")" "$TMP")" main
expect_eq "class: code-reviewer fixture" "$(review_caller_class "$(cat "$FIX/bash-code-reviewer.json")" "$TMP")" reviewer
expect_eq "class: general-purpose fixture" "$(review_caller_class "$(cat "$FIX/bash-general-purpose.json")" "$TMP")" other-agent
expect_eq "class: security-reviewer" "$(review_caller_class '{"agent_type":"security-reviewer","agent_id":"a1"}' "$TMP")" reviewer
expect_eq "class: solution-architect" "$(review_caller_class '{"agent_type":"solution-architect","agent_id":"a1"}' "$TMP")" reviewer
expect_eq "class: build agent" "$(review_caller_class '{"agent_type":"backend-engineer","agent_id":"a1"}' "$TMP")" other-agent
expect_eq "class: untyped sub-agent, no marker" "$(review_caller_class '{"agent_id":"a1"}' "$TMP")" untyped-agent
expect_eq "class: not JSON" "$(review_caller_class 'not json' "$TMP")" unparsable

# --- 3. Per-review markers: two at once, no clobbering ----------------------
M1=$(active_reviewer_marker_path "$TMP" "" "acme/app" 7 rex)
M2=$(active_reviewer_marker_path "$TMP" "" "acme/app" 8 security)
M3=$(active_reviewer_marker_path "$TMP" "" "acme/other" 7 rex)
mkdir -p "$(dirname "$M1")"
printf '%s\n' 'acme/app#7:rex' > "$M1"
printf '%s\n' 'acme/app#8:security' > "$M2"
printf '%s\n' 'acme/other#7:rex' > "$M3"
if [ "$M1" != "$M2" ] && [ "$M1" != "$M3" ] && [ -f "$M1" ] && [ -f "$M2" ] && [ -f "$M3" ]; then
  check "three concurrent review markers keep distinct files" ok
else
  check "three concurrent review markers keep distinct files" no "$M1 $M2 $M3"
fi
expect_eq "marker content survives the other writes" "$(cat "$M1")" 'acme/app#7:rex'
case "$M1" in "$TMP/.claude/session/active-reviewers/$SID/"*) check "marker lives in this session's set" ok ;; *) check "marker lives in this session's set" no "$M1" ;; esac

# --- 4. Hook behaviour with markers present ---------------------------------
run_hook() { # name json expected(blocked|allowed)
  local name="$1" json="$2" expected="$3" out rc
  out=$(cd "$TMP" && printf '%s' "$json" | "$TMP/.claude/hooks/block-reviewer-repo-mutation.sh" 2>&1)
  rc=$?
  if [ "$expected" = blocked ] && [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q 'BLOCKED:'; then
    check "$name" ok
  elif [ "$expected" = allowed ] && [ "$rc" -eq 0 ]; then
    check "$name" ok
  else
    check "$name" no "rc=$rc out=$out"
  fi
}
payload() { # agent_type agent_id command
  jq -cn --arg t "$1" --arg i "$2" --arg c "$3" \
    '({tool_input:{command:$c}}) + (if $t != "" then {agent_type:$t} else {} end) + (if $i != "" then {agent_id:$i} else {} end)'
}

run_hook "orchestrator commit during active reviews succeeds" "$(payload '' '' 'git commit -m work')" allowed
run_hook "orchestrator push during active reviews succeeds" "$(payload '' '' 'git push origin feature/x')" allowed
run_hook "build agent push during active reviews succeeds" "$(payload backend-engineer a1 'git push origin feature/x')" allowed
run_hook "build agent commit during active reviews succeeds" "$(payload platform-engineer a1 'git commit -m work')" allowed
run_hook "general-purpose agent commit succeeds" "$(payload general-purpose a1 'git commit -m work')" allowed
run_hook "code-reviewer commit is blocked" "$(payload code-reviewer a1 'git commit -m x')" blocked
run_hook "security-reviewer push is blocked" "$(payload security-reviewer a1 'git push origin x')" blocked
run_hook "solution-architect checkout is blocked" "$(payload solution-architect a1 'git checkout main')" blocked
run_hook "reviewer read-only git stays available" "$(payload code-reviewer a1 'git diff --stat')" allowed
run_hook "untyped sub-agent with a marker is blocked" "$(payload '' a1 'git commit -m x')" blocked
run_hook "unparsable payload with a marker fails closed" 'git commit -m x' blocked
run_hook "captured code-reviewer payload with a git commit is blocked" \
  "$(jq -c '.tool_input.command="git commit -m x"' "$FIX/bash-code-reviewer.json")" blocked
run_hook "captured main-thread payload with a git commit is allowed" \
  "$(jq -c '.tool_input.command="git commit -m x"' "$FIX/bash-main-thread.json")" allowed

# --- 5. Each review clears only its own marker ------------------------------
rm -f "$M1"
if [ ! -f "$M1" ] && [ -f "$M2" ] && [ -f "$M3" ]; then
  check "clearing one review leaves the others" ok
else
  check "clearing one review leaves the others" no "$M1 $M2 $M3"
fi
run_hook "reviewer still blocked while another review is active" "$(payload code-reviewer a1 'git commit -m x')" blocked
rm -f "$M2" "$M3"
run_hook "reviewer not blocked once every review is cleared" "$(payload code-reviewer a1 'git commit -m x')" allowed
run_hook "untyped sub-agent without a marker is allowed" "$(payload '' a1 'git commit -m x')" allowed

# --- 6. Legacy single-file marker is still read ------------------------------
LEGACY=$(active_reviewer_marker_path "$TMP")
printf '%s\n' 'acme/app#9:rex' > "$LEGACY"
run_hook "legacy single-file marker still locks a reviewer" "$(payload code-reviewer a1 'git commit -m x')" blocked
run_hook "legacy single-file marker never locks the orchestrator" "$(payload '' '' 'git commit -m x')" allowed
rm -f "$LEGACY"

# --- 7. SessionStart clears this session's set only --------------------------
OTHER=$(active_reviewer_marker_path "$TMP" "sess-B" "acme/app" 5 rex)
mkdir -p "$(dirname "$OTHER")"
printf '%s\n' 'acme/app#5:rex' > "$OTHER"
printf '%s\n' 'acme/app#7:rex' > "$M1"
(cd "$TMP" && "$TMP/.claude/hooks/clear-active-reviewer-marker.sh" >/dev/null 2>&1)
if [ ! -f "$M1" ] && [ -f "$OTHER" ]; then
  check "SessionStart clears this session's set and spares another session" ok
else
  check "SessionStart clears this session's set and spares another session" no "mine=$([ -f "$M1" ] && echo kept || echo cleared) other=$([ -f "$OTHER" ] && echo kept || echo cleared)"
fi

# --- 8. The lib is missing: fail closed ---------------------------------------
NOLIB=$(mktemp -d "${TMPDIR:-/tmp}/apexyard-review-nolib.XXXXXX")
trap 'rm -rf "$TMP" "$NOLIB"' EXIT
mkdir -p "$NOLIB/.claude/session" "$NOLIB/.claude/hooks"
touch "$NOLIB/.apexyard-fork"
git -C "$NOLIB" init -q
cp "$HOOKS/block-reviewer-repo-mutation.sh" "$HOOKS/_lib-strip-heredoc.sh" "$NOLIB/.claude/hooks/"
run_nolib() { # name json expected
  local out rc
  out=$(cd "$NOLIB" && printf '%s' "$2" | "$NOLIB/.claude/hooks/block-reviewer-repo-mutation.sh" 2>&1)
  rc=$?
  if [ "$3" = blocked ] && [ "$rc" -eq 2 ]; then check "$1" ok
  elif [ "$3" = allowed ] && [ "$rc" -eq 0 ]; then check "$1" ok
  else check "$1" no "rc=$rc out=$out"; fi
}
run_nolib "lib missing, reviewer type, no marker: commit blocked" "$(payload code-reviewer a1 'git commit -m x')" blocked
run_nolib "lib missing, solution-architect type: push blocked" "$(payload solution-architect a1 'git push origin x')" blocked
run_nolib "lib missing, build agent, no marker: commit allowed" "$(payload backend-engineer a1 'git commit -m x')" allowed
run_nolib "lib missing, orchestrator, no marker: commit allowed" "$(payload '' '' 'git commit -m x')" allowed
printf '%s\n' 'acme/app#9:rex' > "$NOLIB/.claude/session/active-reviewer"
run_nolib "lib missing, any caller with a marker: commit blocked (old behaviour)" "$(payload backend-engineer a1 'git commit -m x')" blocked
rm -f "$NOLIB/.claude/session/active-reviewer"

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
