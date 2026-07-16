#!/bin/bash
# Smoke tests for .claude/hooks/detect-skill-intent.sh — the SKILL-side
# sibling of detect-role-trigger.sh (me2resh/apexyard#894).
#
# Verifies the acceptance criteria:
#   - An advisory hook recognizes a configurable set of intent phrases and
#     names the owning skill + template, non-blocking (always exit 0)
#   - The phrase→skill map is data-driven (read from
#     .claude/project-config.defaults.json → skill_intent.map, not
#     hard-coded in the hook)
#   - Phrase-detection covers at least the audit/diagram/spec skill
#     families
#
# Test style matches the existing tests/*.sh — bash + jq + grep, no
# external test framework. Each case pipes a synthetic hook payload into
# the script and asserts:
#   - exit code is 0 (non-blocking — advisory only)
#   - stderr matches the expected SKILL TRIGGER banner (or is silent when
#     no trigger applies)
#
# APEXYARD_OPS_DISABLE_PIN=1 is exported for every case: this repo may be
# running inside an isolated git worktree with a stale SessionStart ops-root
# pin pointing at a DIFFERENT checkout (see .claude/hooks/_lib-ops-root.sh).
# Without the escape hatch, config_get would silently read the wrong
# checkout's project-config.defaults.json and every case would look
# "silent" regardless of the phrase. Disabling the pin forces walk-up
# resolution from $PWD, which finds THIS checkout's config — the
# deterministic, environment-independent behaviour a test suite needs.

set -u

SRC_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
HOOK="$SRC_ROOT/.claude/hooks/detect-skill-intent.sh"

export APEXYARD_OPS_DISABLE_PIN=1

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

  got_stderr=$(cd "$SRC_ROOT" && printf '%s' "$input" | bash "$HOOK" 2>&1 >/dev/null)
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

# --- Audit family ------------------------------------------------------------

# 1a. "do a threat model" → /threat-model.
in=$(jq -nc --arg prm "Can you do a threat model on the payments service?" \
  '{hook_event_name:"UserPromptSubmit", prompt:$prm}')
run_case "audit family: 'threat model' fires /threat-model" 0 \
  "SKILL TRIGGER: intent matches the /threat-model skill.*templates/audits/threat-model\\.md" "$in"

# 1b. "accessibility audit" → /accessibility-audit.
in=$(jq -nc --arg prm "Run an accessibility audit on the checkout flow" \
  '{hook_event_name:"UserPromptSubmit", prompt:$prm}')
run_case "audit family: 'accessibility audit' fires /accessibility-audit" 0 \
  "SKILL TRIGGER: intent matches the /accessibility-audit skill" "$in"

# 1c. "gdpr audit" → /compliance-check.
in=$(jq -nc --arg prm "We need a gdpr audit before launch" \
  '{hook_event_name:"UserPromptSubmit", prompt:$prm}')
run_case "audit family: 'gdpr audit' fires /compliance-check" 0 \
  "SKILL TRIGGER: intent matches the /compliance-check skill" "$in"

# 1d. "seo audit" → /seo-audit.
in=$(jq -nc --arg prm "Can we get a seo audit done this week?" \
  '{hook_event_name:"UserPromptSubmit", prompt:$prm}')
run_case "audit family: 'seo audit' fires /seo-audit" 0 \
  "SKILL TRIGGER: intent matches the /seo-audit skill" "$in"

# --- Diagram family -----------------------------------------------------------

# 2a. "make a DFD" → /dfd.
in=$(jq -nc --arg prm "Please make a dfd for the checkout service" \
  '{hook_event_name:"UserPromptSubmit", prompt:$prm}')
run_case "diagram family: 'make a dfd' fires /dfd" 0 \
  "SKILL TRIGGER: intent matches the /dfd skill.*templates/architecture/dfd\\.md" "$in"

# 2b. "data flow diagram" → /dfd.
in=$(jq -nc --arg prm "I want a data flow diagram of the payments flow" \
  '{hook_event_name:"UserPromptSubmit", prompt:$prm}')
run_case "diagram family: 'data flow diagram' fires /dfd" 0 \
  "SKILL TRIGGER: intent matches the /dfd skill" "$in"

# --- Spec family --------------------------------------------------------------

# 3a. "write a PRD" → /write-spec.
in=$(jq -nc --arg prm "Let's write a PRD for the new onboarding flow" \
  '{hook_event_name:"UserPromptSubmit", prompt:$prm}')
run_case "spec family: 'write a prd' fires /write-spec" 0 \
  "SKILL TRIGGER: intent matches the /write-spec skill.*templates/prd\\.md" "$in"

# 3b. "draft a spec" → /write-spec.
in=$(jq -nc --arg prm "Can someone draft a spec for the export feature?" \
  '{hook_event_name:"UserPromptSubmit", prompt:$prm}')
run_case "spec family: 'draft a spec' fires /write-spec" 0 \
  "SKILL TRIGGER: intent matches the /write-spec skill" "$in"

# --- Ticket / decision family --------------------------------------------------

# 4a. "file a bug" → /bug.
in=$(jq -nc --arg prm "I need to file a bug for the login timeout" \
  '{hook_event_name:"UserPromptSubmit", prompt:$prm}')
run_case "ticket family: 'file a bug' fires /bug" 0 \
  "SKILL TRIGGER: intent matches the /bug skill" "$in"

# 4b. "plan this initiative" → /plan-initiative.
in=$(jq -nc --arg prm "Let's plan this initiative for Q3" \
  '{hook_event_name:"UserPromptSubmit", prompt:$prm}')
