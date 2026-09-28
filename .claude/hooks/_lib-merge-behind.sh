#!/bin/bash
# _lib-merge-behind.sh — decide whether a PR's head is behind its base
# branch, without relying on the forge's own `mergeStateStatus` field.
#
# WHY THIS EXISTS (me2resh/apexyard#1386)
# ----------------------------------------
# GitHub reports `mergeStateStatus=BEHIND` only when the base branch's
# ruleset has `strict_required_status_checks_policy=true`. When that policy
# is off — the common case, and the case #1386's own issue body describes —
# GitHub instead reports `BLOCKED`, `CLEAN`, or `UNKNOWN` for a PR that is
# genuinely behind its base. A check that reads `mergeStateStatus == BEHIND`
# therefore misses the exact race it was written to catch: a PR 8 or 19
# commits behind an unprotected base branch reports `BLOCKED`, `CLEAN`, or
# `UNKNOWN`, never `BEHIND`.
#
# This library computes "behind" directly from the compare API instead,
# which reports the real commit graph and does not depend on any ruleset
# setting.
#
# PUBLIC FUNCTIONS
# -----------------
#   is_pr_behind_base <owner/repo> <base_branch> <head_sha>
#       Echoes one of: true | false | unknown
#       - "true"    the base branch has commits the head does not (behind_by > 0)
#       - "false"   the head has every commit the base branch has (behind_by == 0)
#       - "unknown" the lookup failed (network/auth, a non-zero exit code
#                    even when stdout printed a number) or an argument was
#                    empty — the caller decides what "unknown" means; this
#                    function never blocks and always exits 0.
#
# The caller supplies the base branch name and the head SHA — this library
# does not itself resolve them, so it stays testable with a stubbed `gh`
# and has no opinion on where those values came from.

is_pr_behind_base() {
  local repo="$1" base="$2" head_sha="$3"
  if [ -z "$repo" ] || [ -z "$base" ] || [ -z "$head_sha" ]; then
    echo "unknown"
    return 0
  fi

  local behind_by rc
  behind_by=$(gh api "repos/${repo}/compare/${base}...${head_sha}" -q '.behind_by' 2>/dev/null)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "unknown"
    return 0
  fi

  case "$behind_by" in
    ''|*[!0-9]*)
      echo "unknown"
      ;;
    0)
      echo "false"
      ;;
    *)
      echo "true"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# CHEAPER MERGE REFRESH (me2resh/apexyard#1437)
# ---------------------------------------------------------------------------
# Two independent cost-cutters for the behind-base flow. Neither weakens the
# skew protection #1386 added — both fail closed on any uncertainty.
#
#   rex_approval_carries_over <owner/repo> <old_sha> <new_sha>
#       Echoes one of: true | false | unknown
#       "true" only when <new_sha> is a two-parent merge commit whose FIRST
#       parent is exactly <old_sha> (the Rex-approved commit) and whose
#       remerge is empty (`git show --remerge-diff`, no conflict fixes, no
#       hand edits). Every other shape — a missing object, a failed fetch,
#       a non-merge commit, an octopus merge (>2 parents), a first parent
#       that isn't <old_sha>, or a non-empty remerge-diff — is "false" or
#       "unknown", never "true". Requires a local git checkout; the caller
#       supplies the two SHAs, this function does not resolve them.
#
#   merge_refresh_required <owner/repo> <base_branch> <pr_number> <merge_base_sha> <shared_patterns>
#       Echoes one of: required | skippable
#       "skippable" only when every file the base branch touched since
#       <merge_base_sha> is NEITHER one of the PR's own files NOR matched by
#       any pattern in <shared_patterns> (newline-separated glob patterns,
#       matched with the same syntax as a bash `case` pattern). Any lookup
#       failure, a truncated compare (300 files or more on either side), or
#       an empty/missing argument returns "required" — this function never
#       returns "skippable" on a result it could not fully verify.

