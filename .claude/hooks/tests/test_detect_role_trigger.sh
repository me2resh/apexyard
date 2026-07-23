#!/bin/bash
# Smoke tests for .claude/hooks/detect-role-trigger.sh — verifies the
# three trigger families called out in me2resh/apexyard#206:
#
#   1. Label-based  (Bash → gh issue edit ... --add-label qa)
#   2. Diff/path    (Edit/Write/MultiEdit on **/auth/**, .env*, etc.)
#   3. Prompted     (UserPromptSubmit "act as the X")
#
# Each case pipes a synthetic hook payload into the script and asserts:
#   - exit code is 0 (non-blocking — advisory only)
#   - stderr matches the expected ROLE TRIGGER banner (or is silent when
#     no trigger applies)
#
# Test style matches the existing tests/*.sh — bash + jq + grep, no
# external test framework.

set -u

# The session-scoped de-dupe (#995) keys on CLAUDE_CODE_SESSION_ID. Unset it
# for the per-case tests below so each invocation is in the fail-open
# always-fire mode — deterministic and independent of whatever ambient
# session happens to be running this test. Section (7) sets its own id to
# exercise the de-dupe explicitly.
unset CLAUDE_CODE_SESSION_ID

SRC_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
HOOK="$SRC_ROOT/.claude/hooks/detect-role-trigger.sh"

if [ ! -x "$HOOK" ]; then
  echo "FAIL: hook is not executable: $HOOK" >&2
  exit 1
fi

PASS=0
FAIL=0
FAILED=""

# run_case <label> <expected_rc> <expected_stderr_regex|""> <json_input>
#
# Empty regex string means "expect silent" — stderr must be empty.
run_case() {
  local label="$1" want_rc="$2" want_regex="$3" input="$4"
  local got_stderr got_rc

  got_stderr=$(printf '%s' "$input" | bash "$HOOK" 2>&1 >/dev/null)
  got_rc=$?

  if [ "$got_rc" != "$want_rc" ]; then
    echo "FAIL [$label]: want rc=$want_rc, got $got_rc (stderr: ${got_stderr:0:200})" >&2
    FAIL=$((FAIL+1)); FAILED="${FAILED}${label} "; return
  fi

  if [ -z "$want_regex" ]; then
    if [ -n "$got_stderr" ]; then
      echo "FAIL [$label]: expected silent, got: $got_stderr" >&2
      FAIL=$((FAIL+1)); FAILED="${FAILED}${label} "; return
    fi
    echo "PASS [$label] — silent"
    PASS=$((PASS+1)); return
  fi

  if echo "$got_stderr" | grep -qE "$want_regex"; then
    echo "PASS [$label]"
    PASS=$((PASS+1)); return
  fi

  echo "FAIL [$label]: stderr did not match /$want_regex/" >&2
  echo "    stderr: $got_stderr" >&2
  FAIL=$((FAIL+1)); FAILED="${FAILED}${label} "
}

# --- (1) Label-based trigger — QA Engineer -----------------------------------

# 1a. `gh issue edit --add-label qa` → QA Engineer banner.
in=$(jq -nc \
  --arg c "gh issue edit 42 --add-label qa" \
  '{hook_event_name:"PreToolUse", tool_name:"Bash", tool_input:{command:$c}}')
run_case "label trigger: qa label fires QA Engineer" 0 \
  "ROLE TRIGGER: QA Engineer.*roles/engineering/qa-engineer\\.md" "$in"

# 1b. `gh issue edit --add-label foo,qa,bar` → QA Engineer banner (comma list).
in=$(jq -nc \
  --arg c "gh issue edit 42 --add-label foo,qa,bar" \
  '{hook_event_name:"PreToolUse", tool_name:"Bash", tool_input:{command:$c}}')
run_case "label trigger: qa in comma list fires QA Engineer" 0 \
  "ROLE TRIGGER: QA Engineer" "$in"

# 1c. `gh issue edit --add-label bug` → silent (no role for bug label in v1).
in=$(jq -nc \
  --arg c "gh issue edit 42 --add-label bug" \
  '{hook_event_name:"PreToolUse", tool_name:"Bash", tool_input:{command:$c}}')
run_case "label trigger: non-mapped label is silent" 0 "" "$in"

# 1d. `gh issue create --label qa` → silent (CREATE, not EDIT — trigger
# semantics are transition only, see hook comment).
in=$(jq -nc \
  --arg c "gh issue create --label qa --title 'x' --body 'y'" \
  '{hook_event_name:"PreToolUse", tool_name:"Bash", tool_input:{command:$c}}')
