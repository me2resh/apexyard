#!/bin/bash
# SessionStart advisory: warn when .cursorignore is missing or does not
# exclude workspace/ on an ApexYard ops fork.
#
# Git ignores workspace/* but Cursor indexes gitignored paths unless
# .cursorignore says otherwise. Without it, every managed clone (and
# node_modules) inflates search and context — regardless of project count.
#
# Non-blocking, exit 0 always. Same shape as check-jq-installed.sh.

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
ops_root=""
if [ -f "$HOOK_DIR/_lib-ops-root.sh" ]; then
  # shellcheck source=/dev/null
  . "$HOOK_DIR/_lib-ops-root.sh"
  ops_root=$(resolve_ops_root "$PWD")
else
  r="$PWD"
  while [ -n "$r" ] && [ "$r" != "/" ]; do
    if [ -f "$r/.apexyard-fork" ]; then
      ops_root="$r"; break
    fi
    if [ -f "$r/onboarding.yaml" ] && [ -f "$r/apexyard.projects.yaml" ]; then
      ops_root="$r"; break
    fi
    r=$(dirname "$r")
  done
fi

if [ -z "$ops_root" ]; then
  exit 0
fi

cursorignore="$ops_root/.cursorignore"
if [ -f "$cursorignore" ] && grep -qE '^[[:space:]]*workspace/' "$cursorignore" 2>/dev/null; then
  exit 0
fi

cat >&2 <<MSG
ApexYard (Cursor): .cursorignore is missing or does not exclude workspace/.
Every clone under workspace/ will be indexed (slow search, high token burn).
Fix: cp templates/cursorignore .cursorignore && git add .cursorignore
Then reload the Cursor window. See docs/cursor-agent-performance.md
MSG

exit 0
