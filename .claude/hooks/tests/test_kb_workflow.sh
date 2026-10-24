#!/bin/bash
# Static checks for the knowledge-base workflow and related docs.
set -u

# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"

TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
WF="$REPO_ROOT/.github/workflows/kb.yml"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1 — $2"; }

[ -f "$WF" ] && pass "workflow exists" || fail "workflow exists" "missing"

grep -q 'push:' "$WF" && pass "trigger push" || fail "trigger push" ""
grep -q 'schedule:' "$WF" && pass "trigger schedule" || fail "trigger schedule" ""

# freshness job has pull-requests: write
awk '
  /^  freshness:/ { in_f=1 }
  in_f && /^  [a-z]/ && !/^  freshness:/ { in_f=0 }
  in_f && /pull-requests:[[:space:]]*write/ { found=1 }
  END { exit(found ? 0 : 1) }
' "$WF" && pass "freshness pull-requests write" || fail "freshness pull-requests write" ""

# compile job has only contents: read (no write)
awk '
  /^  compile:/ { in_c=1 }
  in_c && /^  [a-z]/ && !/^  compile:/ { in_c=0 }
  in_c && /permissions:/ { perm=1 }
  in_c && perm && /contents:[[:space:]]*read/ { read=1 }
  in_c && perm && /contents:[[:space:]]*write/ { write=1 }
  in_c && perm && /pull-requests:/ { pr=1 }
  END { exit((read && !write && !pr) ? 0 : 1) }
' "$WF" && pass "compile contents read only" || fail "compile contents read only" ""

# No ${{ inside any run: block
# Simple scan: after a line matching `run: |` or `run:`, collect until dedent — check for ${{
if awk '
  BEGIN { in_run=0; bad=0 }
  /^[[:space:]]*run:[[:space:]]*\|/ { in_run=1; next }
  /^[[:space:]]*run:[[:space:]]*[^|]/ { in_run=0; next }
  in_run {
    # leave run block when a key at same-or-less indent as typical step keys
    if ($0 ~ /^[[:space:]]{0,6}[A-Za-z_-]+:/ && $0 !~ /^[[:space:]]{8,}/) {
      in_run=0
    } else if ($0 ~ /\$\{\{/) {
      bad=1
      exit
    }
  }
  END { exit(bad ? 1 : 0) }
' "$WF"; then
  pass "no expression in run blocks"
else
  fail "no expression in run blocks" "found \${{ in run"
fi

# Actions pinned by 40-hex SHA
unpinned=0
while IFS= read -r line; do
  case "$line" in
    *uses:*)
      if ! printf '%s\n' "$line" | grep -Eq 'uses:[[:space:]]*[^@]+@[0-9a-f]{40}'; then
        unpinned=1
        echo "FAIL detail: $line"
      fi
      ;;
  esac
done < "$WF"
[ "$unpinned" -eq 0 ] && pass "actions pinned by SHA" || fail "actions pinned by SHA" ""


# No change to existing hooks or settings.json vs a base ref when available
base=""
if git -C "$REPO_ROOT" rev-parse --verify upstream/dev >/dev/null 2>&1; then
  base=upstream/dev
elif git -C "$REPO_ROOT" rev-parse --verify origin/dev >/dev/null 2>&1; then
  base=origin/dev
fi

if [ -n "$base" ]; then
  changed=$(git -C "$REPO_ROOT" diff --name-only "$base" -- .claude/hooks/*.sh .claude/settings.json 2>/dev/null || true)
  if [ -z "$changed" ]; then
    pass "no hook or settings.json changes vs $base"
  else
    fail "no hook or settings.json changes vs $base" "$changed"
  fi
else
  echo "NOTE: skip fail-before: no base ref"
  pass "no base ref note emitted"
fi

echo
echo "Total: $((PASS + FAIL))  Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