run_case "label trigger: issue CREATE with qa label is silent (not a transition)" 0 "" "$in"

# 1e. Non-gh command with the word 'qa' in it → silent.
in=$(jq -nc \
  --arg c "echo qa pass" \
  '{hook_event_name:"PreToolUse", tool_name:"Bash", tool_input:{command:$c}}')
run_case "label trigger: unrelated qa string is silent" 0 "" "$in"

# --- (2) Diff/path-based trigger — Security Auditor --------------------------

# 2a. Edit on src/auth/login.ts → Security Auditor banner.
in=$(jq -nc \
  --arg p "src/auth/login.ts" \
  '{hook_event_name:"PreToolUse", tool_name:"Edit", tool_input:{file_path:$p}}')
run_case "path trigger: src/auth/* fires Security Auditor" 0 \
  "ROLE TRIGGER: Security Auditor.*roles/security/security-auditor\\.md" "$in"

# 2b. Write on packages/api/src/auth/jwt.ts → Security Auditor.
in=$(jq -nc \
  --arg p "packages/api/src/auth/jwt.ts" \
  '{hook_event_name:"PreToolUse", tool_name:"Write", tool_input:{file_path:$p}}')
run_case "path trigger: deep auth/ path fires Security Auditor" 0 \
  "ROLE TRIGGER: Security Auditor" "$in"

# 2c. Edit on .env.production → Security Auditor.
in=$(jq -nc \
  --arg p ".env.production" \
  '{hook_event_name:"PreToolUse", tool_name:"Edit", tool_input:{file_path:$p}}')
run_case "path trigger: .env.* fires Security Auditor" 0 \
  "ROLE TRIGGER: Security Auditor" "$in"

# 2d. Edit on src/crypto/hash.ts → Security Auditor.
in=$(jq -nc \
  --arg p "src/crypto/hash.ts" \
  '{hook_event_name:"PreToolUse", tool_name:"Edit", tool_input:{file_path:$p}}')
run_case "path trigger: crypto/ fires Security Auditor" 0 \
  "ROLE TRIGGER: Security Auditor" "$in"

# 2e. Edit on src/utils/format.ts → silent (no security-sensitive segment).
in=$(jq -nc \
  --arg p "src/utils/format.ts" \
  '{hook_event_name:"PreToolUse", tool_name:"Edit", tool_input:{file_path:$p}}')
run_case "path trigger: ordinary path is silent" 0 "" "$in"

# 2e-i. Trust chain (#777): a merge-gate hook fires Security Auditor.
in=$(jq -nc \
  --arg p ".claude/hooks/block-unreviewed-merge.sh" \
  '{hook_event_name:"PreToolUse", tool_name:"Edit", tool_input:{file_path:$p}}')
run_case "trust chain: .claude/hooks/* fires Security Auditor [#777]" 0 \
  "ROLE TRIGGER: Security Auditor.*roles/security/security-auditor\\.md" "$in"

# 2e-ii. Trust chain (#777): settings.json (the matcher wiring) fires Security Auditor.
in=$(jq -nc \
  --arg p ".claude/settings.json" \
  '{hook_event_name:"PreToolUse", tool_name:"Write", tool_input:{file_path:$p}}')
run_case "trust chain: .claude/settings.json fires Security Auditor [#777]" 0 \
  "ROLE TRIGGER: Security Auditor" "$in"

# 2e-iii. Trust chain (#777): a nested hooks path (e.g. a managed-project fork) fires too.
in=$(jq -nc \
  --arg p "workspace/proj/.claude/hooks/_lib-tracker.sh" \
  '{hook_event_name:"PreToolUse", tool_name:"Edit", tool_input:{file_path:$p}}')
run_case "trust chain: */.claude/hooks/* fires Security Auditor [#777]" 0 \
  "ROLE TRIGGER: Security Auditor" "$in"

# 2e-iv. A .claude path that is NOT trust-chain (a skill doc) stays silent.
in=$(jq -nc \
  --arg p ".claude/skills/roadmap/SKILL.md" \
  '{hook_event_name:"PreToolUse", tool_name:"Edit", tool_input:{file_path:$p}}')
run_case "trust chain: non-hook .claude path is silent [#777]" 0 "" "$in"

