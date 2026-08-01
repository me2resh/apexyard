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
#
# Prefer is_protected_branch() (below) over hand-rolling the grep yourself.
# me2resh/apexyard#1086 step 3 / AgDR-0114: a caller that does its own
# `command -v protected_branch_regex` guard and its own `grep -qE` silently
# ALLOWS whenever either check misbehaves — a renamed/missing function skips
# the guard with no warning, and a malformed `.git.protected_branches[]`
# entry (e.g. an unbalanced-paren fragment like `"ma(in"`) makes `grep -qE`
# exit non-zero for EVERY branch, which an `if grep ...; then BLOCK; fi`
# reads as "never protected". Both are real, both were found on
# `.githooks/pre-push` before this function existed. is_protected_branch()
# is the single place both hardenings live, so every caller inherits them
# by construction instead of by each caller remembering to reimplement them.

# ------------------------------------------------------------------------
# protected_branch_regex
#
# Prints a `|`-joined alternation of protected branch names to stdout (no
# trailing newline guaranteed either way — callers should use it inside
# `$(...)`, which strips trailing newlines regardless).
# ------------------------------------------------------------------------
protected_branch_regex() {
  local hook_dir repo_root regex raw_bash_source_0 candidate_dir

  # SELF-LOCATION BOOTSTRAP (me2resh/apexyard#1102 / AgDR-0118)
  # ------------------------------------------------------------
  # Was `hook_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" ...)"` -- the
  # `:-$0` fallback is a FAKE fix: under zsh, $0 in a sourced file is the
  # sourcing invocation path AS TYPED, not a reliable self-location signal,
  # so it inherits the exact same "dirname resolves to the caller's cwd"
  # hazard `:-` alone has. BASH_SOURCE[0] here still refers to THIS file
  # (bash tracks the currently-executing source file regardless of function
  # nesting depth), so the guard below is safe to apply inside a function
  # body the same way it applies at top level. The bootstrap guard (raw
  # BASH_SOURCE[0] captured once, empty short-circuits to no self-location,
  # never $0) plus `resolve_anchored_lib_dir` in _lib-ops-root.sh (the
  # anchor check) are the ONE shared idiom every _lib-*.sh self-location
  # site now uses -- see that function's header for why the very first hop
  # can never itself be centralized behind a sourced call.
  raw_bash_source_0="${BASH_SOURCE[0]:-}"
  hook_dir=""
  if [ -n "$raw_bash_source_0" ]; then
    candidate_dir="$(cd "$(dirname "$raw_bash_source_0")" 2>/dev/null && pwd)"
  else
    candidate_dir=""
  fi
  if [ -n "$candidate_dir" ] && [ -f "$candidate_dir/_lib-ops-root.sh" ]; then
    # shellcheck source=./_lib-ops-root.sh
    # shellcheck disable=SC1091
    . "$candidate_dir/_lib-ops-root.sh"
    if command -v resolve_anchored_lib_dir >/dev/null 2>&1; then
      hook_dir="$(resolve_anchored_lib_dir "$raw_bash_source_0")"
    fi
  fi

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

# ------------------------------------------------------------------------
# is_protected_branch BRANCH
#
# Fail-closed predicate: returns 0 (shell-true, "protected") when BRANCH
# should be blocked, 1 (shell-false, "not protected") when it's safe to
# proceed. Callers use it as `if is_protected_branch "$BRANCH"; then BLOCK;
# fi`.
#
# Two fail-closed hardenings, both me2resh/apexyard#1086 step 3 / AgDR-0114
# (MEDIUMs found reviewing the issue's step-3 proposal):
#
#   1. protected_branch_regex missing after a successful `source` (a
#      renamed function, a partially-corrupted lib file) -> WARN + treat as
#      protected, instead of the silent `command -v` allow a caller doing
#      its own guard would fall into.
#   2. The composed regex fails to evaluate at all (grep exits > 1 — a
#      malformed `.git.protected_branches[]` entry, e.g. an unbalanced-paren
#      fragment like "ma(in", produces invalid ERE syntax) -> WARN + treat
#      as protected, instead of reading grep's non-zero exit as "no match".
#      grep -qE's exit codes: 0 = match, 1 = no match, >1 = usage/regex
#      error — only 1 means "genuinely not protected".
#
# Both hardenings live HERE, once, so every caller (`.githooks/pre-push`,
# `.githooks/pre-commit`) inherits them by construction rather than by each
# caller separately remembering to guard against the same two failure
# shapes — the exact "two copies that have to be trusted to agree" pattern
# this lib's header comment already warns is this file family's dominant
# defect generator.
# ------------------------------------------------------------------------
is_protected_branch() {
  local branch="$1" regex rc

  if [ -z "$branch" ]; then
    return 1
  fi

  if ! command -v protected_branch_regex >/dev/null 2>&1; then
    echo "WARN: protected_branch_regex is unavailable (renamed, or _lib-protected-branches.sh only partially sourced?) — cannot determine whether '${branch}' is protected. Failing CLOSED (treating it as protected)." >&2
    return 0
  fi

  regex=$(protected_branch_regex)

  echo "$branch" | grep -qE "^(${regex})$" 2>/dev/null
  rc=$?
  case "$rc" in
    0) return 0 ;;  # matched: protected
    1) return 1 ;;  # no match: not protected
    *)
      echo "WARN: protected-branch pattern evaluation failed (grep exit ${rc}) for pattern derived from .git.protected_branches[] — likely a malformed entry (e.g. unbalanced parentheses). Failing CLOSED (treating '${branch}' as protected)." >&2
      return 0 ;;
  esac
}
