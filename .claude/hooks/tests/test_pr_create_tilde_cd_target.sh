#!/bin/bash
# Regression test — tilde-expansion bug in the PR-create cd-target resolution
# (apexyard bug report, 2026-07).
#
# THE BUG
# -------
# `pr_cmd_cd_target` (in _lib-pr-repo.sh) extracts the literal path text from
# a leading `cd <path> && …` prefix — e.g. for
# `cd ~/Projects/foo && gh pr create …` it returned the literal string
# `~/Projects/foo`. That string was then handed straight to `git -C`:
#
#     CD_TOPLEVEL=$(git -C "$CD_TARGET" rev-parse --show-toplevel ...)
#
# `git -C` does NOT perform shell tilde-expansion — it treats `~` as a
# literal path-name character. So `git -C "~/Projects/foo"` failed silently,
# CD_TOPLEVEL came back empty, and validate-pr-create.sh's branch-ticket-ID
# fallback used the HOOK'S OWN cwd instead (typically the ops-fork root, on
# `dev`) — producing a false "Branch 'dev' missing ticket ID" block for a
# perfectly valid PR from a tilde-path worktree.
#
# THE FIX
# -------
# `_pr_repo_expand_tilde` (in _lib-pr-repo.sh) expands a leading `~` / `~user`
# to an absolute path before `pr_cmd_cd_target` returns it, so `git -C`
# receives a real path. This is a single fix point shared by every hook that
# calls `pr_cmd_cd_target` (validate-pr-create.sh, validate-branch-name.sh,
# require-agdr-for-arch-pr.sh, require-architecture-review.sh,
# require-design-review-for-ui.sh).
#
# THIS TEST
# ---------
# Uses a per-case fake $HOME (via `HOME=<tmp> bash validate-pr-create.sh`) so
# `~/Projects/tilde-target` resolves to a directory this test fully controls
# — no dependency on, or pollution of, the real user's home directory.
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

BODY_OK="## Summary
test

## Testing
1. unit tests pass

## Glossary
| Term | Definition |
|------|------------|
| tilde | home-directory shorthand |"

# make_host_sandbox [local_branch]
#   Host sandbox with the hook + libs installed, on an intentionally
#   non-conforming local branch — proves the fix resolves the CD-TARGET's
#   own branch, not the host sandbox's cwd branch.
make_host_sandbox() {
  local branch="${1:-totally-bogus-host-branch}"
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
    git checkout -q -B "$branch"
  )
  mkdir -p "$sb/.claude/hooks"
  cp "$HOOK_SRC" "$sb/.claude/hooks/validate-pr-create.sh"
  chmod +x "$sb/.claude/hooks/validate-pr-create.sh"
  [ -f "$LIB_CFG" ]     && cp "$LIB_CFG"     "$sb/.claude/hooks/_lib-read-config.sh"
  [ -f "$LIB_TRACKER" ] && cp "$LIB_TRACKER" "$sb/.claude/hooks/_lib-tracker.sh"
  [ -f "$LIB_PR_REPO" ] && cp "$LIB_PR_REPO" "$sb/.claude/hooks/_lib-pr-repo.sh"
  [ -f "$DEFAULTS" ]    && cp "$DEFAULTS"    "$sb/.claude/project-config.defaults.json"
  echo "$sb"
}

# make_target_repo_under <fake_home> <subpath-under-home> <branch>
#   Creates a git repo at $fake_home/<subpath>, checked out on <branch>.
#   Echoes the absolute path.
make_target_repo_under() {
  local fake_home="$1" subpath="$2" branch="$3" tdir
  tdir="$fake_home/$subpath"
  mkdir -p "$tdir"
  (
    cd "$tdir" || exit 1
    git init -q
    git config user.email "test@example.com"
    git config user.name "test"
    : > onboarding.yaml
    git add onboarding.yaml
    git commit -q -m "init"
    git checkout -q -B "$branch"
  )
  echo "$tdir"
}

# run_tilde_case label target_branch want_rc want_stderr_regex
run_tilde_case() {
  local label="$1" target_branch="$2" want_rc="$3" want_stderr_regex="$4"
  local sb fake_home tgt
  sb=$(make_host_sandbox)
  mock_gh_install "$sb"
  fake_home=$(mktemp -d)
  tgt=$(make_target_repo_under "$fake_home" "Projects/tilde-target" "$target_branch")

  local body_file="$sb/body.md"
  printf '%s' "$BODY_OK" > "$body_file"

  # NB: this whole assignment is double-quoted so the literal '~' is NOT
  # expanded by THIS test script's own shell — it must reach the hook
  # exactly as a real (un-executed) user command would contain it: a raw,
  # un-expanded tilde in the cd-target path.
  local cmd="cd ~/Projects/tilde-target && gh pr create --repo me2resh/apexyard --title 'fix(#900): test' --body-file $body_file"
  local input
  input=$(jq -nc --arg c "$cmd" '{tool_input:{command:$c}}')

  local got_stderr got_rc
  got_stderr=$(cd "$sb" && printf '%s' "$input" | HOME="$fake_home" bash .claude/hooks/validate-pr-create.sh 2>&1 >/dev/null)
  got_rc=$?
  rm -rf "$sb" "$fake_home" "$tgt"

  if [ "$got_rc" != "$want_rc" ]; then
    echo "FAIL [$label]: want rc=$want_rc, got $got_rc" >&2
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

# (a) tilde cd-target on a CONFORMING branch, host cwd bogus, no --head →
#     PASS. Pre-fix this BLOCKED on the host sandbox's bogus branch because
#     `git -C "~/Projects/tilde-target"` failed silently and the fallback hit
#     the (bogus-branch) host cwd instead.
run_tilde_case "tilde cd-target on conforming branch resolves the TARGET, not host cwd → PASS" \
  "feature/GH-900-tilde-target" 0 ""

# (b) tilde cd-target on a genuinely non-conforming branch → still BLOCKS.
#     Proves the fix re-roots to the RIGHT tree, not a blanket no-op that
#     would silently pass everything.
run_tilde_case "tilde cd-target on non-conforming branch still BLOCKS (true-negative)" \
  "bogus-no-ticket-branch" 2 "missing ticket ID"

echo ""
echo "==================================="
echo "  PASS: $PASS   FAIL: $FAIL"
echo "==================================="
if [ "$FAIL" -gt 0 ]; then
  echo "Failed: $FAILED_CASES" >&2
  exit 1
fi
exit 0
