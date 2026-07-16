#!/usr/bin/env bash
# /inbox smoke test — Reconcile section (#923)
#
# /inbox is a prompt-driven skill: SKILL.md's bash blocks are executed by
# Claude Code at invocation time, not by a shipped script. This smoke test
# pins the *contract* the Reconcile section must satisfy — the same
# contract-pinning shape used by .claude/skills/codify-rule/tests/smoke.sh
# — plus a standalone re-implementation of the detection/classification
# logic so the conservative-matching behaviour (no false positives on a
# gated/genuinely-open ticket) is actually exercised, not just asserted
# in prose.
#
# What this checks:
#
#   1. SKILL.md frontmatter sanity (name, allowed-tools unchanged).
#   2. SKILL.md documents the Reconcile section: numbered section 9,
#      the batched (once-per-repo, not once-per-issue) query shape,
#      the Closes-vs-Refs distinction, graceful degradation, and the
#      --no-reconcile filter.
#   3. SKILL.md's output-format example includes a Reconcile row so the
#      shape is discoverable without reading the prose.
#   4. The detection/classification logic (extracted below as a small
#      shell function mirroring the SKILL.md prose) correctly:
#        a. flags an issue closed-but-open by a merged PR's "Closes #N"
#        b. flags an issue refs-open by a merged PR's "Refs #N"
#        c. does NOT flag a genuinely-open issue with no PR reference
#        d. does NOT flag an issue merely mentioned in passing (no
#           adjacent closing/referencing keyword)
#        e. does NOT flag when the referenced issue isn't in the open set
#
# The skill itself is NOT executed here (no live `gh` calls) — this is a
# contract + logic test, matching the rest of this repo's skill smoke tests.

set -euo pipefail

PASS=0
FAIL=0

assert_grep() {
  local label="$1" pattern="$2" file="$3"
  if grep -qE "$pattern" "$file"; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label (pattern: $pattern; file: $file)"
    FAIL=$((FAIL + 1))
  fi
}

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label (expected: $expected; actual: $actual)"
    FAIL=$((FAIL + 1))
  fi
}

# Resolve the ops-fork root by walking up from this script.
script_dir="$(cd "$(dirname "$0")" && pwd)"
ops_root="$script_dir"
while [ "$ops_root" != "/" ] && [ ! -f "$ops_root/CLAUDE.md" ]; do
  ops_root=$(dirname "$ops_root")
done
if [ ! -f "$ops_root/CLAUDE.md" ]; then
  echo "FAIL: could not locate ops-fork root (CLAUDE.md missing)"
  exit 1
fi

skill_md="$ops_root/.claude/skills/inbox/SKILL.md"

echo "Smoke test: /inbox Reconcile section (#923) (ops_root=$ops_root)"
echo ""

# ---------------------------------------------------------------------------
# 1. Frontmatter sanity
# ---------------------------------------------------------------------------
echo "1. SKILL.md frontmatter sanity:"
assert_grep "name: inbox"                  "^name: inbox$"                          "$skill_md"
assert_grep "allowed-tools unchanged (read-only)" "^allowed-tools: Bash, Read, Grep, Glob$" "$skill_md"

# ---------------------------------------------------------------------------
# 2. Reconcile section contract
# ---------------------------------------------------------------------------
echo ""
echo "2. Reconcile section contract:"
assert_grep "numbered section 9 exists"          "### 9\. Reconcile"                              "$skill_md"
assert_grep "references ticket #923"             "#923"                                            "$skill_md"
assert_grep "batched once-per-repo framing"      "Fetch \*\*once per repo\*\*"                      "$skill_md"
assert_grep "open-issue set fetched first"       "open_issues="                                    "$skill_md"
assert_grep "merged-PR query present"            "gh pr list --repo \"\\\$repo\" --state merged"    "$skill_md"
assert_grep "Closing-keyword classification"     "Closing keywords"                                "$skill_md"
assert_grep "Referencing-keyword classification" "Referencing keywords"                            "$skill_md"
assert_grep "release-cut artifact framing"       "release-cut artifact"                            "$skill_md"
assert_grep "QA-gate framing"                    "intentional QA gate"                             "$skill_md"
assert_grep "conservative-by-construction note"  "Conservative by construction"                    "$skill_md"
assert_grep "graceful degradation note"          "Graceful degradation"                             "$skill_md"
assert_grep "--no-reconcile filter documented"   "\-\-no-reconcile"                                 "$skill_md"
assert_grep "Rules section: advisory-only note"  "Reconcile is a passive surface, not an action"    "$skill_md"

# ---------------------------------------------------------------------------
# 3. Output-format example includes a Reconcile row
# ---------------------------------------------------------------------------
echo ""
echo "3. Output-format example:"
assert_grep "Reconcile row in the sample output" "Reconcile — open issues with a merged PR" "$skill_md"

# ---------------------------------------------------------------------------
# 4. Detection/classification logic — exercised, not just asserted in prose
# ---------------------------------------------------------------------------
echo ""
echo "4. Detection/classification logic (standalone re-implementation):"

# classify <pr_text> <issue_number> <open_issues_csv>
# Echoes "closes", "refs", or "" (no match / not conservative-eligible).
classify() {
  local text="$1" issue="$2" open_csv="$3"

  # Not in the open set at all → never flag (regardless of PR text).
  case ",$open_csv," in
    *",$issue,"*) : ;;
    *) echo ""; return ;;
  esac

  if echo "$text" | grep -qiE "(close[sd]?|fix(e[sd])?|resolve[sd]?)[^\n]{0,20}#${issue}\b"; then
    echo "closes"
  elif echo "$text" | grep -qiE "(refs?|references?|related to)[^\n]{0,20}#${issue}\b"; then
    echo "refs"
  else
    echo ""
  fi
}

open_set="88,31,42"

result=$(classify "This PR closes #88 by fixing the race condition" "88" "$open_set")
assert_eq "4a. Closes #N against an open issue -> classified 'closes'" "closes" "$result"

result=$(classify "Refs #31 — awaiting QA sign-off before closing" "31" "$open_set")
assert_eq "4b. Refs #N against an open issue -> classified 'refs'" "refs" "$result"

result=$(classify "General cleanup, no ticket references here" "42" "$open_set")
assert_eq "4c. No reference at all -> no flag (empty)" "" "$result"

result=$(classify "See #42 for background on why this approach was chosen" "42" "$open_set")
assert_eq "4d. Bare mention with no adjacent closing/refs keyword -> no flag" "" "$result"

result=$(classify "Closes #999" "999" "$open_set")
assert_eq "4e. Closing keyword for an issue NOT in the open set -> no flag" "" "$result"

echo ""
echo "-----------------------------------------------------------"
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
