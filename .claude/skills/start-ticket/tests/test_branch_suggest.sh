#!/bin/bash
# Tests for _lib-branch-suggest.sh — the branch name /start-ticket suggests
# (me2resh/apexyard#2083).
#
# Before this lib, step 3 of /start-ticket described the shape in prose and let
# the agent assemble it. That cannot express a tracker-native name such as
# Jira's "Create branch" output, and it gave no way to test the result.
#
# The load-bearing cases:
#
#   - no template configured -> today's shape, slug capped at 40
#   - a template set        -> rendered, {title_slug} NOT capped
#   - an unknown token      -> reported, built-in shape returned (a typo must
#                              not stop a ticket from starting)
#
# Exit 0 if all cases pass; 1 on first failure.

set -u

# Isolate from live Claude Code session pin/cache (me2resh/apexyard#1549).
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../../../hooks/tests" && pwd)/_test-session-isolation.sh"

SRC_ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"
LIB_CONFIG_SRC="$SRC_ROOT/.claude/hooks/_lib-read-config.sh"
LIB_SUGGEST_SRC="$SRC_ROOT/.claude/hooks/_lib-branch-suggest.sh"
DEFAULTS_SRC="$SRC_ROOT/.claude/project-config.defaults.json"

for f in "$LIB_CONFIG_SRC" "$LIB_SUGGEST_SRC" "$DEFAULTS_SRC"; do
  if [ ! -f "$f" ]; then
    echo "FAIL: required source missing: $f" >&2
    exit 1
  fi
done

PASS=0
FAIL=0
FAILED_CASES=""

# make_sandbox [project-config.json content]
make_sandbox() {
  local config="${1:-}"
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
  )
  mkdir -p "$sb/.claude/hooks"
  cp "$DEFAULTS_SRC" "$sb/.claude/project-config.defaults.json"
  if [ -n "$config" ]; then
    printf '%s\n' "$config" > "$sb/.claude/project-config.json"
  fi
  echo "$sb"
}

# call_suggest <sandbox> <id> <title> [forced type] -> stdout, stderr in $ERR
# A fresh bash per call: config_get caches the merged config per process, so
# reusing one process across sandboxes would leak the first config into later
# cases.
ERR=""
call_suggest() {
  local sb="$1" id="$2" title="$3" forced="${4:-}"
  local errfile out rc
  errfile=$(mktemp)
  out=$(cd "$sb" && bash -c '
    lib_root="$1"; id="$2"; title="$3"; forced="${4:-}"
    . "$lib_root/.claude/hooks/_lib-read-config.sh"
    . "$lib_root/.claude/hooks/_lib-branch-suggest.sh"
    if [ -n "$forced" ]; then
      branch_suggest "$id" "$title" "$forced"
    else
      branch_suggest "$id" "$title"
    fi
  ' _ "$SRC_ROOT" "$id" "$title" "$forced" 2>"$errfile")
  rc=$?
  ERR=$(cat "$errfile")
  rm -f "$errfile"
  printf '%s\n' "$out"
  return "$rc"
}

# run_case <label> <id> <title> <want> [config] [forced type] [want stderr substring]
run_case() {
  local label="$1" id="$2" title="$3" want="$4"
  local config="${5:-}" forced="${6:-}" want_msg="${7:-}"
  local sb got rc outfile
  sb=$(make_sandbox "$config")
  outfile=$(mktemp)
  call_suggest "$sb" "$id" "$title" "$forced" > "$outfile"
  rc=$?
  got=$(cat "$outfile")
  rm -f "$outfile"
  rm -rf "$sb"

  if [ "$rc" -ne 0 ]; then
    echo "FAIL [$label]: want rc=0, got $rc" >&2
    echo "    stderr: ${ERR:0:300}" >&2
    FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}${label} "
    return
  fi
  if [ "$got" != "$want" ]; then
    echo "FAIL [$label]:" >&2
    echo "    want: $want" >&2
    echo "    got:  $got" >&2
    FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}${label} "
    return
  fi
  if [ -n "$want_msg" ] && ! printf '%s' "$ERR" | grep -qF -- "$want_msg"; then
    echo "FAIL [$label]: stderr does not contain: $want_msg" >&2
    echo "    stderr: ${ERR:0:300}" >&2
    FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}${label} "
    return
  fi
  echo "PASS [$label]"
  PASS=$((PASS+1))
}

