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
# `hook_drift_notice <file> [<file>...]` prints one short paragraph when any
# of the listed files differs from upstream's copy, and prints nothing
# otherwise. Callers append it to a refusal message they were printing anyway.
#
# `hook_drift_notice_for_gate <gate-file>` is the call site used by a gate. It
# checks the gate itself plus every `.claude/hooks/_lib-*.sh` the gate sources.
# The lib list is derived from the gate's `source` / `.` lines (including a
# `$VAR` source whose assignment in the same file names a `_lib-*.sh`), not
# from a hardcoded list. That is what covers the motivating case: a stale
# `_lib-active-ticket.sh` behind an unchanged `require-active-ticket.sh`.
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
# Known silent false negatives (never false notes): a fork that tracks `dev`
# while a local `upstream/main` exists stays silent, because `main` never
# shipped its blob. A shallow fork whose version is older than the shallow
# boundary also stays silent — `--find-object` cannot see a blob the shallow
# clone never fetched.
#
# Advisory only. Every failure path returns 0 and prints nothing: a gate must
# refuse or permit on its own logic, never on whether this helper worked.

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

# Echo the repo-relative path when <file> is a shipped-but-behind upstream
# copy. Echo nothing otherwise. Always returns 0.
_hd_stale_rel() {
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

  printf '%s\n' "$rel"
}

# From a `.` / `source` argument, emit a `_lib-*.sh` basename when one is
# named on the line, or when a bare `$VAR` / `${VAR}` resolves to an
# assignment in <script> that names one.
_hd_lib_basename_from_source_arg() {
  local script="$1" arg="$2"
  local var assign

  # Strip surrounding quotes.
  case "$arg" in
    \"*\") arg=${arg#\"}; arg=${arg%\"} ;;
    \'*\') arg=${arg#\'}; arg=${arg%\'} ;;
  esac

  case "$arg" in
    *_lib-*.sh*)
      printf '%s' "$arg" | sed -n 's/.*\(_lib-[A-Za-z0-9_-]*\.sh\).*/\1/p'
      return 0
      ;;
  esac

  case "$arg" in
    \$\{[A-Za-z_][A-Za-z0-9_]*\})
      var=${arg#\$\{}
      var=${var%\}}
      ;;
    \$[A-Za-z_][A-Za-z0-9_]*)
      var=${arg#\$}
      ;;
    *)
      return 0
      ;;
  esac
  [ -n "$var" ] || return 0

  # Last assignment of VAR (or `local VAR=...`) in the same file.
  assign=$(grep -E "^[[:space:]]*(local[[:space:]]+)?${var}=" "$script" 2>/dev/null | tail -n 1) || true
  [ -n "$assign" ] || return 0
  case "$assign" in
    *_lib-*.sh*)
      printf '%s' "$assign" | sed -n 's/.*\(_lib-[A-Za-z0-9_-]*\.sh\).*/\1/p'
      ;;
  esac
}

# Emit unique `_lib-*.sh` basenames sourced by <script>, derived from its
# `source` / `.` lines. Not a hardcoded list.
_hd_source_lib_basenames() {
  local script="$1"
  [ -f "$script" ] || return 0

  local tok base seen
  seen=$'\n'
  # Collect `.` / `source` arguments. Inline comments after the path are
  # stripped; `#` inside the path itself does not appear in these hooks.
  while IFS= read -r tok || [ -n "$tok" ]; do
    [ -n "$tok" ] || continue
    base=$(_hd_lib_basename_from_source_arg "$script" "$tok")
    [ -n "$base" ] || continue
    case "$seen" in
      *$'\n'"$base"$'\n'*) continue ;;
    esac
    seen="${seen}${base}"$'\n'
    printf '%s\n' "$base"
  done <<EOF
$(awk '
  /^[[:space:]]*(\.|source)[[:space:]]+/ {
    line = $0
    sub(/^[[:space:]]*(\.|source)[[:space:]]+/, "", line)
    if (match(line, /[[:space:]]+#/)) {
      line = substr(line, 1, RSTART - 1)
    }
    sub(/[[:space:]]+$/, "", line)
    if (length(line) > 0) print line
  }
' "$script")
EOF
}

# Print one note listing every listed file that is a shipped-but-behind
# upstream copy. Accepts one or more paths. Always returns 0.
hook_drift_notice() {
  local stale_rels='' rel f n list file_clause

  for f in "$@"; do
    rel=$(_hd_stale_rel "$f")
    [ -n "$rel" ] || continue
    case $'\n'"$stale_rels" in
      *$'\n'"$rel"$'\n'*) ;;
      *) stale_rels="${stale_rels}${rel}"$'\n' ;;
    esac
  done
  [ -n "$stale_rels" ] || return 0

  list=$(printf '%s' "$stale_rels" | sed '/^$/d' | sed 's/^/  /')
  n=$(printf '%s' "$stale_rels" | sed '/^$/d' | wc -l | tr -d ' ')
  if [ "$n" -eq 1 ]; then
    file_clause="and upstream's copy of that file has changed since your version."
  else
    file_clause="and upstream's copies of those files have changed since your version."
  fi

  cat <<MSG

Note: this refusal came from your fork's copy of
$list
${file_clause} It may
already be fixed. Run /update before investigating the hook or filing a bug
against it.
MSG
}

# Check <gate-file> and every `.claude/hooks/_lib-*.sh` it sources. Lib names
# come from the gate's own `source` / `.` lines (see _hd_source_lib_basenames).
hook_drift_notice_for_gate() {
  local gate="$1"
  [ -n "$gate" ] || return 0
  [ -f "$gate" ] || return 0

  local dir base path
  dir=$(CDPATH='' cd -- "$(dirname -- "$gate")" 2>/dev/null && pwd -P) || return 0

  # Positional list starts with the gate; append each unique existing lib.
  set -- "$gate"
  while IFS= read -r base || [ -n "$base" ]; do
    [ -n "$base" ] || continue
    path="$dir/$base"
    [ -f "$path" ] || continue
    set -- "$@" "$path"
  done <<EOF
$(_hd_source_lib_basenames "$gate")
EOF

  hook_drift_notice "$@"
}
