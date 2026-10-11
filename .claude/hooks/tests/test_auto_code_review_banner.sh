#!/bin/bash
# Tests for the auto-code-review.sh banner size (me2resh/apexyard#1625).
# The PostToolUse banner must stay at 300 bytes or fewer, keep exit 2, keep
# the pending-review marker, and carry the CI-order instruction.
set -u

# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"

SRC_ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/apexyard-banner.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/.claude/hooks"
git -C "$TMP" init -q
cp "$SRC_ROOT"/.claude/hooks/auto-code-review.sh "$TMP/.claude/hooks/"
cp "$SRC_ROOT"/.claude/hooks/_lib-command-scrub.sh "$TMP/.claude/hooks/"

fail=0
check() {
  if [ "$2" = ok ]; then echo "PASS: $1"; else echo "FAIL: $1" >&2; fail=1; fi
}

run_hook() {
  local input
  input=$(jq -cn --arg o "$1" '{tool_name:"Bash",tool_input:{command:"gh pr create --title x"},tool_response:{stdout:$o}}')
  # Capture stderr only: the banner goes to stderr.
  # shellcheck disable=SC2069
  (cd "$TMP" && printf '%s' "$input" | "$TMP/.claude/hooks/auto-code-review.sh" 2>&1 >/dev/null)
}

out=$(run_hook "https://github.com/acme/app/pull/123456")
rc=$?
size=$(printf '%s' "$out" | wc -c | tr -d ' ')

# The subshell in run_hook returns the hook's exit status through $(...).
if [ "$rc" -eq 2 ]; then check "exit code is 2" ok; else check "exit code is 2 (got $rc)" no; fi
if [ "$size" -le 300 ]; then check "banner is at most 300 bytes ($size)" ok; else check "banner is at most 300 bytes (got $size)" no; fi
if [ -f "$TMP/.claude/session/pending-reviews/123456" ]; then check "pending-review marker written" ok; else check "pending-review marker written" no; fi
case "$out" in *"wait for green CI with a Monitor"*) check "banner names the Monitor wait" ok ;; *) check "banner names the Monitor wait" no ;; esac
case "$out" in *"/code-review 123456"*) check "banner names /code-review" ok ;; *) check "banner names /code-review" no ;; esac
case "$out" in *"never review"*) check "banner keeps the build-agent warning" ok ;; *) check "banner keeps the build-agent warning" no ;; esac

# No PR number in the output: the fallback text must still fit.
out=$(run_hook "done")
size=$(printf '%s' "$out" | wc -c | tr -d ' ')
if [ "$size" -le 300 ]; then check "fallback banner is at most 300 bytes ($size)" ok; else check "fallback banner is at most 300 bytes (got $size)" no; fi

exit "$fail"
