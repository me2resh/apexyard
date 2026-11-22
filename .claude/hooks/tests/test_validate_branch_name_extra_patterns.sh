#!/bin/bash
# Tests for `.branch.extra_patterns[]` in validate-branch-name.sh
# (me2resh/apexyard#2083).
#
# Some trackers name branches themselves. Jira's "Create branch" action
# produces `<KEY>-<number>-<summary-slug>` with no `type/` prefix, and Jira
# links the branch and its PR to the ticket by that exact name. The opt-in
# `.branch.extra_patterns[]` list lets an adopter accept those shapes without
# weakening the default gate for anyone else.
#
# The load-bearing cases are the negative ones:
#
#   - the same Jira-style name is BLOCKED when no pattern is configured
#   - a pattern matches the WHOLE name only, never a substring
#   - an invalid regex fails CLOSED and says so
#
# If a later change anchors the match loosely, or silently skips a malformed
# pattern, one of the cases below fails — which is the point.
#
# Exit 0 if all cases pass; 1 on first failure.

set -u

# Isolate from live Claude Code session pin/cache (me2resh/apexyard#1549).
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"

SRC_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
HOOK_SRC="$SRC_ROOT/.claude/hooks/validate-branch-name.sh"
LIB_SRC="$SRC_ROOT/.claude/hooks/_lib-extract-push-ref.sh"
LIB_STRIP_HEREDOC_SRC="$SRC_ROOT/.claude/hooks/_lib-strip-heredoc.sh"
LIB_CONFIG_SRC="$SRC_ROOT/.claude/hooks/_lib-read-config.sh"
LIB_PR_REPO_SRC="$SRC_ROOT/.claude/hooks/_lib-pr-repo.sh"
DEFAULTS_SRC="$SRC_ROOT/.claude/project-config.defaults.json"

for f in "$HOOK_SRC" "$LIB_SRC" "$LIB_CONFIG_SRC" "$DEFAULTS_SRC"; do
  if [ ! -f "$f" ]; then
    echo "FAIL: required source missing: $f" >&2
    exit 1
  fi
done

PASS=0
FAIL=0
FAILED_CASES=""

# make_sandbox [project-config.json content]
#
# An empty second argument leaves the sandbox with only the shipped defaults,
# which is the "no patterns configured" case every adopter starts from.
make_sandbox() {
  local config="${1:-}"
  local sb
  sb=$(mktemp -d)
  (
    cd "$sb" || exit 1
    git init -q
    git config user.email "test@example.com"
    git config user.name "test"
    : > onboarding.yaml
    git add onboarding.yaml
    git commit -q -m "init"
    git checkout -q -B "work-branch"
  )
  mkdir -p "$sb/.claude/hooks"
  cp "$HOOK_SRC" "$sb/.claude/hooks/validate-branch-name.sh"
  cp "$SRC_ROOT/.claude/hooks/_lib-git-global.sh" "$sb/.claude/hooks/"
  cp "$SRC_ROOT/.claude/hooks/_lib-awk-fallback.sh" "$sb/.claude/hooks/"
  cp "$LIB_SRC" "$sb/.claude/hooks/_lib-extract-push-ref.sh"
  [ -f "$LIB_STRIP_HEREDOC_SRC" ] && cp "$LIB_STRIP_HEREDOC_SRC" "$sb/.claude/hooks/_lib-strip-heredoc.sh"
  cp "$LIB_CONFIG_SRC" "$sb/.claude/hooks/_lib-read-config.sh"
  [ -f "$LIB_PR_REPO_SRC" ] && cp "$LIB_PR_REPO_SRC" "$sb/.claude/hooks/_lib-pr-repo.sh"
  cp "$DEFAULTS_SRC" "$sb/.claude/project-config.defaults.json"
  if [ -n "$config" ]; then
    printf '%s\n' "$config" > "$sb/.claude/project-config.json"
  fi
  chmod +x "$sb/.claude/hooks/validate-branch-name.sh"
  echo "$sb"
}

