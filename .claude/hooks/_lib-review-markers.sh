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

# ---------------------------------------------------------------------------
# GATE-INVISIBLE (bare-number) MARKER DETECTION — me2resh/apexyard#1144
# ---------------------------------------------------------------------------

# review_role_skill <role>
#
# Maps a marker role to the skill that legitimately produces it, so refusal
# messages can name the right re-run command instead of a generic one.
review_role_skill() {
  case "${1:-}" in
    rex)          printf '/code-review' ;;
    security)     printf '/security-review' ;;
    architecture) printf '/design-review' ;;
    design)       printf '/approve-design' ;;
    ceo)          printf '/approve-merge' ;;
    *)            printf '/code-review' ;;
  esac
}

# unqualified_marker_path <marker_home> <pr> <role>
#
# Echoes the BARE-NUMBER sibling of `review_marker_path`'s output:
#
#   <marker_home>/.claude/session/reviews/<pr>-<role>.approved
#
# This is the pre-AgDR-0060 filename shape, and it is the shape an agent
# produces when a spawn prompt hands it a literal marker path instead of
# letting it resolve one through `review_marker_path` (me2resh/apexyard#1144).
#
# NOTHING READS THIS PATH. Every merge gate — block-unreviewed-merge.sh,
# require-architecture-review.sh, require-design-review-for-ui.sh — resolves
# the marker it looks for through `review_marker_path`, which always emits the
# repo-qualified form. There is no bare-number fallback on any on-disk marker
# lookup. (block-unreviewed-merge.sh does match a bare-number basename when
# scanning the *command text* of a compound write-then-merge command, but that
# is inline-content validation for the CEO marker, not an on-disk read — it
# does not make a bare-number file on disk visible to the gate.)
#
# So a file at this path is GATE-INVISIBLE while looking, to a human running
# `ls .claude/session/reviews/`, exactly like a valid approval. This helper
# exists so gates and skills can NAME that near-miss in their refusal message
# rather than reporting a bare "marker missing".
#
# Output (stdout): the bare-number marker path.
# Exit code: 0 on success; 1 if required args are missing (with stderr msg).
unqualified_marker_path() {
  local marker_home="${1:-${MARKER_HOME:-.}}"
  local pr="${2:-}"
  local role="${3:-}"

  if [ -z "$pr" ] || [ -z "$role" ]; then
    echo "_lib-review-markers.sh: unqualified_marker_path requires <marker_home> <pr> <role>" >&2
    return 1
  fi

  local reviews_dir
  reviews_dir=$(review_markers_dir "$marker_home")

  printf '%s/%s-%s.approved' "$reviews_dir" "$pr" "$role"
}

# unqualified_marker_hint <marker_home> <pr> <role> <expected_path>
#
# Echoes a ready-to-print diagnostic paragraph when a gate-invisible
# bare-number sibling EXISTS on disk for this (pr, role); echoes nothing and
# returns 1 otherwise. Callers append the output to their own refusal message:
#
#   if HINT=$(unqualified_marker_hint "$MARKER_HOME" "$PR" rex "$REX_APPROVAL"); then
#     printf '%s\n' "$HINT" >&2
#   fi
#
# WHY THE "DO NOT MOVE IT" LINE IS THE LOAD-BEARING PART
# -----------------------------------------------------
# The obvious repair for a near-miss marker — renaming it to the qualified
# path — is exactly the marker-forging behaviour `.claude/rules/pr-workflow.md`
# § "Build agents cannot self-review" exists to prevent. An agent that has
# blocked itself on a path mistake, and believes the review genuinely passed,
# is one rationalisation away from hand-writing a gate signal for a review
# this session cannot vouch for. Naming the near-miss without also naming the
# wrong fix would hand that agent a diagnosis and a temptation in the same
# breath. See me2resh/apexyard#1144.
unqualified_marker_hint() {
  local marker_home="${1:-${MARKER_HOME:-.}}"
  local pr="${2:-}"
  local role="${3:-}"
  local expected="${4:-}"
  local near_miss skill

  near_miss=$(unqualified_marker_path "$marker_home" "$pr" "$role") || return 1
  [ -f "$near_miss" ] || return 1
  skill=$(review_role_skill "$role")

  cat <<HINT

NEAR MISS — a gate-invisible marker for this PR exists on disk:

  found:    ${near_miss}
  expected: ${expected}

That file is named in the pre-AgDR-0060 bare-number form. No gate reads it,
which is why this PR reads as unreviewed even though a marker is sitting in
.claude/session/reviews/. It is what you get when a reviewer is handed a
literal marker path in its spawn prompt instead of resolving one through
review_marker_path (me2resh/apexyard#1144).

Do NOT rename, move, or copy it into place. Nothing mechanically stops you,
and that is the point: the qualified path is a gate signal, and relocating a
file to satisfy a gate records a review this session cannot vouch for — the
exact behaviour .claude/rules/pr-workflow.md forbids.

Delete it and re-run the real review, passing NO marker path:

  rm ${near_miss}
  ${skill} ${pr}
HINT
}
