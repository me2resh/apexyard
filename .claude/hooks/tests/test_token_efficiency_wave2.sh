#!/usr/bin/env bash
# test_token_efficiency_wave2.sh — pin Wave 2 on-demand rule loading
# from AgDR-0160 / me2resh/apexyard#1319.
#
# Invariants:
#   1. CLAUDE.md does not auto-import rule files (@.claude/rules/ is absent).
#   2. Every tracked .claude/rules/*.md file is named in CLAUDE.md.
#   3. The always-on catalogue (CLAUDE.md + skill description: strings) stays
#      below the 54,000-token chars÷4 baseline from 2026-09-16.
#
# Usage: bash .claude/hooks/tests/test_token_efficiency_wave2.sh
# Exit 0 on success, 1 on any hard-cap failure.

set -u

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="${TOKEN_EFFICIENCY_ROOT:-$(cd "$TEST_DIR/../../.." && pwd)}"

CLAUDE_MD="$ROOT/CLAUDE.md"
RULES_DIR="$ROOT/.claude/rules"

FAIL=0

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }

echo "== Invariant 1: CLAUDE.md has no @.claude/rules auto-import"
if grep -qF '@.claude/rules/' "$CLAUDE_MD"; then
  red "  FAIL: CLAUDE.md still contains @.claude/rules/ (Claude Code would import those files)"
  FAIL=$((FAIL + 1))
else
  green "  OK"
fi

echo "== Invariant 2: every rule file is named in CLAUDE.md"
missing=0
for f in "$RULES_DIR"/*.md; do
  [ -f "$f" ] || continue
  base=$(basename "$f")
  if ! grep -qF ".claude/rules/$base" "$CLAUDE_MD"; then
    red "  FAIL: $base is not named in CLAUDE.md"
    missing=$((missing + 1))
    FAIL=$((FAIL + 1))
  fi
done
[ "$missing" -eq 0 ] && green "  OK"

echo "== Invariant 3: always-on catalogue stays below 54k tokens (chars÷4)"
claude_chars=$(wc -c < "$CLAUDE_MD" | tr -d ' ')
skill_chars=0
skill_files=$(git -C "$ROOT" ls-files '.claude/skills/*/SKILL.md' 2>/dev/null || true)
while IFS= read -r relative_f; do
  [ -n "$relative_f" ] || continue
  f="$ROOT/$relative_f"
  desc=$(awk '
    BEGIN{infm=0; indesc=0; out=""}
    /^---[[:space:]]*$/ { infm=!infm; if (!infm) exit; next }
    infm && /^description:/ {
      sub(/^description:[[:space:]]*/, "")
      sub(/^["'\''"]/, "")
      sub(/["'\''"][[:space:]]*$/, "")
      indesc=1
      out = out $0
      next
    }
    infm && indesc && /^[a-zA-Z_][a-zA-Z_0-9-]*:/ { indesc=0 }
    infm && indesc {
      line=$0
      sub(/^[[:space:]]+/, " ", line)
      out = out line
    }
    END { print out }
  ' "$f")
  skill_chars=$((skill_chars + ${#desc}))
done <<EOF
$skill_files
EOF
total_chars=$((claude_chars + skill_chars))
tokens=$((total_chars / 4))
echo "  CLAUDE.md: $claude_chars chars"
echo "  skill description: $skill_chars chars"
echo "  catalogue: $total_chars chars (~$tokens tokens)"
if [ "$tokens" -ge 54000 ]; then
  red "  FAIL: catalogue is ~$tokens tokens (>= 54000 baseline)"
  FAIL=$((FAIL + 1))
else
  green "  OK"
fi

echo ""
if [ "$FAIL" -eq 0 ]; then
  green "All Wave 2 invariants pass."
  exit 0
else
  red "$FAIL Wave 2 invariant(s) failed."
  exit 1
fi
