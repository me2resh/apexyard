#!/bin/bash
# Static presence test for me2resh/apexyard#1402 — every review-class agent
# file must carry a "Running tests in a scratch clone" section, and that
# section must tell the reviewer to STOP and REPORT a blocked command
# rather than rephrase, split, encode, or disguise it. This cannot be a
# behavioral test (nothing here runs an agent), so it pins the wiring: the
# section exists, and it carries the stop-and-report language, in each of
# the three review-class agent files and their three invoking skills.
#
# Exit 0 if all files carry the section; 1 on the first missing file.

set -u

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"

AGENT_FILES=(
  "$ROOT/.claude/agents/code-reviewer.md"
  "$ROOT/.claude/agents/security-reviewer.md"
  "$ROOT/.claude/agents/solution-architect.md"
)

SKILL_FILES=(
  "$ROOT/.claude/skills/code-review/SKILL.md"
  "$ROOT/.claude/skills/security-review/SKILL.md"
  "$ROOT/.claude/skills/design-review/SKILL.md"
)

FAIL=0

# extract_section FILE: prints the "Running tests in a scratch clone"
# section body (from its heading up to, but excluding, the next `## `
# heading). A4 (Rex, PR #1404): the checks below must read only this slice,
# not the whole file — the base files already contain "stop" and "report"
# elsewhere, so a whole-file grep cannot fail even if the new section lost
# its stop-and-report text.
extract_section() {
  awk '
    /^## Running tests in a scratch clone/ { found=1; print; next }
    found && /^## / { exit }
    found { print }
  ' "$1"
}

check_file() {
  local f="$1" label="$2" section

  if [ ! -f "$f" ]; then
    echo "FAIL: missing file: $f" >&2
    FAIL=1
    return
  fi

  section=$(extract_section "$f")

  if [ -z "$section" ]; then
    echo "FAIL [$label]: no 'Running tests in a scratch clone' section in $f" >&2
    FAIL=1
    return
  fi

  # The agent files carry the full stop-and-report instruction; the skill
  # files carry a short pointer back to the owning agent file plus the
  # same instruction in miniature. Either way "stop" and "report" must
  # both appear inside the scratch-clone section itself, and "rephrase"
  # (or "disguise") must appear — the exact failure mode #1402 calls out.
  if ! grep -qi "stop" <<<"$section"; then
    echo "FAIL [$label]: scratch-clone section in $f has no 'stop' instruction" >&2
    FAIL=1
    return
  fi
  if ! grep -qi "report" <<<"$section"; then
    echo "FAIL [$label]: scratch-clone section in $f has no 'report' instruction" >&2
    FAIL=1
    return
  fi
  if ! grep -qiE "rephrase|disguise" <<<"$section"; then
    echo "FAIL [$label]: scratch-clone section in $f has no rephrase/disguise warning" >&2
    FAIL=1
    return
  fi

  echo "PASS [$label]: scratch-clone section present with stop-and-report language"
}

for f in "${AGENT_FILES[@]}"; do
  check_file "$f" "agent: $(basename "$f")"
done

for f in "${SKILL_FILES[@]}"; do
  check_file "$f" "skill: $(basename "$(dirname "$f")")"
done

if [ "$FAIL" -ne 0 ]; then
  exit 1
fi
exit 0
