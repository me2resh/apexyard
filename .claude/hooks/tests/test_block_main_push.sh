#!/bin/bash
# Tests for block-main-push.sh worktree-safe fix (me2resh/apexyard#549).
#
# The bug: the hook resolved the current branch via `git branch --show-current`
# in the hook's cwd (the harness primary checkout). When the primary checkout
# sat on a protected branch (e.g. `dev`) but the actual operation targeted a
# feature-branch worktree via `cd ../wt && git commit`, the hook false-blocked.
#
# The fix:
#   Push:   read the DESTINATION branch from the push command via
#           _lib-extract-push-ref.sh (same lib as validate-branch-name.sh).
#           A push whose explicit destination is a non-protected branch passes
#           even when the session cwd is on a protected branch.
#   Commit: detect `cd <path> && git commit` and resolve the branch of the
#           TARGET worktree (`git -C <path> branch --show-current`) instead
#           of the session cwd.
#
# Test cases:
#   (a) push to a protected branch still blocks                  [regression]
#   (b) push to a feature branch passes when cwd is on dev/main  [bug fix]
#   (c) tag push passes                                           [regression]
#   (d) cd ../wt && git commit on feature-branch wt passes        [bug fix]
#       while the session cwd is on dev
#   (e) plain git commit on a protected branch still blocks       [regression]
#
# Exit 0 if all cases pass; 1 on first failure.

set -u

SRC_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
HOOK_SRC="$SRC_ROOT/.claude/hooks/block-main-push.sh"
LIB_SRC="$SRC_ROOT/.claude/hooks/_lib-extract-push-ref.sh"
LIB_STRIP_HEREDOC_SRC="$SRC_ROOT/.claude/hooks/_lib-strip-heredoc.sh"
LIB_CONFIG_SRC="$SRC_ROOT/.claude/hooks/_lib-read-config.sh"
LIB_OPS_ROOT_SRC="$SRC_ROOT/.claude/hooks/_lib-ops-root.sh"
LIB_PROTECTED_SRC="$SRC_ROOT/.claude/hooks/_lib-protected-branches.sh"

for f in "$HOOK_SRC" "$LIB_SRC" "$LIB_STRIP_HEREDOC_SRC" "$LIB_PROTECTED_SRC"; do
  if [ ! -f "$f" ]; then
    echo "FAIL: required source missing: $f" >&2
    exit 1
  fi
done

PASS=0
FAIL=0
FAILED_CASES=""

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# make_git_repo <dir> <branch>
# Initialise a minimal git repo checked out to <branch>.
make_git_repo() {
  local dir="$1" branch="$2"
  mkdir -p "$dir"
  (
    cd "$dir" || exit 1
    git init -q
    git config user.email "test@example.com"
    git config user.name "Test"
    : > README
    git add README
    git commit -q -m "init"
    git checkout -q -B "$branch"
  )
}

# make_sandbox <primary-branch>
# Build an isolated sandbox with:
#   $sb/          — the PRIMARY checkout (session cwd), on <primary-branch>
#   $sb/.claude/hooks/  — the hook + libs
#
# Returns the sandbox root path in $SANDBOX_ROOT.
make_sandbox() {
  local primary_branch="${1:-dev}"
  local sb
  sb=$(mktemp -d)

  # Primary checkout — the harness cwd is here.
  make_git_repo "$sb" "$primary_branch"

  # Install hook + libs.
  mkdir -p "$sb/.claude/hooks"
  cp "$HOOK_SRC"        "$sb/.claude/hooks/block-main-push.sh"
  cp "$LIB_SRC"         "$sb/.claude/hooks/_lib-extract-push-ref.sh"
  cp "$LIB_PROTECTED_SRC" "$sb/.claude/hooks/_lib-protected-branches.sh"
  if [ -f "$LIB_STRIP_HEREDOC_SRC" ]; then
    cp "$LIB_STRIP_HEREDOC_SRC" "$sb/.claude/hooks/_lib-strip-heredoc.sh"
  fi
  if [ -f "$LIB_CONFIG_SRC" ]; then
    cp "$LIB_CONFIG_SRC"  "$sb/.claude/hooks/_lib-read-config.sh"
  fi
  if [ -f "$LIB_OPS_ROOT_SRC" ]; then
    cp "$LIB_OPS_ROOT_SRC" "$sb/.claude/hooks/_lib-ops-root.sh"
  fi
  if [ -f "$SRC_ROOT/.claude/project-config.defaults.json" ]; then
    cp "$SRC_ROOT/.claude/project-config.defaults.json" \
       "$sb/.claude/project-config.defaults.json"
  fi
  chmod +x "$sb/.claude/hooks/block-main-push.sh"

  echo "$sb"
}

