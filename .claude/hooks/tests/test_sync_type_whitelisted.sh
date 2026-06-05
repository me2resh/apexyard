#!/bin/bash
# Regression test for the `sync` conventional-commit type (#458).
#
# The /release-sync skill documents a `sync`-typed shape for its git
# artifacts (branch `sync/...`, commit `sync: ...`, PR title `sync(#N): ...`).
# Before #458, `sync` was absent from all three type whitelists
# (branch.type_whitelist, commit.type_whitelist, pr.title_type_whitelist) and
# from the hooks' hardcoded fallbacks, so every sync artifact was rejected by
# the validators — making the skill's documented happy path impossible to
# follow (surfaced during the v2.2.0 release sync, which had to retitle
# everything to `chore`).
#
# This test guards both layers:
#   - Behavioural: the branch + commit validators accept `sync`-typed input.
#   - Static: `sync` is present in all three config whitelists AND in all
#     three hardcoded fallback strings (so a bare checkout with no jq/config
#     still honours it, and config/fallback don't drift).
#
# Exit 0 if all cases pass; 1 on first failure.

set -u

SRC_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
BRANCH_HOOK="$SRC_ROOT/.claude/hooks/validate-branch-name.sh"
COMMIT_HOOK="$SRC_ROOT/.claude/hooks/validate-commit-format.sh"
PR_HOOK="$SRC_ROOT/.claude/hooks/validate-pr-create.sh"
LIB_CFG="$SRC_ROOT/.claude/hooks/_lib-read-config.sh"
LIB_PUSHREF="$SRC_ROOT/.claude/hooks/_lib-extract-push-ref.sh"
DEFAULTS="$SRC_ROOT/.claude/project-config.defaults.json"

PASS=0
FAIL=0
FAILED_CASES=""

mark_pass() { echo "PASS [$1]"; PASS=$((PASS+1)); }
mark_fail() { echo "FAIL [$1]: $2" >&2; FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}$1 "; }

# ---------------------------------------------------------------------------
# Behavioural sandbox: branch + commit validators against sync-typed input.
# ---------------------------------------------------------------------------
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
    # Local branch intentionally non-conforming so the branch hook must use
    # the push-ref from the command, not local HEAD.
    git checkout -q -B not-conforming-branch-name
  )
  mkdir -p "$sb/.claude/hooks"
  cp "$BRANCH_HOOK" "$sb/.claude/hooks/validate-branch-name.sh"
  cp "$COMMIT_HOOK" "$sb/.claude/hooks/validate-commit-format.sh"
  [ -f "$LIB_CFG" ]     && cp "$LIB_CFG"     "$sb/.claude/hooks/_lib-read-config.sh"
  [ -f "$LIB_PUSHREF" ] && cp "$LIB_PUSHREF" "$sb/.claude/hooks/_lib-extract-push-ref.sh"
  [ -f "$DEFAULTS" ]    && cp "$DEFAULTS"    "$sb/.claude/project-config.defaults.json"
  chmod +x "$sb/.claude/hooks/"*.sh
  echo "$sb"
}

run_hook_case() {
  local label="$1" hook="$2" cmd="$3" want_rc="$4"
  local sb; sb=$(make_sandbox)
  local input got_rc got_stderr
  input=$(jq -nc --arg c "$cmd" '{tool_input:{command:$c}}')
  got_stderr=$(cd "$sb" && echo "$input" | bash ".claude/hooks/$hook" 2>&1 >/dev/null)
  got_rc=$?
  rm -rf "$sb"
  if [ "$got_rc" != "$want_rc" ]; then
    mark_fail "$label" "want rc=$want_rc, got $got_rc — stderr: ${got_stderr:0:200}"
    return
  fi
  mark_pass "$label"
}

# Branch: sync/ prefix is accepted (the /release-sync branch shape).
run_hook_case "branch: sync/main-to-dev-after-v2.2.0 passes" \
  "validate-branch-name.sh" \
  "git push origin sync/main-to-dev-after-v2.2.0" 0

# Commit: `sync:` subject is accepted.
run_hook_case "commit: 'sync: merge main into dev' passes" \
  "validate-commit-format.sh" \
  "git commit -m 'sync: merge main into dev after v2.2.0 release'" 0

# Commit: scoped `sync(#456):` subject is accepted.
run_hook_case "commit: 'sync(#456): ...' passes" \
  "validate-commit-format.sh" \
  "git commit -m 'sync(#456): carry forward CHANGELOG.md from main'" 0

# Control: an unknown type still blocks (proves we didn't open the gate).
run_hook_case "commit: unknown type 'wibble:' still blocks" \
  "validate-commit-format.sh" \
  "git commit -m 'wibble: not a real type'" 2

# ---------------------------------------------------------------------------
# Static: `sync` present in all three config whitelists.
# ---------------------------------------------------------------------------
check_config_has_sync() {
  local label="$1" jqpath="$2"
  if jq -e "$jqpath | index(\"sync\")" "$DEFAULTS" >/dev/null 2>&1; then
    mark_pass "$label"
  else
    mark_fail "$label" "sync missing from $jqpath in project-config.defaults.json"
  fi
}
check_config_has_sync "config: branch.type_whitelist has sync"   '.branch.type_whitelist'
check_config_has_sync "config: commit.type_whitelist has sync"   '.commit.type_whitelist'
check_config_has_sync "config: pr.title_type_whitelist has sync" '.pr.title_type_whitelist'

# ---------------------------------------------------------------------------
# Static: `sync` present in each hook's hardcoded fallback (so a bare checkout
# without jq/config still accepts it, and fallback doesn't drift from config).
# ---------------------------------------------------------------------------
check_fallback_has_sync() {
  local label="$1" hook="$2"
  # The fallback assignment line is `TYPES="..."` / `PR_TYPES="..."` containing
  # the pipe-delimited literal list. Require a `|sync` (or `sync|`) token in it.
  if grep -E '^\s*(PR_)?TYPES="[^"]*sync[^"]*"' "$hook" >/dev/null 2>&1; then
    mark_pass "$label"
  else
    mark_fail "$label" "sync missing from hardcoded fallback in $(basename "$hook")"
  fi
}
check_fallback_has_sync "fallback: validate-branch-name.sh has sync"   "$BRANCH_HOOK"
check_fallback_has_sync "fallback: validate-commit-format.sh has sync" "$COMMIT_HOOK"
check_fallback_has_sync "fallback: validate-pr-create.sh has sync"     "$PR_HOOK"

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
