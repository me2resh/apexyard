#!/bin/bash
# Regression checks for the advisory pre-merge QA flow (#1383).
# Set APEXYARD_TEST_SOURCE_ROOT to inspect another source tree.

set -u

# Isolate from live Claude Code session pin/cache (me2resh/apexyard#1549).
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"


SOURCE_ROOT=${APEXYARD_TEST_SOURCE_ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}
SKILL="$SOURCE_ROOT/.claude/skills/code-review/SKILL.md"
AGENT="$SOURCE_ROOT/.claude/agents/qa-engineer.md"
ROLE="$SOURCE_ROOT/roles/engineering/qa-engineer.md"
DEFAULTS="$SOURCE_ROOT/.claude/project-config.defaults.json"
CONFIG_DOC="$SOURCE_ROOT/docs/project-config.md"
SDLC="$SOURCE_ROOT/workflows/sdlc.md"
AGDR="$SOURCE_ROOT/docs/agdr/AgDR-0201-sha-bound-pre-merge-qa-reuse.md"

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

# 6. All reuse instructions bind PASS to the final head and a trusted author.
reuse_rule_present=true
for doc in "$SKILL" "$AGENT" "$ROLE" "$SDLC" "$CONFIG_DOC" "$AGDR"; do
  while IFS= read -r requirement; do
    if ! has "$doc" "$requirement"; then
      reuse_rule_present=false
      printf 'Missing reuse requirement in %s: %s\n' "$doc" "$requirement"
    fi
  done <<'RULE'
Reuse a complete pre-merge QA PASS only when its stamped SHA matches the merged PR's final head SHA.
This is the PR head commit when it merged (the MR head SHA on GitLab).
A PASS stamped with an earlier head does not count.
Accept reports only from the repository owner, a member or a collaborator, or the account that posted the Rex review.
On GitHub, verify `author_association` of `OWNER`, `MEMBER` or `COLLABORATOR`, or the Rex account match.
Otherwise, run post-merge QA as usual.
RULE
done

if [ "$reuse_rule_present" = true ] \
  && has "$SKILL" 'apexyard-pre-merge-qa: sha=<full-commit-sha> status=PASS' \
  && has "$ROLE" 'Read GitHub PR review bodies and comments, or GitLab MR notes, with their author metadata.' \
  && has "$ROLE" 'latest posted pre-merge QA report' \
  && has "$ROLE" 'Verify author identity and access from forge metadata, not claims inside the report.' \
  && has "$ROLE" 'If author trust or the final head SHA cannot be verified, run QA again.' \
  && has "$ROLE" 'Require evidence for every acceptance criterion before reuse.' \
  && has "$ROLE" 'record the reused result' \
  && has "$ROLE" 'Run QA again'; then
  pass 'reuse-only-final-head-and-trusted-author'
else
  fail 'reuse-only-final-head-and-trusted-author' 'the final-head binding, trusted-author rule, or rerun path is missing'
fi

# 7. Run the actual step-8 config block with local Git and config stubs.
# No tracker calls, real config reads, or review/approval steps are executed.
TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/apexyard-qa-offer.XXXXXX") || exit 1
cleanup() {
  rm -- "$TEST_TMP/ops/.apexyard-fork" "$TEST_TMP/ops/.claude/hooks/_lib-read-config.sh" "$TEST_TMP/run-config.sh"
  rmdir -- "$TEST_TMP/ops/.claude/hooks" "$TEST_TMP/ops/.claude" "$TEST_TMP/ops" "$TEST_TMP"
}
trap cleanup EXIT
mkdir -p "$TEST_TMP/ops/.claude/hooks"
touch "$TEST_TMP/ops/.apexyard-fork"
cat > "$TEST_TMP/ops/.claude/hooks/_lib-read-config.sh" <<'STUB'
config_get_or() {
  [ "$1" = '.qa.pre_merge_offer' ] || return 1
  printf '%s\n' "${QA_TEST_CONFIG_VALUE:-$2}"
}
STUB
cat > "$TEST_TMP/run-config.sh" <<'STUB'
set -eu
git() {
  [ "$*" = 'rev-parse --show-toplevel' ] || return 1
  printf '%s\n' "$QA_TEST_OPS_ROOT"
}
STUB

if awk '
  $0 == "### 8. Offer pre-merge QA after APPROVED" { step = 1; next }
  step && /^## / { exit }
  step && $0 == "```bash" { block = 1; next }
  block && $0 == "```" { closed = 1; exit }
  block { print }
  END { if (!closed) exit 1 }
' "$SKILL" >> "$TEST_TMP/run-config.sh"; then
  cat >> "$TEST_TMP/run-config.sh" <<'STUB'
printf '%s\n' "$qa_offer"
STUB
  for config_value in bogus ask always never ''; do
    expected="$config_value"
    case "$config_value" in
      bogus|'') expected=ask ;;
    esac
    if actual=$(QA_TEST_CONFIG_VALUE="$config_value" QA_TEST_OPS_ROOT="$TEST_TMP/ops" bash "$TEST_TMP/run-config.sh") \
      && [ "$actual" = "$expected" ]; then
      pass "step-8-config-${config_value:-missing}"
    else
      fail "step-8-config-${config_value:-missing}" "expected $expected, got $actual"
    fi
  done
else
  fail 'step-8-config-extraction' 'could not extract a complete step-8 Bash block'
fi

printf 'passed: %s   failed: %s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
