#!/bin/bash
# Tests for the `gh api` matcher refinement in require-skill-for-issue-create.sh
# (me2resh/apexyard#382).
#
# The original `gh api repos/` matcher is a pure substring prefix, so read-only
# GETs like `gh api repos/<owner>/<repo>/contents/README.md` were blocked as if
# they were ticket-create POSTs. The fix downgrades the match to a no-op unless
# the command BOTH targets an `/issues` endpoint AND has a write signal
# (-X POST / --method POST / -f / -F / --field / --raw-field / --input).
#
# Mirrors the sandbox shape of test_require_skill_for_issue_create.sh:
#   - per-case sandbox with onboarding.yaml + empty registry + hook + libs
#   - synthetic PreToolUse Bash JSON via jq
#   - assert exit code only (no stderr-regex needed — the existing test covers that)

set -u

SRC_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
HOOK_SRC="$SRC_ROOT/.claude/hooks/require-skill-for-issue-create.sh"
LIB_OPS="$SRC_ROOT/.claude/hooks/_lib-ops-root.sh"
LIB_CFG="$SRC_ROOT/.claude/hooks/_lib-read-config.sh"
DEFAULTS="$SRC_ROOT/.claude/project-config.defaults.json"

for f in "$HOOK_SRC" "$LIB_CFG" "$DEFAULTS"; do
  if [ ! -f "$f" ]; then
    echo "FAIL: required source missing: $f" >&2
    exit 1
  fi
done
HAVE_LIB_OPS=0
[ -f "$LIB_OPS" ] && HAVE_LIB_OPS=1

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
    : > onboarding.yaml
    : > apexyard.projects.yaml
    git add onboarding.yaml apexyard.projects.yaml
    git commit -q -m "init"
  )
  mkdir -p "$sb/.claude/hooks" "$sb/.claude/session"
  cp "$HOOK_SRC" "$sb/.claude/hooks/require-skill-for-issue-create.sh"
  [ "$HAVE_LIB_OPS" = "1" ] && cp "$LIB_OPS" "$sb/.claude/hooks/_lib-ops-root.sh"
  cp "$LIB_CFG" "$sb/.claude/hooks/_lib-read-config.sh"
  cp "$DEFAULTS" "$sb/.claude/project-config.defaults.json"
  chmod +x "$sb/.claude/hooks/require-skill-for-issue-create.sh"
  echo "$sb"
}

run_case() {
  local label="$1" want_rc="$2" input="$3" sb="$4"
  local got_rc
  (cd "$sb" && echo "$input" | bash .claude/hooks/require-skill-for-issue-create.sh >/dev/null 2>&1)
  got_rc=$?
  rm -rf "$sb"

  if [ "$got_rc" != "$want_rc" ]; then
    echo "FAIL [$label]: want rc=$want_rc, got $got_rc" >&2
    FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}${label} "; return
  fi
  echo "PASS [$label]"
  PASS=$((PASS+1))
}

# --- Bug fix: read-only GETs against /contents/... must NOT be blocked -----

sb=$(make_sandbox)
in=$(jq -nc --arg c "gh api repos/o/r/contents/README.md" \
  '{tool_name:"Bash", tool_input:{command:$c}}')
run_case "GET on /contents is no-op (bug fix)" 0 "$in" "$sb"

# --- Bug fix: reading a single issue must NOT be blocked --------------------
# Endpoint contains /issues but there is no write signal (no -f / -X POST /
# --method POST etc.), so it stays a no-op.

sb=$(make_sandbox)
in=$(jq -nc --arg c "gh api repos/o/r/issues/42" \
  '{tool_name:"Bash", tool_input:{command:$c}}')
run_case "GET on /issues/<id> is no-op (no write signal)" 0 "$in" "$sb"

# --- POST on /pulls (PR create) must NOT be blocked — not an /issues endpoint

sb=$(make_sandbox)
in=$(jq -nc --arg c "gh api repos/o/r/pulls -X POST -f title=x" \
  '{tool_name:"Bash", tool_input:{command:$c}}')
run_case "POST on /pulls is no-op (not an /issues endpoint)" 0 "$in" "$sb"

# --- POST on /issues via --method must STILL be blocked --------------------

sb=$(make_sandbox)
in=$(jq -nc --arg c "gh api repos/o/r/issues --method POST -f title=x" \
  '{tool_name:"Bash", tool_input:{command:$c}}')
run_case "POST on /issues via --method is blocked" 2 "$in" "$sb"

# --- POST on /issues via field flag must STILL be blocked -------------------
# `-f`/`-F` flags imply POST in gh-cli — gh switches from default GET when
# fields are supplied.

sb=$(make_sandbox)
in=$(jq -nc --arg c "gh api repos/o/r/issues -f title=x" \
  '{tool_name:"Bash", tool_input:{command:$c}}')
run_case "POST on /issues via -f field flag is blocked" 2 "$in" "$sb"

# --- gh issue create still blocks (refinement only narrows the gh api case) -

sb=$(make_sandbox)
in=$(jq -nc --arg c "gh issue create --title x" \
  '{tool_name:"Bash", tool_input:{command:$c}}')
run_case "gh issue create still blocked (refinement only narrows gh api)" 2 "$in" "$sb"

# --- Summary --------------------------------------------------------------

echo ""
echo "==================================="
echo "  PASS: $PASS   FAIL: $FAIL"
echo "==================================="
if [ "$FAIL" -gt 0 ]; then
  echo "Failed: $FAILED_CASES" >&2
  exit 1
fi
exit 0
