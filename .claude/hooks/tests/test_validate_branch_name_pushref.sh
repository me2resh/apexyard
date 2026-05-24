#!/bin/bash
# Tests for validate-branch-name.sh's push-source-ref extraction (#194).
#
# Validates that the hook reads the branch from the actual `git push`
# command's source ref when present, rather than from `git branch
# --show-current` against the harness's $PWD. This is the worktree-safe
# behaviour Agent fan-out workers depend on.
#
# Each case:
#   - builds an isolated sandbox with the hook + helper
#   - sets the sandbox to a "wrong" local branch that, if used, would FAIL
#     validation (so we know the hook used the push-ref, not local HEAD)
#   - pipes a synthetic PreToolUse JSON for a `git push` command containing
#     the branch we actually want validated
#   - asserts exit code (0 = pass, 2 = blocked)
#
# Exit 0 if all cases pass; 1 on first failure.

set -u

SRC_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
HOOK_SRC="$SRC_ROOT/.claude/hooks/validate-branch-name.sh"
LIB_SRC="$SRC_ROOT/.claude/hooks/_lib-extract-push-ref.sh"
LIB_CONFIG_SRC="$SRC_ROOT/.claude/hooks/_lib-read-config.sh"

for f in "$HOOK_SRC" "$LIB_SRC"; do
  if [ ! -f "$f" ]; then
    echo "FAIL: required source missing: $f" >&2
    exit 1
  fi
done

PASS=0
FAIL=0
FAILED_CASES=""

# Build a sandbox where the LOCAL branch is intentionally NON-conforming.
# If the hook resolves the branch from local HEAD, it will block (rc=2).
# If the hook resolves from the push command's source ref, it will use
# whatever the test passes in.
make_sandbox_with_wrong_local_branch() {
  local sb local_branch="${1:-not-conforming-branch-name}"
  sb=$(mktemp -d)
  (
    cd "$sb" || exit 1
    git init -q
    git config user.email "test@example.com"
    git config user.name "test"
    : > onboarding.yaml
    git add onboarding.yaml
    git commit -q -m "init"
    # Force the local branch to a name that fails the validator.
    git checkout -q -B "$local_branch"
  )
  mkdir -p "$sb/.claude/hooks"
  cp "$HOOK_SRC" "$sb/.claude/hooks/validate-branch-name.sh"
  cp "$LIB_SRC"  "$sb/.claude/hooks/_lib-extract-push-ref.sh"
  if [ -f "$LIB_CONFIG_SRC" ]; then
    cp "$LIB_CONFIG_SRC" "$sb/.claude/hooks/_lib-read-config.sh"
  fi
  if [ -f "$SRC_ROOT/.claude/project-config.defaults.json" ]; then
    cp "$SRC_ROOT/.claude/project-config.defaults.json" "$sb/.claude/project-config.defaults.json"
  fi
  chmod +x "$sb/.claude/hooks/validate-branch-name.sh"
  echo "$sb"
}

run_case() {
  local label="$1" cmd="$2" want_rc="$3"
  local sb; sb=$(make_sandbox_with_wrong_local_branch)
  local input
  input=$(jq -nc --arg c "$cmd" '{tool_input:{command:$c}}')
  local got_rc got_stderr
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

# -- Cases ---------------------------------------------------------------
#
# Local branch in every sandbox is `not-conforming-branch-name` (would fail
# validation). The hook should use the push-ref from the COMMAND when present.

# Conforming push refs → pass even though local branch is wrong.
run_case "explicit ref: feature/GH-194-foo passes" \
  "git push origin feature/GH-194-worktree-cwd-hooks" 0

run_case "explicit ref: fix/ABC-123-bar passes" \
  "git push origin fix/ABC-123-login-bug" 0

run_case "with -u flag: -u origin <branch> passes" \
  "git push -u origin feature/GH-194-foo" 0

run_case "--set-upstream: passes" \
  "git push --set-upstream origin feature/GH-194-foo" 0

run_case "--force-with-lease: passes" \
  "git push --force-with-lease origin feature/GH-194-foo" 0

run_case "refspec form src:dst passes" \
  "git push origin feature/GH-194-foo:feature/GH-194-foo" 0

run_case "release branch shorthand (no ticket): passes via release exception" \
  "git push origin release/v1.2.3" 0

run_case "main is exempt as trunk" \
  "git push origin main" 0

run_case "dev is exempt as trunk (release-cut model)" \
  "git push origin dev" 0

# Non-conforming push refs → block (the push-ref is now the source of truth).
run_case "explicit ref: bogus-branch blocks" \
  "git push origin bogus-branch" 2

run_case "explicit ref: feature/no-ticket blocks" \
  "git push origin feature/no-ticket-id" 2

# Fallback path: no source ref → falls back to local branch, which fails.
run_case "no-arg push: falls back to local HEAD (which is wrong) → blocks" \
  "git push" 2

run_case "git push origin (no ref): falls back to local HEAD → blocks" \
  "git push origin" 2

# Delete shape — should not trigger the push-ref check; falls back to local
# branch, which is non-conforming and blocks.
run_case "git push --delete: falls back, blocks (local non-conforming)" \
  "git push origin --delete bogus-branch" 2

# Non-push commands → no-op.
run_case "non-push command exits 0 silently" \
  "git status" 0

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
