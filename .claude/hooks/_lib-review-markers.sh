#!/bin/bash
# _lib-review-markers.sh — single source of truth for review-marker path
# construction.
#
# WHY THIS EXISTS
# ---------------
# Review markers (.claude/session/reviews/<qualifier>-<role>.approved) were
# previously keyed by bare PR number, e.g. `429-rex.approved`. Because PR
# numbers are per-repository and routinely overlap across managed repos, two
# repos could each have a PR #429 whose markers shared the same filename —
# a (repo, pr) collision hazard.
#
# This library encodes the repo in every marker path using the scheme:
#
#   <owner>__<repo>__<pr>-<role>.approved
#
# Double-underscore is the separator because GitHub owner/repo slugs use only
# [a-zA-Z0-9._-] — they never contain `__`. Splitting on `__` reliably
# recovers the three components. See docs/agdr/AgDR-0060-review-marker-repo-qualifier.md.
#
# FUNCTIONS
# ---------
#   review_marker_path <owner/repo> <pr> <role>
#       Returns the absolute path to the marker file, anchored at the
#       resolved MARKER_HOME/.claude/session/reviews/ directory. Exits with
#       a non-zero status and an error message if required args are missing.
#       Does NOT create the directory — callers must `mkdir -p` as needed.
#
#   review_markers_dir <marker_home>
#       Returns the absolute path to the reviews directory:
#       <marker_home>/.claude/session/reviews
#
# USAGE (in a hook or skill)
# --------------------------
#   . "$(dirname "$0")/_lib-review-markers.sh"
#   # ... resolve MARKER_HOME as usual via _lib-ops-root.sh ...
#   MARKER_HOME="${OPS_ROOT:-${REPO_ROOT:-.}}"
#   REX_MARKER=$(review_marker_path "owner/repo" "$PR_NUMBER" rex)
#
# SOURCE GUARD
# ------------
# Idempotent: sourcing more than once is a no-op (standard _lib pattern).

[ -n "${_LIB_REVIEW_MARKERS_SOURCED:-}" ] && return 0
_LIB_REVIEW_MARKERS_SOURCED=1

# review_markers_dir <marker_home>
# Returns the path: <marker_home>/.claude/session/reviews
review_markers_dir() {
  local marker_home="${1:-.}"
  printf '%s/.claude/session/reviews' "$marker_home"
}

# review_marker_path <owner/repo> <pr> <role> [marker_home]
#
# Args:
#   owner/repo  — the fully-qualified GitHub repo (e.g. "me2resh/apexyard").
#                 Slashes are sanitised to double-underscores in the filename.
#   pr          — the PR number (integer)
#   role        — the marker role: rex | ceo | design | architecture
#   marker_home — optional; defaults to $MARKER_HOME if set, then "." as last
#                 resort. Callers that have already resolved the ops fork root
#                 via _lib-ops-root.sh should pass it explicitly.
#
# Output (stdout): the absolute marker file path.
# Exit code: 0 on success; 1 if required args are missing (with stderr msg).
review_marker_path() {
  local repo="${1:-}"
  local pr="${2:-}"
  local role="${3:-}"
  local marker_home="${4:-${MARKER_HOME:-.}}"

  if [ -z "$repo" ] || [ -z "$pr" ] || [ -z "$role" ]; then
    echo "_lib-review-markers.sh: review_marker_path requires <owner/repo> <pr> <role>" >&2
    return 1
  fi

  # Sanitise: replace every '/' with '__' so the repo slug is flat-file safe.
  local safe_repo
  safe_repo=$(printf '%s' "$repo" | tr '/' '_' | sed 's/_/__/g; s/____/__/g')
  # The tr+sed above can double the underscores incorrectly for repos that
  # already use underscores. Use a single, cleaner transformation instead:
  # replace ALL '/' with the two-char string '__'.
  safe_repo=$(printf '%s' "$repo" | sed 's|/|__|g')

  local reviews_dir
  reviews_dir=$(review_markers_dir "$marker_home")

  printf '%s/%s__%s-%s.approved' "$reviews_dir" "$safe_repo" "$pr" "$role"
}

