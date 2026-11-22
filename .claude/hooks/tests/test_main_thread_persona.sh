#!/bin/bash
# Structural tests for the main-thread persona, Hadi (me2resh/apexyard#2024).
#
# The owner decision (21 Nov 2026) says: the docs mention Hadi in the roles
# docs and the persona table, like Rex and Hakim. A role marker names the
# main thread only on a hand-off. An ordinary reply stays unnamed.
#
# This test checks the artifacts mechanically:
#
#   1. CLAUDE.md carries the main-thread persona line, in one or two lines.
#   2. docs/agdr/AgDR-0018-persona-naming-convention.md has the main-thread
#      row and the "Amended 21 Nov 2026" note for #2024.
#   3. .claude/rules/role-triggers.md shows the hand-off marker form and
#      states that a marker names the main thread only on a hand-off.
#   4. docs/whats-inside.md (the public roles docs page) names Hadi.

set -u

# Isolate from live Claude Code session pin/cache (me2resh/apexyard#1549).
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"

SRC_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
CLAUDE_MD="$SRC_ROOT/CLAUDE.md"
AGDR_0018="$SRC_ROOT/docs/agdr/AgDR-0018-persona-naming-convention.md"
ROLE_TRIGGERS="$SRC_ROOT/.claude/rules/role-triggers.md"
WHATS_INSIDE="$SRC_ROOT/docs/whats-inside.md"

fail=0
pass() { echo "PASS: $1"; }
die()  { echo "FAIL: $1" >&2; fail=1; }

# 1. CLAUDE.md has the persona line, kept to one or two lines.
if grep -qF '**Main thread**: **Hadi**.' "$CLAUDE_MD" 2>/dev/null; then
  pass "CLAUDE.md has the main-thread persona line"
else
  die "CLAUDE.md is missing the main-thread persona line for Hadi"
fi
persona_line_count=$(awk '
  /\*\*Main thread\*\*: \*\*Hadi\*\*\./ { found=1 }
  found && NF { count++ }
  found && !NF { exit }
  END { print count+0 }
  ' "$CLAUDE_MD" 2>/dev/null)
if [ -n "$persona_line_count" ] && [ "$persona_line_count" -le 2 ]; then
  pass "main-thread persona paragraph stays within two lines (found: $persona_line_count)"
else
  die "main-thread persona paragraph exceeds two lines (found: ${persona_line_count:-0})"
fi

# 2. AgDR-0018 has the main-thread row and the 21 Nov 2026 amendment for #2024.
if grep -qF '| main thread (session router) | **Hadi**' "$AGDR_0018" 2>/dev/null; then
  pass "AgDR-0018 has the main-thread persona-table row"
else
  die "AgDR-0018 is missing the main-thread persona-table row"
fi
if grep -qF 'Amended 21 Nov 2026 (me2resh/apexyard#2024)' "$AGDR_0018" 2>/dev/null; then
  pass "AgDR-0018 has the Amended 21 Nov 2026 note for #2024"
else
  die "AgDR-0018 is missing the Amended 21 Nov 2026 note for #2024"
fi
if grep -qF 'names the main' "$AGDR_0018" 2>/dev/null && \
   grep -qF 'only on a hand-off' "$AGDR_0018" 2>/dev/null; then
  pass "AgDR-0018 amendment states the hand-off-only rule"
else
  die "AgDR-0018 amendment does not state the hand-off-only rule"
fi

# 3. role-triggers.md shows the hand-off marker form and the hand-off-only rule.
if grep -qF '▸ Hadi routes #42 to Rex (Code Reviewer)' "$ROLE_TRIGGERS" 2>/dev/null; then
  pass "role-triggers.md shows the hand-off marker"
else
  die "role-triggers.md is missing the hand-off marker"
fi
if grep -qF 'Hadi prints a marker only when it routes work to a role' "$ROLE_TRIGGERS" 2>/dev/null; then
  pass "role-triggers.md states that only a hand-off names the main thread"
else
  die "role-triggers.md does not state that only a hand-off names the main thread"
fi

# 4. docs/whats-inside.md (the public roles docs page) names Hadi.
if grep -qF 'Hadi' "$WHATS_INSIDE" 2>/dev/null; then
  pass "docs/whats-inside.md names Hadi in the roles docs"
else
  die "docs/whats-inside.md does not name Hadi"
fi
if grep -qF 'like Rex' "$WHATS_INSIDE" 2>/dev/null && grep -qF 'Hakim' "$WHATS_INSIDE" 2>/dev/null; then
  pass "docs/whats-inside.md places Hadi alongside Rex and Hakim"
else
  die "docs/whats-inside.md does not place Hadi alongside Rex and Hakim"
fi

if [ "$fail" -eq 0 ]; then
  echo "All main-thread persona structural tests passed."
  exit 0
else
  echo "Some main-thread persona tests FAILED." >&2
  exit 1
fi
