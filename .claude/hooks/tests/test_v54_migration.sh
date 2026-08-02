#!/bin/bash
# Focused test for .claude/migrations/v5.3.0-to-v5.4.0.sh
#
# The v5.4.0 migration untracks .claude/project-config.json (the #1065
# data-loss fix, adopter side). It must:
#   - untrack a currently-tracked project-config.json (git rm --cached)
#   - leave the working-tree file AND its content exactly in place
#   - be idempotent (re-run is a no-op; already-untracked is a no-op)
#   - stage the untrack, not commit it
#
# Sandbox-based: builds a synthetic ops fork under mktemp, tracks
# project-config.json despite a .gitignore entry (reproducing the inert-ignore
# state #1065 found), runs the real shipped migration, and asserts the end
# state. Exit 0 if every case passes; 1 on first failure.

set -u

SRC_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
MIGRATION="$SRC_ROOT/.claude/migrations/v5.3.0-to-v5.4.0.sh"

[ -f "$MIGRATION" ] || { echo "FAIL: missing $MIGRATION" >&2; exit 1; }
[ -x "$MIGRATION" ] || { echo "FAIL: $MIGRATION not executable" >&2; exit 1; }

PASS=0
FAIL=0
FAILED=""
mark_pass() { echo "  ✓ $1"; PASS=$((PASS+1)); }
mark_fail() { echo "  ✗ $1: $2" >&2; FAIL=$((FAIL+1)); FAILED="$FAILED\n  - $1"; }

CONFIG_CONTENT='{"portfolio":{"registry":"../private/apexyard.projects.yaml"},"_adopter":"custom value that must survive"}'

# build_fork <root> <track_config: yes|no>
#   Creates a git repo anchored by .apexyard-fork, with .gitignore listing
#   .claude/project-config.json. When track_config=yes, the config file is
#   force-added (tracked despite the ignore) — the exact inert-ignore state.
build_fork() {
  local root="$1" track="$2"
  mkdir -p "$root/.claude"
  : > "$root/.apexyard-fork"
  printf '%s\n' '.claude/project-config.json' > "$root/.gitignore"
  printf '%s\n' "$CONFIG_CONTENT" > "$root/.claude/project-config.json"
  (
    cd "$root" || exit 99
    git init -q && git config user.email t@t.t && git config user.name t || exit 99
    git add .apexyard-fork .gitignore >/dev/null 2>&1 || exit 99
    if [ "$track" = "yes" ]; then
      git add -f .claude/project-config.json >/dev/null 2>&1 || exit 99
    fi
    git commit -q -m fixture >/dev/null 2>&1 || exit 99
  ) || return 1
}

