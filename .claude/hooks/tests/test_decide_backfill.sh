#!/bin/bash
# Verify the backfill contract and count real frontmatter markers.
set -eu
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../../.." && pwd)
SB=$(mktemp -d)
trap 'rm -rf "$SB"' EXIT
PASS=0
FAIL=0
check() {
  if "$@"; then PASS=$((PASS + 1)); else
    echo "FAIL: $*"
    FAIL=$((FAIL + 1))
  fi
}
DECIDE="$ROOT/.claude/skills/decide/SKILL.md"
TEMPLATE="$ROOT/templates/agdr.md"
check grep -q -- '--backfill' "$DECIDE"
check grep -q 'Skip steps 2.4' "$DECIDE"
for text in 'recording: back-filled' 'original_decision_date:' 'Remembered reasons' 'Known limits' 'Change triggers'; do
  check grep -Fq "$text" "$TEMPLATE"
done
check grep -Fq 'unless the person confirms' "$DECIDE"
check grep -Fq 'Set `timestamp` to the actual writing time' "$DECIDE"
check grep -Fq 'Record unknown dates and missing recollections as unknown.' "$DECIDE"
check grep -Fq 'Unknown: no comparison confirmed' "$TEMPLATE"
check grep -Fq 'backfilled' "$ROOT/.claude/skills/agdr/SKILL.md"
cat > "$SB/backfill.md" <<'MD'
---
recording: back-filled
---
# Old tool
MD
cat > "$SB/ordinary.md" <<'MD'
---
category: tech-stack
---
recording: back-filled
MD
printf '# Legacy\nrecording: back-filled\n' > "$SB/legacy.md"
printf '%s\n' '---' 'recording: back-filled' > "$SB/unclosed.md"
printf '%s\n' '---' '# recording: back-filled' '---' > "$SB/comment.md"
SCRIPT="$ROOT/.claude/skills/agdr/scripts/count-backfilled.sh"
check test "$(bash "$SCRIPT" "$SB"/*.md)" = 1
cp "$SB/backfill.md" "$SB/second.md"
check test "$(bash "$SCRIPT" "$SB"/*.md)" = 2
check test "$(bash "$SCRIPT")" = 0
check test "$(bash "$SCRIPT" "$SB/ordinary.md" "$SB/legacy.md")" = 0
printf 'PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
