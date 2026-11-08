#!/bin/bash
# The tracked settings file denies reading .env files at the tool boundary
# (#1993). The rules start with `//`, so they match from the filesystem root
# and cover every folder, not only the folder the session runs in.
#
# No deny rule may name the review session folder. When the Bash sandbox is
# on, Claude Code adds Edit deny rules to the sandbox write-deny list, and the
# approval skills write their markers with shell commands.
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
for rule in 'Read(//**/.env)' 'Read(//**/.env.*)'; do
  if has_deny "$rule"; then ok "deny $rule"; else bad "deny $rule" "rule missing from permissions.deny"; fi
done

# Every env rule must start at the filesystem root.
relative=$(jq -r '(.permissions.deny // [])[] | select(test("\\.env") and (startswith("Read(//") | not))' "$SETTINGS")
if [ -z "$relative" ]; then ok "env rules start at the filesystem root"; else bad "env rules start at the filesystem root" "relative rule: $relative"; fi

# No deny rule may name the review session folder (sandbox write-deny).
reviews=$(jq -r '(.permissions.deny // [])[] | select(test("session/reviews"))' "$SETTINGS")
if [ -z "$reviews" ]; then ok "no deny rule names session/reviews"; else bad "no deny rule names session/reviews" "rule: $reviews"; fi

# The rules must not turn into allow rules by mistake.
if jq -e '(.permissions.allow // []) | map(select(test("\\.env"))) | length == 0' "$SETTINGS" >/dev/null 2>&1; then
  ok "no allow rule for env files"
else
  bad "no allow rule for env files" "an allow rule names .env"
fi

echo "PASS: $PASS   FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
