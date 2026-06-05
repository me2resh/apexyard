#!/bin/bash
# Smoke tests for .claude/hooks/warn-bootstrap-scope.sh — verifies the
# advisory banner fires exactly when the bootstrap marker is active AND the
# commit message does not reference handover output.
#
# Test layout (6+ cases):
#
#   1. Bootstrap marker exists + non-bootstrap commit message  → should WARN
#   2. Bootstrap marker exists + "handover" commit message     → should NOT warn
#   3. Bootstrap marker exists + "registry" commit message     → should NOT warn
#   4. No bootstrap marker + any commit message                → should NOT warn
#   5. Bootstrap marker exists + "assessment" commit message   → should NOT warn
#   6. Non-Bash tool name                                      → should NOT fire
#   7. Bootstrap marker + "architecture" commit message        → should NOT warn
#   8. Bootstrap marker + "topology" commit message            → should NOT warn
#   9. Bootstrap marker + non-git command                      → should NOT fire
#  10. Bootstrap marker exists + non-bootstrap commit (double- → should WARN
#      quoted -m)
#
# Each case pipes a synthetic hook payload into the script and asserts:
#   - exit code is 0 (advisory only — never blocks)
#   - stderr matches the expected banner (or is silent when no trigger applies)
#
# Test style matches the existing tests/*.sh — bash + jq + grep, no external
# test framework.

set -u

SRC_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
HOOK="$SRC_ROOT/.claude/hooks/warn-bootstrap-scope.sh"

if [ ! -x "$HOOK" ]; then
  echo "FAIL: hook is not executable: $HOOK" >&2
  exit 1
fi

PASS=0
FAIL=0
FAILED=""

# Helpers -----------------------------------------------------------------------

# Temporary directory for the fake bootstrap marker.
TMPDIR_WORK=$(mktemp -d)
trap 'rm -rf "$TMPDIR_WORK"' EXIT

# Path the hook will look for: .claude/session/active-bootstrap under
# the fake git root.  We create a minimal git repo structure so that
# `git rev-parse --show-toplevel` resolves to $TMPDIR_WORK.
FAKE_ROOT="$TMPDIR_WORK/repo"
mkdir -p "$FAKE_ROOT/.git" "$FAKE_ROOT/.claude/session"
git -C "$FAKE_ROOT" init -q 2>/dev/null || true

# On macOS /tmp is a symlink to /private/var/... — canonicalise so that
# the path written to MARKER matches what `git rev-parse --show-toplevel`
# returns from inside the directory.
if command -v realpath >/dev/null 2>&1; then
  FAKE_ROOT=$(realpath "$FAKE_ROOT")
elif command -v python3 >/dev/null 2>&1; then
  FAKE_ROOT=$(python3 -c "import os; print(os.path.realpath('$FAKE_ROOT'))")
else
  # Fallback: cd into the dir and capture the physical pwd.
  FAKE_ROOT=$(cd -P "$FAKE_ROOT" && pwd)
fi

MARKER="$FAKE_ROOT/.claude/session/active-bootstrap"

set_marker() {
  printf '%s' "handover" > "$MARKER"
}

clear_marker() {
  rm -f "$MARKER"
}

# run_case <label> <expected_rc> <expect_banner:yes|no> <json_input>
#
# Runs the hook with the given JSON input (piped via stdin).
# The hook must be called with GIT_DIR and PWD set so that
# `git rev-parse --show-toplevel` returns FAKE_ROOT — achieved by
# invoking via `bash -c "cd $FAKE_ROOT && exec $HOOK"` with stdin piped.
run_case() {
  local label="$1" want_rc="$2" expect_banner="$3" input="$4"
  local got_stderr got_rc

  got_stderr=$(printf '%s' "$input" | bash -c "cd '$FAKE_ROOT' && exec '$HOOK'" 2>&1 >/dev/null)
  got_rc=$?

  if [ "$got_rc" != "$want_rc" ]; then
    echo "FAIL [$label]: want rc=$want_rc, got $got_rc (stderr: ${got_stderr:0:200})" >&2
    FAIL=$((FAIL+1)); FAILED="${FAILED}${label} "; return
  fi

  if [ "$expect_banner" = "yes" ]; then
    if printf '%s' "$got_stderr" | grep -q "Bootstrap exemption is active"; then
      echo "PASS [$label] — banner emitted"
      PASS=$((PASS+1)); return
    fi
    echo "FAIL [$label]: expected advisory banner, got: $got_stderr" >&2
    FAIL=$((FAIL+1)); FAILED="${FAILED}${label} "; return
  fi

  # expect_banner = no
  if [ -z "$got_stderr" ]; then
    echo "PASS [$label] — silent"
    PASS=$((PASS+1)); return
  fi
  echo "FAIL [$label]: expected silent, got: $got_stderr" >&2
  FAIL=$((FAIL+1)); FAILED="${FAILED}${label} "
}

