#!/bin/bash
# Tests for require-skill-for-issue-create.sh (me2resh/apexyard#268, AgDR-0030).
#
# Mirrors the sandbox shape of test_require_active_ticket_bash.sh:
#   - per-case sandbox with onboarding.yaml + empty registry + hook + libs
#   - synthetic PreToolUse Bash JSON via jq
#   - assert exit code and (optionally) stderr regex

set -u

# Pin isolation: the hook resolves its ops-root (and thus the sandbox markers /
# config) via the session pin. Run interactively inside a live apexyard session,
# the pin resolves PAST each mktemp sandbox to the operator's real fork, so the
# marker-present cases look in the wrong place. The authoritative runner
# (bin/run-hook-tests.sh) disables the pin; unset here too so a direct
# `bash test_require_skill_for_issue_create.sh` is robust under nesting.
unset APEXYARD_OPS_PIN_DIR CLAUDE_CODE_SESSION_ID 2>/dev/null || true

SRC_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
HOOK_SRC="$SRC_ROOT/.claude/hooks/require-skill-for-issue-create.sh"
LIB_OPS="$SRC_ROOT/.claude/hooks/_lib-ops-root.sh"
LIB_CFG="$SRC_ROOT/.claude/hooks/_lib-read-config.sh"
DEFAULTS="$SRC_ROOT/.claude/project-config.defaults.json"

for f in "$HOOK_SRC" "$LIB_CFG" "$DEFAULTS"; do
  if [ ! -f "$f" ]; then
    echo "FAIL: required source missing: $f" >&2
    exit 1
  fi
done
# _lib-ops-root.sh is optional — the hook has an inline fallback walk.
HAVE_LIB_OPS=0
[ -f "$LIB_OPS" ] && HAVE_LIB_OPS=1

PASS=0
FAIL=0
FAILED_CASES=""

make_sandbox() {
  local sb
  sb=$(mktemp -d)
  (
    cd "$sb" || exit 1
    git init -q
    git config user.email "test@example.com"
    git config user.name "test"
    : > onboarding.yaml
    : > apexyard.projects.yaml
    git add onboarding.yaml apexyard.projects.yaml
    git commit -q -m "init"
  )
  mkdir -p "$sb/.claude/hooks" "$sb/.claude/session"
  cp "$HOOK_SRC" "$sb/.claude/hooks/require-skill-for-issue-create.sh"
  [ "$HAVE_LIB_OPS" = "1" ] && cp "$LIB_OPS" "$sb/.claude/hooks/_lib-ops-root.sh"
  cp "$LIB_CFG" "$sb/.claude/hooks/_lib-read-config.sh"
  cp "$DEFAULTS" "$sb/.claude/project-config.defaults.json"
  chmod +x "$sb/.claude/hooks/require-skill-for-issue-create.sh"
  echo "$sb"
}

run_case() {
  local label="$1" want_rc="$2" want_stderr_regex="$3" input="$4" sb="$5" env_var="${6:-}"
  local got_stderr got_rc
  if [ -n "$env_var" ]; then
    got_stderr=$(cd "$sb" && echo "$input" | env "$env_var" bash .claude/hooks/require-skill-for-issue-create.sh 2>&1 >/dev/null)
  else
    got_stderr=$(cd "$sb" && echo "$input" | bash .claude/hooks/require-skill-for-issue-create.sh 2>&1 >/dev/null)
  fi
  got_rc=$?
  rm -rf "$sb"

  if [ "$got_rc" != "$want_rc" ]; then
    echo "FAIL [$label]: want rc=$want_rc, got $got_rc (stderr: ${got_stderr:0:200})" >&2
    FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}${label} "; return
  fi
  if [ -n "$want_stderr_regex" ] && ! echo "$got_stderr" | grep -qE "$want_stderr_regex"; then
    echo "FAIL [$label]: stderr did not match /$want_stderr_regex/" >&2
    echo "    stderr: $got_stderr" >&2
    FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}${label} "; return
  fi
  echo "PASS [$label]"
  PASS=$((PASS+1))
}