JIRA_TEMPLATE='{"branch":{"suggested_template":"{id}-{title_slug}"}}'
TYPED_TEMPLATE='{"branch":{"suggested_template":"{type}/{id}-{title_slug}"}}'
UNKNOWN_TEMPLATE='{"branch":{"suggested_template":"{id}-{nope}"}}'
EMPTY_TEMPLATE='{"branch":{"suggested_template":""}}'

# -- Default shape: unchanged when no template is configured ---------------

run_case "default shape uses type/id/slug" \
  "GH-2083" "[Feature] Configurable branch-name shapes" \
  "feature/GH-2083-configurable-branch-name-shapes"

run_case "default slug is capped at 40 characters" \
  "GH-2083" "[Feature] Configurable branch-name shapes in validate-branch-name.sh for tracker native names" \
  "feature/GH-2083-configurable-branch-name-shapes-in-valid"

run_case "default shape with an explicit empty template" \
  "GH-2083" "[Feature] Configurable branch-name shapes" \
  "feature/GH-2083-configurable-branch-name-shapes" "$EMPTY_TEMPLATE"

# -- Type guessing ---------------------------------------------------------

run_case "[Bug] maps to fix" \
  "GH-1" "[Bug] Login fails on retry" "fix/GH-1-login-fails-on-retry"

run_case "[Docs] maps to docs" \
  "GH-2" "[Docs] Update the readme" "docs/GH-2-update-the-readme"

run_case "[Chore] maps to chore" \
  "GH-3" "[Chore] Bump deps" "chore/GH-3-bump-deps"

run_case "unknown prefix defaults to feature" \
  "GH-4" "Something else entirely" "feature/GH-4-something-else-entirely"

run_case "explicit type wins over the title prefix" \
  "GH-5" "[Bug] Login fails on retry" "fix/GH-5-login-fails-on-retry" "" "fix"

# -- Slug rules ------------------------------------------------------------

run_case "stopwords are trimmed from the edges" \
  "GH-6" "[Feature] The Quick Fix" "feature/GH-6-quick-fix"

run_case "punctuation and underscores collapse to dashes" \
  "GH-7" "[Fix] Fix: cart_total (again!)" "fix/GH-7-fix-cart-total-again"

run_case "an all-stopword title leaves no trailing dash" \
  "GH-8" "[Feature] The And" "feature/GH-8"

# -- Configured template ---------------------------------------------------

run_case "Jira-style template drops the type/ prefix" \
  "ABC-123" "[Feature] Add login" "ABC-123-add-login" "$JIRA_TEMPLATE"

run_case "template keeps the type when it asks for it" \
  "ABC-123" "[Bug] Add login" "fix/ABC-123-add-login" "$TYPED_TEMPLATE"

run_case "template {title_slug} is not capped at 40 characters" \
  "ABC-123" "[Feature] Configurable branch-name shapes in validate-branch-name.sh for tracker native names" \
  "ABC-123-configurable-branch-name-shapes-in-validate-branch-name-sh-for-tracker-native-names" \
  "$JIRA_TEMPLATE"

# -- Bad template: reported, but never blocks the ticket -------------------

run_case "unknown token is reported and the built-in shape is returned" \
  "ABC-123" "[Feature] Add login" "feature/ABC-123-add-login" \
  "$UNKNOWN_TEMPLATE" "" "unknown token"

# -- Rendered template must be a valid ref; otherwise fall back ------------

