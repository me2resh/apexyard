#!/bin/bash
# The tracked settings file denies two things at the tool boundary (#1993):
# reading .env files with the Read tool, and editing review markers with the
# Edit tool. Review bodies stay writable, because Rex and Hakim write them with
# the Write tool. Markers are written by shell helpers, which these rules do
# not cover.
#
# The test reads the tracked `.claude/settings.json` only.

# Isolate from live Claude Code session pin/cache (me2resh/apexyard#1549).
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"

SRC_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
SETTINGS="$SRC_ROOT/.claude/settings.json"

PASS=0
FAIL=0
ok() { echo "PASS [$1]"; PASS=$((PASS + 1)); }
bad() { echo "FAIL [$1]: $2" >&2; FAIL=$((FAIL + 1)); }

if jq -e . "$SETTINGS" >/dev/null 2>&1; then ok "settings is valid JSON"; else bad "settings is valid JSON" "jq could not parse $SETTINGS"; fi

has_deny() {
  jq -e --arg rule "$1" '(.permissions.deny // []) | index($rule) != null' "$SETTINGS" >/dev/null 2>&1
}
for rule in 'Read(**/.env)' 'Read(**/.env.*)' 'Edit(**/.claude/session/reviews/*.approved)'; do
  if has_deny "$rule"; then ok "deny $rule"; else bad "deny $rule" "rule missing from permissions.deny"; fi
done

# No deny rule may cover the review-body folder or the whole reviews tree.
broad=$(jq -r '(.permissions.deny // [])[] | select(test("reviews/(\\*\\*|bodies)|reviews/?\\)"))' "$SETTINGS")
if [ -z "$broad" ]; then ok "review bodies stay writable"; else bad "review bodies stay writable" "broad rule: $broad"; fi

# The rules must not turn into allow rules by mistake.
if jq -e '(.permissions.allow // []) | map(select(test("\\.env|session/reviews"))) | length == 0' "$SETTINGS" >/dev/null 2>&1; then
  ok "no allow rule for env files or markers"
else
  bad "no allow rule for env files or markers" "an allow rule names .env or session/reviews"
fi

echo "PASS: $PASS   FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
