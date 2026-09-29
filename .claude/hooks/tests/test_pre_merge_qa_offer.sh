#!/bin/bash
# Regression checks for the advisory pre-merge QA flow (#1383).
# Set APEXYARD_TEST_SOURCE_ROOT to inspect another source tree.

set -u

SOURCE_ROOT=${APEXYARD_TEST_SOURCE_ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}
SKILL="$SOURCE_ROOT/.claude/skills/code-review/SKILL.md"
AGENT="$SOURCE_ROOT/.claude/agents/qa-engineer.md"
ROLE="$SOURCE_ROOT/roles/engineering/qa-engineer.md"
DEFAULTS="$SOURCE_ROOT/.claude/project-config.defaults.json"
CONFIG_DOC="$SOURCE_ROOT/docs/project-config.md"
SDLC="$SOURCE_ROOT/workflows/sdlc.md"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf 'PASS [%s]\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL [%s] %s\n' "$1" "$2"; }
has() { grep -Fq "$2" "$1"; }

# 1. The question belongs after an APPROVED review, with the PR number.
if has "$SKILL" '### 8. Offer pre-merge QA after APPROVED' \
  && has "$SKILL" 'Rex approved PR #<pr>. Run QA (Salim) against the acceptance criteria before merge? (yes / no)' \
  && has "$SKILL" 'CHANGES REQUESTED or COMMENT'; then
  pass 'offer-after-approved'
else
  fail 'offer-after-approved' 'the APPROVED-only question is missing'
fi

# 2. A yes or always run checks every criterion on the PR head, posts a
# non-approval PR result, and stops on failure before merge approval.
if has "$SKILL" 'Run Salim against the PR branch at the recorded HEAD SHA' \
  && has "$SKILL" 'each acceptance criterion' \
  && has "$SKILL" 'tracker_review_submit' \
  && has "$SKILL" 'comment' \
  && has "$SKILL" 'Stop before requesting human merge approval' \
  && has "$ROLE" 'Pre-merge QA'; then
  pass 'yes-runs-qa-and-stops-on-failure'
else
  fail 'yes-runs-qa-and-stops-on-failure' 'the branch verification, PR report, or failure handoff is missing'
fi

# 3. A no retains post-merge QA.
if has "$SKILL" 'On `no`, leave QA for the existing post-merge `qa` label trigger.' \
  && has "$SDLC" 'Choosing `no` keeps the post-merge QA flow.'; then
  pass 'no-keeps-post-merge-qa'
else
  fail 'no-keeps-post-merge-qa' 'the no branch does not preserve post-merge QA'
fi

# 4. The offer does not grant merge approval or create a QA merge gate.
if has "$SKILL" 'This offer is advisory.' \
  && has "$SKILL" 'Never write or relax a merge marker' \
  && has "$SKILL" 'Only the human-invoked `/approve-merge` records merge approval and merges.' \
  && has "$SDLC" 'Pre-merge QA is not a merge gate.'; then
  pass 'offer-is-advisory'
else
  fail 'offer-is-advisory' 'human-only merge authority is not explicit'
fi

# 5. The shipped default and all three modes are defined and consumed.
if jq -e '.qa.pre_merge_offer == "ask"' "$DEFAULTS" >/dev/null 2>&1 \
  && has "$CONFIG_DOC" '`qa.pre_merge_offer`' \
  && has "$CONFIG_DOC" '`ask`' \
  && has "$CONFIG_DOC" '`always`' \
  && has "$CONFIG_DOC" '`never`' \
  && has "$SKILL" "config_get_or '.qa.pre_merge_offer' 'ask'" \
  && has "$SKILL" 'ask|always|never'; then
  pass 'config-modes-default-ask'
else
  fail 'config-modes-default-ask' 'the default, modes, or skill lookup is missing'
fi

# 6. Reuse requires a posted PASS for the exact merged commit SHA.
if has "$SKILL" 'apexyard-pre-merge-qa: sha=<full-commit-sha> status=PASS' \
  && has "$AGENT" 'exact merged commit SHA' \
  && has "$ROLE" 'exact merged commit SHA' \
  && has "$ROLE" 'Read GitHub PR review bodies or GitLab MR notes' \
  && has "$ROLE" 'latest posted pre-merge QA report' \
  && has "$ROLE" 'record the reused result' \
  && has "$ROLE" 'Run QA again' \
  && has "$SDLC" 'same commit SHA'; then
  pass 'reuse-only-same-sha'
else
  fail 'reuse-only-same-sha' 'the SHA-bound reuse or mismatch path is missing'
fi

printf 'passed: %s   failed: %s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