# pr_base_repo <pr> <repo>
#
# Echoes the PR/MR's BASE (host) repo as "owner/repo" — the repo the PR *lives
# on* and is numbered against. This is the canonical key for approval markers
# (me2resh/apexyard#765).
#
# WHY THE BASE REPO IS CANONICAL
# ------------------------------
# The merge gates (block-unreviewed-merge.sh, require-architecture-review.sh,
# require-design-review-for-ui.sh) derive their marker-lookup repo (`CMD_REPO`)
# from the merge command's `--repo` value or `gh api repos/<o>/<r>/pulls/.../merge`
# path. For a CROSS-FORK PR that is ALWAYS the base repo — you cannot merge a
# fork's copy (`gh pr merge <n> --repo <fork>` errors; the PR doesn't live
# there). So `merge --repo == CMD_REPO == base`. Historically the marker WRITERS
# keyed on `headRepository` (the fork) instead, so on a cross-fork PR the marker
# was written under the fork qualifier while the gate searched under the base →
# a valid approval never satisfied the gate. Keying every writer on the base via
# this helper makes writer/reader agreement STRUCTURAL, not coincidental.
#
# WHY A REQUIRED <repo>, NOT GH'S AMBIENT DEFAULT (me2resh/apexyard#887)
# -----------------------------------------------------------------------
# An earlier version queried `gh pr view "$pr" --json url` with NO --repo,
# trusting gh's ambient base-repo resolution (from the working copy's remotes)
# to prefer the parent/upstream. That assumption holds for a PR filed FROM a
# fork branch TO upstream (ambient parent happens to equal the true base) but
# NOT for a SAME-REPO fork PR (opened against the fork's own main) — there
# gh's ambient default STILL prefers the parent even though the true base is
# the fork itself. The unscoped call then SUCCEEDS with the WRONG repo: it
# resolves to an unrelated PR of the same number on the parent, and the old
# hint/fallback path only fired on a gh ERROR, never on this wrong-but-
# successful resolution. Reviews got posted to, and merge markers got keyed
# on, a public repo the PR never lived on. See #887.
#
# The fix: never let gh guess. `<repo>` is now REQUIRED — the repo the CALLER
# already knows hosts this PR (that is how it found the PR number in the
# first place: an explicit `[repo]` skill argument, an `owner/repo#N` the user
# named, or the current checkout's own remote). Scoping to it is authoritative,
# not a "hint": a PR object only resolves through its own base repo's API
# namespace, so `gh pr view <pr> --repo <repo>` can only succeed when <repo>
# IS that PR's base — querying through the wrong repo (e.g. the head/fork of a
# genuine cross-fork PR) fails closed (gh 404s) instead of silently returning
# an unrelated repo's data. Do NOT pass the head/fork repo here on the
# assumption it's "close enough" — pass the repo you are confident hosts the
# PR (almost always the project's own base repo you're reviewing/merging
# against).
#
# `gh pr view` exposes no baseRepository field, but the PR URL is ALWAYS rooted
# on the base repo — parse owner/repo from it (handles GitHub /pull/ and GitLab
# /-/merge_requests/, including nested GitLab groups). Falls back to the passed
# <repo> when the URL can't be parsed or the scoped gh call fails — so SAME-REPO
# PRs (base == head) resolve exactly as before and this change is a provable
# no-op for them.
#
# Args:
#   pr    — the PR/MR number.
#   repo  — REQUIRED "owner/repo": the repo the caller already knows hosts
#           this PR. Used to SCOPE the gh query (`--repo`), never omitted in
#           favour of gh's ambient default.
#
# Output (stdout): "owner/repo" derived from the resolved PR URL, or the
# passed-in <repo> when the scoped query fails/is unparseable (fail-soft — the
# caller's own repo is still the best available answer).
# Exit code: 0 normally; 1 (with a stderr message, no stdout) when <pr> is
# given but <repo> is missing — there is nothing safe to scope the query to.
pr_base_repo() {
  local pr="${1:-}" repo="${2:-}" url base
  if [ -z "$pr" ]; then
    [ -n "$repo" ] && printf '%s' "$repo"
    return 0
  fi
  if [ -z "$repo" ]; then
    echo "_lib-review-markers.sh: pr_base_repo requires an explicit <repo> (never gh's ambient default — see me2resh/apexyard#887)" >&2
    return 1
  fi
  # ALWAYS scoped to the caller-supplied repo — never an unscoped/ambient gh
  # call. See the WHY-A-REQUIRED-REPO note above.
  url=$(gh pr view "$pr" --repo "$repo" --json url,baseRefName --jq '.url' 2>/dev/null)
  base=$(printf '%s' "$url" | sed -E 's#^https?://[^/]+/(.+)/(pull|-/merge_requests)/[0-9].*#\1#')
  if [ -n "$base" ] && [ "$base" != "$url" ]; then
    printf '%s' "$base"
  else
    printf '%s' "$repo"
  fi
}
