#!/bin/bash
# Tests for warn-isolated-build-risk.sh (me2resh/apexyard#784).
#
# The hook is a PreToolUse advisory (exit 0 always, never blocks) that nudges
# toward the safe pattern in .claude/rules/isolated-builds.md whenever a Bash
# command looks like it's `cd`-ing into a /tmp-class build clone, or running
# destructive git (reset --hard / clean -f / checkout --force) that could land
# on the wrong repo if a preceding `cd` silently failed.
#
# Test matrix:
#   (1) cd /tmp/... && git reset --hard   → banner fires (both warnings), exit 0
#   (2) benign command (npm run build)    → silent, exit 0
#   (3) cd /tmp/... only, no destructive git → banner fires (tmp warning), exit 0
#   (4) git reset --hard only, no tmp cd  → banner fires (reset warning), exit 0
#   (5) cd into a non-tmp path            → silent, exit 0
#   (6) false-positive guard: a `cd-tool` binary name doesn't match bare `cd`
#   (7) missing tool_input.command        → silent, exit 0
#   (8) git clean -fd                     → banner fires (reset warning), exit 0
#   (9) git checkout --force              → banner fires (reset warning), exit 0
#
# Exit 0 if all cases pass; 1 on failure.

set -u

HOOK_SRC="$(cd "$(dirname "$0")/.." && pwd)/warn-isolated-build-risk.sh"

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
# ---------------------------------------------------------------------------
run_hook() {
  local label="$1" json="$2" expect_banner="$3"
  local grep_pattern="${4:-}"
  local stderr_file rc
  stderr_file=$(mktemp)

  printf '%s' "$json" | bash "$HOOK_SRC" 2>"$stderr_file"
  rc=$?

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

  echo "PASS [$label]"
  PASS=$((PASS+1))
  rm -f "$stderr_file"
}

run_hook "cd-tmp-plus-hard-reset" \
  '{"tool_input":{"command":"cd /tmp/sibling-repo && git reset --hard origin/main"}}' \
  1 'tmp-class path.*Destructive git|Destructive git.*tmp-class path|tmp-class path'

run_hook "benign-build-command" \
  '{"tool_input":{"command":"npm run build"}}' \
  0

run_hook "cd-tmp-only" \
  '{"tool_input":{"command":"cd /tmp/xyz && ls"}}' \
  1 'tmp-class path'

run_hook "hard-reset-only-no-tmp" \
  '{"tool_input":{"command":"git reset --hard HEAD~1"}}' \
  1 'Destructive git'

run_hook "cd-non-tmp-path" \
  '{"tool_input":{"command":"cd ~/repos/sibling-repo && ls"}}' \
  0

run_hook "cd-tool-binary-not-bare-cd" \
  '{"tool_input":{"command":"bundle exec cd-tool run"}}' \
  0

run_hook "missing-command-field" \
  '{"tool_input":{}}' \
  0

run_hook "git-clean-force-dirs" \
  '{"tool_input":{"command":"git clean -fd"}}' \
  1 'Destructive git'

run_hook "git-checkout-force" \
  '{"tool_input":{"command":"git checkout --force"}}' \
  1 'Destructive git'

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  echo "Failed cases:$FAILED_CASES" >&2
  exit 1
fi
exit 0
