#!/bin/bash
# me2resh/apexyard#1042 / AgDR-0110 — where the mechanical human gate sits.
#
# `disable-model-invocation` in a SKILL.md's frontmatter decides whether the
# model may invoke that skill. Two families must sit on opposite sides:
#
#   REVIEW skills  (/code-review, /security-review, /design-review)
#     Trigger an independent reviewer SUB-AGENT. Independence comes from that
#     separate agent and its separate context — NOT from who typed the
#     command. Locking these buys no safety and taxes every PR, while
#     contradicting auto-code-review.sh, which explicitly instructs the
#     orchestrator to run /code-review.
#
#   APPROVAL skills (/approve-merge, /approve-design, /approve-architecture)
#     Write the approval markers that merge gates read. /approve-merge also
#     performs the merge — irreversible and externally visible. Its own
#     SKILL.md says "the discrete approval moment is the invocation".
#     A human must make that invocation.
#
# Before #1042 these were exactly inverted: review skills were human-only
# and approval skills were model-invocable (with /approve-architecture
# carrying no frontmatter at all, so it defaulted to model-invocable).
#
# Why this test exists rather than trusting the frontmatter: the original
# defect WAS a frontmatter value nobody was watching, sitting unnoticed from
# the first commit. A silent edit here would reopen the gap invisibly — an
# unlocked approval skill combined with unlocked review skills restores a
# fully autonomous open -> review -> approve -> merge path.
#
# Exit 0 = all pass, exit 1 = at least one failure.

set -u

REPO_ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
SKILLS="$REPO_ROOT/.claude/skills"

PASS=0
FAIL=0

# Read the frontmatter value. Only the frontmatter block counts, so the key
# is matched at line-start and only before the closing `---`.
#
# Trailing \r is stripped first: a CRLF-committed SKILL.md would otherwise
# yield "true\r", which compares unequal to "true" and fails this test for a
# line-ending reason rather than a real one. This repo has been bitten by
# exactly that before (#1019, where config_get left an embedded \r on Windows
# checkouts), so the guard is cheap insurance rather than theory.
invocation_flag() {
  local file="$1"
  awk '
    { sub(/\r$/, "") }
    NR == 1 && $0 != "---" { exit }
    NR > 1 && $0 == "---"  { exit }
    /^disable-model-invocation:[[:space:]]*/ {
      sub(/^disable-model-invocation:[[:space:]]*/, "")
      print
      exit
    }
  ' "$file"
}

expect_flag() {
  local skill="$1" want="$2" why="$3"
  local file="$SKILLS/$skill/SKILL.md"

  if [ ! -f "$file" ]; then
    echo "FAIL: $skill — SKILL.md not found at $file"
    FAIL=$((FAIL + 1))
    return
  fi

  local got
  got=$(invocation_flag "$file")

  # An ABSENT key is not acceptable for either family: absent defaults to
  # model-invocable, which is how /approve-architecture was silently
  # unguarded. Both families must state their posture explicitly.
  if [ -z "$got" ]; then
    echo "FAIL: $skill — no 'disable-model-invocation' in frontmatter (absent defaults to model-invocable). $why"
    FAIL=$((FAIL + 1))
    return
  fi

  if [ "$got" = "$want" ]; then
    echo "PASS: $skill → disable-model-invocation: $got"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $skill → expected 'disable-model-invocation: $want', got '$got'"
    echo "   $why"
    FAIL=$((FAIL + 1))
  fi
}

# ---------------------------------------------------------------------------
# Review skills must be model-invocable (false).
# ---------------------------------------------------------------------------

for s in code-review security-review design-review; do
  expect_flag "$s" "false" \
    "Review skills spawn a separate reviewer sub-agent; independence does not depend on who invokes them. auto-code-review.sh instructs the orchestrator to run /code-review, so locking it makes the framework contradict itself."
done

# ---------------------------------------------------------------------------
# Approval skills must be human-only (true).
# ---------------------------------------------------------------------------

for s in approve-merge approve-design approve-architecture; do
  expect_flag "$s" "true" \
    "Approval skills write the markers merge gates read; /approve-merge also merges. The invocation IS the approval, so a human must make it (see .claude/rules/pr-workflow.md and AgDR-0110)."
done

# ---------------------------------------------------------------------------
# The combination is what matters: if review skills are unlocked, approval
# skills MUST be locked, or the model can drive the whole chain unattended.
# Asserted explicitly so the coupling is visible to whoever edits either side.
# ---------------------------------------------------------------------------

REVIEW_UNLOCKED=1
for s in code-review security-review design-review; do
  [ "$(invocation_flag "$SKILLS/$s/SKILL.md")" = "false" ] || REVIEW_UNLOCKED=0
done

APPROVAL_LOCKED=1
for s in approve-merge approve-design approve-architecture; do
  [ "$(invocation_flag "$SKILLS/$s/SKILL.md")" = "true" ] || APPROVAL_LOCKED=0
done

if [ "$REVIEW_UNLOCKED" = "1" ] && [ "$APPROVAL_LOCKED" = "0" ]; then
  echo "FAIL: review skills are model-invocable while approval skills are NOT locked."
  echo "   That combination restores an autonomous open -> review -> approve -> merge"
  echo "   path with no human in the loop. Lock the approval skills."
  FAIL=$((FAIL + 1))
else
  echo "PASS: no autonomous open -> review -> approve -> merge path"
  PASS=$((PASS + 1))
fi

# ---------------------------------------------------------------------------
# Result
# ---------------------------------------------------------------------------

echo
echo "Passed: $PASS  Failed: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
