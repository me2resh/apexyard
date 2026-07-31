#!/bin/bash
# _lib-protected-branches.sh — single source of truth for the protected-
# branch list, shared by every consumer that needs to answer "is branch X
# one we refuse to push directly to". me2resh/apexyard#1086 step 2.
#
# Not a hook itself (the `_lib-` prefix keeps it out of hook wiring, same
# convention as every other `_lib-*.sh` in this directory). Source it and
# call protected_branch_regex to get a `|`-joined alternation suitable for
# `grep -qE "^(<result>)$"`.
#
# WHY THIS EXISTS
# ---------------
# `.claude/hooks/block-main-push.sh` has resolved this list inline since
# me2resh/apexyard#109 (config_get '.git.protected_branches[]', falling back
# to main|master|dev|develop when config is absent or empty). #1086 adds a
# SECOND consumer — `.githooks/pre-push`, the git-native enforcement layer —
# that needs the exact same list. Re-deriving it a second time inline would
# be precisely the failure mode PR #1087's review flagged as this repo's
# dominant defect generator: two copies of the same resolution that have to
# be trusted to agree, with the agreement asserted in a comment rather than
# enforced in code (see AgDR-0113's whole "additive vs subtractive" /
# "duplicated function" history for how expensive that pattern has been in
# this exact file family).
#
# block-main-push.sh itself is intentionally NOT touched by #1086 step 2 —
# demoting it to advisory is step 3, and must land only after this git-
# native enforcement is proven installed-by-default (step 1) and blocking
# (this file + .githooks/pre-push, step 2). Until step 3 migrates
# block-main-push.sh to source this lib too, its own inline copy remains —
# that overlap is a known, deliberate, temporary consequence of not touching
# it here, not a second FUTURE source of truth: this file is written to be
# the thing step 3 migrates block-main-push.sh onto, not a competing
# implementation.
#
# Resolution order (identical to block-main-push.sh's inline version):
#   1. .claude/project-config.json / .defaults.json -> .git.protected_branches[]
#      (via _lib-read-config.sh, if available)
#   2. Fallback: main|master|dev|develop
#
# Usage:
#   . "$(dirname "$0")/_lib-protected-branches.sh"
#   REGEX=$(protected_branch_regex)
#   echo "$branch" | grep -qE "^(${REGEX})$" && echo "protected"

# ------------------------------------------------------------------------
# protected_branch_regex
#
# Prints a `|`-joined alternation of protected branch names to stdout (no
# trailing newline guaranteed either way — callers should use it inside
# `$(...)`, which strips trailing newlines regardless).
# ------------------------------------------------------------------------
protected_branch_regex() {
  local hook_dir repo_root regex

  hook_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
  repo_root=$(git rev-parse --show-toplevel 2>/dev/null)

  regex=""
  if [ -n "$repo_root" ] && [ -n "$hook_dir" ] && [ -f "$hook_dir/_lib-read-config.sh" ]; then
    # shellcheck disable=SC1090,SC1091
    . "$hook_dir/_lib-read-config.sh"
    regex=$(config_get '.git.protected_branches[]' 2>/dev/null | paste -sd'|' -)
  fi

  if [ -z "$regex" ]; then
    regex="main|master|dev|develop"
  fi

  echo "$regex"
}
