#!/usr/bin/env bash
# test_token_efficiency_wave1.sh — pin the three Wave 1 compression invariants
# from AgDR-0044 so future Wave 2/3 work can verify it isn't regressing them.
#
# Invariants:
#   1. CLAUDE.md skill-table compactness — every row stays terse
#      (≤ 25 words in the description column)
#   2. SKILL.md description: budget — every description ≤ 200 chars, with the
#      majority ≤ 120 chars (the budget is "~120 chars"; we cap at 200 hard,
#      flag overs above 120 as soft warnings)
#   3. Every skill on disk is catalogued in the CLAUDE.md table (no orphans)
#   4. SessionStart happy-path char budget — banner output across the seven
#      SessionStart hooks stays ≤ 600 chars (covers the unconfigured-fork
#      worst-case fixture present in this worktree)
#
# Usage: bash .claude/hooks/tests/test_token_efficiency_wave1.sh
# Exit 0 on success, 1 on any hard-cap failure.

set -u

# Resolve repo root from the test file's location so the test can run from
# any cwd inside the worktree.
TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$TEST_DIR/../../.." && pwd)"

CLAUDE_MD="$ROOT/CLAUDE.md"
SKILLS_DIR="$ROOT/.claude/skills"
HOOKS_DIR="$ROOT/.claude/hooks"

FAIL=0

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }

# -----------------------------------------------------------------------------
# Invariant 1 — CLAUDE.md skill-table rows are terse (≤ 25 words in description)
# -----------------------------------------------------------------------------
echo "== Invariant 1: CLAUDE.md skill-table rows ≤ 25 words"
table=$(awk '/^### Available skills/{flag=1; next} /^The hooks, agents, and skills/{flag=0} flag' "$CLAUDE_MD")
while IFS= read -r line; do
  case "$line" in
    "| \`/"*"\` |"*)
      # Extract description (column 2 of the pipe-table)
      desc=$(printf '%s' "$line" | awk -F'|' '{print $3}')
      words=$(printf '%s' "$desc" | wc -w | tr -d ' ')
      if [ "$words" -gt 25 ]; then
        skill=$(printf '%s' "$line" | awk -F'|' '{print $2}' | tr -d ' `')
        red "  FAIL: $skill — $words words in CLAUDE.md row (> 25)"
        FAIL=$((FAIL + 1))
      fi
      ;;
  esac
done <<EOF
$table
EOF
[ "$FAIL" -eq 0 ] && green "  OK"

# -----------------------------------------------------------------------------
# Invariant 2 — SKILL.md description: char budget
# -----------------------------------------------------------------------------
echo "== Invariant 2: SKILL.md description: ≤ 200 chars (hard), ≤ 120 chars (soft)"
total=0
overs120=0
overs200=0
for f in "$SKILLS_DIR"/*/SKILL.md; do
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
  n=${#desc}
  total=$((total + n))
  if [ "$n" -gt 200 ]; then
    overs200=$((overs200 + 1))
    skill=$(basename "$(dirname "$f")")
    red "  FAIL: $skill — description is $n chars (> 200 hard cap)"
    FAIL=$((FAIL + 1))
  elif [ "$n" -gt 120 ]; then
    overs120=$((overs120 + 1))
  fi
done
echo "  Total: $total chars across 52 skills"
echo "  Soft warnings (121–200 chars): $overs120 (documented exception per AgDR-0044)"
[ "$overs200" -eq 0 ] && green "  OK (hard cap)"

# -----------------------------------------------------------------------------
# Invariant 3 — every skill on disk catalogued in CLAUDE.md
# -----------------------------------------------------------------------------
echo "== Invariant 3: every skill in .claude/skills/ is catalogued in CLAUDE.md"
missing=0
for d in "$SKILLS_DIR"/*/; do
  name=$(basename "$d")
  case "$name" in _lib*) continue ;; esac
  if ! grep -qE "^\| \`/$name\` \|" "$CLAUDE_MD"; then
    red "  FAIL: /$name is in .claude/skills/ but not in CLAUDE.md skill table"
    missing=$((missing + 1))
    FAIL=$((FAIL + 1))
  fi
done
[ "$missing" -eq 0 ] && green "  OK"

# -----------------------------------------------------------------------------
# Invariant 4 — SessionStart happy-path char budget
# -----------------------------------------------------------------------------
echo "== Invariant 4: SessionStart hooks emit ≤ 600 chars on the happy path (worst-case fixture)"
ss_total=0
for h in onboarding-check check-upstream-drift check-jq-installed check-portfolio-config clear-bootstrap-marker clear-issue-skill-marker link-custom-skills; do
  if [ ! -x "$HOOKS_DIR/$h.sh" ] && [ ! -f "$HOOKS_DIR/$h.sh" ]; then
    continue
  fi
  out=$(bash "$HOOKS_DIR/$h.sh" 2>&1 </dev/null || true)
  n=$(printf '%s' "$out" | wc -c | tr -d ' ')
  ss_total=$((ss_total + n))
done
echo "  Total SessionStart banner: $ss_total chars"
if [ "$ss_total" -gt 600 ]; then
  red "  FAIL: SessionStart banner is $ss_total chars (> 600 budget)"
  FAIL=$((FAIL + 1))
else
  green "  OK"
fi

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
echo ""
if [ "$FAIL" -eq 0 ]; then
  green "All Wave 1 invariants pass."
  exit 0
else
  red "$FAIL Wave 1 invariant(s) failed."
  exit 1
fi