# run_case <label> <push command> <want_rc> [config] [want_stderr_substring]
run_case() {
  local label="$1" cmd="$2" want_rc="$3"
  local config="${4:-}" want_msg="${5:-}"
  local sb input got_rc got_stderr
  sb=$(make_sandbox "$config")
  input=$(jq -nc --arg c "$cmd" '{tool_input:{command:$c}}')
  got_stderr=$(cd "$sb" && echo "$input" | bash .claude/hooks/validate-branch-name.sh 2>&1 >/dev/null)
  got_rc=$?
  rm -rf "$sb"

  if [ "$got_rc" != "$want_rc" ]; then
    echo "FAIL [$label]: want rc=$want_rc, got $got_rc" >&2
    echo "    cmd: $cmd" >&2
    echo "    stderr: ${got_stderr:0:300}" >&2
    FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}${label} "
    return
  fi
  if [ -n "$want_msg" ] && ! printf '%s' "$got_stderr" | grep -qF -- "$want_msg"; then
    echo "FAIL [$label]: stderr does not contain: $want_msg" >&2
    echo "    stderr: ${got_stderr:0:300}" >&2
    FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}${label} "
    return
  fi
  echo "PASS [$label]"
  PASS=$((PASS+1))
}

JIRA_CONFIG='{"branch":{"extra_patterns":["^(ABC|JIRA)-[0-9]+-[a-z0-9]+(-[a-z0-9]+)*$"]}}'
TWO_PATTERNS_CONFIG='{"branch":{"extra_patterns":["^NOPE-[0-9]+$","^ABC-[0-9]+-[a-z0-9]+(-[a-z0-9]+)*$"]}}'
BAD_REGEX_CONFIG='{"branch":{"extra_patterns":["^ABC-[0-9"]}}'
BAD_REGEX_SECOND_CONFIG='{"branch":{"extra_patterns":["^NOPE-[0-9]+$","^ABC-[0-9"]}}'
UNANCHORED_CONFIG='{"branch":{"extra_patterns":["ABC-123"]}}'
EMPTY_LIST_CONFIG='{"branch":{"extra_patterns":[]}}'

# -- The headline case: a configured pattern lets the tracker name through ---

run_case "Jira-style name passes with a pattern set" \
  "git push -u origin ABC-123-add-login" 0 "$JIRA_CONFIG"

run_case "pattern match works without -u" \
  "git push origin JIRA-42-fix-cart-total" 0 "$JIRA_CONFIG"

run_case "second pattern in the list matches" \
  "git push -u origin ABC-7-some-summary" 0 "$TWO_PATTERNS_CONFIG"

# -- The default must not move: same name, no pattern configured -----------

run_case "Jira-style name is BLOCKED with no pattern configured" \
  "git push -u origin ABC-123-add-login" 2

run_case "Jira-style name is BLOCKED with an explicitly empty list" \
  "git push -u origin ABC-123-add-login" 2 "$EMPTY_LIST_CONFIG"

# -- Whole-name match, not a substring -------------------------------------

run_case "pattern does not match a substring of the branch name" \
  "git push -u origin xABC-123y" 2 "$UNANCHORED_CONFIG"

run_case "unrelated branch is still BLOCKED when patterns are set" \
  "git push -u origin random-branch" 2 "$JIRA_CONFIG"

# -- Invalid regex fails closed, with a message naming the problem ---------

run_case "invalid regex fails closed with a clear message" \
  "git push -u origin ABC-123-add-login" 2 "$BAD_REGEX_CONFIG" "invalid extended regex"

run_case "invalid regex fails closed even when it is not the first entry" \
  "git push -u origin ABC-123-add-login" 2 "$BAD_REGEX_SECOND_CONFIG" "invalid extended regex"

run_case "invalid regex blocks an otherwise conforming branch" \
  "git push -u origin fix/GH-2083-extra-branch-patterns" 2 "$BAD_REGEX_CONFIG" "invalid extended regex"

# -- Regression: the normal path and the built-in exemptions --------------

run_case "conforming ticket branch still passes with patterns set" \
  "git push -u origin fix/GH-2083-extra-branch-patterns" 0 "$JIRA_CONFIG"

run_case "conforming ticket branch still passes with no patterns" \
  "git push -u origin feature/GH-2083-extra-branch-patterns" 0

run_case "trunk branch still exempt with patterns set" \
  "git push -u origin dev" 0 "$JIRA_CONFIG"

run_case "release branch still exempt with patterns set" \
  "git push -u origin release/v5.10.1" 0 "$JIRA_CONFIG"

# -- Summary ---------------------------------------------------------------

echo
echo "passed: $PASS   failed: $FAIL"
if [ "$FAIL" -ne 0 ]; then
  echo "failed cases: $FAILED_CASES" >&2
  exit 1
fi
exit 0
