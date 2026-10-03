#!/bin/bash
# Stale-hook notice (me2resh/apexyard#1449).
#
# A fork trails upstream between syncs, and `check-upstream-drift.sh` stays
# deliberately quiet about the commits in between so its own banner keeps
# meaning "a release is out". The cost is that a fork owner reading a hook has
# no way to know whether it is the current one. When a gate then refuses
# something that looks like it should have passed, the natural next step is to
# investigate the hook, or file a bug against it, against a copy upstream may
# have already fixed.
#
# `hook_drift_notice <hook-file>` prints one short paragraph when the fork's
# copy of that file differs from upstream's, and prints nothing otherwise.
# Callers append it to a refusal message they were printing anyway.
#
# It compares BLOB CONTENT, not commit ancestry. An earlier revision counted
# `git rev-list HEAD..<ref> -- <path>` and that was unsound: releases reach
# `main` as squash commits, so no individual `dev` commit is ever an ancestor
# of a release tag. A fork synced to the latest release therefore "lacks"
# every `dev` commit that ever touched the file, even when the content is
# byte-identical. Measured against v5.7.0: 57 files under .claude/hooks/ were
# identical to `upstream/dev` while the ancestry count was non-zero — among
# them `_lib-active-ticket.sh`, the file whose fix motivated #1449 in the
# first place. That is the noise this feature exists to avoid, aimed at the
# adopter who followed the sync contract.
#
# Three properties are deliberate:
#
#   - It NEVER performs network I/O. It reads an `upstream/*` ref already in
#     the local object store. A hook runs inside a PreToolUse call, where a
#     fetch could hang on a credential prompt or a dead network; a silent,
#     possibly-stale answer is the right trade for a gate. `GIT_NO_LAZY_FETCH`
#     and `GIT_TERMINAL_PROMPT` close the partial-clone case where a
#     path-limited read would otherwise lazily fetch from a promisor remote.
#   - A locally customised hook stays silent. The note is printed only when
#     the fork's blob is a version upstream itself once shipped, which
#     `git log --find-object` answers locally. An adopter's own edit is not a
#     version upstream shipped, so it never matches.
#   - It names no commit count. Under squash releases a count cannot be made
#     to mean anything reliable, so the message describes the file instead.
#
# Advisory only. Every failure path returns 0 and prints nothing: a gate must
# refuse or permit on its own logic, never on whether this helper worked.

hook_drift_notice() {
  local hook_file="$1"
  [ -n "$hook_file" ] || return 0
  [ -f "$hook_file" ] || return 0
  command -v git >/dev/null 2>&1 || return 0

  local dir abs root rel ref cand fork_blob up_blob shipped
  # `pwd -P` and `--show-toplevel` must both be physical paths, or the prefix
  # strip below silently fails and the notice never fires. On macOS a temp or
  # home path is routinely a symlink (/var -> /private/var), so a logical
  # `pwd` here would disagree with git's answer for the same directory.
  dir=$(CDPATH='' cd -- "$(dirname -- "$hook_file")" 2>/dev/null && pwd -P) || return 0
  abs="$dir/$(basename -- "$hook_file")"
  root=$(_hd_git "$dir" rev-parse --show-toplevel) || return 0
  [ -n "$root" ] || return 0
  root=$(CDPATH='' cd -- "$root" 2>/dev/null && pwd -P) || return 0

  # No upstream remote means no fork relationship to report on.
  _hd_git "$root" remote get-url upstream >/dev/null 2>&1 || return 0

  rel="${abs#"$root"/}"
  # An absolute path that never had $root as a prefix is not a file in this
  # repository; reading a blob at that path would find nothing.
  case "$rel" in /*) return 0 ;; esac

  # The file that actually ran is the working-tree copy, not HEAD's — an
  # uncommitted local edit should count as the fork's version.
  fork_blob=$(_hd_git "$root" hash-object -- "$abs")
  [ -n "$fork_blob" ] || return 0

  # First upstream ref that exists LOCALLY. `main` comes first because it is
  # the adopter sync contract (`/update`, AgDR-0007); a fork that tracks `dev`
  # has a blob that `main` never shipped, so the --find-object check below
  # keeps it silent rather than reporting against the wrong line.
  # The candidates are listed literally rather than expanded from a variable:
  # an unquoted expansion would depend on the shell word-splitting it, which
  # bash does and zsh does not.
  for cand in upstream/main upstream/dev upstream/master; do
    _hd_git "$root" rev-parse --verify --quiet "$cand" >/dev/null 2>&1 || continue
    up_blob=$(_hd_git "$root" rev-parse -q --verify "$cand:$rel")
    [ -n "$up_blob" ] || continue
    ref="$cand"
    break
  done
  [ -n "${ref:-}" ] && [ -n "${up_blob:-}" ] || return 0

  # Identical content: nothing to say, whatever the commit graph looks like.
  [ "$fork_blob" != "$up_blob" ] || return 0

  # Speak only if the fork's copy is a version upstream once shipped. This is
  # what separates "behind" from "customised": an adopter's own edit never
  # appears in upstream history, so it stays silent.
  shipped=$(_hd_git "$root" log -1 --format=%H --find-object="$fork_blob" "$ref" -- "$rel")
  [ -n "$shipped" ] || return 0

  cat <<MSG

Note: this refusal came from your fork's copy of
  $rel
and upstream's copy of that file has changed since your version. It may
already be fixed. Run /update before investigating the hook or filing a bug
against it.
MSG
}

# Every git call the helper makes, with the two environment guards applied in
# one place. GIT_NO_LAZY_FETCH (git 2.45+) stops a path-limited read in a
# treeless partial clone from fetching missing objects from the promisor
# remote; GIT_TERMINAL_PROMPT=0 stops any such attempt from blocking on
# credentials. Both matter because this runs inside a PreToolUse hook.
_hd_git() {
  local wd="$1"
  shift
  GIT_NO_LAZY_FETCH=1 GIT_TERMINAL_PROMPT=0 git -C "$wd" "$@" 2>/dev/null
}