# make_worktree <sandbox-root> <feature-branch>
# Add a linked git worktree at $sb/wt checked out to <feature-branch>.
make_worktree() {
  local sb="$1" branch="$2"
  (
    cd "$sb" || exit 1
    git worktree add -q -b "$branch" "$sb/wt"
  )
  echo "$sb/wt"
}

# run_case <label> <sandbox-root> <cwd-for-hook> <command> <want-rc>
# Pipe the command as a PreToolUse JSON payload to block-main-push.sh
# evaluated with cwd set to <cwd-for-hook>.
run_case() {
  local label="$1" sb="$2" hook_cwd="$3" cmd="$4" want_rc="$5"
  local input
  input=$(jq -nc --arg c "$cmd" '{tool_input:{command:$c}}')
  local got_rc got_stderr
  got_stderr=$(cd "$hook_cwd" && echo "$input" | bash .claude/hooks/block-main-push.sh 2>&1 >/dev/null)
  got_rc=$?

  if [ "$got_rc" != "$want_rc" ]; then
    echo "FAIL [$label]: want rc=$want_rc, got $got_rc" >&2
    echo "    cmd:    $cmd" >&2
    echo "    stderr: ${got_stderr:0:300}" >&2
    FAIL=$((FAIL+1))
    FAILED_CASES="${FAILED_CASES}${label} "
    return
  fi
  echo "PASS [$label]"
  PASS=$((PASS+1))
}

# ---------------------------------------------------------------------------
# (a) Push to a protected branch still blocks — regardless of session cwd
# ---------------------------------------------------------------------------
SB=$(make_sandbox "feature/GH-1-safe")   # cwd on a NON-protected branch
run_case "push to main blocks (explicit ref)" \
  "$SB" "$SB" "git push origin main" 2
run_case "push to dev blocks (explicit ref)" \
  "$SB" "$SB" "git push upstream dev" 2
run_case "push to master blocks" \
  "$SB" "$SB" "git push origin master" 2
run_case "push to develop blocks" \
  "$SB" "$SB" "git push origin develop" 2
run_case "push HEAD:main (refspec dst) blocks" \
  "$SB" "$SB" "git push origin HEAD:main" 2
run_case "push HEAD:dev (refspec dst) blocks" \
  "$SB" "$SB" "git push upstream HEAD:dev" 2
rm -rf "$SB"

# ---------------------------------------------------------------------------
# (b) Push to a feature branch passes even when session cwd is on dev
#     This is the primary regression from #549.
# ---------------------------------------------------------------------------
SB=$(make_sandbox "dev")   # cwd is on PROTECTED branch 'dev'
run_case "push feature branch passes (cwd=dev, explicit ref)" \
  "$SB" "$SB" "git push origin feature/GH-549-fix" 0
run_case "push fix branch passes (cwd=dev, -u flag)" \
  "$SB" "$SB" "git push -u origin fix/GH-100-foo" 0
run_case "push with HEAD:feature refspec passes (cwd=dev)" \
  "$SB" "$SB" "git push upstream HEAD:feature/GH-549-fix" 0
run_case "push feature branch passes (cwd=dev, --force)" \
  "$SB" "$SB" "git push --force origin feature/GH-1-bar" 0