# --- 1. Bootstrap marker + non-bootstrap commit message → should WARN ---------

set_marker
in=$(jq -nc \
  --arg c "git commit -m 'style: update palette colours to match brand'" \
  '{tool_name:"Bash", tool_input:{command:$c}}')
run_case "marker + non-bootstrap commit → warns" 0 "yes" "$in"

# --- 2. Bootstrap marker + handover commit message → should NOT warn ----------

set_marker
in=$(jq -nc \
  --arg c "git commit -m 'chore: add handover assessment for legacy-billing-api'" \
  '{tool_name:"Bash", tool_input:{command:$c}}')
run_case "marker + handover commit → silent" 0 "no" "$in"

# --- 3. Bootstrap marker + registry commit message → should NOT warn ----------

set_marker
in=$(jq -nc \
  --arg c "git commit -m 'chore: append legacy-billing-api to registry'" \
  '{tool_name:"Bash", tool_input:{command:$c}}')
run_case "marker + registry commit → silent" 0 "no" "$in"

# --- 4. No bootstrap marker + any commit message → should NOT warn ------------

clear_marker
in=$(jq -nc \
  --arg c "git commit -m 'style: update palette colours to match brand'" \
  '{tool_name:"Bash", tool_input:{command:$c}}')
run_case "no marker + non-bootstrap commit → silent" 0 "no" "$in"

# --- 5. Bootstrap marker + assessment commit message → should NOT warn --------

set_marker
in=$(jq -nc \
  --arg c "git commit -m 'chore: write handover assessment for marketing-site'" \
  '{tool_name:"Bash", tool_input:{command:$c}}')
run_case "marker + assessment commit → silent" 0 "no" "$in"

# --- 6. Non-Bash tool → should NOT fire at all --------------------------------

set_marker
in=$(jq -nc \
  --arg cmd "git commit -m 'style: update palette'" \
  '{tool_name:"Edit", tool_input:{file_path:"src/index.ts"}}')
run_case "non-Bash tool → silent" 0 "no" "$in"

# --- 7. Bootstrap marker + architecture commit → should NOT warn --------------

set_marker
in=$(jq -nc \
  --arg c "git commit -m 'chore: add architecture container stub for billing-api'" \
  '{tool_name:"Bash", tool_input:{command:$c}}')
run_case "marker + architecture commit → silent" 0 "no" "$in"

# --- 8. Bootstrap marker + topology commit → should NOT warn ------------------

set_marker
in=$(jq -nc \
  --arg c "git commit -m 'chore: instantiate typescript-nextjs topology for marketing-site'" \
  '{tool_name:"Bash", tool_input:{command:$c}}')
run_case "marker + topology commit → silent" 0 "no" "$in"

# --- 9. Bootstrap marker + non-git command → should NOT fire ------------------

set_marker
in=$(jq -nc \
  --arg c "npm run build" \
  '{tool_name:"Bash", tool_input:{command:$c}}')
run_case "marker + non-git command → silent" 0 "no" "$in"

# --- 10. Bootstrap marker + non-bootstrap commit (double-quoted -m) → warn ----

set_marker
in=$(jq -nc \
  --arg c 'git commit -m "feat: add dark mode toggle to settings page"' \
  '{tool_name:"Bash", tool_input:{command:$c}}')
run_case "marker + non-bootstrap double-quoted commit → warns" 0 "yes" "$in"

# --- Non-blocking guarantee ---------------------------------------------------
# Even when the hook fires, exit code is 0 — the underlying tool call proceeds.

set_marker
in=$(jq -nc \
  --arg c "git commit -m 'style: unrelated change'" \
  '{tool_name:"Bash", tool_input:{command:$c}}')
got_rc=$(printf '%s' "$in" | bash -c "cd '$FAKE_ROOT' && exec '$HOOK'" >/dev/null 2>&1; echo $?)
if [ "$got_rc" = "0" ]; then
  echo "PASS [non-blocking: hook exits 0 even when banner fires]"
  PASS=$((PASS+1))
else
  echo "FAIL [non-blocking: expected rc=0, got $got_rc]" >&2
  FAIL=$((FAIL+1)); FAILED="${FAILED}non-blocking "
fi

# --- Summary ------------------------------------------------------------------

echo ""
echo "==================================="
echo "  PASS: $PASS   FAIL: $FAIL"
echo "==================================="
if [ "$FAIL" -gt 0 ]; then
  echo "Failed: $FAILED" >&2
  exit 1
fi
exit 0
