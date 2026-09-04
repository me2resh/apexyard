#!/bin/bash
# Tests for validate-branch-name.sh's /handover branch exemption
# (me2resh/apexyard#1161, AgDR-0129).
#
# /handover steps 8.5 and 8.6 push two hardcoded branches INTO AN ADOPTED REPO:
#
#   docs/agents-md        — the generated AGENTS.md operating manual
#   docs/apexyard-badge   — the "Governed by ApexYard" README badge
#
# Neither carries a ticket-ID, and neither can: /handover is bootstrap-class and
# runs before the adopted repo has any ticket to name — that repo may have no
# tracker at all. Before #1161 the gate rejected both (exit 2), so the skill's
# own prescribed branch could not satisfy the fork's own gate.
#
# The exemption is an EXACT LITERAL match on the two names. These tests pin both
# directions, and the negative direction is the load-bearing half: a
# near-miss like `docs/agents-md-v2` must still be BLOCKED. If someone later
# loosens the anchored regex to a prefix or a `docs/*` glob, the "near-miss"
# cases below fail — which is the point.
#
# Exit 0 if all cases pass; 1 on first failure.

set -u

SRC_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
HOOK_SRC="$SRC_ROOT/.claude/hooks/validate-branch-name.sh"
LIB_SRC="$SRC_ROOT/.claude/hooks/_lib-extract-push-ref.sh"
LIB_STRIP_HEREDOC_SRC="$SRC_ROOT/.claude/hooks/_lib-strip-heredoc.sh"
LIB_CONFIG_SRC="$SRC_ROOT/.claude/hooks/_lib-read-config.sh"
LIB_PR_REPO_SRC="$SRC_ROOT/.claude/hooks/_lib-pr-repo.sh"

for f in "$HOOK_SRC" "$LIB_SRC"; do
  if [ ! -f "$f" ]; then
    echo "FAIL: required source missing: $f" >&2
    exit 1
  fi
done

PASS=0
FAIL=0
FAILED_CASES=""

# Sandbox whose LOCAL branch intentionally fails validation, so a case that
# passes proves the hook read the push-ref from the command, not local HEAD.
make_sandbox() {
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
    git checkout -q -B "not-conforming-branch-name"
  )
  mkdir -p "$sb/.claude/hooks"
  cp "$HOOK_SRC" "$sb/.claude/hooks/validate-branch-name.sh"
  cp "$LIB_SRC"  "$sb/.claude/hooks/_lib-extract-push-ref.sh"
  [ -f "$LIB_STRIP_HEREDOC_SRC" ] && cp "$LIB_STRIP_HEREDOC_SRC" "$sb/.claude/hooks/_lib-strip-heredoc.sh"
  [ -f "$LIB_CONFIG_SRC" ] && cp "$LIB_CONFIG_SRC" "$sb/.claude/hooks/_lib-read-config.sh"
  [ -f "$LIB_PR_REPO_SRC" ] && cp "$LIB_PR_REPO_SRC" "$sb/.claude/hooks/_lib-pr-repo.sh"
  [ -f "$SRC_ROOT/.claude/project-config.defaults.json" ] && \
    cp "$SRC_ROOT/.claude/project-config.defaults.json" "$sb/.claude/project-config.defaults.json"
  chmod +x "$sb/.claude/hooks/validate-branch-name.sh"
  echo "$sb"
}

run_case() {
  local label="$1" cmd="$2" want_rc="$3"
  local sb; sb=$(make_sandbox)
  local input got_rc got_stderr
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
  echo "PASS [$label]"
  PASS=$((PASS+1))
}

# -- Exempt: the two names /handover actually prescribes --------------------

run_case "8.5 branch docs/agents-md is exempt" \
  "git push -u origin docs/agents-md" 0

run_case "8.6 branch docs/apexyard-badge is exempt" \
  "git push -u origin docs/apexyard-badge" 0

run_case "exempt branch still exempt without -u" \
  "git push origin docs/agents-md" 0

run_case "exempt branch still exempt with --force-with-lease" \
  "git push --force-with-lease origin docs/apexyard-badge" 0

# -- NOT exempt: near-misses must still require a ticket-ID -----------------
#
# This is the half that keeps the exemption narrow. Each of these differs from
# an exempt name by a suffix, a prefix, or a path segment.

run_case "near-miss docs/agents-md-v2 is BLOCKED" \
  "git push -u origin docs/agents-md-v2" 2

run_case "near-miss docs/agents-md/foo is BLOCKED" \
  "git push -u origin docs/agents-md/foo" 2

run_case "near-miss docs/agents is BLOCKED" \
  "git push -u origin docs/agents" 2

run_case "near-miss feature/agents-md is BLOCKED" \
  "git push -u origin feature/agents-md" 2

run_case "near-miss docs/apexyard-badge-2 is BLOCKED" \
  "git push -u origin docs/apexyard-badge-2" 2

run_case "unrelated ticketless docs branch still BLOCKED" \
  "git push -u origin docs/update-readme" 2

# -- Regression: the pre-existing exemptions and the normal path -----------

run_case "release branch still exempt" \
  "git push -u origin release/v5.4.0" 0

run_case "sync branch still exempt" \
  "git push -u origin sync/main-to-dev-after-v5.4.0" 0

run_case "conforming ticket branch still passes" \
  "git push -u origin fix/GH-1161-code-review-fork-marker" 0

# -- Summary ---------------------------------------------------------------

echo
echo "passed: $PASS   failed: $FAIL"
if [ "$FAIL" -ne 0 ]; then
  echo "failed cases: $FAILED_CASES" >&2
  exit 1
fi
exit 0