run_case "planning family: 'plan this initiative' fires /plan-initiative" 0 \
  "SKILL TRIGGER: intent matches the /plan-initiative skill" "$in"

# 4c. "decide between X and Y" → /decide.
in=$(jq -nc --arg prm "We need to decide between Postgres and DynamoDB" \
  '{hook_event_name:"UserPromptSubmit", prompt:$prm}')
run_case "decision family: 'decide between' fires /decide" 0 \
  "SKILL TRIGGER: intent matches the /decide skill" "$in"

# --- Non-matching / silent cases ----------------------------------------------

# 5a. Plain unrelated prompt — silent.
in=$(jq -nc --arg prm "What is the weather today?" \
  '{hook_event_name:"UserPromptSubmit", prompt:$prm}')
run_case "non-matching: unrelated prompt is silent" 0 "" "$in"

# 5b. Passing mention of a family word without the multi-word phrase — silent.
# ("audit" alone is not high-signal; only the specific multi-word phrases fire.)
in=$(jq -nc --arg prm "The audit team will look at this next sprint" \
  '{hook_event_name:"UserPromptSubmit", prompt:$prm}')
run_case "non-matching: bare 'audit' mention is silent (noise guard)" 0 "" "$in"

# 5c. Implementation request with no owning-skill phrase — silent.
in=$(jq -nc --arg prm "Implement the nav filter feature" \
  '{hook_event_name:"UserPromptSubmit", prompt:$prm}')
run_case "non-matching: ordinary build prompt is silent" 0 "" "$in"

# --- Non-UserPromptSubmit events are no-ops -----------------------------------

# 6a. A PreToolUse Edit event (this hook only wires to UserPromptSubmit) — silent.
in=$(jq -nc --arg p "src/auth/login.ts" \
  '{hook_event_name:"PreToolUse", tool_name:"Edit", tool_input:{file_path:$p}}')
run_case "event dispatch: PreToolUse is a no-op for this hook" 0 "" "$in"

# --- Non-blocking guarantee ----------------------------------------------------
# Even when the hook fires, exit code is 0 — the underlying prompt submission
# proceeds unmodified.
in=$(jq -nc --arg prm "do a threat model on the API gateway" \
  '{hook_event_name:"UserPromptSubmit", prompt:$prm}')
got_rc=$(cd "$SRC_ROOT" && printf '%s' "$in" | bash "$HOOK" >/dev/null 2>&1; echo $?)
if [ "$got_rc" = "0" ]; then
  echo "PASS [non-blocking: hook exits 0 even on trigger]"
  PASS=$((PASS+1))
else
  echo "FAIL [non-blocking: expected rc=0, got $got_rc]" >&2
  FAIL=$((FAIL+1)); FAILED="${FAILED}non-blocking "
fi

# --- Data-driven guarantee: map comes from project-config, not hard-coded ----
# Point the hook at a project-config override that ADDS a bogus skill/phrase
# pair that could not possibly be hard-coded in the script, and confirm it
# fires. This is the acceptance-criterion-2 check ("phrase→skill map is
# data-driven / extendable without editing hook logic").
TMP_OVERRIDE_DIR=$(mktemp -d 2>/dev/null || mktemp -d -t skillintent)
cleanup_override() { rm -rf "$TMP_OVERRIDE_DIR"; }
trap cleanup_override EXIT

mkdir -p "$TMP_OVERRIDE_DIR/.claude"
cat > "$TMP_OVERRIDE_DIR/.apexyard-fork" <<'EOF'
test fixture ops-root anchor for test_detect_skill_intent.sh
EOF
cp "$SRC_ROOT/.claude/project-config.defaults.json" "$TMP_OVERRIDE_DIR/.claude/project-config.defaults.json"
cat > "$TMP_OVERRIDE_DIR/.claude/project-config.json" <<'EOF'
{
  "skill_intent": {
    "map": [
      { "skill": "totally-custom-test-skill", "template": "", "phrases": ["zzz custom fixture phrase zzz"] }
    ]
  }
}
EOF
mkdir -p "$TMP_OVERRIDE_DIR/.claude/hooks"
cp "$SRC_ROOT/.claude/hooks/detect-skill-intent.sh" "$TMP_OVERRIDE_DIR/.claude/hooks/detect-skill-intent.sh"
cp "$SRC_ROOT/.claude/hooks/_lib-read-config.sh" "$TMP_OVERRIDE_DIR/.claude/hooks/_lib-read-config.sh"
cp "$SRC_ROOT/.claude/hooks/_lib-ops-root.sh" "$TMP_OVERRIDE_DIR/.claude/hooks/_lib-ops-root.sh"
chmod +x "$TMP_OVERRIDE_DIR/.claude/hooks/detect-skill-intent.sh"

in=$(jq -nc --arg prm "please run the zzz custom fixture phrase zzz workflow" \
  '{hook_event_name:"UserPromptSubmit", prompt:$prm}')
got_stderr=$(cd "$TMP_OVERRIDE_DIR" && printf '%s' "$in" | APEXYARD_OPS_DISABLE_PIN=1 bash .claude/hooks/detect-skill-intent.sh 2>&1 >/dev/null)
if echo "$got_stderr" | grep -qE "SKILL TRIGGER: intent matches the /totally-custom-test-skill skill"; then
  echo "PASS [data-driven: project-config.json override extends the map without editing hook logic]"
  PASS=$((PASS+1))
else
  echo "FAIL [data-driven: override map entry did not fire]: $got_stderr" >&2
  FAIL=$((FAIL+1)); FAILED="${FAILED}data-driven "
fi
cleanup_override
trap - EXIT

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
