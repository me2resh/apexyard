#!/usr/bin/env bash
# Pin the label contract: Rex never edits the label; the orchestrator does.
set -euo pipefail
root=$(cd "$(dirname "$0")/../../.." && pwd)
agent="$root/.claude/agents/code-reviewer.md"
skill="$root/.claude/skills/code-review/SKILL.md"
# Literal Markdown backticks are intentional.
# shellcheck disable=SC2016
{
  grep -F 'Do NOT add or remove the `ready-to-merge` label.' "$agent" >/dev/null
  if grep -F -- '--add-label ready-to-merge' "$agent" >/dev/null; then
    echo 'FAIL: Rex file still carries the label edit command' >&2
    exit 1
  fi
  grep -F 'Rex does not edit the `ready-to-merge` label.' "$skill" >/dev/null
  grep -F 'add `ready-to-merge` after APPROVED:' "$skill" >/dev/null
  grep -F -- '--add-label ready-to-merge' "$skill" >/dev/null
  grep -F 'Remove it after CHANGES REQUESTED:' "$skill" >/dev/null
  grep -F -- '--remove-label ready-to-merge' "$skill" >/dev/null
  grep -F 'A denied or failed label call changes no verdict and no marker.' "$skill" >/dev/null
}
printf '%s\n' 'PASS: the orchestrator owns the ready label; Rex writes the marker with no label edit'
