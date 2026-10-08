#!/bin/bash
# No file may read the old ticket marker paths outside the resolver (AgDR-0222).
#
# The old layout kept the active ticket in `.claude/session/current-ticket` and
# `.claude/session/tickets/<project>`. Every reader now goes through
# `_lib-active-ticket.sh`. This test fails when a tracked file other than the
# resolver family names either path. A new reader that bypasses the resolver
# is caught here.
#
# Allowed files:
#   - the resolver and its SessionStart notice (they implement the legacy rule)
#   - /start-ticket (it describes the old-layout marker it also writes)
#   - the /status briefing helper (it keeps the old display rule for a tree
#     without a new marker, and must work in a fork without the hooks)
#   - the ambient tracker guard (when the resolver library is missing, it
#     reads the old markers inline so that it still blocks, not allows)
#   - AgDRs, technical designs and the CHANGELOG (history)
#   - hook tests (their fixtures exercise the legacy rule)
#   - this test

# Isolate from live Claude Code session pin/cache (me2resh/apexyard#1549).
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"

SRC_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$SRC_ROOT" || exit 1

PASS=0
FAIL=0
ok() { echo "PASS [$1]"; PASS=$((PASS + 1)); }
bad() { echo "FAIL [$1]: $2" >&2; FAIL=$((FAIL + 1)); }

PATTERN='session/tickets|current-ticket'
ALLOWED_RX='^(\.claude/hooks/_lib-active-ticket\.sh|\.claude/hooks/warn-legacy-ticket-markers\.sh|\.claude/hooks/block-ambient-tracker-repo\.sh|\.claude/skills/start-ticket/SKILL\.md|\.claude/skills/status/briefing\.sh|CHANGELOG\.md|docs/agdr/.*|docs/technical-designs/.*|\.claude/hooks/tests/.*)$'

# offenders <file list on stdin>: prints each file that matches PATTERN and is not allowed
offenders() {
  local f
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    if printf '%s\n' "$f" | grep -Eq "$ALLOWED_RX"; then continue; fi
    if grep -Eq -- "$PATTERN" "$f" 2>/dev/null; then printf '%s\n' "$f"; fi
  done
}

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1 || [ -z "$(git ls-files 2>/dev/null | head -n 1)" ]; then
  echo "INFO: no git index here, so the tracked-file scan did not run"
  echo "PASS=$PASS FAIL=$FAIL"
  exit 0
fi

found=$(git ls-files | offenders)
if [ -z "$found" ]; then
  ok "no tracked file reads the old marker paths outside the resolver"
else
  bad "no tracked file reads the old marker paths outside the resolver" "$(printf '%s' "$found" | tr '\n' ' ')"
fi

# The scan must catch a new reader. Add one to a scratch tree and scan it.
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/.claude/hooks" "$TMP/docs/agdr"
printf 'cat "$OPS/.claude/session/current-ticket"\n' > "$TMP/.claude/hooks/new-reader.sh"
printf 'tickets live in session/tickets/<project>\n' > "$TMP/notes.md"
printf 'history: current-ticket\n' > "$TMP/docs/agdr/AgDR-9999-x.md"
printf 'clean\n' > "$TMP/.claude/hooks/clean.sh"
caught=$(cd "$TMP" && printf '%s\n' .claude/hooks/new-reader.sh notes.md docs/agdr/AgDR-9999-x.md .claude/hooks/clean.sh | offenders | tr '\n' ' ')
case "$caught" in
  ".claude/hooks/new-reader.sh notes.md ") ok "the scan catches a new reader and ignores history and clean files" ;;
  *) bad "the scan catches a new reader" "caught: [$caught]" ;;
esac

# Every reader the ticket names goes through the resolver or names it.
for f in .claude/hooks/require-active-ticket.sh .claude/hooks/require-migration-ticket.sh \
         .claude/hooks/require-agdr-for-arch-changes.sh .claude/hooks/require-agdr-for-arch-pr.sh \
         .claude/hooks/block-ambient-tracker-repo.sh .claude/skills/status/briefing.sh; do
  if grep -q '_lib-active-ticket.sh' "$f"; then ok "$f uses the resolver"; else bad "$f uses the resolver" "no reference to _lib-active-ticket.sh"; fi
done

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
