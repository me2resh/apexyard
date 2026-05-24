#!/bin/bash
# Tests for validate-pr-create.sh upstream awareness (me2resh/apexyard#207).
#
# The validator extracts the ticket number from the PR title and confirms it
# exists + is OPEN in the tracker. Before #207 the lookup was origin-only;
# after #207 a missing-in-origin ticket is rechecked against `upstream` when
# that remote is configured. Same short-circuit behavior as the commit-ref
# validator — try origin first, only fall back on miss.
#
# Coverage:
#   - title #N exists in origin → pass (regression)
#   - title #N missing in origin but present in upstream → pass (NEW)
#   - title #N missing in both → block (regression)
#   - title #N exists in origin, upstream unconfigured → pass (no regression)
#   - title #N CLOSED in upstream → block, error names upstream repo
#   - --repo flag overrides origin and is checked first (existing behavior)

set -u

HOOK_SRC="$(cd "$(dirname "$0")/.." && pwd)/validate-pr-create.sh"
# shellcheck source=_lib-mock-gh.sh
source "$(cd "$(dirname "$0")" && pwd)/_lib-mock-gh.sh"
if [ ! -x "$HOOK_SRC" ]; then
  echo "FAIL: hook not found or not executable at $HOOK_SRC" >&2
  exit 1
fi

PASS=0
FAIL=0
FAILED_CASES=""

make_sandbox_fork() {
  local with_upstream="$1"
  local sb
  sb=$(mktemp -d)
  (
    cd "$sb" || exit 1
    git init -q
    git config user.email "test@example.com"
    git config user.name "test"
    git remote add origin git@github.com:fork-org/apexyard.git
    if [ "$with_upstream" = "yes" ]; then
      git remote add upstream git@github.com:me2resh/apexyard.git
    fi
    git checkout -q -b "fix/#207-pr-upstream-test" 2>/dev/null || git checkout -q -B "fix/#207-pr-upstream-test"
    touch onboarding.yaml
    git add onboarding.yaml
    git commit -q -m "init"
  )
  mkdir -p "$sb/.claude/hooks"
  cp "$HOOK_SRC" "$sb/.claude/hooks/validate-pr-create.sh"
  chmod +x "$sb/.claude/hooks/validate-pr-create.sh"
  local src_root
  src_root=$(cd "$(dirname "$0")/../../.." && pwd)
  cp "$src_root/.claude/hooks/_lib-read-config.sh" "$sb/.claude/hooks/_lib-read-config.sh"
  if [ -f "$src_root/.claude/hooks/_lib-tracker.sh" ]; then
    cp "$src_root/.claude/hooks/_lib-tracker.sh" "$sb/.claude/hooks/_lib-tracker.sh"
  fi
  cp "$src_root/.claude/project-config.defaults.json" "$sb/.claude/project-config.defaults.json"
  echo "$sb"
}

# Minimal PR body with the required Testing + Glossary sections so the body
# check isn't what trips the validator. We're testing the ticket-existence
# fallback, not the body parser.
BODY=$'## Summary\nx\n\n## Testing\ny\n\n## Glossary\n| t | d |'

# Build a `gh pr create` command. Pass `with_repo_flag=yes` to include
# `--repo me2resh/apexyard` (forces TRACKER_REPO=me2resh/apexyard regardless
# of origin) — used to test the --repo branch, which is unchanged.
build_cmd() {
  local title="$1" with_repo_flag="${2:-no}" body_file="$3"
  if [ "$with_repo_flag" = "yes" ]; then
    printf 'gh pr create --repo me2resh/apexyard --title "%s" --body-file %s --head fix/#207-pr-upstream-test' "$title" "$body_file"
  else
    printf 'gh pr create --title "%s" --body-file %s --head fix/#207-pr-upstream-test' "$title" "$body_file"
  fi
}