# --- Marker absent → BLOCK on each default matcher --------------------------

sb=$(make_sandbox)
in=$(jq -nc --arg c "gh issue create --repo foo/bar --title x --body y" \
  '{tool_name:"Bash", tool_input:{command:$c}}')
run_case "gh issue create blocked w/o marker" 2 "BLOCKED" "$in" "$sb"

sb=$(make_sandbox)
in=$(jq -nc --arg c "gh api repos/foo/bar/issues -f title=x -f body=y" \
  '{tool_name:"Bash", tool_input:{command:$c}}')
run_case "gh api repos/.../issues blocked w/o marker" 2 "BLOCKED" "$in" "$sb"

sb=$(make_sandbox)
in=$(jq -nc --arg c "linear issue create --title x" \
  '{tool_name:"Bash", tool_input:{command:$c}}')
run_case "linear issue create blocked w/o marker" 2 "BLOCKED" "$in" "$sb"

sb=$(make_sandbox)
in=$(jq -nc --arg c "jira issue create --summary x" \
  '{tool_name:"Bash", tool_input:{command:$c}}')
run_case "jira issue create blocked w/o marker" 2 "BLOCKED" "$in" "$sb"

sb=$(make_sandbox)
in=$(jq -nc --arg c "asana task create --name x" \
  '{tool_name:"Bash", tool_input:{command:$c}}')
run_case "asana task create blocked w/o marker" 2 "BLOCKED" "$in" "$sb"

# tracker_create (the #670 creation abstraction) is itself an issue-creation
# entry point — it MUST be gated, or `tracker_create <repo> <title> <body>` run
# outside a skill is a bypass of the structured-create rule.
sb=$(make_sandbox)
in=$(jq -nc --arg c 'tracker_create foo/bar "my title" /tmp/body.md' \
  '{tool_name:"Bash", tool_input:{command:$c}}')
run_case "tracker_create blocked w/o marker (#670)" 2 "BLOCKED" "$in" "$sb"

# glab (GitLab) create — the create-guard previously didn't recognise it (#670).
sb=$(make_sandbox)
in=$(jq -nc --arg c "glab issue create -R foo/bar --title x" \
  '{tool_name:"Bash", tool_input:{command:$c}}')
run_case "glab issue create blocked w/o marker (#670)" 2 "BLOCKED" "$in" "$sb"

# --- Marker present → ALLOW on each default matcher ------------------------

sb=$(make_sandbox); echo "feature" > "$sb/.claude/session/active-issue-skill"
in=$(jq -nc --arg c "gh issue create --repo foo/bar --title x" '{tool_name:"Bash", tool_input:{command:$c}}')
run_case "gh issue create allowed with skill marker" 0 "" "$in" "$sb"

sb=$(make_sandbox); echo "task" > "$sb/.claude/session/active-issue-skill"
in=$(jq -nc --arg c "gh api repos/foo/bar/issues -f title=x" '{tool_name:"Bash", tool_input:{command:$c}}')
run_case "gh api allowed with skill marker" 0 "" "$in" "$sb"

sb=$(make_sandbox); echo "bug" > "$sb/.claude/session/active-issue-skill"
in=$(jq -nc --arg c "linear issue create --title x" '{tool_name:"Bash", tool_input:{command:$c}}')
run_case "linear allowed with skill marker" 0 "" "$in" "$sb"

sb=$(make_sandbox); echo "task" > "$sb/.claude/session/active-issue-skill"
in=$(jq -nc --arg c 'tracker_create foo/bar "my title" /tmp/body.md' '{tool_name:"Bash", tool_input:{command:$c}}')
run_case "tracker_create allowed with skill marker (#670)" 0 "" "$in" "$sb"

# --- Non-matching commands → no-op -----------------------------------------

