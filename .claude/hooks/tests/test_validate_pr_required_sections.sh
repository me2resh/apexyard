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

# ===========================================================================
# me2resh/apexyard#1058 (residual of #1048, reported by @Ref34t) — the hook
# must not report what a file contains when it could not read that file.
#
# #1041 fixed the common trigger (a quoted --body-file path was mis-extracted),
# but not the misdiagnosis behind it: when the body file cannot be read, the
# hook warns "not readable ... section check may miss content" and then blocks
# saying '## Testing' and '## Glossary' are MISSING — a claim about the file's
# contents, drawn from a haystack it never read.
#
# The stated reason is the defect, not the blocking. These cases assert the
# hook still fails closed, but names the real cause.
#
# `run_case_missing_file` points --body-file at a path that does not exist,
# which is what a typo, a path relative to a directory the hook could not
# infer, or a permissions problem all look like from inside the hook.
# ===========================================================================

run_case_missing_file() {
  local label="$1" want_rc="$2" want_stderr_regex="$3" reject_stderr_regex="${4:-}"
  local sb; sb=$(make_sandbox)
  mock_gh_install "$sb"
  local missing="$sb/definitely-not-here-1058.md"
  local cmd="gh pr create --repo me2resh/apexyard --title 'chore(#113): test' --body-file $missing"
  local input; input=$(jq -nc --arg c "$cmd" '{tool_input:{command:$c}}')
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
  if [ -n "$reject_stderr_regex" ] && echo "$got_stderr" | grep -qE "$reject_stderr_regex"; then
    echo "FAIL [$label]: stderr WRONGLY matched /$reject_stderr_regex/ (asserting a claim about a file it could not read)" >&2
    echo "    stderr: $got_stderr" >&2
    FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}${label} "; return
  fi
  echo "PASS [$label]"
  PASS=$((PASS+1))
}

# Same as run_case_missing_file, but the caller supplies the (nonexistent)
# path verbatim — used to exercise paths containing shell/printf metacharacters.
run_case_missing_file_path() {
  local label="$1" missing="$2" want_rc="$3" want_stderr_regex="$4" reject_stderr_regex="${5:-}"
  local sb; sb=$(make_sandbox)
  mock_gh_install "$sb"
  local cmd="gh pr create --repo me2resh/apexyard --title 'chore(#113): test' --body-file $missing"
  local input; input=$(jq -nc --arg c "$cmd" '{tool_input:{command:$c}}')
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
  if [ -n "$reject_stderr_regex" ] && echo "$got_stderr" | grep -qE "$reject_stderr_regex"; then
    echo "FAIL [$label]: stderr WRONGLY matched /$reject_stderr_regex/" >&2
    FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}${label} "; return
  fi
  echo "PASS [$label]"
  PASS=$((PASS+1))
}

# The core defect: no section claim may be made about an unread file.
run_case_missing_file "#1058: unreadable body-file does NOT claim '## Testing' is missing" \
  2 "" "missing required '## Testing' section"

run_case_missing_file "#1058: unreadable body-file does NOT claim '## Glossary' is missing" \
  2 "" "missing required '## Glossary' section"

# It must still fail closed, and the message must name the real cause so the
# fix is discoverable from the output (the whole point of @Ref34t's report:
# the old message sent the author to edit a body that was never the problem).
run_case_missing_file "#1058: unreadable body-file blocks (fail closed, not permissive)" \
  2 "" ""

# These two assert the NEW blocking message specifically, not the pre-existing
# "not readable" WARN — matching the WARN would pass before and after the fix
# and therefore prove nothing.
run_case_missing_file "#1058: the block names the unreadable body-file as the cause" \
  2 "PR body file could not be read" ""

run_case_missing_file "#1058: the block quotes the offending path" \
  2 "PR body file could not be read:.*definitely-not-here-1058\.md" ""

# The message must NAME the sections it did not verify. An earlier draft said
# "the sections above", which referred to nothing — this branch replaces the
# per-section list rather than following it.
run_case_missing_file "#1058: the block names the sections it could not verify" \
  2 "UNVERIFIED, not missing: ## Testing, ## Glossary" ""

# A '%' in the body-file path must survive into the message. `printf "$ERRORS"`
# treated the accumulated text as a FORMAT STRING, so a path containing '%s'
# or a trailing '%' printed a DIFFERENT path and silently swallowed the
# guidance lines after it. Caught by Rex on PR #1060; fixed with `printf '%b'`.
# A typo'd path is precisely the scenario this whole branch exists to serve,
# so a path-shaped typo corrupting the message is not acceptable.
run_case_missing_file_path "#1058: a '%' in the body-file path does not corrupt the message" \
  '/tmp/nope%s-100%.md' 2 "PR body file could not be read: /tmp/nope%s-100%\.md" ""

# Uses the SAME path shape as the case above deliberately: a lone '%d' still
# left the guidance lines intact pre-fix (printf substituted 0 and carried on),
# so it proved nothing. The '%s' + trailing-'%' shape is what actually
# truncated the format and swallowed everything after it.
run_case_missing_file_path "#1058: guidance lines survive a '%' path" \
  '/tmp/nope%s-100%.md' 2 "Fix the path \(check for a typo" ""

# ---- No-regression guards for #1058 -------------------------------------
# The fix must not make the hook permissive. A body the hook CAN read and
# which genuinely lacks a section must still be blocked with the section
# message — that is the check's actual job, and the one thing a careless
# "just skip when unreadable" fix could quietly destroy.

run_case "#1058 guard: readable body genuinely missing Testing still blocks with the section message" \
  "## Summary
x

## Glossary
| t | d |" \
  2 "missing required '## Testing' section"

run_case "#1058 guard: readable complete body still passes" \
  "## Summary
x

## Testing
y

## Glossary
| t | d |" \
  0 ""

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
