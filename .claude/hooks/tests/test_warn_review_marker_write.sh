#!/bin/bash
# Tests for warn-review-marker-write.sh (#728 hardening).
#
# The hook fires when a Write tool call or a Bash command targets a
# *-rex.approved or *-ceo.approved file under .claude/session/reviews/.
# It is ADVISORY (exit 0 always) because the harness provides no per-agent-type
# env var that would let the hook distinguish the sanctioned code-reviewer from a
# build-class agent — both run as CLAUDE_CODE_CHILD_SESSION=1 sub-agents with
# identical environments.  The achievable hardening is an unmissable banner.
#
# Test matrix:
#   (1) Write tool → rex marker path → banner fires, exit 0
#   (2) Write tool → ceo marker path → banner fires, exit 0
#   (3) Bash tool  → echo redirect to rex marker → banner fires, exit 0
#   (4) Bash tool  → tee to rex marker           → banner fires, exit 0
#   (5) Write tool → non-marker path             → silent, exit 0
#   (6) Bash tool  → unrelated command           → silent, exit 0
#   (7) Write tool → rex marker (architecture variant) → banner fires, exit 0
#   (8) Missing tool_name field                  → silent, exit 0
#   (9) Banner content — rex case contains "VIOLATION" and "Rex"
#  (10) Banner content — ceo case contains "VIOLATION" and "/approve-merge"
#  (11) Bash tool  → rex marker via printf       → banner fires, exit 0
#
# Exit 0 if all cases pass; 1 on failure.

set -u

HOOK_SRC="$(cd "$(dirname "$0")/.." && pwd)/warn-review-marker-write.sh"

if [ ! -f "$HOOK_SRC" ]; then
  echo "FAIL: hook not found: $HOOK_SRC" >&2
  exit 1
fi
if ! bash -n "$HOOK_SRC" 2>/dev/null; then
  echo "FAIL: syntax error in $HOOK_SRC" >&2
  exit 1
fi

PASS=0; FAIL=0; FAILED_CASES=""

# ---------------------------------------------------------------------------
# Helper: run_hook <label> <json> <expect_banner:0|1> [<grep_pattern>]
#   Pipes <json> into the hook, asserts exit=0 always.
#   If expect_banner=1, asserts stderr is non-empty (and optionally matches
#   <grep_pattern>).  If expect_banner=0, asserts stderr is empty.
# ---------------------------------------------------------------------------
run_hook() {
  local label="$1" json="$2" expect_banner="$3"
  local grep_pattern="${4:-}"
  local stderr_file rc
  stderr_file=$(mktemp)

  printf '%s' "$json" | bash "$HOOK_SRC" 2>"$stderr_file"
  rc=$?

  # Hook must ALWAYS exit 0 (advisory — never blocks).
  if [ "$rc" -ne 0 ]; then
    echo "FAIL [$label]: hook exited $rc, expected 0" >&2
    FAIL=$((FAIL+1)); FAILED_CASES="$FAILED_CASES $label"; rm -f "$stderr_file"; return
  fi

  local stderr_content
  stderr_content=$(cat "$stderr_file")

  if [ "$expect_banner" -eq 1 ]; then
    if [ -z "$stderr_content" ]; then
      echo "FAIL [$label]: expected banner on stderr, got silence" >&2
      FAIL=$((FAIL+1)); FAILED_CASES="$FAILED_CASES $label"; rm -f "$stderr_file"; return
    fi
    if [ -n "$grep_pattern" ] && ! echo "$stderr_content" | grep -qE "$grep_pattern"; then
      echo "FAIL [$label]: banner present but did not match /$grep_pattern/" >&2
      echo "  stderr (first 400 chars): ${stderr_content:0:400}" >&2
      FAIL=$((FAIL+1)); FAILED_CASES="$FAILED_CASES $label"; rm -f "$stderr_file"; return
    fi
  else
    if [ -n "$stderr_content" ]; then
      echo "FAIL [$label]: expected silence, got: ${stderr_content:0:200}" >&2
      FAIL=$((FAIL+1)); FAILED_CASES="$FAILED_CASES $label"; rm -f "$stderr_file"; return
    fi
  fi

  rm -f "$stderr_file"
  echo "PASS [$label]"
  PASS=$((PASS+1))
}

