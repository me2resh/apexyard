#!/usr/bin/env bash
# test_token_efficiency_wave2.sh — pin Wave 2 on-demand rule loading
# from AgDR-0160 / me2resh/apexyard#1319.
#
# Invariants:
#   1. CLAUDE.md does not auto-import rule files (@.claude/rules/ is absent).
#   2. Every tracked .claude/rules/*.md file is named in CLAUDE.md.
#   3. CLAUDE.md plus skill description: strings stay below 9,000 tokens
#      (chars÷4). The 54k figure from the ticket overstated the load.
#   4. AGENTS.md stays below 5,000 tokens so Cursor/pi do not ingest a
#      second full rule restatement.
#
# Usage: bash .claude/hooks/tests/test_token_efficiency_wave2.sh
# Exit 0 on success, 1 on any hard-cap failure.

set -u

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="${TOKEN_EFFICIENCY_ROOT:-$(cd "$TEST_DIR/../../.." && pwd)}"

CLAUDE_MD="$ROOT/CLAUDE.md"
AGENTS_MD="$ROOT/AGENTS.md"
RULES_DIR="$ROOT/.claude/rules"

FAIL=0
CLAUDE_CAP_TOKENS=9000
AGENTS_CAP_TOKENS=5000

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }

skill_description_chars() {
  local skill_chars=0 relative_f f desc
  local skill_files
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
  printf '%s' "$skill_chars"
}

echo "== Invariant 1: CLAUDE.md has no @.claude/rules auto-import"
if grep -qF '@.claude/rules/' "$CLAUDE_MD"; then
  red "  FAIL: CLAUDE.md still contains @.claude/rules/ (Claude Code would import those files)"
  FAIL=$((FAIL + 1))
else
  green "  OK"
fi

echo "== Invariant 2: every rule file is named in CLAUDE.md"
missing=0
rule_bytes=0
for f in "$RULES_DIR"/*.md; do
  [ -f "$f" ] || continue
  base=$(basename "$f")
  n=$(wc -c < "$f" | tr -d ' ')
  rule_bytes=$((rule_bytes + n))
  if ! grep -qF ".claude/rules/$base" "$CLAUDE_MD"; then
    red "  FAIL: $base is not named in CLAUDE.md"
    missing=$((missing + 1))
    FAIL=$((FAIL + 1))
  fi
done
echo "  rule files on disk: $rule_bytes chars (~$((rule_bytes / 4)) tokens, not always-on)"
[ "$missing" -eq 0 ] && green "  OK"

echo "== Invariant 3: CLAUDE.md + skill descriptions stay below $CLAUDE_CAP_TOKENS tokens"
claude_chars=$(wc -c < "$CLAUDE_MD" | tr -d ' ')
skill_chars=$(skill_description_chars)
total_chars=$((claude_chars + skill_chars))
tokens=$((total_chars / 4))
echo "  CLAUDE.md: $claude_chars chars (~$((claude_chars / 4)) tokens)"
echo "  skill description: $skill_chars chars (~$((skill_chars / 4)) tokens)"
echo "  catalogue: $total_chars chars (~$tokens tokens)"
if [ "$tokens" -ge "$CLAUDE_CAP_TOKENS" ]; then
  red "  FAIL: catalogue is ~$tokens tokens (>= $CLAUDE_CAP_TOKENS cap)"
  FAIL=$((FAIL + 1))
else
  green "  OK"
fi

echo "== Invariant 4: AGENTS.md stays below $AGENTS_CAP_TOKENS tokens"
if [ ! -f "$AGENTS_MD" ]; then
  red "  FAIL: AGENTS.md missing"
  FAIL=$((FAIL + 1))
else
  agents_chars=$(wc -c < "$AGENTS_MD" | tr -d ' ')
  agents_tokens=$((agents_chars / 4))
  echo "  AGENTS.md: $agents_chars chars (~$agents_tokens tokens)"
  if [ "$agents_tokens" -ge "$AGENTS_CAP_TOKENS" ]; then
    red "  FAIL: AGENTS.md is ~$agents_tokens tokens (>= $AGENTS_CAP_TOKENS cap)"
    FAIL=$((FAIL + 1))
  else
    green "  OK"
  fi
fi

echo ""
if [ "$FAIL" -eq 0 ]; then
  green "All Wave 2 invariants pass."
  exit 0
else
  red "$FAIL Wave 2 invariant(s) failed."
  exit 1
fi
