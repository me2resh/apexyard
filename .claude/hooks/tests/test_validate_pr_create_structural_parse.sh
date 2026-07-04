#!/bin/bash
# Tests for validate-pr-create.sh structural parsing (apexyard#743).
#
# Covers three classes of bug where scanning the raw command string was wrong:
#
#   Bug 1 — --body-file content treated as invisible.
#     When the body is in a file the sections check must read that file and
#     validate its content.  An absolute-path --body-file with both required
#     sections must PASS; one with a missing section must BLOCK.
#
#   Bug 2 — backslash-continued multi-line commands mis-resolve --repo.
#     Line continuations must be normalised before flag extraction so that
#     --repo on a continuation line is parsed correctly, not garbled.
#
#   Bug 3 — matcher fires on "gh pr create" text inside a body payload.
#     A 'gh issue create --body "... gh pr create ..."' command must not
#     trigger pr-create validation.  The gate check operates on the command
#     head (stripped of body content), not the raw command string.
#
#   Regression — existing inline --body behaviour must be unchanged.
#
# Test harness mirrors the style of the sibling test files in this directory:
#   - isolated sandbox per case (mktemp -d)
#   - mock_gh_install for the ticket-existence check
#   - pipes JSON {tool_input:{command:...}} to the hook
#   - asserts exit code + optional stderr regex
#
# Exit 0 if all cases pass; exit 1 on first failure.

set -u

SRC_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
HOOK_SRC="$SRC_ROOT/.claude/hooks/validate-pr-create.sh"
LIB_CFG="$SRC_ROOT/.claude/hooks/_lib-read-config.sh"
LIB_TRACKER="$SRC_ROOT/.claude/hooks/_lib-tracker.sh"
LIB_PR_REPO="$SRC_ROOT/.claude/hooks/_lib-pr-repo.sh"
DEFAULTS="$SRC_ROOT/.claude/project-config.defaults.json"

# shellcheck source=_lib-mock-gh.sh
source "$(cd "$(dirname "$0")" && pwd)/_lib-mock-gh.sh"

if [ ! -x "$HOOK_SRC" ]; then
  echo "FAIL: hook not found or not executable at $HOOK_SRC" >&2
  exit 1
fi

PASS=0
FAIL=0
FAILED_CASES=""

# ---------------------------------------------------------------------------
# Sandbox helpers
# ---------------------------------------------------------------------------

# make_sandbox [local_branch]
#   Creates an isolated git repo wired with the hook and its libraries.
#   Default local branch is 'fix/#743-test' (has a ticket ID so the branch
#   check does not fire on cases that are testing something else).
make_sandbox() {
  local branch="${1:-fix/#743-test}"
  local sb
  sb=$(mktemp -d)
  (
    cd "$sb" || exit 1
    git init -q
    git config user.email "test@example.com"
    git config user.name "test"
    git remote add origin "git@github.com:me2resh/apexyard.git"
    : > onboarding.yaml
    git add onboarding.yaml
    git commit -q -m "init"
    git checkout -q -B "$branch"
  )
  mkdir -p "$sb/.claude/hooks"
  cp "$HOOK_SRC" "$sb/.claude/hooks/validate-pr-create.sh"
  chmod +x "$sb/.claude/hooks/validate-pr-create.sh"
  [ -f "$LIB_CFG" ]     && cp "$LIB_CFG"     "$sb/.claude/hooks/_lib-read-config.sh"
  [ -f "$LIB_TRACKER" ] && cp "$LIB_TRACKER"  "$sb/.claude/hooks/_lib-tracker.sh"
  [ -f "$LIB_PR_REPO" ] && cp "$LIB_PR_REPO"  "$sb/.claude/hooks/_lib-pr-repo.sh"
  [ -f "$DEFAULTS" ]    && cp "$DEFAULTS"      "$sb/.claude/project-config.defaults.json"
  echo "$sb"
}

# run_case label command want_rc [want_stderr_regex]
#   Pipes the command as a PreToolUse JSON blob into the hook, asserts exit
#   code and (optionally) a stderr pattern.
run_case() {
  local label="$1" cmd="$2" want_rc="$3" want_stderr_regex="${4:-}"
  local sb; sb=$(make_sandbox)
  mock_gh_install "$sb"

  local input
  input=$(jq -nc --arg c "$cmd" '{tool_input:{command:$c}}')
  local got_stderr got_rc
  got_stderr=$(cd "$sb" && printf '%s' "$input" | bash .claude/hooks/validate-pr-create.sh 2>&1 >/dev/null)
  got_rc=$?
  rm -rf "$sb"

  if [ "$got_rc" != "$want_rc" ]; then
    echo "FAIL [$label]: want rc=$want_rc, got $got_rc (stderr: ${got_stderr:0:300})" >&2
    FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}${label} "; return
  fi
  if [ -n "$want_stderr_regex" ] && ! printf '%s' "$got_stderr" | grep -qE "$want_stderr_regex"; then
    echo "FAIL [$label]: stderr did not match /$want_stderr_regex/" >&2
    echo "    stderr: $got_stderr" >&2
    FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}${label} "; return
  fi
  echo "PASS [$label]"
  PASS=$((PASS+1))
}

# ---------------------------------------------------------------------------
# Bug 1 — --body-file content is read and validated
# ---------------------------------------------------------------------------

BODY_WITH_SECTIONS="## Summary
Change description.

## Testing
1. Run the tests.

## Glossary
| Term | Definition |
|------|------------|
| #743 | structural parse bug |"

BODY_MISSING_GLOSSARY="## Summary
Change description.

## Testing
1. Run the tests."

