#!/bin/bash
# PreToolUse hook on `gh pr merge`: blocks the merge if any required CI
# check is failing, pending, or cancelled.
#
# Enforces .claude/rules/pr-quality.md § "No Red CI Before Merge" —
# "Never merge with red CI - even if the failure is pre-existing or
# unrelated. Fix the pre-existing issue first (separate commit), rebase
# the PR so all checks are green, and only then merge." Was prose-only
# until this hook shipped.
#
# Uses `gh pr checks <pr>` which returns one line per check with status.
# Exit codes:
#   0 = all checks passed (and none required are missing)
#   1 = at least one check failed, was cancelled, or skipped
#   8 = no checks at all
#
# The hook allows:
#   - exit 0 (all green)
#   - exit 8 if the repo has no CI (gh pr checks returns "no checks" — allow)
# Blocks:
#   - exit 1 (red CI)
#   - any check with state FAILURE | CANCELLED | TIMED_OUT
#
# Pending checks (IN_PROGRESS | QUEUED): BLOCKED. The rule says all checks
# must be green; pending is not green. Wait for CI to finish, then retry.

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)

if [ -z "$COMMAND" ]; then
  exit 0
fi

if ! echo "$COMMAND" | grep -qE '\bgh\s+pr\s+merge\b'; then
  exit 0
fi

# Parse --repo from the command for cross-repo merge operations
CMD_REPO=$(echo "$COMMAND" | sed -nE 's/.*--repo[[:space:]]+([^[:space:]]+).*/\1/p' | head -1)
REPO_FLAG=""
if [ -n "$CMD_REPO" ]; then
  REPO_FLAG="--repo $CMD_REPO"
fi

# Extract PR number (same approach as the other merge-gate hooks)
PR_NUMBER=$(echo "$COMMAND" | grep -oE '\bgh\s+pr\s+merge\b[^|;&]*' | grep -oE '[0-9]+' | head -1)
if [ -z "$PR_NUMBER" ]; then
  PR_NUMBER=$(gh pr view $REPO_FLAG --json number --jq '.number' 2>/dev/null)
fi

if [ -z "$PR_NUMBER" ]; then
  # Another hook will handle "no PR number" — skip
  exit 0
fi

# Query checks. gh pr checks returns text output; we check both the exit code
# and a "no checks reported" substring — the latter is how gh reports the
# genuinely-unchecked case regardless of exit code version.
CHECKS_OUTPUT=$(gh pr checks "$PR_NUMBER" $REPO_FLAG 2>&1)
CHECKS_RC=$?

# "no checks reported on the 'X' branch" — legitimate no-CI state. Allow.
# Projects without CI (or branches without the expected workflow wiring)
# hit this path. Log a single-line note so the user knows the gate was a no-op.
if echo "$CHECKS_OUTPUT" | grep -q "no checks reported"; then
  echo "NOTE: PR #${PR_NUMBER} has no CI checks configured. Merge-on-red-CI gate is a no-op for this PR." >&2
  exit 0
fi

if [ "$CHECKS_RC" = "0" ]; then
  # All green — allow
  exit 0
fi

# Red CI (exit 1) or unknown non-zero. Emit the raw check output in the
# error message so the user can see exactly which checks are red.
cat >&2 <<MSG
BLOCKED: PR #${PR_NUMBER} has red CI. Cannot merge.

\`gh pr checks ${PR_NUMBER}\` reported failures or pending checks:

$(echo "$CHECKS_OUTPUT" | head -30 | sed 's/^/  /')

ApexStack rule (.claude/rules/pr-quality.md § "No Red CI Before Merge"):

  "Never merge with red CI — even if the failure is pre-existing or
  unrelated. Fix the pre-existing issue first (separate commit), rebase
  the PR so all checks are green, and only then merge."

To unblock:

  1. Look at the failing check logs: \`gh pr checks ${PR_NUMBER} --watch\`
     or click through from https://github.com/{owner}/{repo}/pull/${PR_NUMBER}
  2. If the failure is in YOUR change, fix it and push
  3. If the failure is PRE-EXISTING (CI was already red on main), fix the
     pre-existing issue in a separate commit on this branch, then retry
  4. If checks are PENDING, wait for them to finish, then retry
  5. Re-invoke Rex after any new commit (re-review required)
  6. Retry \`gh pr merge ${PR_NUMBER}\`

No exceptions. Not even for "unrelated" failures. Red CI stays red until
someone fixes it — that's the whole point of the rule.
MSG
exit 2
