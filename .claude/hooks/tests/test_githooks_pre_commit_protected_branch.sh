#!/bin/bash
# Tests for .githooks/pre-commit's protected-branch enforcement — the git-
# native commit-time layer added in me2resh/apexyard#1086 step 3
# (AgDR-0114). Sibling to test_githooks_pre_push_protected_branch.sh, same
# "real git, not a stub" philosophy: this hook runs INSIDE the real
# git-commit lifecycle, so a real local repo proves "the commit genuinely
# lands or is genuinely rejected" more strictly than any stub could.
#
# EACH "must block" CASE IS DISCRIMINATING BY CONSTRUCTION
# ------------------------------------------------------------------------
# Before this PR, .githooks/ contained no pre-commit hook at all — every
# "must block" case below therefore FAILS against the pre-change tree (the
# commit succeeds, HEAD advances) and PASSES only once .githooks/pre-commit
# exists and core.hooksPath picks it up. The "must NOT block" cases are
# regression controls, not novelty proofs — they already passed against the
# pre-change tree (which blocked nothing) and exist here to catch
# over-blocking, the mirror failure mode block-main-push.sh's own worktree
# fix (#549/#727) had to correct for.
#
# Cases:
#   1.  Commit on `main`                                -> BLOCKED
#   2.  Commit on `dev`                                  -> BLOCKED
#   3.  Commit on a feature branch                       -> NOT blocked
#   4.  Commit in a cd-reached WORKTREE on a feature
#       branch, primary checkout on `main`                -> NOT blocked
#   5.  Remediation text, tracker.kind=gh                -> names `gh pr create --base main`
#   6.  Remediation text, tracker.kind=glab               -> names `glab mr create --target-branch main`
#   7.  Detached HEAD commit                              -> NOT blocked (nothing to protect)
#   8.  _lib-protected-branches.sh missing                -> WARN, NOT blocked (graceful degrade)
#   9.  bin/install-git-hooks.sh (the REAL installer) sets
#       core.hooksPath with NO enumeration of hook
#       filenames -> pre-commit is picked up anyway        -> BLOCKED on main
#
# Exit 0 if all cases pass; 1 on any failure.

set -u

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
REAL_PRE_COMMIT="$ROOT/.githooks/pre-commit"
REAL_PROTECTED_LIB="$ROOT/.claude/hooks/_lib-protected-branches.sh"
REAL_READ_CONFIG_LIB="$ROOT/.claude/hooks/_lib-read-config.sh"
REAL_TRACKER_LIB="$ROOT/.claude/hooks/_lib-tracker.sh"
REAL_INSTALLER="$ROOT/bin/install-git-hooks.sh"
REAL_GIT_HOOKS_PATH_LIB="$ROOT/.claude/hooks/_lib-git-hooks-path.sh"
REAL_PATH_RESOLVE_LIB="$ROOT/.claude/hooks/_lib-path-resolve.sh"
# me2resh/apexyard#1102 / AgDR-0118: _lib-protected-branches.sh's and
# _lib-git-hooks-path.sh's self-location now sources _lib-ops-root.sh (via
# the shared resolve_anchored_lib_dir guard) before reaching their own
# sibling libs — every sandbox that ships either must ship this too.
REAL_OPS_ROOT_LIB="$ROOT/.claude/hooks/_lib-ops-root.sh"

PASS=0
FAIL=0
FAILED=""

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "PASS [$label]"
    PASS=$((PASS+1))
  else
    echo "FAIL [$label] — expected '$expected', got '$actual'" >&2
    FAIL=$((FAIL+1)); FAILED="${FAILED}${label} "
  fi
}

assert_match() {
  local label="$1" pattern="$2" actual="$3"
  if printf '%s' "$actual" | grep -qE "$pattern"; then
    echo "PASS [$label]"
    PASS=$((PASS+1))
  else
    echo "FAIL [$label] — expected to match /$pattern/, got: $actual" >&2
    FAIL=$((FAIL+1)); FAILED="${FAILED}${label} "
  fi
}

assert_ne() {
  local label="$1" not_expected="$2" actual="$3"
  if [ "$not_expected" != "$actual" ]; then
    echo "PASS [$label]"
    PASS=$((PASS+1))
  else
    echo "FAIL [$label] — expected NOT '$not_expected', got exactly that" >&2
    FAIL=$((FAIL+1)); FAILED="${FAILED}${label} "
  fi
}