# Helper: write a body file inside the sandbox, then build the command + run.
run_pr_case() {
  local label="$1" with_upstream="$2" title="$3" with_repo_flag="$4" want_rc="$5" want_stderr_regex="$6" exist_setup="${7:-}"
  local sb; sb=$(make_sandbox_fork "$with_upstream")
  mock_gh_install "$sb"
  if [ -n "$exist_setup" ]; then
    eval "$exist_setup"
  fi
  local body_file="$sb/body.md"
  printf '%s' "$BODY" > "$body_file"
  local cmd; cmd=$(build_cmd "$title" "$with_repo_flag" "$body_file")
  local input
  input=$(jq -nc --arg c "$cmd" '{tool_input:{command:$c}}')
  local got_stderr got_rc
  got_stderr=$(cd "$sb" && echo "$input" | bash .claude/hooks/validate-pr-create.sh 2>&1 >/dev/null)
  got_rc=$?
  rm -rf "$sb"

  if [ "$got_rc" != "$want_rc" ]; then
    echo "FAIL [$label]: want rc=$want_rc, got $got_rc (stderr: ${got_stderr:0:300})" >&2
    FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}${label} "; return
  fi
  if [ -n "$want_stderr_regex" ] && ! echo "$got_stderr" | grep -qE "$want_stderr_regex"; then
    echo "FAIL [$label]: stderr did not match /$want_stderr_regex/" >&2
    echo "    stderr: $got_stderr" >&2
    FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}${label} "; return
  fi
  echo "PASS [$label]"
  PASS=$((PASS+1))
}

# ---- Cases --------------------------------------------------------------

# Regression: #N exists in origin, no upstream remote → pass.
run_pr_case "title #N in origin, no upstream → pass" \
  "no" "fix(#42): something" "no" 0 ""

# NEW: #N missing in origin, present in upstream → pass.
run_pr_case "title #N in upstream only → pass (the #207 fix)" \
  "yes" "fix(#150): upstream issue" "no" 0 "" \
  'mock_gh_set_repo_existence "$sb" 150 fork-org/apexyard no
   mock_gh_set_repo_existence "$sb" 150 me2resh/apexyard yes'

# Regression: missing in both → block, error message names both.
run_pr_case "title #N missing in both → block, names both" \
  "yes" "fix(#99999): phantom" "no" 2 "does not.*exist|or upstream" \
  'mock_gh_set_repo_existence "$sb" 99999 fork-org/apexyard no
   mock_gh_set_repo_existence "$sb" 99999 me2resh/apexyard no'

# Regression: origin exists, no upstream configured → pass.
run_pr_case "title #N in origin, upstream unconfigured → pass" \
  "no" "feat(#5): do thing" "no" 0 ""

# CLOSED-in-upstream → block. Tests that the CLOSED error names the upstream
# repo (the one that actually matched) rather than always saying origin.
run_pr_case "title #N CLOSED in upstream → block, error names upstream" \
  "yes" "fix(#321): closed in upstream" "no" 2 "me2resh/apexyard.*CLOSED|CLOSED.*me2resh/apexyard" \
  'mock_gh_set_repo_existence "$sb" 321 fork-org/apexyard no
   mock_gh_set_repo_existence "$sb" 321 me2resh/apexyard yes
   mock_gh_set_state "$sb" 321 CLOSED'

# Existing behavior: --repo me2resh/apexyard makes TRACKER_REPO = upstream
# directly. The upstream-fallback would then be skipped (UPSTREAM_REPO ==
# TRACKER_REPO). Should still pass for an issue that exists in upstream.
run_pr_case "title #N with --repo upstream → pass (upstream IS tracker)" \
  "yes" "fix(#200): explicit upstream" "yes" 0 "" \
  'mock_gh_set_repo_existence "$sb" 200 me2resh/apexyard yes'

# Short-circuit: origin yes, upstream no → upstream not consulted.
# Indirect verification: the case passes because origin matches first.
run_pr_case "origin yes, upstream no → pass (short-circuit)" \
  "yes" "fix(#7): in origin" "no" 0 "" \
  'mock_gh_set_repo_existence "$sb" 7 fork-org/apexyard yes
   mock_gh_set_repo_existence "$sb" 7 me2resh/apexyard no'

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
