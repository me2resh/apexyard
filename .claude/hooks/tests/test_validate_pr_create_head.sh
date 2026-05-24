#!/bin/bash
# Tests for validate-pr-create.sh's --head flag handling (#194).
#
# Validates that the hook reads the branch from `gh pr create --head <branch>`
# when present, rather than from `git branch --show-current` against the
# harness's $PWD. This is the worktree-safe path Agent fan-out workers depend
# on — the parent session's $PWD is often a sibling worktree, but the
# command itself carries the truth via --head.
#
# Each case:
#   - builds an isolated sandbox where the LOCAL branch is intentionally
#     non-conforming (would fail the trailing branch-ID check if used)
#   - mocks gh so the title's referenced issue resolves OPEN
#   - pipes a synthetic `gh pr create --head <branch> ...` command
#   - asserts exit code (0 = pass, 2 = blocked)
#
# Exit 0 if all cases pass; 1 on first failure.

set -u

SRC_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
HOOK_SRC="$SRC_ROOT/.claude/hooks/validate-pr-create.sh"
LIB_CFG="$SRC_ROOT/.claude/hooks/_lib-read-config.sh"
LIB_TRACKER="$SRC_ROOT/.claude/hooks/_lib-tracker.sh"
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

# Build a sandbox where the LOCAL branch is intentionally non-conforming.
# If the hook resolves from local HEAD (the bug), the trailing branch-ID
# check fires (rc=2 with "missing ticket ID"). If it resolves from --head,
# the conforming branch passed via --head wins.
make_sandbox() {
  local sb local_branch="${1:-totally-bogus-host-branch}"
  sb=$(mktemp -d)
  (
    cd "$sb" || exit 1
    git init -q
    git config user.email "test@example.com"
    git config user.name "test"
    : > onboarding.yaml
    git add onboarding.yaml
    git commit -q -m "init"
    git checkout -q -B "$local_branch"
  )
  mkdir -p "$sb/.claude/hooks"
  cp "$HOOK_SRC" "$sb/.claude/hooks/validate-pr-create.sh"
  if [ -f "$LIB_CFG" ]; then cp "$LIB_CFG" "$sb/.claude/hooks/_lib-read-config.sh"; fi
  if [ -f "$LIB_TRACKER" ]; then cp "$LIB_TRACKER" "$sb/.claude/hooks/_lib-tracker.sh"; fi
  if [ -f "$DEFAULTS" ]; then cp "$DEFAULTS" "$sb/.claude/project-config.defaults.json"; fi
  chmod +x "$sb/.claude/hooks/validate-pr-create.sh"
  echo "$sb"
}

# A valid PR body — has Testing + Glossary so the body checks don't fire.
BODY_OK="## Summary
test

## Testing
1. unit tests pass

## Glossary
| Term | Definition |
|------|------------|
| GH-194 | the bug we're fixing |"

run_case() {
  local label="$1" cmd_extra_flags="$2" want_rc="$3" want_stderr_regex="$4"
  local sb; sb=$(make_sandbox)
  mock_gh_install "$sb"
  local body_file="$sb/body.md"
  printf '%s' "$BODY_OK" > "$body_file"

  local cmd="gh pr create --repo me2resh/apexyard --title 'fix(#194): test' --body-file $body_file $cmd_extra_flags"
  local input
  input=$(jq -nc --arg c "$cmd" '{tool_input:{command:$c}}')
  local got_stderr got_rc
  got_stderr=$(cd "$sb" && echo "$input" | bash .claude/hooks/validate-pr-create.sh 2>&1 >/dev/null)
  got_rc=$?
  rm -rf "$sb"

  if [ "$got_rc" != "$want_rc" ]; then
    echo "FAIL [$label]: want rc=$want_rc, got $got_rc" >&2
    echo "    extra: $cmd_extra_flags" >&2
    echo "    stderr: ${got_stderr:0:300}" >&2
    FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}${label} "
    return
  fi
  if [ -n "$want_stderr_regex" ] && ! echo "$got_stderr" | grep -qE "$want_stderr_regex"; then
    echo "FAIL [$label]: stderr did not match /$want_stderr_regex/" >&2
    echo "    stderr: $got_stderr" >&2
    FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}${label} "
    return
  fi
  echo "PASS [$label]"
  PASS=$((PASS+1))
}

# -- Cases ---------------------------------------------------------------
#
# Local branch in every sandbox is `totally-bogus-host-branch` (no ticket
# ID). The hook should use --head when present.

# --head with conforming branch → pass.
run_case "--head feature/GH-194-foo passes" \
  "--head feature/GH-194-worktree-cwd-hooks" 0 ""

run_case "--head fix/ABC-123-foo passes" \
  "--head fix/ABC-123-login-bug" 0 ""

# No --head → falls back to local HEAD which is non-conforming → block.
run_case "no --head: falls back to local HEAD (no ticket ID) → blocks" \
  "" 2 "missing ticket ID"

# --head with non-conforming branch → blocks (the --head value is the truth).
run_case "--head bogus-branch blocks (no ticket ID)" \
  "--head bogus-branch" 2 "missing ticket ID"

# --head with main → exempt (trunk-style branch).
run_case "--head main is exempt (trunk)" \
  "--head main" 0 ""

# --head with master → exempt.
run_case "--head master is exempt" \
  "--head master" 0 ""

# Make sure --head still works with other flags interleaved.
run_case "--head later in command line still resolves" \
  "--head feature/GH-194-foo --draft" 0 ""

run_case "--head before --title still resolves" \
  "--head feature/GH-194-foo --base dev" 0 ""

# ---- Summary ------------------------------------------------------------

echo ""
echo "==================================="
echo "  PASS: $PASS   FAIL: $FAIL"
echo "==================================="
if [ "$FAIL" -gt 0 ]; then
  echo "Failed: $FAILED_CASES" >&2
  exit 1
fi
exit 0