# Convenience wrappers for common JSON payloads.
write_json() {
  # Write tool targeting a file path.
  local path="$1"
  printf '{"tool_name":"Write","tool_input":{"file_path":"%s","content":"sha123"}}' "$path"
}
bash_json() {
  # Bash tool running a command string.
  local cmd="$1"
  printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$cmd"
}

# A canonical rex marker path (new qualified scheme).
REX_PATH=".claude/session/reviews/acme__myrepo__42-rex.approved"
CEO_PATH=".claude/session/reviews/acme__myrepo__42-ceo.approved"
ARC_PATH=".claude/session/reviews/acme__myrepo__42-architecture.approved"
SAFE_PATH=".claude/session/notes/build-log.txt"

# ---------------------------------------------------------------------------
# (1) Write → rex marker → banner fires, exit 0
# ---------------------------------------------------------------------------
run_hook "Write rex marker fires banner" \
  "$(write_json "$REX_PATH")" 1

# ---------------------------------------------------------------------------
# (2) Write → ceo marker → banner fires, exit 0
# ---------------------------------------------------------------------------
run_hook "Write ceo marker fires banner" \
  "$(write_json "$CEO_PATH")" 1

# ---------------------------------------------------------------------------
# (3) Bash → echo redirect to rex marker → banner fires, exit 0
# ---------------------------------------------------------------------------
run_hook "Bash echo redirect rex marker fires banner" \
  "$(bash_json "echo 'abc123' > ${REX_PATH}")" 1

# ---------------------------------------------------------------------------
# (4) Bash → tee to rex marker → banner fires, exit 0
# ---------------------------------------------------------------------------
run_hook "Bash tee rex marker fires banner" \
  "$(bash_json "printf sha | tee ${REX_PATH}")" 1

# ---------------------------------------------------------------------------
# (5) Write → non-marker path → silent, exit 0
# ---------------------------------------------------------------------------
run_hook "Write non-marker path is silent" \
  "$(write_json "$SAFE_PATH")" 0

# ---------------------------------------------------------------------------
# (6) Bash → unrelated command → silent, exit 0
# ---------------------------------------------------------------------------
run_hook "Bash unrelated command is silent" \
  "$(bash_json "gh pr merge 42 --squash")" 0

# ---------------------------------------------------------------------------
# (7) Write → architecture marker (.claude/session/reviews/*-architecture.approved)
#     NOT a *-rex.approved or *-ceo.approved → must be silent.
#     (Architecture markers are written by Tariq/approve-architecture, not Rex.)
# ---------------------------------------------------------------------------
run_hook "Write architecture marker is silent (different marker type)" \
  "$(write_json "$ARC_PATH")" 0

# ---------------------------------------------------------------------------
# (8) Missing tool_name field → silent, exit 0
# ---------------------------------------------------------------------------
run_hook "Missing tool_name is silent" \
  '{"tool_input":{"file_path":".claude/session/reviews/42-rex.approved"}}' 0

# ---------------------------------------------------------------------------
# (9) Banner content — rex case: must contain VIOLATION and mention Rex
# ---------------------------------------------------------------------------
run_hook "Rex banner contains VIOLATION keyword" \
  "$(write_json "$REX_PATH")" 1 "VIOLATION"
run_hook "Rex banner mentions Rex / code-reviewer" \
  "$(write_json "$REX_PATH")" 1 "Rex|code.reviewer"

# ---------------------------------------------------------------------------
# (10) Banner content — ceo case: must contain VIOLATION and mention /approve-merge
# ---------------------------------------------------------------------------
run_hook "CEO banner contains VIOLATION keyword" \
  "$(write_json "$CEO_PATH")" 1 "VIOLATION"
run_hook "CEO banner mentions /approve-merge" \
  "$(write_json "$CEO_PATH")" 1 "/approve-merge"

# ---------------------------------------------------------------------------
# (11) Bash → printf to rex marker → banner fires, exit 0
# ---------------------------------------------------------------------------
run_hook "Bash printf rex marker fires banner" \
  "$(bash_json "printf '%s' sha > ${REX_PATH}")" 1

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "==================================="
echo "  PASS: $PASS   FAIL: $FAIL"
echo "==================================="
if [ "$FAIL" -gt 0 ]; then
  echo "Failed cases:$FAILED_CASES" >&2
  exit 1
fi
exit 0