# 2f. Edit on .github/workflows/ci.yml → Platform Engineer banner.
in=$(jq -nc \
  --arg p ".github/workflows/ci.yml" \
  '{hook_event_name:"PreToolUse", tool_name:"Edit", tool_input:{file_path:$p}}')
run_case "path trigger: .github/workflows/* fires Platform Engineer" 0 \
  "ROLE TRIGGER: Platform Engineer.*roles/engineering/platform-engineer\\.md" "$in"

# 2g. Edit on docs/agdr/AgDR-0007-something.md → Tech Lead.
in=$(jq -nc \
  --arg p "docs/agdr/AgDR-0099-test.md" \
  '{hook_event_name:"PreToolUse", tool_name:"Edit", tool_input:{file_path:$p}}')
run_case "path trigger: docs/agdr/* fires Tech Lead" 0 \
  "ROLE TRIGGER: Tech Lead.*roles/engineering/tech-lead\\.md" "$in"

# --- (3) Prompted-activation trigger -----------------------------------------

# 3a. "Act as the QA Engineer …" → QA Engineer banner.
in=$(jq -nc \
  --arg prm "Act as the QA Engineer and verify ticket 42" \
  '{hook_event_name:"UserPromptSubmit", prompt:$prm}')
run_case "prompt trigger: 'act as the QA Engineer' fires QA Engineer" 0 \
  "ROLE TRIGGER: Qa Engineer.*roles/engineering/qa-engineer\\.md" "$in"

# 3b. "As the Security Auditor …" → Security Auditor banner.
in=$(jq -nc \
  --arg prm "As the Security Auditor, please check this PR for OWASP issues" \
  '{hook_event_name:"UserPromptSubmit", prompt:$prm}')
run_case "prompt trigger: 'as the Security Auditor' fires Security Auditor" 0 \
  "ROLE TRIGGER: Security Auditor" "$in"

# 3c. "Put on your Tech Lead hat …" → Tech Lead banner.
in=$(jq -nc \
  --arg prm "Put on your Tech Lead hat and review this PR" \
  '{hook_event_name:"UserPromptSubmit", prompt:$prm}')
run_case "prompt trigger: 'put on your Tech Lead hat' fires Tech Lead" 0 \
  "ROLE TRIGGER: Tech Lead" "$in"

# 3d. Mixed case + extra whitespace → still fires.
in=$(jq -nc \
  --arg prm "  ACT  AS  THE  qa  engineer  please" \
  '{hook_event_name:"UserPromptSubmit", prompt:$prm}')
run_case "prompt trigger: case + whitespace tolerant" 0 \
  "ROLE TRIGGER: Qa Engineer" "$in"

# 3e. Plain question — silent.
in=$(jq -nc \
  --arg prm "What is the weather today?" \
  '{hook_event_name:"UserPromptSubmit", prompt:$prm}')
run_case "prompt trigger: unrelated prompt is silent" 0 "" "$in"

# 3f. Mention of QA without activation phrase — silent.
in=$(jq -nc \
  --arg prm "The QA team asked about ticket 42" \
  '{hook_event_name:"UserPromptSubmit", prompt:$prm}')
run_case "prompt trigger: passing mention is silent" 0 "" "$in"

# --- Non-blocking guarantee --------------------------------------------------
# Even when the hook fires, exit code is 0 — the underlying tool call
# proceeds.
in=$(jq -nc \
  --arg p "src/auth/login.ts" \
  '{hook_event_name:"PreToolUse", tool_name:"Edit", tool_input:{file_path:$p}}')
got_rc=$(printf '%s' "$in" | bash "$HOOK" >/dev/null 2>&1; echo $?)
if [ "$got_rc" = "0" ]; then
  echo "PASS [non-blocking: hook exits 0 even on trigger]"
  PASS=$((PASS+1))
else
  echo "FAIL [non-blocking: expected rc=0, got $got_rc]" >&2
  FAIL=$((FAIL+1)); FAILED="${FAILED}non-blocking "
fi

# --- (4) HYBRID class-aware banner — AgDR-0050 § Axis 6 (Wave 2 PR 5) --------
# Each banner is now ADVISORY with a convergence guard (#995): isolated-work
# roles carry "you MAY spawn it ... subagent_type: <slug>", in-flow roles carry
# "read <file> to adopt its lens in-thread", and BOTH carry "do NOT switch
# persona ... finish the current unit first". Verifies the class lookup fires +
# the security-auditor → security-reviewer slug exception.