# ---------------------------------------------------------------------------
# build_sandbox DIR [TRACKER_KIND]
#
# Builds $DIR/work — a local repo, `main` checked out, with the REAL
# .githooks/pre-commit and its sourced libs installed via core.hooksPath
# (set directly here, NOT via the installer — case 9 below tests the
# installer path specifically so it isn't baked into every case).
#
# TRACKER_KIND (optional): when set, writes a minimal
# .claude/project-config.defaults.json so tracker_kind() resolves to it.
# Omitted entirely for cases that don't care (tracker_kind() then falls
# back to "gh" on its own, which the lib-missing/generic cases rely on).
# ---------------------------------------------------------------------------
build_sandbox() {
  local dir="$1" tracker_kind="${2:-}"
  local work="$dir/work"

  mkdir -p "$work"
  git -C "$work" init -q -b main
  git -C "$work" config user.name t
  git -C "$work" config user.email t@t.com

  mkdir -p "$work/.githooks"
  cp "$REAL_PRE_COMMIT" "$work/.githooks/pre-commit"
  chmod +x "$work/.githooks/pre-commit"

  mkdir -p "$work/.claude/hooks"
  cp "$REAL_PROTECTED_LIB" "$work/.claude/hooks/_lib-protected-branches.sh"
  cp "$REAL_READ_CONFIG_LIB" "$work/.claude/hooks/_lib-read-config.sh"
  cp "$REAL_OPS_ROOT_LIB" "$work/.claude/hooks/_lib-ops-root.sh"
  cp "$REAL_TRACKER_LIB" "$work/.claude/hooks/_lib-tracker.sh"

  if [ -n "$tracker_kind" ]; then
    mkdir -p "$work/.claude"
    printf '{"tracker": {"kind": "%s"}}\n' "$tracker_kind" > "$work/.claude/project-config.defaults.json"
  fi

  # Seed commit BEFORE core.hooksPath is set — unlike pre-push (which never
  # fires on `git commit`), THIS hook fires on every commit, including a
  # naive seed commit on `main` made while wiring up the sandbox. Setting
  # core.hooksPath first would block the seed commit itself, leaving every
  # case testing against an unborn HEAD instead of a real baseline commit.
  echo "seed" > "$work/README.md"
  git -C "$work" add README.md
  git -C "$work" commit -q -m "chore: init"

  git -C "$work" config core.hooksPath .githooks
}

# ---------------------------------------------------------------------------
# CASE 1: commit on `main` -> BLOCKED
# ---------------------------------------------------------------------------
case_main_branch_commit_blocked() {
  local sandbox; sandbox=$(mktemp -d)
  build_sandbox "$sandbox"
  local work="$sandbox/work"
  local before; before=$(git -C "$work" rev-parse HEAD)

  echo "change" >> "$work/README.md"
  git -C "$work" add README.md

  local out rc
  out=$(git -C "$work" commit -q -m "direct commit on main" 2>&1); rc=$?
  assert_ne "main branch commit: exit code non-zero" "0" "$rc"
  assert_match "main branch commit: BLOCKED message" "BLOCKED: Committing directly to protected branch 'main'" "$out"
  assert_eq "main branch commit: HEAD unchanged" "$before" "$(git -C "$work" rev-parse HEAD)"

  rm -rf "$sandbox"
}

# ---------------------------------------------------------------------------
# CASE 2: commit on `dev` -> BLOCKED
# ---------------------------------------------------------------------------
case_dev_branch_commit_blocked() {
  local sandbox; sandbox=$(mktemp -d)
  build_sandbox "$sandbox"
  local work="$sandbox/work"

  git -C "$work" checkout -q -b dev
  local before; before=$(git -C "$work" rev-parse HEAD)
  echo "change" >> "$work/README.md"
  git -C "$work" add README.md

  local out rc
  out=$(git -C "$work" commit -q -m "direct commit on dev" 2>&1); rc=$?
  assert_ne "dev branch commit: exit code non-zero" "0" "$rc"
  assert_match "dev branch commit: BLOCKED message" "BLOCKED: Committing directly to protected branch 'dev'" "$out"
  assert_eq "dev branch commit: HEAD unchanged" "$before" "$(git -C "$work" rev-parse HEAD)"

  rm -rf "$sandbox"
}

# ---------------------------------------------------------------------------
# CASE 3: commit on a feature branch -> NOT blocked
# ---------------------------------------------------------------------------
case_feature_branch_commit_allowed() {
  local sandbox; sandbox=$(mktemp -d)
  build_sandbox "$sandbox"
  local work="$sandbox/work"

  git -C "$work" checkout -q -b feature/GH-1-safe
  local before; before=$(git -C "$work" rev-parse HEAD)
  echo "change" >> "$work/README.md"
  git -C "$work" add README.md

  local out rc
  out=$(git -C "$work" commit -q -m "commit on feature branch" 2>&1); rc=$?
  assert_eq "feature branch commit: exit code" "0" "$rc"
  assert_ne "feature branch commit: HEAD advanced" "$before" "$(git -C "$work" rev-parse HEAD)"

  rm -rf "$sandbox"
}

