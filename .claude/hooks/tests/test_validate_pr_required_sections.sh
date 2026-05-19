#!/bin/bash
# Tests for the required-PR-sections check in validate-pr-create.sh (#113).
#
# Each case:
#   - builds an isolated sandbox with the shared config lib + shipped defaults
#   - writes a body file with the case-specific content
#   - pipes a synthetic PreToolUse JSON blob with `gh pr create --body-file <path>`
#   - asserts exit code + stderr contents
#
# The sandbox installs a fake `gh` on PATH (see _lib-mock-gh.sh) so the
# validator's `gh issue view` call against the PR-title's referenced issue
# returns synthetic OPEN data — no live-tracker dependency. See
# me2resh/apexyard#154.
#
# Exit 0 if all cases pass; exit 1 on first failure.

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

make_sandbox() {
  local sb
  sb=$(mktemp -d)
  (
    cd "$sb" || exit 1
    git init -q
    git config user.email "test@example.com"
    git config user.name "test"
    git checkout -q -b chore/GH-113-test 2>/dev/null || git checkout -q -B chore/GH-113-test
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

run_case() {
  local label="$1" body_content="$2" want_rc="$3" want_stderr_regex="$4"
  local sb; sb=$(make_sandbox)
  mock_gh_install "$sb"
  local body_file="$sb/body.md"
  printf '%s' "$body_content" > "$body_file"
  local cmd="gh pr create --repo me2resh/apexyard --title 'chore(#113): test' --body-file $body_file"
  local input
  input=$(jq -nc --arg c "$cmd" '{tool_input:{command:$c}}')
  local got_stderr got_rc
  got_stderr=$(cd "$sb" && echo "$input" | bash .claude/hooks/validate-pr-create.sh 2>&1 >/dev/null)
  got_rc=$?
  rm -rf "$sb"

  if [ "$got_rc" != "$want_rc" ]; then
    echo "FAIL [$label]: want rc=$want_rc, got $got_rc (stderr: ${got_stderr:0:200})" >&2
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

run_case "body with Summary + Testing + Glossary → pass" \
  "## Summary
x

## Testing
y

## Glossary
| t | d |" \
  0 ""

run_case "body missing Testing → block" \
  "## Summary
x

## Glossary
| t | d |" \
  2 "missing required '## Testing' section"

run_case "body missing Glossary → block" \
  "## Summary
x

## Testing
y" \
  2 "missing required '## Glossary' section"

run_case "body missing both → block with Testing message" \
  "just a plain summary" \
  2 "missing required '## Testing' section"

run_case "body missing both → block also names Glossary" \
  "just a plain summary" \
  2 "missing required '## Glossary' section"

run_case "skip marker bypasses with warning" \
  "no sections here
<!-- pr-sections: skip -->" \
  0 "pr-sections check bypassed by skip marker"

run_case "headings are case-insensitive" \
  "## testing
y

## glossary
x" \
  0 ""

run_case "H3 headings do NOT satisfy the check (require H2)" \
  "### Testing
y
### Glossary
x" \
  2 "missing required '## Testing' section"

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
