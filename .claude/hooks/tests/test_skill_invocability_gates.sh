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

# Read the frontmatter value, RAW — exactly as written. Only the frontmatter
# block counts, so the key is matched at line-start and only before the
# closing `---`.
#
# Trailing \r is stripped first: a CRLF-committed SKILL.md would otherwise
# yield "true\r", which compares unequal to "true" and fails this test for a
# line-ending reason rather than a real one. This repo has been bitten by
# exactly that before (#1019, where config_get left an embedded \r on Windows
# checkouts), so the guard is cheap insurance rather than theory.
#
# The value is deliberately NOT normalised here. The per-family assertions
# below must stay strict: for the three approval skills, only the canonical
# bare `true` counts as locked. A quoted scalar (`"true"`) is a YAML *string*,
# not a boolean, and whether the harness coerces it is unverified — accepting
# it would let this test report "locked" for a value the runtime may treat as
# unlocked. Strict comparison fails LOUDLY on any unrecognised spelling, the
# safe direction for the most safety-critical assertion in this file.
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

# NORMALISED value — trailing `# comment`, surrounding quotes, whitespace and
# capitalisation removed. Used ONLY by the every-skill sweep at the bottom.
#
# The two accessors exist because the same spelling needs opposite treatment at
# the two call sites (#1094 review, security finding). In the per-family checks
# an unrecognised spelling fails loudly — annoying but safe. In the sweep it
# made a LOCKED skill read as unlocked and be skipped SILENTLY, which is exactly
# the case that assertion exists to catch. Normalising only the sweep closes
# that fail-open without loosening the strict path.
invocation_flag_normalised() {
  local file="$1"
  invocation_flag "$file" | awk '
    {
      sub(/[[:space:]]*#.*$/, "")          # strip a trailing comment
      gsub(/^[[:space:]]+|[[:space:]]+$/, "")
      gsub(/^["\x27]|["\x27]$/, "")        # strip surrounding quotes
      print tolower($0)
    }
  '
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
# Every LOCKED skill must be justified (#1094).
#
# The family checks above pin the six skills someone thought about. They
# structurally cannot catch a SEVENTH skill acquiring the flag — which is
# exactly what happened: /decide and /audit-deps were human-only outside
# AgDR-0110's reasoning and outside this test's coverage, and nobody noticed
# because nothing asserted over the whole set.
#
# /decide's lock was the costly one. `.claude/rules/agdr-decisions.md` opens
# with "HARD STOP … run /decide" and repeats "→ /decide" four more times, so
# the framework was ordering an action it had mechanically forbidden. That is
# the same self-contradiction the review-skill justification above names for
# auto-code-review.sh — one skill over, and undetected.
#
# So assert the inverse: iterate EVERY skill, and require any that is locked to
# appear in an explicit allow-list. Adding a lock now means editing this list
# and stating why, which is the point.
# ---------------------------------------------------------------------------

# Only skills whose INVOCATION IS THE APPROVAL belong here (AgDR-0110).
# A skill that merely writes a document, reads state, or reports does not.
LOCK_ALLOWED="approve-merge approve-design approve-architecture"

UNJUSTIFIED=0
for f in "$SKILLS"/*/SKILL.md; do
  [ -f "$f" ] || continue
  name=$(basename "$(dirname "$f")")
  [ "$(invocation_flag_normalised "$f")" = "true" ] || continue
  case " $LOCK_ALLOWED " in
    *" $name "*) ;;
    *)
      echo "FAIL: /$name is human-only but is not in the justified lock list."
      echo "   Only approval skills may be locked — the ones where invoking the"
      echo "   skill IS the human approval (AgDR-0110). If this lock is"
      echo "   deliberate, add /$name to LOCK_ALLOWED with a stated reason, AND"
      echo "   check that no rule instructs the agent to invoke it — a rule that"
      echo "   does is a contradiction the agent cannot resolve (#1094)."
      FAIL=$((FAIL + 1))
      UNJUSTIFIED=1
      ;;
  esac
done

if [ "$UNJUSTIFIED" = "0" ]; then
  echo "PASS: every human-only skill is in the justified lock list"
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
