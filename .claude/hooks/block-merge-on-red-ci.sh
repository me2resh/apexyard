#!/bin/bash
# PreToolUse hook on `gh pr merge` / `gh api .../pulls/<N>/merge` AND their
# GitLab counterparts `glab mr merge` / `glab api .../merge_requests/<N>/merge`:
# blocks the merge if CI is failing, pending, or unresolvable.
#
# All four merge shapes are covered — see _lib-extract-pr.sh for the parser.
# #47 is why the gh-api-shape bypass was worth closing; #764/#767 added the
# glab shapes to the OTHER three merge gates; this hook was the one sibling
# still hardcoded to `gh pr checks` (#790 — the last non-forge-aware gate).
#
# Enforces .claude/rules/pr-quality.md § "No Red CI Before Merge" —
# "Never merge with red CI - even if the failure is pre-existing or
# unrelated. Fix the pre-existing issue first (separate commit), rebase
# the PR so all checks are green, and only then merge." Was prose-only
# until this hook shipped.
#
# GH PATH (unchanged, byte-identical to pre-#790 behaviour)
# -----------------------------------------------------------
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
#
# GLAB PATH (new, #790)
# ----------------------
# `resolve_ci_status_glab` (see _lib-extract-pr.sh) resolves the GitLab MR's
# head-pipeline status via `glab mr view <iid> --output json`, normalised to
# one of: success | pending | failure | none | "" (unresolvable).
#   Allows: "success"; "none" (MR has no pipeline configured — the glab
#   analog of gh's "no checks reported").
#   Blocks: "pending"; "failure"; "" — an EMPTY status means the pipeline
#   state could not be determined (glab missing, network/auth failure,
#   unparseable response). Fail CLOSED: an unresolvable status is never
#   treated as green, exactly like a red-or-unfetchable gh CI check.

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)

if [ -z "$COMMAND" ]; then
  exit 0
fi

# Shared merge-shape detector + PR-number parser (see _lib-extract-pr.sh).
# Handles `gh pr merge <N>`, `gh api repos/<owner>/<repo>/pulls/<N>/merge`,
# `glab mr merge <N>`, and `glab api .../merge_requests/<N>/merge` (#764/#767).
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
(e.g. `gh pr merge $PR --repo $REPO` or `glab mr merge $MR -R $REPO`) to the
real PR/MR or repo, so it cannot check the correct one's CI status. Re-run
with literal values:

  gh pr merge <number> --repo <owner>/<repo> --squash
  glab mr merge <iid> -R <owner>/<repo>

(Use the actual PR/MR number and owner/repo — not shell variables.)
EOF
  exit 2
fi

# Parse --repo / -R (for `gh pr merge --repo owner/repo` or `glab mr merge -R
# owner/repo`). Uses the shared extractor, which also recovers the repo from a
# `gh api .../pulls/<N>/merge` or `glab api .../merge_requests/<N>/merge` URL
# path so the CI-status check below is still scoped correctly.
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

# Forge dispatch (#790): the command text normally says which CLI it drives —
# the same detector _lib-extract-pr.sh's own resolvers use internally. The
# `tracker_pr_merge` wrapper (#759) is the one shape where that's NOT true by
# design — the wrapper's whole point is that its OWN text never says "gh" or
# "glab" (that choice lives in the registry, resolved at call time via
# `tracker_kind`). Text-based `_forge_from_command` would silently default to
# "gh" for a glab-kind project calling the wrapper, so for that shape ONLY,
# dispatch via the registry (`_forge_kind_for`, the same resolver
# resolve_pr_head/resolve_pr_head_branch already use) instead. Every other
# shape (explicit `gh pr merge` / `gh api` / `glab mr merge` / `glab api`)
# keeps the original text-based dispatch unchanged — this preserves the
# existing #790 test behaviour exactly.
if echo "$COMMAND" | grep -qE '\btracker_pr_merge\b'; then
  FORGE=$(_forge_kind_for "$CMD_REPO")
else
  FORGE=$(_forge_from_command "$COMMAND")
fi
if [ "$FORGE" = "glab" ]; then
  # --- GitLab path ---
  PIPELINE_STATUS=$(resolve_ci_status_glab "$PR_NUMBER" "$CMD_REPO")

  case "$PIPELINE_STATUS" in
    success)
      exit 0
      ;;
    none)
      echo "NOTE: MR !${PR_NUMBER} has no pipeline configured. Merge-on-red-CI gate is a no-op for this MR." >&2
      exit 0
      ;;
    *)
      # pending | failure | "" (unresolvable) — all three BLOCK. An empty
      # status must never be treated as green: if glab is missing, the
      # network/auth failed, or the response was unparseable, that is a
      # reason to block, not a reason to guess "probably fine".
      STATUS_DESC="${PIPELINE_STATUS:-unresolvable (glab CLI missing, network/auth failure, or unparseable response)}"
      cat >&2 <<MSG
BLOCKED: MR !${PR_NUMBER} has red or unresolvable CI. Cannot merge.

\`glab mr view ${PR_NUMBER}\` reports pipeline status: ${STATUS_DESC}

ApexYard rule (.claude/rules/pr-quality.md § "No Red CI Before Merge"):

  "Never merge with red CI — even if the failure is pre-existing or
  unrelated. Fix the pre-existing issue first (separate commit), rebase
  the PR so all checks are green, and only then merge."

To unblock:

  1. Look at the pipeline: \`glab mr view ${PR_NUMBER} --web\` or
     \`glab ci status\` on the MR's source branch
  2. If the failure is in YOUR change, fix it and push
  3. If the failure is PRE-EXISTING (pipeline was already red on the target
     branch), fix the pre-existing issue in a separate commit, then retry
  4. If the pipeline is PENDING, wait for it to finish, then retry
  5. If the status could not be fetched at all, check glab auth/network and
     retry — this gate fails CLOSED on an unresolvable status
  6. Re-invoke Rex after any new commit (re-review required)
  7. Retry \`glab mr merge ${PR_NUMBER}\`

No exceptions. Not even for "unrelated" failures. Red or unresolvable CI
stays blocking until someone fixes it — that's the whole point of the rule.
MSG
      exit 2
      ;;
  esac
fi

# --- GitHub path (unchanged, byte-identical to pre-#790 behaviour) ---
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