# Bare push with no explicit ref falls back to local HEAD (dev) → should block.
run_case "bare push (no ref) on dev falls back to local HEAD → blocks" \
  "$SB" "$SB" "git push" 2
run_case "push origin (no ref) on dev falls back to local HEAD → blocks" \
  "$SB" "$SB" "git push origin" 2
rm -rf "$SB"

# ---------------------------------------------------------------------------
# (c) Tag push passes — never subject to branch-protection check
# ---------------------------------------------------------------------------
SB=$(make_sandbox "dev")   # cwd on protected branch
run_case "tag push --tags passes (cwd=dev)" \
  "$SB" "$SB" "git push origin --tags" 0
run_case "tag push refs/tags/ passes (cwd=dev)" \
  "$SB" "$SB" "git push origin refs/tags/v1.0.0:refs/tags/v1.0.0" 0
run_case "tag push 'tag <name>' passes (cwd=dev)" \
  "$SB" "$SB" "git push upstream tag v3.0.0" 0
run_case "tag push --tags with 2>&1 pipe passes" \
  "$SB" "$SB" "git push upstream --tags 2>&1 | tail -5" 0
rm -rf "$SB"

# ---------------------------------------------------------------------------
# (d) cd <path> && git commit on a feature-branch worktree passes
#     while the session cwd is on a protected branch (the #549 scenario).
# ---------------------------------------------------------------------------
SB=$(make_sandbox "dev")   # primary checkout on protected 'dev'
WT=$(make_worktree "$SB" "feature/GH-549-worktree-fix")

# The hook cwd is the primary checkout ($SB, on 'dev').
# The command targets the worktree via 'cd'.
run_case "cd wt && git commit passes (worktree=feature, cwd=dev)" \
  "$SB" "$SB" "cd ${WT} && git commit -m 'wip'" 0

run_case "cd wt && git commit -am passes (worktree=feature, cwd=dev)" \
  "$SB" "$SB" "cd ${WT} && git commit -am 'wip'" 0

# Worktree is on a protected branch — cd into it must still block.
# Use a secondary sandbox repo on 'main' and point cd at it.
SB2=$(make_sandbox "main")   # second sandbox with primary on main
run_case "cd protected-wt && git commit blocks (worktree on main)" \
  "$SB" "$SB" "cd ${SB2} && git commit -m 'bad'" 2
rm -rf "$SB2"

# --- #580 review follow-ups: quoted-path + chained-cd resolution ---
SB3=$(make_sandbox "main")   # a separate checkout on protected 'main'

# Quoted cd into a protected worktree must STILL block. Before the fix the
# quotes reached `git -C`, which errored → empty branch → silent slip-through.
run_case "cd \"protected\" (double-quoted) && commit blocks" \
  "$SB" "$SB" "cd \"${SB3}\" && git commit -m 'bad'" 2
run_case "cd 'protected' (single-quoted) && commit blocks" \
  "$SB" "$SB" "cd '${SB3}' && git commit -m 'bad'" 2

# Quoted cd into a feature worktree must still PASS (quote-strip must not over-block).
run_case "cd \"feature-wt\" (quoted) && commit passes" \
  "$SB" "$SB" "cd \"${WT}\" && git commit -m 'wip'" 0

# Chained cd resolves the LAST target, not the first.
run_case "chained cd: last=feature passes (cd main && cd wt && commit)" \
  "$SB" "$SB" "cd ${SB3} && cd ${WT} && git commit -m 'wip'" 0
run_case "chained cd: last=protected blocks (cd wt && cd main && commit)" \
  "$SB" "$SB" "cd ${WT} && cd ${SB3} && git commit -m 'bad'" 2

rm -rf "$SB3"

rm -rf "$SB"

# ---------------------------------------------------------------------------
# (e) Plain git commit on a protected branch still blocks — regression
# ---------------------------------------------------------------------------
SB=$(make_sandbox "main")   # cwd on protected 'main'
run_case "plain git commit on main blocks" \
  "$SB" "$SB" "git commit -m 'bad'" 2
