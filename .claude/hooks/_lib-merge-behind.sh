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
#       - "unknown" the lookup failed (network/auth) or an argument was empty —
#                    the caller decides what "unknown" means; this function
#                    never blocks and always exits 0.
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

  local behind_by
  behind_by=$(gh api "repos/${repo}/compare/${base}...${head_sha}" -q '.behind_by' 2>/dev/null)

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
