#!/bin/bash
# #1507: AgDR-0196 must record known limits of the merge data scrub.
# Also pin that the three new raw shapes detect, while ordinary data does not.
set -u

# Isolate from live Claude Code session pin/cache (me2resh/apexyard#1549).
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"


ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
HOOKS=${HOOKS_OVERRIDE:-$ROOT/.claude/hooks}
AGDR=${AGDR_0196_OVERRIDE:-$ROOT/docs/agdr/AgDR-0196-merge-command-data-and-library-integrity.md}
TMP=$(mktemp -d)
export GIT_CEILING_DIRECTORIES="$TMP"
trap 'rm -rf "$TMP"' EXIT
PASS=0
FAIL=0

# shellcheck source=/dev/null
. "$HOOKS/_lib-extract-pr.sh"

check() {
  local label="$1" want="$2" cmd="$3" got=no
  if is_merge_command "$cmd"; then got=yes; fi
  if [ "$got" = "$want" ]; then
    printf 'PASS [%s]\n' "$label"
    PASS=$((PASS + 1))
  else
    printf 'FAIL [%s]: want %s, got %s\n' "$label" "$want" "$got" >&2
    FAIL=$((FAIL + 1))
  fi
}

# Documentation gate: Known limits names both residual cases.
if [ -f "$AGDR" ] && grep -q '^## Known limits$' "$AGDR"; then
  printf 'PASS [AgDR-0196 has Known limits heading]\n'
  PASS=$((PASS + 1))
else
  printf 'FAIL [AgDR-0196 has Known limits heading]\n' >&2
  FAIL=$((FAIL + 1))
fi
if [ -f "$AGDR" ] && grep -qi 'split with quotes' "$AGDR"; then
  printf 'PASS [Known limits mentions split with quotes]\n'
  PASS=$((PASS + 1))
else
  printf 'FAIL [Known limits mentions split with quotes]\n' >&2
  FAIL=$((FAIL + 1))
fi
if [ -f "$AGDR" ] && grep -qi 'write-then-run' "$AGDR"; then
  printf 'PASS [Known limits mentions write-then-run]\n'
  PASS=$((PASS + 1))
else
  printf 'FAIL [Known limits mentions write-then-run]\n' >&2
  FAIL=$((FAIL + 1))
fi

# Must-detect: the three #1507 shapes.
check 'raw scan for unquoted ~[' yes "echo 'gh pr merge 7' ~[demo]"
check 'raw scan for zshenv redirect' yes "echo 'gh pr merge 7' > ~/.zshenv"
check 'raw scan for git hooks redirect' yes "echo 'gh pr merge 7' >> .git/hooks/pre-commit"
check 'raw scan for grep --filter' yes "grep --filter='gh pr merge 7' notes.txt"
check 'raw scan for grep --pager' yes "grep --pager=sh 'gh pr merge 7' notes.txt"
check 'raw scan for grep --view' yes "grep --view ./show.sh 'gh pr merge 7' notes.txt"
check 'raw scan for grep --format-open' yes "grep --format-open=edit 'gh pr merge 7' notes.txt"

# Read-only data cases must stay quiet.
check 'grep data still quiet' no "grep 'gh pr merge 7' notes.txt"
check 'cat data still quiet' no "cat 'gh pr merge 7'"
check 'echo data still quiet' no "echo 'gh pr merge 7'"

# Known-limit pins: these stay quiet by design (documented, not closed here).
check 'known limit: write to tmp is data' no "echo 'gh pr merge 7' > /tmp/merge-notes"
check 'known limit: quoted ~[ is data' no "echo 'gh pr merge 7' '~[demo]'"

printf 'RESULT: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