# ---------------------------------------------------------------------------
# CASE 4: commit in a cd-reached WORKTREE on a feature branch, while the
# PRIMARY checkout stays on `main` -> NOT blocked (no over-block)
#
# This is the exact shape block-main-push.sh's own commit-check needed a
# dedicated fix for (#549/#727 — detecting a `cd <path>` prefix and
# re-resolving the branch from THAT path). .githooks/pre-commit needs no
# such special-casing: git invokes this hook from inside the worktree
# actually being committed to, so `git symbolic-ref --short HEAD` is
# correct by construction, not by a fix.
# ---------------------------------------------------------------------------
case_worktree_feature_branch_allowed_primary_on_main() {
  local sandbox; sandbox=$(mktemp -d)
  build_sandbox "$sandbox"
  local work="$sandbox/work"
  local wt="$sandbox/work-wt"

  # Primary checkout stays on `main` throughout this case.
  git -C "$work" worktree add -q -b feature/GH-2-worktree "$wt"

  local before; before=$(git -C "$wt" rev-parse HEAD)
  echo "change" >> "$wt/README.md"
  git -C "$wt" add README.md

  local out rc
  out=$(git -C "$wt" commit -q -m "commit in worktree on feature branch" 2>&1); rc=$?
  assert_eq "worktree feature branch commit: exit code" "0" "$rc"
  assert_ne "worktree feature branch commit: HEAD advanced" "$before" "$(git -C "$wt" rev-parse HEAD)"
  assert_eq "worktree feature branch commit: primary checkout still on main" "main" "$(git -C "$work" symbolic-ref --short HEAD)"

  rm -rf "$sandbox"
}

# ---------------------------------------------------------------------------
# CASE 5: remediation text names `gh` when tracker.kind=gh
# ---------------------------------------------------------------------------
case_remediation_gh() {
  local sandbox; sandbox=$(mktemp -d)
  build_sandbox "$sandbox" "gh"
  local work="$sandbox/work"

  echo "change" >> "$work/README.md"
  git -C "$work" add README.md

  local out
  out=$(git -C "$work" commit -q -m "direct commit on main" 2>&1)
  assert_match "remediation gh: names gh pr create" "gh pr create --base main --head <feature-branch>" "$out"

  rm -rf "$sandbox"
}

# ---------------------------------------------------------------------------
# CASE 6: remediation text names `glab` when tracker.kind=glab
# ---------------------------------------------------------------------------
case_remediation_glab() {
  local sandbox; sandbox=$(mktemp -d)
  build_sandbox "$sandbox" "glab"
  local work="$sandbox/work"

  echo "change" >> "$work/README.md"
  git -C "$work" add README.md

  local out
  out=$(git -C "$work" commit -q -m "direct commit on main" 2>&1)
  assert_match "remediation glab: names glab mr create" "glab mr create --target-branch main" "$out"
  assert_eq "remediation glab: does NOT name gh pr create" "0" "$(printf '%s' "$out" | grep -c '^ *gh pr create' || true)"

  rm -rf "$sandbox"
}

# ---------------------------------------------------------------------------
# CASE 7: detached HEAD commit -> NOT blocked (nothing to protect)
# ---------------------------------------------------------------------------
case_detached_head_allowed() {
  local sandbox; sandbox=$(mktemp -d)
  build_sandbox "$sandbox"
  local work="$sandbox/work"

  local base_sha; base_sha=$(git -C "$work" rev-parse HEAD)
  git -C "$work" checkout -q "$base_sha"

  echo "change" >> "$work/README.md"
  git -C "$work" add README.md

  local out rc
  out=$(git -C "$work" commit -q -m "detached HEAD commit" 2>&1); rc=$?
  assert_eq "detached HEAD commit: exit code" "0" "$rc"
  assert_ne "detached HEAD commit: HEAD advanced" "$base_sha" "$(git -C "$work" rev-parse HEAD)"

  rm -rf "$sandbox"
}

# ---------------------------------------------------------------------------
# CASE 8: _lib-protected-branches.sh missing -> WARN, NOT blocked
# (intentional graceful degrade for an old clone that hasn't pulled the lib
# file yet — same shape as .githooks/pre-push's identical case)
# ---------------------------------------------------------------------------
case_lib_missing_warn_allow() {
  local sandbox; sandbox=$(mktemp -d)
  build_sandbox "$sandbox"
  local work="$sandbox/work"
  rm -f "$work/.claude/hooks/_lib-protected-branches.sh"

  echo "change" >> "$work/README.md"
  git -C "$work" add README.md

  local out rc
  out=$(git -C "$work" commit -q -m "commit on main, lib missing" 2>&1); rc=$?
  assert_eq "lib missing: exit code (graceful degrade)" "0" "$rc"
  assert_match "lib missing: WARN emitted" "WARN:.*_lib-protected-branches\.sh not found" "$out"

  rm -rf "$sandbox"
}

