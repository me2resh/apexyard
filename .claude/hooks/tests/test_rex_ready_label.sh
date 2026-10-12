#!/usr/bin/env bash
# Pin Rex's verdict-to-label contract in both posting instructions.
set -euo pipefail
root=$(cd "$(dirname "$0")/../../.." && pwd)
for file in "$root/.claude/agents/code-reviewer.md" "$root/.claude/skills/code-review/SKILL.md"; do
  # Literal Markdown backticks are intentional.
  # shellcheck disable=SC2016
  grep -F 'add `ready-to-merge` after APPROVED:' "$file" >/dev/null
  grep -F -- '--add-label ready-to-merge' "$file" >/dev/null
  grep -F 'Remove it after CHANGES REQUESTED:' "$file" >/dev/null
  grep -F -- '--remove-label ready-to-merge' "$file" >/dev/null
done
printf '%s\n' 'PASS: Rex APPROVED adds readiness, CHANGES REQUESTED removes readiness'
