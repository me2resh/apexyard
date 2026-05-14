#!/bin/bash
# Tests for require-active-ticket.sh — Bash-write coverage (#151) and
# bootstrap-skill exemption (#150).
#
# Each case:
#   - builds an isolated sandbox containing onboarding.yaml, an empty
#     registry, the hook script, the two libs it sources, and the shipped
#     project-config defaults
#   - optionally writes a current-ticket marker and/or active-bootstrap
#     marker to flip the gate
#   - pipes a synthetic PreToolUse JSON (Edit or Bash tool) to the hook
#   - asserts exit code (0=pass-through, 2=blocked) and stderr regex
#
# Exit 0 if all cases pass; 1 on first failure.

set -u

SRC_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
HOOK_SRC="$SRC_ROOT/.claude/hooks/require-active-ticket.sh"
LIB_BASH="$SRC_ROOT/.claude/hooks/_lib-detect-bash-write.sh"
LIB_CFG="$SRC_ROOT/.claude/hooks/_lib-read-config.sh"
DEFAULTS="$SRC_ROOT/.claude/project-config.defaults.json"

for f in "$HOOK_SRC" "$LIB_BASH" "$LIB_CFG" "$DEFAULTS"; do
  if [ ! -f "$f" ]; then
    echo "FAIL: required source missing: $f" >&2
    exit 1
  fi
done

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
  cp "$HOOK_SRC" "$sb/.claude/hooks/require-active-ticket.sh"
  cp "$LIB_BASH" "$sb/.claude/hooks/_lib-detect-bash-write.sh"
  cp "$LIB_CFG"  "$sb/.claude/hooks/_lib-read-config.sh"
  cp "$DEFAULTS" "$sb/.claude/project-config.defaults.json"
  chmod +x "$sb/.claude/hooks/require-active-ticket.sh"
  echo "$sb"
}

run_case() {
  local label="$1" want_rc="$2" want_stderr_regex="$3" input="$4" sb="$5"
  local got_stderr got_rc
  got_stderr=$(cd "$sb" && echo "$input" | bash .claude/hooks/require-active-ticket.sh 2>&1 >/dev/null)
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

# --- Bash-write coverage (#151) -----------------------------------------

# 1. echo > .gitignore with no ticket → BLOCKED
sb=$(make_sandbox)
in=$(jq -nc --arg c "echo x > .gitignore" '{tool_name:"Bash", tool_input:{command:$c}}')
run_case "bash echo redirect blocked w/o ticket" 2 "BLOCKED" "$in" "$sb"

# 2. python -c '...write_text...' on .gitignore w/o ticket → BLOCKED
#    (the exact bypass attempt from #151)
sb=$(make_sandbox)
in=$(jq -nc --arg c 'python3 -c "import pathlib; pathlib.Path(\".gitignore\").write_text(\"x\")"' \
  '{tool_name:"Bash", tool_input:{command:$c}}')
run_case "bash python write_text bypass blocked" 2 "BLOCKED" "$in" "$sb"

# 3. cat /file → allowed (read-only)
sb=$(make_sandbox)
in=$(jq -nc --arg c "cat /etc/hostname" '{tool_name:"Bash", tool_input:{command:$c}}')
run_case "bash read passes through" 0 "" "$in" "$sb"

# 4. echo > .claude/foo.json → allowed (path exemption catches it)
sb=$(make_sandbox)
in=$(jq -nc --arg c "echo x > .claude/foo.json" '{tool_name:"Bash", tool_input:{command:$c}}')
run_case "bash write to .claude/ exempt" 0 "" "$in" "$sb"

# 5. tee /docs/note.md → allowed (path + .md exemption)
sb=$(make_sandbox)
in=$(jq -nc --arg c "echo x | tee docs/note.md" '{tool_name:"Bash", tool_input:{command:$c}}')
run_case "bash write to .md exempt" 0 "" "$in" "$sb"

# --- Bootstrap-skill exemption (#150) -----------------------------------

# 6. Edit src/foo.ts, no ticket, NO bootstrap marker → BLOCKED
sb=$(make_sandbox)
in=$(jq -nc --arg p "$sb/src/foo.ts" '{tool_name:"Edit", tool_input:{file_path:$p}}')
run_case "edit blocked w/o ticket no bootstrap" 2 "BLOCKED" "$in" "$sb"

# 7. Edit .gitignore, no ticket, BOOTSTRAP marker (setup) → allowed
sb=$(make_sandbox)
echo "setup" > "$sb/.claude/session/active-bootstrap"
in=$(jq -nc --arg p "$sb/.gitignore" '{tool_name:"Edit", tool_input:{file_path:$p}}')
run_case "edit allowed with setup bootstrap marker" 0 "" "$in" "$sb"

# 8. Edit src/foo.ts, no ticket, BOOTSTRAP marker (handover) → allowed
sb=$(make_sandbox)
echo "handover" > "$sb/.claude/session/active-bootstrap"
in=$(jq -nc --arg p "$sb/src/foo.ts" '{tool_name:"Edit", tool_input:{file_path:$p}}')
run_case "edit allowed with handover bootstrap marker" 0 "" "$in" "$sb"

# 9. Edit src/foo.ts, no ticket, BOOTSTRAP marker (UNKNOWN skill) → BLOCKED
#    (only skills on the configured bootstrap_skills list are exempt)
sb=$(make_sandbox)
echo "some-random-skill" > "$sb/.claude/session/active-bootstrap"
in=$(jq -nc --arg p "$sb/src/foo.ts" '{tool_name:"Edit", tool_input:{file_path:$p}}')
run_case "edit blocked when bootstrap marker is for non-listed skill" 2 "BLOCKED" "$in" "$sb"

# 10. Bash python write to .gitignore, BOOTSTRAP marker (setup) → allowed
#     (this is the exact /setup-runs-into-#151-bypass scenario from #150)
sb=$(make_sandbox)
echo "setup" > "$sb/.claude/session/active-bootstrap"
in=$(jq -nc --arg c 'python3 -c "import pathlib; pathlib.Path(\".gitignore\").write_text(\"x\")"' \
  '{tool_name:"Bash", tool_input:{command:$c}}')
run_case "bash write allowed with setup bootstrap" 0 "" "$in" "$sb"

# 11. Empty bootstrap marker → no exemption (treated as no marker)
sb=$(make_sandbox)
: > "$sb/.claude/session/active-bootstrap"
in=$(jq -nc --arg p "$sb/src/foo.ts" '{tool_name:"Edit", tool_input:{file_path:$p}}')
run_case "edit blocked when bootstrap marker is empty" 2 "BLOCKED" "$in" "$sb"

# --- Active-ticket marker still works (regression for the legacy path) -

# 12. Edit src/foo.ts with a current-ticket marker → allowed
sb=$(make_sandbox)
cat > "$sb/.claude/session/current-ticket" <<EOF
repo=me2resh/apexyard
number=999
title=test
url=https://example.com
EOF
in=$(jq -nc --arg p "$sb/src/foo.ts" '{tool_name:"Edit", tool_input:{file_path:$p}}')
run_case "edit allowed with active ticket marker" 0 "" "$in" "$sb"

# --- Summary -----------------------------------------------------------

echo ""
echo "==================================="
echo "  PASS: $PASS   FAIL: $FAIL"
echo "==================================="
if [ "$FAIL" -gt 0 ]; then
  echo "Failed: $FAILED_CASES" >&2
  exit 1
fi
exit 0