rm -rf "$SB"

# Rebuild cleanly for the dev case.
SB=$(make_sandbox "dev")
run_case "plain git commit on dev blocks" \
  "$SB" "$SB" "git commit -m 'bad'" 2
run_case "plain git commit -am on dev blocks (clean sandbox)" \
  "$SB" "$SB" "git commit -am 'bad'" 2
run_case "plain git commit --allow-empty on dev blocks" \
  "$SB" "$SB" "git commit --allow-empty -m 'bad'" 2
rm -rf "$SB"

# Plain commit on a feature branch must pass.
SB=$(make_sandbox "feature/GH-549-fix")
run_case "plain git commit on feature branch passes" \
  "$SB" "$SB" "git commit -m 'good'" 0
rm -rf "$SB"

# ---------------------------------------------------------------------------
# (f) cd <wt> && git push -u/--set-upstream origin (no explicit refspec)
#     resolves the WORKTREE branch, not the hook's session cwd — #727
#
# Bug: when `extract_push_ref` returns empty (no explicit ref in the command),
#      the hook fell back to `git branch --show-current` in the session cwd.
#      In a worktree session cwd=dev, `git push -u origin` from a feature
#      worktree was falsely blocked.
# ---------------------------------------------------------------------------
SB=$(make_sandbox "dev")   # primary checkout on protected 'dev'
WT=$(make_worktree "$SB" "feature/GH-727-push-u")

# Hook cwd = $SB (on dev). Command cd-s into feature worktree then pushes
# without an explicit branch name — must resolve wt branch, not cwd branch.
run_case "cd wt && push -u origin (no ref) passes (wt=feature, cwd=dev)" \
  "$SB" "$SB" "cd ${WT} && git push -u origin" 0
run_case "cd wt && push --set-upstream origin (no ref) passes (wt=feature, cwd=dev)" \
  "$SB" "$SB" "cd ${WT} && git push --set-upstream origin" 0
run_case "cd wt && push -u upstream (no ref) passes (wt=feature, cwd=dev)" \
  "$SB" "$SB" "cd ${WT} && git push -u upstream" 0

# cd into a protected-branch repo + bare -u push must still block.
SB_PROT=$(make_sandbox "main")
run_case "cd main-repo && push -u origin blocks (repo=main, cwd=dev)" \
  "$SB" "$SB" "cd ${SB_PROT} && git push -u origin" 2
rm -rf "$SB_PROT"

# Bare `git push -u origin` with NO cd prefix — session cwd is dev → blocks.
run_case "bare push -u origin on dev cwd blocks (no cd)" \
  "$SB" "$SB" "git push -u origin" 2

# Quoted cd into feature wt must still pass (same quote-stripping as #580).
run_case "cd \"wt\" && push -u origin (double-quoted) passes" \
  "$SB" "$SB" "cd \"${WT}\" && git push -u origin" 0

rm -rf "$SB"

# ---------------------------------------------------------------------------
# Non-git commands must be no-ops.
# ---------------------------------------------------------------------------
SB=$(make_sandbox "dev")
run_case "non-git command is no-op" \
  "$SB" "$SB" "echo hello" 0
run_case "gh pr create is no-op" \
  "$SB" "$SB" "gh pr create --base dev --head feature/GH-1-foo" 0
rm -rf "$SB"