# Write the test body files to /tmp (absolute paths) so they are visible to
# the hook regardless of the sandbox's working directory.
BODY_FILE_FULL=$(mktemp /tmp/test-743-body-full.XXXXXX.md)
BODY_FILE_PARTIAL=$(mktemp /tmp/test-743-body-partial.XXXXXX.md)
printf '%s' "$BODY_WITH_SECTIONS"    > "$BODY_FILE_FULL"
printf '%s' "$BODY_MISSING_GLOSSARY" > "$BODY_FILE_PARTIAL"

run_case "Bug1: --body-file with both sections → PASS" \
  "gh pr create --repo me2resh/apexyard --title 'fix(#743): test' --body-file $BODY_FILE_FULL" \
  0 ""

run_case "Bug1: --body-file missing ## Glossary → BLOCK" \
  "gh pr create --repo me2resh/apexyard --title 'fix(#743): test' --body-file $BODY_FILE_PARTIAL" \
  2 "missing required '## Glossary' section"

rm -f "$BODY_FILE_FULL" "$BODY_FILE_PARTIAL"

# ---------------------------------------------------------------------------
# Bug 2 — backslash-continued multi-line command resolves --repo correctly
# ---------------------------------------------------------------------------
#
# The command below is split across lines with backslash continuations.
# Before the fix the sed extraction of --repo could capture the trailing '\'
# (or produce empty), yielding a garbled TRACKER_REPO and a false block.
# After the fix, line-continuation normalisation runs first so --repo is
# extracted as 'me2resh/apexyard'.
#
# We use a body-file with the required sections so the only potential block
# is the garbled-repo path.

BF2=$(mktemp /tmp/test-743-bug2-body.XXXXXX.md)
printf '%s' "$BODY_WITH_SECTIONS" > "$BF2"

# Embed actual backslash-newlines via $'...'. The regression is anchored on the
# --body-file flag split across a continuation with NO space before the '\'
# ('--body-file\<newline>PATH'). This makes the proof DETERMINISTIC (no network):
#   - WITHOUT the collapse, the line-oriented extraction can't recover the path,
#     the body-file is unreadable, the section check falls back to the (section-
#     less) command text, and the hook BLOCKS for missing ## Testing/## Glossary.
#   - WITH the collapse, '\<newline>' → space, so '--body-file PATH' resolves,
#     the sections are found, and the hook passes.
# (A --repo-only garble degrades gracefully and would pass either way — i.e. it
# would pass for the wrong reason, which is exactly the gap Rex flagged.)
MULTI_LINE_CMD=$'gh pr create --repo me2resh/apexyard \\\n  --title \'fix(#743): multiline\' \\\n  --head fix/GH-743-test \\\n  --body-file\\\n'"$BF2"

run_case "Bug2: backslash-continued multi-line (--body-file on continuation) resolves cleanly → PASS" \
  "$MULTI_LINE_CMD" \
  0 ""

rm -f "$BF2"

# ---------------------------------------------------------------------------
# Bug 3 — gate does NOT fire when 'gh pr create' appears only in a body
# ---------------------------------------------------------------------------
#
# Case A: inline --body contains 'gh pr create' sample text.
# The gate check strips --body payload before the subcommand test, so the
# leading 'gh issue create' verb wins and validation is skipped entirely.

run_case "Bug3A: gh issue create --body with embedded 'gh pr create' text → no-op (exit 0)" \
  "gh issue create --repo me2resh/apexyard --title '[Bug] test' --body 'Example: gh pr create --title feat(#1): x --body body'" \
  0 ""

# Case B: --body-file on a non-pr-create command.
# The body file content (which could contain 'gh pr create') is never consulted
# for the gate decision — only the command head matters.
BF3=$(mktemp /tmp/test-743-bug3-body.XXXXXX.md)
printf 'Example usage:\n\ngh pr create --title "feat(#1): x" --body "body"\n' > "$BF3"

run_case "Bug3B: gh issue create --body-file whose content has 'gh pr create' → no-op (exit 0)" \
  "gh issue create --repo me2resh/apexyard --title '[Bug] test' --body-file $BF3" \
  0 ""

rm -f "$BF3"

# ---------------------------------------------------------------------------
# Regression — existing inline --body behaviour unchanged
# ---------------------------------------------------------------------------

# Use a body file for the regression test so actual newlines are present —
# the section grep requires '## Heading' at a real line start, which literal
# '\n' in a shell string does not provide.
BF_REG_PASS=$(mktemp /tmp/test-743-reg-pass.XXXXXX.md)
BF_REG_FAIL=$(mktemp /tmp/test-743-reg-fail.XXXXXX.md)
printf '## Summary\nfoo\n\n## Testing\nbar\n' > "$BF_REG_FAIL"
printf '## Summary\nfoo\n\n## Testing\nbar\n\n## Glossary\n| t | d |\n' > "$BF_REG_PASS"

run_case "Regression: --body-file missing ## Glossary still BLOCKS" \
  "gh pr create --repo me2resh/apexyard --title 'fix(#743): test' --head fix/#743-test --body-file $BF_REG_FAIL" \
  2 "missing required '## Glossary' section"

run_case "Regression: --body-file with both sections → PASS" \
  "gh pr create --repo me2resh/apexyard --title 'fix(#743): test' --head fix/#743-test --body-file $BF_REG_PASS" \
  0 ""

rm -f "$BF_REG_PASS" "$BF_REG_FAIL"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

echo ""
echo "==================================="
echo "  PASS: $PASS   FAIL: $FAIL"
echo "==================================="
if [ "$FAIL" -gt 0 ]; then
  echo "Failed: $FAILED_CASES" >&2
  exit 1
fi
exit 0