sb=$(make_sandbox)
in=$(jq -nc --arg c "gh issue view 42" '{tool_name:"Bash", tool_input:{command:$c}}')
run_case "gh issue view is no-op" 0 "" "$in" "$sb"

sb=$(make_sandbox)
in=$(jq -nc --arg c "echo hello world" '{tool_name:"Bash", tool_input:{command:$c}}')
run_case "echo is no-op" 0 "" "$in" "$sb"

sb=$(make_sandbox)
in=$(jq -nc --arg c "ls -la" '{tool_name:"Bash", tool_input:{command:$c}}')
run_case "ls is no-op" 0 "" "$in" "$sb"

# --- Non-Bash tools → no-op ------------------------------------------------

sb=$(make_sandbox)
in=$(jq -nc --arg p "/tmp/foo" '{tool_name:"Edit", tool_input:{file_path:$p}}')
run_case "Edit tool is no-op" 0 "" "$in" "$sb"

# --- Bootstrap-skill exemption ---------------------------------------------

sb=$(make_sandbox); echo "handover" > "$sb/.claude/session/active-bootstrap"
in=$(jq -nc --arg c "gh issue create --repo foo/bar --title x" '{tool_name:"Bash", tool_input:{command:$c}}')
run_case "gh issue create allowed during handover bootstrap" 0 "" "$in" "$sb"

sb=$(make_sandbox); echo "setup" > "$sb/.claude/session/active-bootstrap"
in=$(jq -nc --arg c "gh issue create --repo foo/bar --title x" '{tool_name:"Bash", tool_input:{command:$c}}')
run_case "gh issue create allowed during setup bootstrap" 0 "" "$in" "$sb"

# An UNLISTED bootstrap skill should NOT grant the exemption — blocked.
sb=$(make_sandbox); echo "some-random-skill" > "$sb/.claude/session/active-bootstrap"
in=$(jq -nc --arg c "gh issue create --repo foo/bar --title x" '{tool_name:"Bash", tool_input:{command:$c}}')
run_case "gh issue create blocked when bootstrap marker is non-listed" 2 "BLOCKED" "$in" "$sb"

# --- Env-var escape hatch --------------------------------------------------

sb=$(make_sandbox)
in=$(jq -nc --arg c "gh issue create --repo foo/bar --title x" '{tool_name:"Bash", tool_input:{command:$c}}')
run_case "env-var escape hatch allows with warning" 0 "APEXYARD_ALLOW_RAW_TICKET_CREATE=1" "$in" "$sb" "APEXYARD_ALLOW_RAW_TICKET_CREATE=1"

# --- Custom matcher via project-config override -----------------------------

sb=$(make_sandbox)
cat > "$sb/.claude/project-config.json" <<'JSON'
{
  "ticket": {
    "bootstrap_skills": ["setup", "handover", "update", "split-portfolio"],
    "create_command_patterns": [
      "gh issue create",
      "mycorp-tracker new"
    ]
  }
}
JSON
in=$(jq -nc --arg c "mycorp-tracker new --title x" '{tool_name:"Bash", tool_input:{command:$c}}')
run_case "custom matcher 'mycorp-tracker new' enforced" 2 "BLOCKED" "$in" "$sb"

# --- Empty marker → no exemption (treated as no marker) --------------------

sb=$(make_sandbox); : > "$sb/.claude/session/active-issue-skill"
in=$(jq -nc --arg c "gh issue create --repo foo/bar --title x" '{tool_name:"Bash", tool_input:{command:$c}}')
run_case "empty skill marker → blocked" 2 "BLOCKED" "$in" "$sb"

# --- Summary --------------------------------------------------------------

echo ""
echo "==================================="
echo "  PASS: $PASS   FAIL: $FAIL"
echo "==================================="
if [ "$FAIL" -gt 0 ]; then
  echo "Failed: $FAILED_CASES" >&2
  exit 1
fi
exit 0