# 4a. Security Auditor (isolated-work-class) — banner offers SPAWN with
#     subagent_type: security-reviewer (NOT security-auditor; the
#     Hatim→Hakim consolidation in PR #360 kept the filename).
in=$(jq -nc \
  --arg p "src/auth/login.ts" \
  '{hook_event_name:"PreToolUse", tool_name:"Edit", tool_input:{file_path:$p}}')
run_case "hybrid class-aware: Security Auditor → spawn-offer banner" 0 \
  "MAY spawn.*subagent_type: security-reviewer" "$in"

# 4b. Platform Engineer (in-flow-class) — banner offers in-thread lens
#     adoption. The CI/CD diff path triggers this role.
in=$(jq -nc \
  --arg p ".github/workflows/ci.yml" \
  '{hook_event_name:"PreToolUse", tool_name:"Edit", tool_input:{file_path:$p}}')
run_case "hybrid class-aware: Platform Engineer → in-thread-lens banner" 0 \
  "Platform Engineer.*adopt its lens in-thread" "$in"

# 4c. Tech Lead (isolated-work-class) — banner offers SPAWN with
#     subagent_type: tech-lead. Triggered by edits under docs/agdr/.
in=$(jq -nc \
  --arg p "docs/agdr/AgDR-0099-example.md" \
  '{hook_event_name:"PreToolUse", tool_name:"Edit", tool_input:{file_path:$p}}')
run_case "hybrid class-aware: Tech Lead → spawn-offer banner" 0 \
  "Tech Lead.*subagent_type: tech-lead" "$in"

# 4d. QA Engineer (isolated-work-class) — banner offers SPAWN with
#     subagent_type: qa-engineer. Triggered by `gh issue edit --add-label qa`.
in=$(jq -nc \
  --arg c "gh issue edit 42 --add-label qa" \
  '{hook_event_name:"PreToolUse", tool_name:"Bash", tool_input:{command:$c}}')
run_case "hybrid class-aware: QA Engineer → spawn-offer banner" 0 \
  "QA Engineer.*subagent_type: qa-engineer" "$in"

# 4e. Prompted Backend Engineer (in-flow-class) — banner offers in-thread
#     lens adoption.
in=$(jq -nc \
  --arg prm "act as the backend engineer and refactor this handler" \
  '{hook_event_name:"UserPromptSubmit", prompt:$prm}')
run_case "hybrid class-aware: Backend Engineer prompted → in-thread-lens banner" 0 \
  "Backend Engineer.*adopt its lens in-thread" "$in"

# 4f. Prompted UX Designer (in-flow-class) — banner offers in-thread lens
#     adoption.
in=$(jq -nc \
  --arg prm "put on your UX Designer hat for this flow review" \
  '{hook_event_name:"UserPromptSubmit", prompt:$prm}')
run_case "hybrid class-aware: UX Designer prompted → in-thread-lens banner" 0 \
  "Ux Designer.*adopt its lens in-thread" "$in"

# 4g. Prompted Pen Tester (isolated-work-class) — banner offers SPAWN
#     with subagent_type: penetration-tester.
in=$(jq -nc \
  --arg prm "as the pen tester, dry-run an exploit on the new endpoint" \
  '{hook_event_name:"UserPromptSubmit", prompt:$prm}')
run_case "hybrid class-aware: Pen Tester prompted → spawn-offer banner" 0 \
  "Pen Tester.*subagent_type: penetration-tester" "$in"

# 4h. Convergence guard (#995): EVERY banner tells the agent not to switch
#     persona / open ceremony mid-task. Assert it on both an isolated-work
#     and an in-flow banner.
in=$(jq -nc \
  --arg p "src/auth/login.ts" \
  '{hook_event_name:"PreToolUse", tool_name:"Edit", tool_input:{file_path:$p}}')
run_case "convergence guard present (isolated-work banner) [#995]" 0 \
  "do NOT switch persona.*finish the current unit first" "$in"
in=$(jq -nc \
  --arg p ".github/workflows/ci.yml" \
  '{hook_event_name:"PreToolUse", tool_name:"Edit", tool_input:{file_path:$p}}')
run_case "convergence guard present (in-flow banner) [#995]" 0 \
  "do NOT switch persona.*finish the current unit first" "$in"

# --- (5) Solution Architect (Tariq) — design-artifact triggers --------------

# 5a. Edit on a technical-design doc → Solution Architect banner.
in=$(jq -nc \
  --arg p "projects/foo/docs/technical-design-checkout.md" \
  '{hook_event_name:"PreToolUse", tool_name:"Edit", tool_input:{file_path:$p}}')
