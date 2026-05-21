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
# Each banner now includes either "Isolated-work-class — SPAWN the sub-agent"
# or "In-flow-class — adopt the persona IN-THREAD" depending on the matched
# role's **Class** value in its role file. Verifies the class lookup actually
# fires + the security-auditor → security-reviewer slug exception.

# 4a. Security Auditor (isolated-work-class) — banner instructs SPAWN with
#     subagent_type: security-reviewer (NOT security-auditor; the
#     Hatim→Hakim consolidation in PR #360 kept the filename).
in=$(jq -nc \
  --arg p "src/auth/login.ts" \
  '{hook_event_name:"PreToolUse", tool_name:"Edit", tool_input:{file_path:$p}}')
run_case "hybrid class-aware: Security Auditor → isolated-work-class banner" 0 \
  "Isolated-work-class.*subagent_type: security-reviewer" "$in"

# 4b. Platform Engineer (in-flow-class) — banner instructs in-thread
#     adoption. The CI/CD diff path triggers this role.
in=$(jq -nc \
  --arg p ".github/workflows/ci.yml" \
  '{hook_event_name:"PreToolUse", tool_name:"Edit", tool_input:{file_path:$p}}')
run_case "hybrid class-aware: Platform Engineer → in-flow-class banner" 0 \
  "Platform Engineer.*In-flow-class.*adopt the persona IN-THREAD" "$in"

# 4c. Tech Lead (isolated-work-class) — banner instructs SPAWN with
#     subagent_type: tech-lead. Triggered by edits under docs/agdr/.
in=$(jq -nc \
  --arg p "docs/agdr/AgDR-0099-example.md" \
  '{hook_event_name:"PreToolUse", tool_name:"Edit", tool_input:{file_path:$p}}')
run_case "hybrid class-aware: Tech Lead → isolated-work-class banner" 0 \
  "Tech Lead.*Isolated-work-class.*subagent_type: tech-lead" "$in"

# 4d. QA Engineer (isolated-work-class) — banner instructs SPAWN with
#     subagent_type: qa-engineer. Triggered by `gh issue edit --add-label qa`.
in=$(jq -nc \
  --arg c "gh issue edit 42 --add-label qa" \
  '{hook_event_name:"PreToolUse", tool_name:"Bash", tool_input:{command:$c}}')
run_case "hybrid class-aware: QA Engineer → isolated-work-class banner" 0 \
  "QA Engineer.*Isolated-work-class.*subagent_type: qa-engineer" "$in"

# 4e. Prompted Backend Engineer (in-flow-class) — banner instructs
#     in-thread adoption.
in=$(jq -nc \
  --arg prm "act as the backend engineer and refactor this handler" \
  '{hook_event_name:"UserPromptSubmit", prompt:$prm}')
run_case "hybrid class-aware: Backend Engineer prompted → in-flow-class banner" 0 \
  "Backend Engineer.*In-flow-class.*adopt the persona IN-THREAD" "$in"

# 4f. Prompted UX Designer (in-flow-class) — banner instructs in-thread
#     adoption.
in=$(jq -nc \
  --arg prm "put on your UX Designer hat for this flow review" \
  '{hook_event_name:"UserPromptSubmit", prompt:$prm}')
run_case "hybrid class-aware: UX Designer prompted → in-flow-class banner" 0 \
  "Ux Designer.*In-flow-class.*adopt the persona IN-THREAD" "$in"

# 4g. Prompted Pen Tester (isolated-work-class) — banner instructs SPAWN
#     with subagent_type: penetration-tester.
in=$(jq -nc \
  --arg prm "as the pen tester, dry-run an exploit on the new endpoint" \
  '{hook_event_name:"UserPromptSubmit", prompt:$prm}')
run_case "hybrid class-aware: Pen Tester prompted → isolated-work-class banner" 0 \
  "Pen Tester.*Isolated-work-class.*subagent_type: penetration-tester" "$in"

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