# ---------------------------------------------------------------------------
# CASE 9: the REAL installer (bin/install-git-hooks.sh) sets core.hooksPath
# with NO per-hook-filename enumeration anywhere in its own logic — proving
# .githooks/pre-commit is picked up by any clone that runs it, with no
# installer change needed for this new hook file to take effect.
# ---------------------------------------------------------------------------
case_installer_autopickup_blocks_main() {
  local sandbox; sandbox=$(mktemp -d)
  local work="$sandbox/work"

  mkdir -p "$work"
  git -C "$work" init -q -b main
  git -C "$work" config user.name t
  git -C "$work" config user.email t@t.com

  mkdir -p "$work/.githooks"
  cp "$REAL_PRE_COMMIT" "$work/.githooks/pre-commit"
  chmod +x "$work/.githooks/pre-commit"

  mkdir -p "$work/.claude/hooks" "$work/bin"
  cp "$REAL_PROTECTED_LIB" "$work/.claude/hooks/_lib-protected-branches.sh"
  cp "$REAL_READ_CONFIG_LIB" "$work/.claude/hooks/_lib-read-config.sh"
  cp "$REAL_OPS_ROOT_LIB" "$work/.claude/hooks/_lib-ops-root.sh"
  cp "$REAL_GIT_HOOKS_PATH_LIB" "$work/.claude/hooks/_lib-git-hooks-path.sh"
  cp "$REAL_PATH_RESOLVE_LIB" "$work/.claude/hooks/_lib-path-resolve.sh"
  cp "$REAL_INSTALLER" "$work/bin/install-git-hooks.sh"
  chmod +x "$work/bin/install-git-hooks.sh"

  echo "seed" > "$work/README.md"
  git -C "$work" add README.md
  git -C "$work" commit -q -m "chore: init"

  # Confirm core.hooksPath is genuinely unset before the installer runs —
  # so a subsequent block can only be explained by the installer's own
  # directory-level pickup, not by a pre-set config this test forgot to
  # clear.
  local pre_state
  pre_state=$(git -C "$work" config core.hooksPath 2>/dev/null || true)
  assert_eq "installer autopickup: hooksPath unset before install" "" "$pre_state"

  local install_out install_rc
  install_out=$(bash "$work/bin/install-git-hooks.sh" --repo-dir "$work" 2>&1); install_rc=$?
  assert_eq "installer autopickup: installer exit code" "0" "$install_rc"
  assert_eq "installer autopickup: no ERROR in installer output" "0" "$(printf '%s' "$install_out" | grep -c '^ERROR' || true)"
  assert_eq "installer autopickup: hooksPath now set" ".githooks" "$(git -C "$work" config core.hooksPath)"

  local before; before=$(git -C "$work" rev-parse HEAD)
  echo "change" >> "$work/README.md"
  git -C "$work" add README.md

  local out rc
  out=$(git -C "$work" commit -q -m "direct commit on main after real install" 2>&1); rc=$?
  assert_ne "installer autopickup: commit blocked (exit code non-zero)" "0" "$rc"
  assert_match "installer autopickup: BLOCKED message" "BLOCKED: Committing directly to protected branch 'main'" "$out"
  assert_eq "installer autopickup: HEAD unchanged" "$before" "$(git -C "$work" rev-parse HEAD)"

  rm -rf "$sandbox"
}

for f in "$REAL_PRE_COMMIT" "$REAL_PROTECTED_LIB" "$REAL_READ_CONFIG_LIB" "$REAL_TRACKER_LIB" "$REAL_INSTALLER" "$REAL_GIT_HOOKS_PATH_LIB" "$REAL_PATH_RESOLVE_LIB"; do
  if [ ! -f "$f" ]; then
    echo "FAIL: required file not found at $f" >&2
    exit 1
  fi
done

case_main_branch_commit_blocked
case_dev_branch_commit_blocked
case_feature_branch_commit_allowed
case_worktree_feature_branch_allowed_primary_on_main
case_remediation_gh
case_remediation_glab
case_detached_head_allowed
case_lib_missing_warn_allow
case_installer_autopickup_blocks_main

echo ""
echo "==================================="
echo "  PASS: $PASS   FAIL: $FAIL"
echo "==================================="
if [ "$FAIL" -gt 0 ]; then
  echo "Failed: $FAILED" >&2
  exit 1
fi
exit 0