# run_case_stderr <label> <sandbox-root> <cwd-for-hook> <command> <want-rc> <want-substring>
# Like run_case, but additionally asserts stderr contains <want-substring>.
run_case_stderr() {
  local label="$1" sb="$2" hook_cwd="$3" cmd="$4" want_rc="$5" want_substr="$6"
  local input
  input=$(jq -nc --arg c "$cmd" '{tool_input:{command:$c}}')
  local got_rc got_stderr
  got_stderr=$(cd "$hook_cwd" && echo "$input" | bash .claude/hooks/block-main-push.sh 2>&1 >/dev/null)
  got_rc=$?

  if [ "$got_rc" != "$want_rc" ]; then
    echo "FAIL [$label]: want rc=$want_rc, got $got_rc" >&2
    echo "    cmd:    $cmd" >&2
    echo "    stderr: ${got_stderr:0:300}" >&2
    FAIL=$((FAIL+1))
    FAILED_CASES="${FAILED_CASES}${label} "
    return
  fi
  if ! echo "$got_stderr" | grep -qF "$want_substr"; then
    echo "FAIL [$label]: rc matched but stderr missing substring '$want_substr'" >&2
    echo "    stderr: ${got_stderr:0:400}" >&2
    FAIL=$((FAIL+1))
    FAILED_CASES="${FAILED_CASES}${label} "
    return
  fi
  echo "PASS [$label]"
  PASS=$((PASS+1))
}

# ---------------------------------------------------------------------------
# me2resh/apexyard#1086 step 3 (PR-2, AgDR-0114): migration onto the shared
# _lib-protected-branches.sh lib, plus the new --no-verify note.
#
# (g) The migration must not demote any former exit-2 site: every case in
#     sections (a)-(e) above already re-proves this (identical rc=2/0
#     expectations, now running against the migrated hook). This section
#     adds NEW coverage the migration specifically introduces.
# ---------------------------------------------------------------------------

# --no-verify on a protected-branch push still blocks, AND the message
# names --no-verify explicitly (the one shape with no git-native
# replacement -- .githooks/pre-push would be skipped by this flag, this
# PreToolUse hook is not).
SB=$(make_sandbox "feature/GH-1-safe")
run_case_stderr "push --no-verify to main blocks + message names --no-verify" \
  "$SB" "$SB" "git push --no-verify origin main" 2 "does not bypass this check"
rm -rf "$SB"

# --no-verify on a protected-branch commit still blocks, same message.
SB=$(make_sandbox "main")
run_case_stderr "commit --no-verify on main blocks + message names --no-verify" \
  "$SB" "$SB" "git commit --no-verify -m 'bad'" 2 "does not bypass this check"
rm -rf "$SB"

# A legitimate, non-protected push/commit with --no-verify must still pass
# (the note only appears on an already-blocked command -- --no-verify never
# manufactures a NEW block on its own).
SB=$(make_sandbox "feature/GH-1-safe")
run_case "push --no-verify to feature branch passes (no new block introduced)" \
  "$SB" "$SB" "git push --no-verify origin feature/GH-2-bar" 0
run_case "commit --no-verify on feature branch passes (no new block introduced)" \
  "$SB" "$SB" "git commit --no-verify -m 'wip'" 0
rm -rf "$SB"

# ---------------------------------------------------------------------------
# (h) Migrated hook resolves the SAME protected set as
#     _lib-protected-branches.sh, driven by the SAME config key
#     (.git.protected_branches[]) -- proves the lib migration is real, not
#     cosmetic. An override that REPLACES the default list must be honoured
#     identically to how .githooks/pre-push and .githooks/pre-commit honour
#     it (they already source the same lib function).
# ---------------------------------------------------------------------------
SB=$(make_sandbox "main")
mkdir -p "$SB/.claude"
cat > "$SB/.claude/project-config.json" <<'CFG'
{
  "git": {
    "protected_branches": ["release"]
  }
}
CFG
# main is no longer in the overridden list -> must be ALLOWED now.
run_case "config override REPLACES default list: push to main now passes" \
  "$SB" "$SB" "git push origin main" 0
run_case "config override REPLACES default list: commit on main now passes" \
  "$SB" "$SB" "git commit -m 'ok now'" 0
# release IS in the overridden list -> must BLOCK.
run_case "config override REPLACES default list: push to release blocks" \
  "$SB" "$SB" "git push origin release" 2
rm -rf "$SB"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "==================================="
echo "  PASS: $PASS   FAIL: $FAIL"
echo "==================================="
if [ "$FAIL" -gt 0 ]; then
  echo "Failed cases: $FAILED_CASES" >&2
  exit 1
fi
exit 0
