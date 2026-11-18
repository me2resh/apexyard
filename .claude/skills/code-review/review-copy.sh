#!/bin/bash
# review-copy.sh - make, list and remove light review copies (me2resh/apexyard#2070).
#
# A light review copy is a shallow, single-commit, standalone clone of one PR head.
# It is small. It keeps the scratch-clone ticket exemption that a linked worktree
# does not have. All copies live under one folder. Each copy has a record in its
# git directory, so a later sweep can find it.
#
# Run "create" BEFORE the active-reviewer marker is armed. The reviewer mutation
# lock blocks git clone, git fetch and git checkout after that. This script does
# not touch the lock.
#
# Usage:
#   review-copy.sh root
#   review-copy.sh create <repo-url> <owner/name> <pr-number> [<head-sha>]
#   review-copy.sh list
#   review-copy.sh remove <copy-path>
#
# Root folder: $APEXYARD_REVIEW_COPY_ROOT, else <physical temp dir>/apexyard-review-copies.
# Record file: <copy>/.git/apexyard-review-copy.json (never in the work tree).

set -u

RECORD_NAME="apexyard-review-copy.json"

rc_root() {
  local base
  if [ -n "${APEXYARD_REVIEW_COPY_ROOT:-}" ]; then
    printf '%s\n' "${APEXYARD_REVIEW_COPY_ROOT%/}"
    return 0
  fi
  base="${TMPDIR:-/tmp}"
  [ -d "$base" ] || base=/tmp
  base=$(cd "$base" 2>/dev/null && pwd -P) || return 1
  printf '%s/apexyard-review-copies\n' "${base%/}"
}

rc_die() { printf 'review-copy: %s\n' "$*" >&2; exit 1; }

# Validate before resolving so a symlink cannot hide behind its destination.
rc_checked_root() {
  local root metadata owner mode
  root=$(rc_root) || rc_die "cannot resolve the review copy root"
  [ ! -L "$root" ] || rc_die "root must not be a symlink: $root"
  if [ ! -e "$root" ]; then
    # Parent directories may be shared. Only the review root needs mode 0700.
    # shellcheck disable=SC2174
    mkdir -m 700 -p "$root" || rc_die "cannot create $root"
  fi
  [ -d "$root" ] || rc_die "root must be a real directory: $root"
  if metadata=$(stat -c '%u %a' "$root" 2>/dev/null); then
    :
  else
    metadata=$(stat -f '%u %Lp' "$root" 2>/dev/null) || rc_die "cannot inspect root: $root"
  fi
  read -r owner mode <<< "$metadata"
  [ "$owner" = "$(id -u)" ] || rc_die "root must be owned by the current user: $root"
  [[ "$mode" =~ ^[0-7]{3,4}$ ]] || rc_die "cannot read root permissions: $root"
  (( (8#$mode & 0022) == 0 )) || rc_die "root must not be group- or world-writable: $root"
  (cd "$root" && pwd -P) || rc_die "cannot resolve $root"
}

rc_create() {
  local url="${1:-}" repo="${2:-}" pr="${3:-}" sha="${4:-}" root dir got now
  [ -n "$url" ] && [ -n "$repo" ] && [ -n "$pr" ] || rc_die "usage: create <repo-url> <owner/name> <pr-number> [<head-sha>]"
  case "$pr" in ''|*[!0-9]*) rc_die "pr-number must be digits" ;; esac
  [[ "$repo" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || rc_die "repo must be owner/name with safe letters, digits, dot, dash or underscore"
  case "$sha" in *[!0-9a-f]*) rc_die "head-sha must be lower-case hex" ;; esac
  command -v jq >/dev/null 2>&1 || rc_die "jq is required"
  root=$(rc_checked_root) || exit 1
  dir="$root/${repo%/*}__${repo#*/}-pr$pr"
  [ ! -e "$dir" ] && [ ! -L "$dir" ] || rc_die "$dir exists; run remove first"
  git init -q "$dir" || rc_die "git init failed"
  cd "$dir" || rc_die "cannot enter $dir"
  if ! git remote add origin "$url" \
     || ! git fetch -q --depth 1 --no-tags origin "refs/pull/$pr/head" \
     || ! git checkout -q --detach FETCH_HEAD; then
    cd "$root" && rm -rf "$dir"
    rc_die "could not fetch and check out PR $pr from $url"
  fi
  got=$(git rev-parse HEAD) || got=""
  if [ -n "$sha" ] && [ "$got" != "$sha" ]; then
    cd "$root" && rm -rf "$dir"
    rc_die "PR $pr head is $got, not $sha; the PR changed"
  fi
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  if ! jq -n --arg repo "$repo" --argjson pr "$pr" --arg sha "$got" \
    --arg session "${CLAUDE_CODE_SESSION_ID:-unknown}" --arg created "$now" --arg path "$dir" \
    '{repo:$repo,pr:$pr,head_sha:$sha,session:$session,created_at:$created,path:$path}' \
    > "$dir/.git/$RECORD_NAME"; then
    cd "$root" && rm -rf "$dir"
    rc_die "cannot write the record"
  fi
  printf '%s\n' "$dir"
  printf 'review-copy: PR %s at %s\n' "$pr" "${got:0:12}" >&2
}

rc_list() {
  local root f
  root=$(rc_checked_root) || exit 1
  for f in "$root"/*/.git/"$RECORD_NAME"; do
    [ -f "$f" ] || continue
    jq -c 'if (.repo | type) == "string" then
      if (.repo | test("^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$")) then . else .repo = "unknown" end
      else .repo = "unknown" end' "$f" 2>/dev/null || printf '{"path":"%s","error":"unreadable record"}\n' "${f%/.git/*}"
  done
}

rc_remove() {
  local target="${1:-}" root phys
  [ -n "$target" ] || rc_die "usage: remove <copy-path>"
  root=$(rc_checked_root) || exit 1
  [ ! -L "${target%/}" ] || rc_die "copy must not be a symlink: $target"
  [ -d "$target" ] || rc_die "$target is not a folder"
  phys=$(cd "$target" && pwd -P) || rc_die "cannot resolve $target"
  [ "${phys%/*}" = "$root" ] || rc_die "$phys must be a direct child of $root"
  [ -f "$phys/.git/$RECORD_NAME" ] || rc_die "$phys has no review copy record; not removed"
  [ -d "$phys/.git" ] && [ ! -L "$phys/.git" ] || rc_die "$phys is not a standalone clone"
  rm -rf "$phys"
}

case "${1:-}" in
  root) rc_root ;;
  create) shift; rc_create "$@" ;;
  list) rc_list ;;
  remove) shift; rc_remove "$@" ;;
  *) rc_die "usage: review-copy.sh root|create|list|remove" ;;
esac
