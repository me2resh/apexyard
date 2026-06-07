#!/bin/bash
# Shared PR-number and repo extraction for the merge-gate hooks:
#   - block-unreviewed-merge.sh
#   - require-design-review-for-ui.sh
#   - require-architecture-review.sh
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
#   2. `gh pr merge <N>` first numeric arg (strict: must be a bare integer token
#      immediately following `merge`; NOT a digit scraped from a redirection such
#      as `2>&1`, and NOT an unexpanded shell variable such as `$pr` or `$PR`).
#      When the token is a shell variable the function returns empty so the
#      caller's step-3 fallback can invoke `gh pr view`.
#   3. falls back to `gh pr view --json number` (current branch's PR)
#
# BUG #568 — root cause and fix:
#   The old step-2 span `[^|;&]*` included `2>&1` because the `&` lookahead
#   was not anchored before the pipe, causing `grep -oE '[0-9]+'` to return `2`
#   (the stderr fd number) instead of the PR number when the invocation was
#   `gh pr merge $pr --squash 2>&1 | tail -5` and `$pr` was unexpanded at hook
#   evaluation time.
#
#   Fix: strip redirection tokens from the span before the digit search, then
#   require that the first post-`merge` token is a bare integer — not a shell
#   variable, not a flag. If it is a variable or absent, return empty.
extract_pr_number() {
  local cmd="$1"
  local pr=""

  # 1. gh api path extraction — greps the /pulls/<N>/merge segment directly.
  #    The PR number lives in the URL path, so redirections cannot affect it.
  pr=$(echo "$cmd" | grep -oE 'repos/[^/[:space:]]+/[^/[:space:]]+/pulls/[0-9]+/merge' | grep -oE '/pulls/[0-9]+/' | grep -oE '[0-9]+' | head -1)

  # 2. gh pr merge positional arg.
  if [ -z "$pr" ]; then
    # a) Isolate the `gh pr merge …` span up to the first shell separator
    #    (pipe, &&, ;). The [^|;&]* fence keeps us from reading past a piped
    #    follow-up command (e.g. `| tail -5`).
    local span
    span=$(echo "$cmd" | grep -oE '\bgh\s+pr\s+merge\b[^|;&]*')

    # b) Strip all redirection tokens so that `2>&1`, `2>file`, `&>file`,
    #    `>>file`, `>file` etc. cannot contribute digits to the PR search.
    #    Patterns (ordered most-specific first to avoid partial matches):
    #      [0-9]*>&[0-9]*   — fd-to-fd redirections like `2>&1`, `1>&2`
    #      &>[^[:space:]]*  — Bash &> combined redirect
    #      >>[^[:space:]]* — append redirect
    #      >[^[:space:]]*  — overwrite redirect
    local clean_span
    clean_span=$(echo "$span" | sed \
      -e 's/[0-9]*>&[0-9]*/  /g' \
      -e 's/&>[^[:space:]]*/  /g' \
      -e 's/>>[^[:space:]]*/  /g' \
      -e 's/>[^[:space:]]*/  /g')

    # c) After `merge`, take the first whitespace-delimited token.
    #    - If it starts with `$` → unexpanded variable → PR number unknown.
    #      Return empty; step 3 will ask `gh pr view`.
    #    - If it is a bare integer → that is the PR number.
    #    - Anything else (flag, string) → no literal PR number present;
    #      return empty. Do NOT scan further for stray digits — that is
    #      precisely the bug.
    #
    #    Use `grep -oE '\bmerge\b …'` rather than `sed 's/.*\bmerge\b…'`
    #    because BSD sed on macOS does not support \b word boundaries.
    local first_token
    first_token=$(echo "$clean_span" | grep -oE '\bmerge\b[[:space:]]+[^[:space:]]*' | awk 'NR==1 {print $NF}')

    if echo "$first_token" | grep -qE '^\$'; then
      # Unexpanded variable — cannot determine PR number from command text.
      pr=""
    elif echo "$first_token" | grep -qE '^[0-9]+$'; then
      pr="$first_token"
    else
      # No bare integer immediately after merge; leave pr empty.
      pr=""
    fi
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

# Echoes the owner/repo extracted from the merge command, or empty if not found.
#
# This is a SIBLING function to extract_pr_number — same parsing approach,
# repo-extraction only. Kept separate so the existing extract_pr_number
# contract is not disturbed (it is used widely; callers that don't need the
# repo are unaffected).
#
# Recognises:
#   1. `gh api repos/<owner>/<repo>/pulls/<N>/merge ...`  — repo from URL path
#   2. `gh pr merge ... --repo <owner>/<repo> ...`        — repo from --repo flag
#   3. Falls back to `gh pr view --json headRepository`   — current branch's PR
#
# Returns empty if the repo cannot be determined.
extract_repo_from_command() {
  local cmd="$1"
  local repo=""

  # 1. gh api path extraction.
  repo=$(echo "$cmd" | grep -oE 'repos/[^/[:space:]]+/[^/[:space:]]+/pulls/[0-9]+/merge' \
    | sed -nE 's|repos/([^/]+/[^/]+)/pulls/.*|\1|p' | head -1)

  # 2. --repo flag on gh pr merge.
  if [ -z "$repo" ]; then
    repo=$(echo "$cmd" | sed -nE 's/.*--repo[[:space:]]+([^[:space:]]+).*/\1/p' | head -1)
  fi

  # 3. Last resort: ask gh which repo the current branch's PR belongs to.
  if [ -z "$repo" ]; then
    repo=$(gh pr view --json headRepository --jq '.headRepository.nameWithOwner' 2>/dev/null)
  fi

  echo "$repo"
}