run_case "path trigger: technical-design doc fires Solution Architect" 0 \
  "ROLE TRIGGER: Solution Architect.*roles/architecture/solution-architect\\.md" "$in"

# 5b. Edit under a designs/ dir → Solution Architect.
in=$(jq -nc \
  --arg p "projects/foo/designs/payments.md" \
  '{hook_event_name:"PreToolUse", tool_name:"Write", tool_input:{file_path:$p}}')
run_case "path trigger: designs/ dir fires Solution Architect" 0 \
  "ROLE TRIGGER: Solution Architect" "$in"

# 5c. Edit on a PRD → Solution Architect.
in=$(jq -nc \
  --arg p "projects/foo/prds/onboarding.md" \
  '{hook_event_name:"PreToolUse", tool_name:"Edit", tool_input:{file_path:$p}}')
run_case "path trigger: prds/ fires Solution Architect" 0 \
  "ROLE TRIGGER: Solution Architect" "$in"

# 5d. A migration AgDR fires BOTH Tech Lead (author) AND Solution Architect
#     (reviewer) — the two triggers are additive by design.
in=$(jq -nc \
  --arg p "workspace/foo/docs/agdr/AgDR-0032-cognito-fresh-pool-migration.md" \
  '{hook_event_name:"PreToolUse", tool_name:"Edit", tool_input:{file_path:$p}}')
run_case "path trigger: migration AgDR fires Tech Lead" 0 \
  "ROLE TRIGGER: Tech Lead" "$in"
run_case "path trigger: migration AgDR also fires Solution Architect" 0 \
  "ROLE TRIGGER: Solution Architect" "$in"

# 5e. Solution Architect is isolated-work-class — banner instructs SPAWN with
#     subagent_type: solution-architect.
in=$(jq -nc \
  --arg p "projects/foo/docs/technical-design-x.md" \
  '{hook_event_name:"PreToolUse", tool_name:"Edit", tool_input:{file_path:$p}}')
run_case "hybrid class-aware: Solution Architect → spawn-offer banner" 0 \
  "Solution Architect.*subagent_type: solution-architect" "$in"

# 5f. Prompted "as the Solution Architect" → Solution Architect banner.
in=$(jq -nc \
  --arg prm "as the solution architect, review the proposed design" \
  '{hook_event_name:"UserPromptSubmit", prompt:$prm}')
run_case "prompt trigger: 'as the solution architect' fires Solution Architect" 0 \
  "Solution Architect.*subagent_type: solution-architect" "$in"

# 5g. An ordinary source file does NOT fire the Solution Architect.
in=$(jq -nc \
  --arg p "src/handlers/checkout.ts" \
  '{hook_event_name:"PreToolUse", tool_name:"Edit", tool_input:{file_path:$p}}')
got=$(printf '%s' "$in" | bash "$HOOK" 2>&1 >/dev/null)
if echo "$got" | grep -q "Solution Architect"; then
  echo "FAIL [path trigger: source file must not fire Solution Architect]" >&2
  FAIL=$((FAIL+1)); FAILED="${FAILED}sa-source-noise "
else
  echo "PASS [path trigger: source file does not fire Solution Architect]"
  PASS=$((PASS+1))
fi

# --- The Contrarian (utility agent, prompted phrase family — AgDR-0078) -------

# 6a. "play devil's advocate" fires The Contrarian.
in=$(jq -nc \
  --arg prm "play devil's advocate on adding a second database" \
  '{hook_event_name:"UserPromptSubmit", prompt:$prm}')
run_case "prompt trigger: 'play devil's advocate' fires The Contrarian" 0 \
  "The Contrarian \(Naqid\).*subagent_type: contrarian" "$in"

# 6b. "poke holes in" fires The Contrarian.
in=$(jq -nc \
  --arg prm "poke holes in this plan before we commit" \
  '{hook_event_name:"UserPromptSubmit", prompt:$prm}')
run_case "prompt trigger: 'poke holes in' fires The Contrarian" 0 \
  "The Contrarian \(Naqid\)" "$in"

# 6c. "challenge this" fires The Contrarian.
in=$(jq -nc \
  --arg prm "challenge this idea" \
  '{hook_event_name:"UserPromptSubmit", prompt:$prm}')
run_case "prompt trigger: 'challenge this' fires The Contrarian" 0 \
  "The Contrarian \(Naqid\)" "$in"

