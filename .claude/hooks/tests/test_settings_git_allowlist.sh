#!/bin/bash
# The tracked settings file must not grant broad access to a .git directory
# (AgDR-0222). A sandbox or permission rule may name only the exact marker
# file and its temporary file in a git dir. A rule such as `.git/**`, `.git/*`
# or a bare `.git` would let a session write hooks and config.
#
# The test reads the tracked `.claude/settings.json` only. It does not see
# `.claude/settings.local.json` or user settings.

# Isolate from live Claude Code session pin/cache (me2resh/apexyard#1549).
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"

SRC_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
SETTINGS="$SRC_ROOT/.claude/settings.json"

PASS=0
FAIL=0
ok() { echo "PASS [$1]"; PASS=$((PASS + 1)); }
bad() { echo "FAIL [$1]: $2" >&2; FAIL=$((FAIL + 1)); }

if ! command -v jq >/dev/null 2>&1; then
  echo "FAIL: jq is required" >&2
  exit 1
fi

# check_file <settings.json>: prints each offending string on stdout
check_file() {
  local s
  jq -r '.. | strings' "$1" 2>/dev/null | while IFS= read -r s; do
    case "$s" in
      *.git*) ;;
      *) continue ;;
    esac
    # Only path-like rules count. A hook command that merely mentions .git in
    # a longer shell snippet is not a path rule.
    case "$s" in
      *' '*) case "$s" in Write\(*|Edit\(*|MultiEdit\(*|Bash\(*|Read\(*) ;; *) continue ;; esac ;;
    esac
    case "$s" in
      *'**'*|*'.git/*'*|*'.git/'|*'.git'|*'.git)'|*'.git/)') printf '%s\n' "$s"; continue ;;
    esac
    # The only accepted shapes end in the marker or its temporary file.
    if printf '%s\n' "$s" | grep -Eq '\.git/(worktrees/[^/]*/)?apexyard-ticket(\.tmp\.\*)?\)?$'; then continue; fi
    printf '%s\n' "$s"
  done
}

if [ ! -f "$SETTINGS" ]; then
  bad "settings file exists" "$SETTINGS is missing"
else
  bad_rules=$(check_file "$SETTINGS")
  if [ -z "$bad_rules" ]; then ok "the tracked settings grant no broad .git access"; else bad "the tracked settings grant no broad .git access" "$(printf '%s' "$bad_rules" | tr '\n' ' ')"; fi
fi

# The check must catch broad rules and accept the exact marker rules.
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mk() { printf '%s\n' "$2" > "$TMP/$1.json"; }
mk broad1 '{"permissions":{"allow":["Write(workspace/*/.git/**)"]}}'
mk broad2 '{"sandbox":{"filesystem":{"allowWrite":["workspace/p1/.git"]}}}'
mk broad3 '{"sandbox":{"filesystem":{"allowWrite":["workspace/p1/.git/*"]}}}'
mk broad4 '{"sandbox":{"filesystem":{"allowWrite":["/repo/.git/"]}}}'
mk broad5 '{"permissions":{"allow":["Write(.git/hooks/pre-commit)"]}}'
mk exact1 '{"sandbox":{"filesystem":{"allowWrite":["workspace/p1/.git/apexyard-ticket","workspace/p1/.git/apexyard-ticket.tmp.*"]}}}'
mk exact2 '{"sandbox":{"filesystem":{"allowWrite":["workspace/p1/.git/worktrees/wt1/apexyard-ticket"]}}}'
mk none '{"permissions":{"allow":["Bash(git status)"]},"hooks":{"PreToolUse":[{"hooks":[{"command":"bash -c '"'"'ls .git'"'"'"}]}]}}'
for n in broad1 broad2 broad3 broad4 broad5; do
  if [ -n "$(check_file "$TMP/$n.json")" ]; then ok "check flags $n"; else bad "check flags $n" "not flagged"; fi
done
for n in exact1 exact2 none; do
  if [ -z "$(check_file "$TMP/$n.json")" ]; then ok "check accepts $n"; else bad "check accepts $n" "flagged: $(check_file "$TMP/$n.json")"; fi
done

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