is_tracked() { git -C "$1" ls-files --error-unmatch .claude/project-config.json >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# Case 1: tracked config → untracked after run, working-tree file + content preserved
# ---------------------------------------------------------------------------
SB=$(mktemp -d) && SB=$(cd "$SB" && pwd -P)
if build_fork "$SB" yes; then
  is_tracked "$SB" || mark_fail "case1 precondition" "config should start tracked"
  ( cd "$SB" && APEXYARD_MIGRATION_QUIET=1 bash "$MIGRATION" ); rc=$?
  if [ "$rc" -ne 0 ]; then
    mark_fail "case1 exit" "expected 0, got $rc"
  elif is_tracked "$SB"; then
    mark_fail "case1 untrack" "config still tracked after migration"
  elif [ ! -f "$SB/.claude/project-config.json" ]; then
    mark_fail "case1 worktree" "working-tree file was removed (must be preserved)"
  elif [ "$(cat "$SB/.claude/project-config.json")" != "$CONFIG_CONTENT" ]; then
    mark_fail "case1 content" "working-tree content changed (customisations lost)"
  else
    mark_pass "tracked config → untracked, working-tree file + content preserved, exit 0"
  fi
else
  mark_fail "case1 build" "build_fork failed"
fi

# ---------------------------------------------------------------------------
# Case 2: the untrack is STAGED (not committed) — operator owns the commit
# ---------------------------------------------------------------------------
# Reuses the Case 1 sandbox: after the run, a staged index deletion should exist
# and HEAD should still contain the file (nothing was committed).
if [ -d "$SB" ]; then
  staged=$(git -C "$SB" diff --cached --name-only -- .claude/project-config.json)
  in_head=$(git -C "$SB" ls-tree --name-only HEAD -- .claude/project-config.json)
  if [ "$staged" = ".claude/project-config.json" ] && [ -n "$in_head" ]; then
    mark_pass "untrack is staged (index), not committed (still in HEAD)"
  else
    mark_fail "case2 staged" "staged='$staged' in_head='$in_head' (want staged path present, still in HEAD)"
  fi
fi

# ---------------------------------------------------------------------------
# Case 3: idempotent — a second run on the same fork is a clean no-op
# ---------------------------------------------------------------------------
if [ -d "$SB" ]; then
  ( cd "$SB" && APEXYARD_MIGRATION_QUIET=1 bash "$MIGRATION" ); rc=$?
  if [ "$rc" -eq 0 ] && [ -f "$SB/.claude/project-config.json" ] && ! is_tracked "$SB"; then
    mark_pass "idempotent re-run → exit 0, still untracked, file present"
  else
    mark_fail "case3 idempotent" "rc=$rc, file-present=$([ -f "$SB/.claude/project-config.json" ] && echo y || echo n), tracked=$(is_tracked "$SB" && echo y || echo n)"
  fi
fi

# ---------------------------------------------------------------------------
# Case 4: already-untracked fork (never tracked the file) → no-op, exit 0
# ---------------------------------------------------------------------------
SB2=$(mktemp -d) && SB2=$(cd "$SB2" && pwd -P)
if build_fork "$SB2" no; then
  is_tracked "$SB2" && mark_fail "case4 precondition" "config should start untracked"
  ( cd "$SB2" && APEXYARD_MIGRATION_QUIET=1 bash "$MIGRATION" ); rc=$?
  if [ "$rc" -eq 0 ] && [ -f "$SB2/.claude/project-config.json" ] && ! is_tracked "$SB2"; then
    mark_pass "already-untracked fork → no-op, exit 0, file untouched"
  else
    mark_fail "case4 noop" "rc=$rc"
  fi
else
  mark_fail "case4 build" "build_fork failed"
fi

# ---------------------------------------------------------------------------
# Case 5: v1-anchor fork (legacy onboarding.yaml + apexyard.projects.yaml pair,
#         no .apexyard-fork) → find_ops_root resolves via the legacy branch and
#         the untrack still works. Gives find_ops_root's non-v2 path coverage.
# ---------------------------------------------------------------------------
SB3=$(mktemp -d) && SB3=$(cd "$SB3" && pwd -P)
mkdir -p "$SB3/.claude"
: > "$SB3/onboarding.yaml"
: > "$SB3/apexyard.projects.yaml"
printf '%s\n' '.claude/project-config.json' > "$SB3/.gitignore"
printf '%s\n' "$CONFIG_CONTENT" > "$SB3/.claude/project-config.json"
if (
    cd "$SB3" || exit 99
    git init -q && git config user.email t@t.t && git config user.name t || exit 99
    git add onboarding.yaml apexyard.projects.yaml .gitignore >/dev/null 2>&1 || exit 99
    git add -f .claude/project-config.json >/dev/null 2>&1 || exit 99
    git commit -q -m fixture >/dev/null 2>&1 || exit 99
  ); then
  is_tracked "$SB3" || mark_fail "case5 precondition" "config should start tracked"
  ( cd "$SB3" && APEXYARD_MIGRATION_QUIET=1 bash "$MIGRATION" ); rc=$?
  if [ "$rc" -eq 0 ] && ! is_tracked "$SB3" && [ -f "$SB3/.claude/project-config.json" ]; then
    mark_pass "v1-anchor fork (legacy pair) → find_ops_root resolves, untrack works"
  else
    mark_fail "case5 v1anchor" "rc=$rc tracked=$(is_tracked "$SB3" && echo y || echo n)"
  fi
else
  mark_fail "case5 build" "build failed"
fi

# ---------------------------------------------------------------------------
# Case 6: defer-not-force. Staged content differs from BOTH HEAD and the working
#         tree → `git rm --cached` refuses (no -f), the migration exits 1, the
#         file stays tracked, and the working-tree content is untouched. Locks
#         the "never discard a staged change" safety contract.
# ---------------------------------------------------------------------------
SB4=$(mktemp -d) && SB4=$(cd "$SB4" && pwd -P)
if build_fork "$SB4" yes; then
  (
    cd "$SB4" || exit 99
    printf '%s\n' '{"_adopter":"STAGED-version-B"}' > .claude/project-config.json
    git add -f .claude/project-config.json >/dev/null 2>&1   # index (staged) = B, differs from HEAD
    printf '%s\n' '{"_adopter":"WORKTREE-version-C"}' > .claude/project-config.json  # working tree = C
  )
  ( cd "$SB4" && APEXYARD_MIGRATION_QUIET=1 bash "$MIGRATION" ); rc=$?
  wt=$(cat "$SB4/.claude/project-config.json")
  if [ "$rc" -eq 1 ] && is_tracked "$SB4" && [ "$wt" = '{"_adopter":"WORKTREE-version-C"}' ]; then
    mark_pass "unexpected staged state → exit 1 defer-not-force, still tracked, worktree preserved"
  else
    mark_fail "case6 defer" "rc=$rc (want 1), tracked=$(is_tracked "$SB4" && echo y || echo n), wt=$wt"
  fi
else
  mark_fail "case6 build" "build_fork failed"
fi

rm -rf "$SB" "$SB2" "$SB3" "$SB4" 2>/dev/null

echo ""
echo "v5.4.0 migration test: PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -ne 0 ]; then
  # shellcheck disable=SC2059
  printf "FAILED:$FAILED\n" >&2
  exit 1
fi
exit 0