# rex_approval_carries_over <owner/repo> <old_sha> <new_sha>
rex_approval_carries_over() {
  local repo="$1" old_sha="$2" new_sha="$3"
  if [ -z "$repo" ] || [ -z "$old_sha" ] || [ -z "$new_sha" ]; then
    echo "unknown"
    return 0
  fi

  if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "unknown"
    return 0
  fi

  # Best-effort fetch of either object when it isn't present locally. A
  # failed fetch (network, auth, unknown SHA) leaves the object missing —
  # the follow-up cat-file check catches that and returns "unknown".
  if ! git cat-file -e "${new_sha}^{commit}" 2>/dev/null; then
    git fetch -q "https://github.com/${repo}.git" "$new_sha" >/dev/null 2>&1
  fi
  if ! git cat-file -e "${new_sha}^{commit}" 2>/dev/null; then
    echo "unknown"
    return 0
  fi
  if ! git cat-file -e "${old_sha}^{commit}" 2>/dev/null; then
    git fetch -q "https://github.com/${repo}.git" "$old_sha" >/dev/null 2>&1
  fi
  if ! git cat-file -e "${old_sha}^{commit}" 2>/dev/null; then
    echo "unknown"
    return 0
  fi

  local parents parents_rc
  parents=$(git show -s --format='%P' "$new_sha" 2>/dev/null)
  parents_rc=$?
  if [ "$parents_rc" -ne 0 ]; then
    echo "unknown"
    return 0
  fi
  # Word-split on purpose: %P is a space-separated list of parent SHAs.
  # shellcheck disable=SC2206
  local parent_arr=($parents)
  local parent_count="${#parent_arr[@]}"

  if [ "$parent_count" -ne 2 ]; then
    # A non-merge commit (1 parent, e.g. an amend/rebase) or an octopus
    # merge (3+ parents) is never a "clean base merge" — no carry-over.
    echo "false"
    return 0
  fi

  if [ "${parent_arr[0]}" != "$old_sha" ]; then
    echo "false"
    return 0
  fi

  # --remerge-diff re-runs the merge in-memory and diffs it against the
  # recorded tree. Empty output means the recorded merge commit is exactly
  # what git's own merge would produce — no conflict resolution, no hand
  # edit. --format='' suppresses the commit-message header so the check is
  # of the diff alone, not "did git print anything at all".
  local remerge rc
  remerge=$(git show --format='' --remerge-diff "$new_sha" 2>/dev/null)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "unknown"
    return 0
  fi
  if [ -n "$remerge" ]; then
    echo "false"
    return 0
  fi

  echo "true"
}

# _merge_behind_path_matches_any <path> <newline-separated patterns>
# Internal helper. Echoes "true"/"false". Patterns use bash `case` glob
# syntax (`*` matches any run of characters, including `/`).
_merge_behind_path_matches_any() {
  local path="$1" patterns="$2" pattern
  [ -z "$path" ] && { echo "false"; return 0; }
  while IFS= read -r pattern; do
    [ -z "$pattern" ] && continue
    # shellcheck disable=SC2254
    case "$path" in
      $pattern) echo "true"; return 0 ;;
    esac
  done <<EOF
${patterns}
EOF
  echo "false"
}

# merge_refresh_required <owner/repo> <base_branch> <pr_number> <merge_base_sha> <shared_patterns>
merge_refresh_required() {
  local repo="$1" base="$2" pr="$3" merge_base="$4" patterns="${5:-}"

  if [ -z "$repo" ] || [ -z "$base" ] || [ -z "$pr" ] || [ -z "$merge_base" ]; then
    echo "required"
    return 0
  fi

  # Files the PR itself touches. --paginate avoids the 30-per-page default
  # truncating a large PR's file list before the 300-file guard below sees
  # it.
  local pr_files pr_rc
  pr_files=$(gh api "repos/${repo}/pulls/${pr}/files" --paginate -q '.[].filename' 2>/dev/null)
  pr_rc=$?
  if [ "$pr_rc" -ne 0 ]; then
    echo "required"
    return 0
  fi
  local pr_file_count=0
  if [ -n "$pr_files" ]; then
    pr_file_count=$(printf '%s\n' "$pr_files" | grep -c .)
  fi
  if [ "$pr_file_count" -ge 300 ]; then
    echo "required"
    return 0
  fi

  # Files the base branch touched since the merge base — i.e. exactly the
  # commits a refresh would pull in.
  local compare_json compare_rc
  compare_json=$(gh api "repos/${repo}/compare/${merge_base}...${base}" 2>/dev/null)
  compare_rc=$?
  if [ "$compare_rc" -ne 0 ] || [ -z "$compare_json" ]; then
    echo "required"
    return 0
  fi

  local base_file_count
  base_file_count=$(printf '%s' "$compare_json" | jq -r '.files | length' 2>/dev/null)
  case "$base_file_count" in
    ''|*[!0-9]*)
      echo "required"
      return 0
      ;;
  esac
  if [ "$base_file_count" -ge 300 ]; then
    echo "required"
    return 0
  fi
  if [ "$base_file_count" -eq 0 ]; then
    echo "skippable"
    return 0
  fi

  local base_files
  base_files=$(printf '%s' "$compare_json" | jq -r '.files[].filename' 2>/dev/null)
  if [ -z "$base_files" ]; then
    echo "required"
    return 0
  fi

  local f overlap
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    if [ -n "$pr_files" ] && printf '%s\n' "$pr_files" | grep -qxF "$f"; then
      echo "required"
      return 0
    fi
    overlap=$(_merge_behind_path_matches_any "$f" "$patterns")
    if [ "$overlap" = "true" ]; then
      echo "required"
      return 0
    fi
  done <<EOF
${base_files}
EOF

  echo "skippable"
}