# 6d. An ordinary build prompt does NOT fire The Contrarian.
in=$(jq -nc \
  --arg prm "implement the nav filter feature" \
  '{hook_event_name:"UserPromptSubmit", prompt:$prm}')
got=$(printf '%s' "$in" | bash "$HOOK" 2>&1 >/dev/null)
if echo "$got" | grep -q "The Contrarian"; then
  echo "FAIL [prompt trigger: build prompt must not fire The Contrarian]" >&2
  FAIL=$((FAIL+1)); FAILED="${FAILED}contrarian-noise "
else
  echo "PASS [prompt trigger: build prompt does not fire The Contrarian]"
  PASS=$((PASS+1))
fi

# --- (7) Session-scoped once-per-role de-dupe (#995) -------------------------
# The bug: path/label triggers re-fired on every edit, so a multi-layer unit
# of work re-triggered a role handover per file → the infinite-loop symptom.
# The fix fires each role's banner at most once per CLAUDE_CODE_SESSION_ID.
# These run in a throwaway git repo so REPO_ROOT (and the role-fired marker
# dir) resolve there, never polluting the real session dir.

DEDUP_REPO=$(mktemp -d)
( cd "$DEDUP_REPO" && git init -q )

SID_A="test-session-aaa-995"
SID_B="test-session-bbb-995"

# dedup_edit <sid> <path> — fire an Edit-trigger with a given session id under
# DEDUP_REPO; echoes stderr (the banner, if any). Empty sid → fail-open path.
dedup_edit() {
  local sid="$1" path="$2" input
  input=$(jq -nc --arg p "$path" \
    '{hook_event_name:"PreToolUse", tool_name:"Edit", tool_input:{file_path:$p}}')
  # Capture stderr (the banner), discard stdout. The brace-group form keeps the
  # redirection order unambiguous (shellcheck SC2069).
  { printf '%s' "$input" | ( cd "$DEDUP_REPO" && CLAUDE_CODE_SESSION_ID="$sid" bash "$HOOK" ) >/dev/null; } 2>&1
}

assert_dedup() {
  local label="$1" expect="$2" out="$3"
  if [ "$expect" = "fire" ]; then
    if [ -n "$out" ]; then echo "PASS [$label]"; PASS=$((PASS+1));
    else echo "FAIL [$label]: expected a banner, got silence" >&2; FAIL=$((FAIL+1)); FAILED="${FAILED}${label} "; fi
  else
    if [ -z "$out" ]; then echo "PASS [$label]"; PASS=$((PASS+1));
    else echo "FAIL [$label]: expected silence, got: ${out:0:120}" >&2; FAIL=$((FAIL+1)); FAILED="${FAILED}${label} "; fi
  fi
}

# 7a. First Security-Auditor edit in session A → fires.
assert_dedup "dedup 7a: first auth edit (session A) fires" fire \
  "$(dedup_edit "$SID_A" "src/auth/login.ts")"

# 7b. A DIFFERENT file that maps to the SAME role (Security Auditor) in the
#     same session → silent. This is the exact loop scenario: many files, one
#     role, one banner.
assert_dedup "dedup 7b: second same-role edit (session A) is silent" silent \
  "$(dedup_edit "$SID_A" "packages/api/src/auth/jwt.ts")"

# 7c. A DIFFERENT role in the same session still fires — de-dupe is per-role,
#     not a global once-per-session mute.
assert_dedup "dedup 7c: different role (session A) still fires" fire \
  "$(dedup_edit "$SID_A" ".github/workflows/ci.yml")"

# 7d. The original role in a NEW session fires again — de-dupe is session-scoped.
assert_dedup "dedup 7d: same role in a new session fires again" fire \
  "$(dedup_edit "$SID_B" "src/auth/login.ts")"

# 7e. Fail-open: with no session id, repeated same-role edits BOTH fire
#     (degrades to pre-#995 always-fire, since a banner is advisory).
assert_dedup "dedup 7e-i: no session id — first edit fires" fire \
  "$(dedup_edit "" "src/auth/login.ts")"
assert_dedup "dedup 7e-ii: no session id — second edit ALSO fires (fail-open)" fire \
  "$(dedup_edit "" "src/auth/login.ts")"

rm -rf "$DEDUP_REPO"

# --- Summary -----------------------------------------------------------------

echo ""
echo "==================================="
echo "  PASS: $PASS   FAIL: $FAIL"
echo "==================================="
if [ "$FAIL" -gt 0 ]; then
  echo "Failed: $FAILED" >&2
  exit 1
fi
exit 0