SLUG_FIRST='{"branch":{"suggested_template":"{title_slug}-{id}"}}'
TYPE_SLASH='{"branch":{"suggested_template":"{type}/{title_slug}"}}'
SPACED='{"branch":{"suggested_template":"{id} {title_slug}"}}'
DASH_LEAD='{"branch":{"suggested_template":"-{id}"}}'
UNCLOSED='{"branch":{"suggested_template":"{id}-{title_slug"}}'
DOTDOT='{"branch":{"suggested_template":"x/../{id}"}}'

run_case "empty slug with a slug-first template falls back" \
  "ABC-123" "[Feature] ***" "feature/ABC-123" "$SLUG_FIRST" "" "invalid branch name"

run_case "empty slug with {type}/{title_slug} falls back" \
  "ABC-123" "[Feature] ***" "feature/ABC-123" "$TYPE_SLASH" "" "invalid branch name"

run_case "a space in the template falls back" \
  "ABC-123" "[Feature] Add login" "feature/ABC-123-add-login" "$SPACED" "" "invalid branch name"

run_case "a leading dash falls back" \
  "ABC-123" "[Feature] Add login" "feature/ABC-123-add-login" "$DASH_LEAD" "" "invalid branch name"

run_case "an unclosed brace falls back" \
  "ABC-123" "[Feature] Add login" "feature/ABC-123-add-login" "$UNCLOSED" "" "invalid branch name"

run_case "dot-dot in the template falls back" \
  "ABC-123" "[Feature] Add login" "feature/ABC-123-add-login" "$DOTDOT" "" "invalid branch name"

# -- Hostile titles are data: never evaluated, always cleaned --------------

HOSTILE_DIR=$(mktemp -d)
run_case "command substitution in a title is not run" \
  "GH-9" "[Fix] Crash \$(touch $HOSTILE_DIR/pwned) now" "fix/GH-9-crash-touch-$(printf '%s' "$HOSTILE_DIR" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//')-pwned-now"
if [ -e "$HOSTILE_DIR/pwned" ]; then
  echo "FAIL [title command substitution created a file]" >&2
  FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}title-exec "
else
  echo "PASS [title command substitution created no file]"
  PASS=$((PASS+1))
fi
rm -rf "$HOSTILE_DIR"

run_case "backticks and a double quote are cleaned" \
  "GH-10" '[Bug] `make clean` fails "again"' "fix/GH-10-make-clean-fails-again"

run_case "a leading dash and dot-dot in a title are cleaned" \
  "GH-11" "[Feature] --../etc@{x}" "feature/GH-11-etc-x"

run_case "invalid UTF-8 does not truncate the slug" \
  "GH-12" "$(printf '[Feature] Add \377 login now')" "feature/GH-12-add-login-now"

# '&' is not a valid ref character, so the name falls back. The point is that
# it is substituted literally, not as the matched token (bash 5.2).
run_case "ampersand in the id is literal, then rejected as a ref" \
  "A&B-1" "[Feature] Add login" "feature/A&B-1-add-login" "$JIRA_TEMPLATE" "" "invalid branch name"

# -- SKILL.md never puts the issue title on a command line -----------------

if awk '/^```/{f=!f; next} f' "$SRC_ROOT/.claude/skills/start-ticket/SKILL.md" | grep -q '<issue title>'; then
  echo "FAIL [no fenced SKILL.md block holds <issue title>]" >&2
  FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}skill-title "
else
  echo "PASS [no fenced SKILL.md block holds <issue title>]"
  PASS=$((PASS+1))
fi

# -- Missing id is a caller bug, not a config problem ----------------------

sb=$(make_sandbox)
call_suggest "$sb" "" "[Feature] Add login" >/dev/null
rc=$?
rm -rf "$sb"
if [ "$rc" -eq 2 ]; then
  echo "PASS [missing ticket id exits 2]"
  PASS=$((PASS+1))
else
  echo "FAIL [missing ticket id exits 2]: got rc=$rc" >&2
  FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}missing-id "
fi

# -- Summary ---------------------------------------------------------------

echo
echo "passed: $PASS   failed: $FAIL"
if [ "$FAIL" -ne 0 ]; then
  echo "failed cases: $FAILED_CASES" >&2
  exit 1
fi
exit 0
