#!/bin/bash
# Wiring test for the /update file-level path (me2resh/apexyard#1887).
#
# The engine behaviour is tested in .claude/hooks/tests/test_update_files.sh.
# This test checks that SKILL.md calls the engine as the contract says:
#   - --plan and --git-merge are parsed;
#   - step 2a computes the plan with bin/update-files.sh --plan;
#   - --plan stops before any branch or write;
#   - step 6 applies with --apply and handles exit 0, 1, 2 and 3;
#   - --confirm-security is passed only after an explicit user choice;
#   - staging is by name from the step 2a plan.

set -u
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../../../hooks/tests" && pwd)/_test-session-isolation.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../../../.." && pwd)"
SKILL="$ROOT/.claude/skills/update/SKILL.md"
PASS=0
FAIL=0

check() {
  local label="$1" pattern="$2"
  if grep -Fq -- "$pattern" "$SKILL"; then
    echo "PASS [$label]"; PASS=$((PASS + 1))
  else
    echo "FAIL [$label]: missing '$pattern'" >&2; FAIL=$((FAIL + 1))
  fi
}

check 'parse --plan' '--plan)             PLAN=1 ;;'
check 'parse --git-merge' '--git-merge)        GIT_MERGE=1 ;;'
check 'plan default' 'PLAN=0'
check 'git-merge default' 'GIT_MERGE=0'
check 'step 2a heading' '### 2a. File-level plan (ownership-aware)'
check 'engine path' 'ENGINE="$(git rev-parse --show-toplevel)/bin/update-files.sh"'
check 'plan call' 'bash "$ENGINE" --plan --target "$UPSTREAM_REF"'
check 'plan stops' 'If `--plan` is set, print the plan and stop.'
check 'apply call' 'bash "$ENGINE" --apply --target "$UPSTREAM_REF"'
check 'exit 1 row' '| 1 | Conflict. Nothing is written.'
check 'exit 3 row' '| 3 | A gate file has a local edit. Nothing is written.'
check 'explicit security choice' 'Never pass `--confirm-security` without that choice.'
check 'stage from plan' "awk -F '\\t' '\$1 == \"updated\" || \$1 == \"merged\" { print \$3 }' \"\$PLAN_FILE\""
check 'merge or rebase skipped' 'Skip this step when `SYNC_MODE=files`.'
check 'per-file is the default' '**Default: the per-file update.**'
check 'git-merge is the escape hatch' '`--git-merge` is the escape hatch'
check 'plan header documented' 'The plan starts with two header lines that begin with `#`.'

check 'description names the default' 'per-file update by owner class on a sync branch (the default; --git-merge runs the history merge)'
check 'usage names the default' '/update                              # per-file update by owner class (the default)'
check 'fallback asks the user' '`SYNC_MODE=ask`: the per-file update cannot run'
check 'fallback shows the engine error' 'Show `$PLAN_ERROR` to the user.'
check 'checkout before branch delete' 'Check out the default branch (`git checkout "$DEFAULT_BRANCH"`), then delete the empty sync branch'
check 'nothing to commit' 'No framework file changed. Nothing to commit.'
check 'commit subject without ticket' 'SUBJECT="chore: sync framework files from $UPSTREAM_REF"'

# The old default text must not come back (Rex on #1895).
refuse() {
  local label="$1" pattern="$2"
  if grep -Fq -- "$pattern" "$SKILL"; then
    echo "FAIL [$label]: found '$pattern'" >&2; FAIL=$((FAIL + 1))
  else
    echo "PASS [$label]"; PASS=$((PASS + 1))
  fi
}
refuse 'no merge-based default' 'merge-based sync (default'
refuse 'no merge-or-rebase description' 'description: Sync the ApexYard fork with upstream — preview, merge-or-rebase on a sync branch'
refuse 'no empty ticket subject' 'git commit -m "chore(#${TICKET}): sync framework files'

# The file-level section must not stage with a wildcard.
section=$(awk '/^\*\*File-level path/{on=1} /^\*\*Merge path:\*\*/{on=0} on' "$SKILL")
if printf '%s\n' "$section" | grep -Eq 'git add (-A|\.)( |$)'; then
  echo "FAIL [no wildcard staging]" >&2; FAIL=$((FAIL + 1))
else
  echo "PASS [no wildcard staging]"; PASS=$((PASS + 1))
fi

echo "===== test_file_level_wiring.sh ====="
echo "Passed: $PASS"
echo "Failed: $FAIL"
[ "$FAIL" -eq 0 ]
