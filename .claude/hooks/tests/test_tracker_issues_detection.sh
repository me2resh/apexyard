#!/bin/bash
# Tests for the GitHub-Issues-enabled detection helpers in _lib-tracker.sh
# (#653, AgDR-0071). Run: bash .claude/hooks/tests/test_tracker_issues_detection.sh
#
# Covers the PURE verdict logic exhaustively, plus tracker_check_issues against
# a PATH-mocked `gh` (disabled → warn + rc1; enabled → silent + rc0; non-github
# kind → short-circuit, no gh call, silent + rc0).

set -u

LIB="$(cd "$(dirname "$0")/.." && pwd)/_lib-tracker.sh"
# shellcheck source=/dev/null
. "$LIB"

PASS=0
FAIL=0
check() { # <desc> <got> <want>
  if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: $1 — want '$3' got '$2'"; fi
}

# --- pure verdict logic ------------------------------------------------------
check "gh + false → disabled"      "$(tracker_issues_verdict gh false)"      "disabled"
check "github + false → disabled"  "$(tracker_issues_verdict github false)"  "disabled"
check "gh + true → ok"             "$(tracker_issues_verdict gh true)"       "ok"
check "gh + empty → ok"            "$(tracker_issues_verdict gh '')"         "ok"
check "gh + unknown → ok"          "$(tracker_issues_verdict gh banana)"     "ok"
check "linear + false → skip"      "$(tracker_issues_verdict linear false)"  "skip"
check "jira + false → skip"        "$(tracker_issues_verdict jira false)"    "skip"
check "asana + true → skip"        "$(tracker_issues_verdict asana true)"    "skip"
check "none + false → skip"        "$(tracker_issues_verdict none false)"    "skip"

# --- enable hint -------------------------------------------------------------
check "enable hint" "$(tracker_issues_enable_hint owner/repo)" "gh repo edit owner/repo --enable-issues"

# --- tracker_check_issues with a PATH-mocked gh ------------------------------
MOCK=$(mktemp -d)
mk_gh() { printf '#!/bin/bash\necho "%s"\n' "$1" > "$MOCK/gh"; chmod +x "$MOCK/gh"; }
trap 'rm -rf "$MOCK"' EXIT

# github kind + issues disabled → return 1 and warn on stderr
_TRACKER_KIND_CACHE="gh"
mk_gh false
out=$(PATH="$MOCK:$PATH" tracker_check_issues owner/repo 2>&1); rc=$?
check "disabled → rc 1" "$rc" "1"
if echo "$out" | grep -q "DISABLED"; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: disabled should warn (got: $out)"; fi
if echo "$out" | grep -q "gh repo edit owner/repo --enable-issues"; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: disabled should print enable hint"; fi

# github kind + issues enabled → return 0, silent
mk_gh true
out=$(PATH="$MOCK:$PATH" tracker_check_issues owner/repo 2>&1); rc=$?
check "enabled → rc 0" "$rc" "0"
check "enabled → silent" "$out" ""

# non-github kind → short-circuit: rc 0, silent, gh NOT consulted (mock says false)
_TRACKER_KIND_CACHE="linear"
mk_gh false
out=$(PATH="$MOCK:$PATH" tracker_check_issues owner/repo 2>&1); rc=$?
check "linear → rc 0 (short-circuit)" "$rc" "0"
check "linear → silent" "$out" ""

# empty repo arg → no-op rc 0
_TRACKER_KIND_CACHE="gh"
out=$(PATH="$MOCK:$PATH" tracker_check_issues "" 2>&1); rc=$?
check "empty repo → rc 0" "$rc" "0"

echo ""
echo "tracker-issues-detection: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
