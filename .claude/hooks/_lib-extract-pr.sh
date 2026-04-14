#!/bin/bash
# Shared PR-number extraction for the three merge-gate hooks:
#   - block-unreviewed-merge.sh
#   - require-design-review-for-ui.sh
#   - block-merge-on-red-ci.sh
#
# Not a hook itself (prefixed with `_lib-` so it's never wired as one). Sourced
# by the hooks above via `. "$(dirname "$0")/_lib-extract-pr.sh"`.
#
# WHY THIS EXISTS
# ---------------
# The merge gates originally only matched `gh pr merge <N>`. Incident (#47):
# merges via `gh api repos/<owner>/<repo>/pulls/<N>/merge -X PUT` silently
# bypassed all three gates because neither the matcher nor the PR-number
# extraction knew about the API shape. This helper gives every gate a single,
# tested way to recognise both shapes:
#
#   1. `gh pr merge 42 --squash`                                  → PR is 42
#   2. `gh api repos/owner/repo/pulls/42/merge -X PUT`            → PR is 42
#
# Any tool that edits one of the three merge hooks MUST keep calling this
# helper, not re-implement the parsing inline. That's the whole point.
#
# USAGE
# -----
#   . "$(dirname "$0")/_lib-extract-pr.sh"
#   if ! is_merge_command "$COMMAND"; then exit 0; fi
#   PR_NUMBER=$(extract_pr_number "$COMMAND")

# Returns 0 if $1 looks like a merge command this gate should fire on.
# Matches EITHER:
#   - `gh pr merge ...`
#   - `gh api ... repos/<owner>/<repo>/pulls/<N>/merge ...`
is_merge_command() {
  local cmd="$1"
  if echo "$cmd" | grep -qE '\bgh\s+pr\s+merge\b'; then
    return 0
  fi
  # `gh api` with a `/pulls/<N>/merge` path anywhere in the command. The path
  # may be quoted, slash-separated, and may include query params.
  if echo "$cmd" | grep -qE '\bgh\s+api\b.*repos/[^/[:space:]]+/[^/[:space:]]+/pulls/[0-9]+/merge\b'; then
    return 0
  fi
  return 1
}

# Echoes the PR number extracted from the command, or empty if none found.
# Tries (in order):
#   1. `gh api .../pulls/<N>/merge` URL path
#   2. `gh pr merge <N>` first numeric arg
#   3. falls back to `gh pr view --json number` (current branch's PR)
extract_pr_number() {
  local cmd="$1"
  local pr=""

  # 1. gh api path extraction — greps the /pulls/<N>/merge segment directly.
  pr=$(echo "$cmd" | grep -oE 'repos/[^/[:space:]]+/[^/[:space:]]+/pulls/[0-9]+/merge' | grep -oE '/pulls/[0-9]+/' | grep -oE '[0-9]+' | head -1)

  # 2. gh pr merge positional arg — first bare number after `gh pr merge`,
  #    ignoring anything on the right side of a pipe / && / ; to avoid picking
  #    up a number from a follow-up command.
  if [ -z "$pr" ]; then
    pr=$(echo "$cmd" | grep -oE '\bgh\s+pr\s+merge\b[^|;&]*' | grep -oE '[0-9]+' | head -1)
  fi

  # 3. Last resort: ask gh which PR the current branch points at.
  if [ -z "$pr" ]; then
    pr=$(gh pr view --json number --jq '.number' 2>/dev/null)
  fi

  echo "$pr"
}

# Echoes the PR's HEAD SHA as reported by GitHub, or empty on failure.
#
# Why this exists (see #55): merge-gate hooks previously compared approval
# markers against `git rev-parse HEAD` (local HEAD). But `gh pr merge <N>`
# merges the PR's branch on GitHub's side, which is almost never equal to
# the local HEAD (local is usually `main` or a different feature branch).
# That meant every merge required a `gh pr checkout <N> && gh pr merge <N>`
# dance. Tedious and error-prone.
#
# This helper asks GitHub directly for the PR's HEAD via `gh pr view`.
# Works for both the `gh pr merge` and `gh api .../pulls/<N>/merge` shapes.
#
# Usage:
#   PR_HEAD=$(resolve_pr_head "$PR_NUMBER" "$CMD_REPO")
#   # Compare PR_HEAD against marker SHAs instead of git rev-parse HEAD.
#
# Failure modes (returns empty, caller should fall back):
#   - Network error / rate limit / gh auth expired
#   - PR doesn't exist (wrong number, closed, or wrong repo)
#   - GitHub API transient failure
#
# On failure the caller should fall back to `git rev-parse HEAD` with a
# visible warning — better to block a valid merge that the user can retry
# than silently allow a merge on the wrong SHA.
resolve_pr_head() {
  local pr_number="$1"
  local cmd_repo="$2"
  local sha=""

  if [ -z "$pr_number" ]; then
    echo ""
    return
  fi

  if [ -n "$cmd_repo" ]; then
    sha=$(gh pr view "$pr_number" --repo "$cmd_repo" --json headRefOid --jq '.headRefOid' 2>/dev/null)
  else
    sha=$(gh pr view "$pr_number" --json headRefOid --jq '.headRefOid' 2>/dev/null)
  fi

  echo "$sha"
}
