#!/bin/bash
# PreToolUse hook on `gh pr merge` AND `gh api .../pulls/<N>/merge`: blocks the
# merge if any required CI check is failing, pending, or cancelled.
#
# Both merge shapes are covered — see _lib-extract-pr.sh for the parser and
# #47 for why the API-shape bypass was a gap worth closing.
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

# Shared merge-shape detector + PR-number parser (see _lib-extract-pr.sh).
# Handles `gh pr merge <N>` and `gh api repos/<owner>/<repo>/pulls/<N>/merge`.
. "$(dirname "$0")/_lib-extract-pr.sh"

if ! is_merge_command "$COMMAND"; then
  exit 0
fi

# Variable-substituted merge (#643): if the PR arg or --repo value is an
# unexpanded shell variable, this hook can't resolve the real target from the
# command text — the old code fell back to the CWD's PR and checked an
# UNRELATED PR's CI (and passed `$REPO` to gh, producing garbage errors). A CI
# gate must not guess. Block with a clear, accurate instruction instead.
if merge_command_uses_variable "$COMMAND"; then
  cat >&2 <<'EOF'
BLOCKED: cannot verify CI on a variable-substituted merge command.

This gate reads the literal command text and can't resolve shell variables
(e.g. `gh pr merge $PR --repo $REPO`) to the real PR / repo, so it cannot
check the correct PR's CI status. Re-run with literal values:

  gh pr merge <number> --repo <owner>/<repo> --squash

(Use the actual PR number and owner/repo — not shell variables.)
EOF
  exit 2
fi

# Parse --repo (for `gh pr merge --repo owner/repo`). Uses the shared extractor,
# which also recovers the repo from a `gh api .../pulls/<N>/merge` URL path so
# `gh pr checks` below is still scoped correctly.
CMD_REPO=$(extract_repo_from_command "$COMMAND")
REPO_FLAG=""
if [ -n "$CMD_REPO" ]; then
  REPO_FLAG="--repo $CMD_REPO"
fi

PR_NUMBER=$(extract_pr_number "$COMMAND")

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

ApexYard rule (.claude/rules/pr-quality.md § "No Red CI Before Merge"):

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
