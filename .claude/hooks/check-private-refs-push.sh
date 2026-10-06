#!/bin/bash
# Blocks a push when objects being pushed contain a private portfolio
# identifier and the destination remote is not confirmed private.
#
# me2resh/apexyard#1528 / AgDR-0220. Wired from .githooks/pre-push.
#
# Git invokes this with:
#   $1 = remote name (or the URL when pushing by URL)
#   $2 = the URL git actually pushes to (pushurl and insteadOf applied)
#   stdin = pre-push ref lines:
#     <local-ref> <local-sha> <remote-ref> <remote-sha>
#
# The scan reads OBJECTS, not diff lines. For each non-delete ref update it
# lists the new objects (`git rev-list --objects <local-sha> --not <known>`)
# and checks every new blob, every new commit message, and every new
# annotated-tag message with the shared matcher
# (_lib-private-refs-match.sh): whole content, case-insensitive, binary
# included. A merge's resolved blobs, binary and `-diff` files, odd file
# names, and a commit already on another remote are all covered, because no
# diff is parsed and no pathspec is built.
#
# "Known" means (a) the pushed ref's current remote sha from the pre-push
# stdin, when that commit exists locally, (b) tips this hook already scanned
# CLEAN over their full reachable history for the same registry content (a
# local record keyed by a hash of every matcher input), and (c) every commit
# the destination itself currently advertises (git ls-remote --heads --tags
# of $2) that also exists locally. (a) and (c) are destination-derived: they
# are safe for the current push but must not be used to write a clean record.
# A tip is recorded only when its scan covered the full reachable history
# apart from tips that are themselves already full-history-clean records
# (Rex B-1 / #1528). Remote-tracking refs are never trusted: they describe
# the fetch URL's old state, not what this destination holds. When nothing is
# known, everything reachable from the pushed tip is scanned. If ls-remote
# fails or times out, (c) adds nothing (fail closed: full scan).
#
# Also matched: file and directory names, the pushed ref names, and whole
# commit and tag objects (author, committer, tagger headers and message).
#
# Remote classification (_lib-leak-remote-visibility.sh): scan unless the
# remote is confirmed private. Public-class remotes, lookup failures,
# non-GitHub hosts, and unknown visibility all scan (fail closed). The
# remote is classified by $2. Only when $2 is a local path that equals the
# configured remote's resolved push URL is the configured (pre-rewrite) URL
# used instead.
#
# Any git failure on the scan path exits 2. It is never read as "nothing
# to scan".
#
# Bypass: skip git hooks on push (`--no-verify` / unset core.hooksPath).
# No dedicated skip environment variable.

set -u

ALL_ZERO_SHA='0000000000000000000000000000000000000000'
CHUNK_SIZE=200

ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || {
  echo "BLOCKED: cannot resolve the Git root for the push private-reference scan." >&2
  exit 2
}

HOOK_DIR="$ROOT/.claude/hooks"
_SELF_DIR=$(CDPATH="" cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)

_source_lib() {
  local name="$1" path
  for path in "$_SELF_DIR/$name" "$HOOK_DIR/$name"; do
    if [ -f "$path" ]; then
      # shellcheck source=/dev/null
      . "$path"
      return 0
    fi
  done
  return 1
}

if ! _source_lib "_lib-leak-remote-visibility.sh"; then
  echo "BLOCKED: _lib-leak-remote-visibility.sh is missing. Cannot classify the push remote for leak protection." >&2
  exit 2
fi
if ! _source_lib "_lib-private-refs-match.sh"; then
  echo "BLOCKED: _lib-private-refs-match.sh is missing. Cannot scan push content for a private portfolio reference." >&2
  exit 2
fi

REMOTE_NAME="${1:-}"
REMOTE_URL="${2:-}"

# Load the registry first: a repo with nothing to scan never needs a
# visibility lookup (and never calls gh).
private_refs_match_init
init_rc=$?
case "$PRIVATE_REFS_MATCH_INIT_RC" in
  1) exit 0 ;;
  2) exit 2 ;;
esac
[ "$init_rc" -eq 1 ] && exit 0
[ "$init_rc" -eq 2 ] && exit 2

# --- Destination identity -------------------------------------------------
_is_local_target() {
  case "$1" in
    /*|./*|../*|file://*) return 0 ;;
  esac
  return 1
}

_remote_is_configured() {
  case "$1" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  [ -n "$(git config --get "remote.$1.url" 2>/dev/null)" ]
}

CLASSIFY_URL="$REMOTE_URL"
if _remote_is_configured "$REMOTE_NAME"; then
  _push_resolved=$(git remote get-url --push "$REMOTE_NAME" 2>/dev/null || true)
  if [ -n "$REMOTE_URL" ] && [ "$REMOTE_URL" = "$_push_resolved" ] && _is_local_target "$REMOTE_URL"; then
    # Git rewrote a configured URL to a local transport. Use the configured
    # destination (pushurl when set, else url) for visibility.
    CLASSIFY_URL=$(git config --get "remote.${REMOTE_NAME}.pushurl" 2>/dev/null || true)
    [ -n "$CLASSIFY_URL" ] || CLASSIFY_URL=$(git config --get "remote.${REMOTE_NAME}.url" 2>/dev/null || true)
  fi
fi

# Confirmed-private destination → nothing to protect at this boundary.
if [ -n "$CLASSIFY_URL" ] && leak_remote_is_confirmed_private "$CLASSIFY_URL"; then
  exit 0
fi
# Empty / non-GitHub / unknown / public-class → scan (fail closed).


# --- Scan -----------------------------------------------------------------
fail_closed() {
  echo "BLOCKED: the push private-reference scan could not complete ($1). Failing closed. Fix the repository state or skip git hooks deliberately." >&2
  exit 2
}

TMP=$(mktemp -d -t push-leak.XXXXXX) || fail_closed "cannot create a temp directory"
trap 'rm -rf "$TMP"' EXIT

private_refs_write_prefilter "$TMP/patterns"
pf_rc=$?
case "$pf_rc" in
  0) ;;
  1) exit 0 ;; # no scannable token (every entry is public: true)
  *) fail_closed "cannot build the prefilter" ;;
esac

block_push() {
  local object="$1" where="$2"
  cat >&2 <<MSG
BLOCKED: push contains a private portfolio reference.

Object: $object
Location: $where
The matched identifier is intentionally withheld. Replace it with an abstract
description, amend or rewrite the commits, and retry. See
.claude/rules/leak-protection.md § "Remediation" if the identifier has
already reached a public repository.
MSG
  exit 2
}

# Clean-scan records. A tip is recorded only when the scan covered its full
# reachable history apart from tips that are themselves already
# full-history-clean records. Destination-derived exclusions (stdin remote
# sha, ls-remote) stay in the scan for this push but must not produce a
# record: that tip is only known-clean relative to what that destination
# already held (Rex B-1). A recorded tip is then safe to reuse for any
# remote. The record is keyed by a hash of every matcher input (registry
# tokens, flags, identity, matcher version): a registry change makes the
# old record unused. Remote-tracking refs are NOT used.
FINGERPRINT=$(private_refs_match_fingerprint) || fail_closed "cannot fingerprint the match inputs"
[ -n "$FINGERPRINT" ] || fail_closed "empty match fingerprint"
GIT_COMMON=$(git rev-parse --git-common-dir 2>/dev/null) || fail_closed "cannot resolve the git directory"
GIT_COMMON=$(CDPATH="" cd "$GIT_COMMON" && pwd) || fail_closed "cannot resolve the git directory"
REC_DIR="$GIT_COMMON/apexyard-leak-scanned"
REC_FILE="$REC_DIR/$FINGERPRINT"
: > "$TMP/records"
if [ -f "$REC_FILE" ]; then
  # Keep only records whose object still exists locally.
  git cat-file --batch-check='%(objectname) %(objecttype)' < "$REC_FILE" > "$TMP/records.typed" \
    || fail_closed "cannot read the clean-scan records"
  LC_ALL=C grep -E ' (commit|tag)$' "$TMP/records.typed" > "$TMP/records.keep"
  [ "$?" -le 1 ] || fail_closed "grep failed on the clean-scan records"
  cut -d' ' -f1 "$TMP/records.keep" > "$TMP/records" || fail_closed "cut failed"
fi

# Destination refs (exclusion c). Ask the URL git is pushing to — never
# refs/remotes/* — what commits it already holds. Feed as ^sha lines via
# stdin to rev-list (never as argv) so a large ref list stays under the
# Linux argv limit. Missing local objects are ignored. Failure / timeout
# adds nothing (full scan).
#
# TEST ONLY: APEXYARD_LEAK_LS_REMOTE_CMD — invoked as
#   $APEXYARD_LEAK_LS_REMOTE_CMD <dest-url>
# Must print git ls-remote --heads --tags style lines on stdout. Honoured
# only when APEXYARD_LEAK_TEST_MODE=1; without the flag the override is
# ignored and real `git ls-remote` runs. Used by hook tests to force a
# failure; production uses git ls-remote.
# APEXYARD_LEAK_LS_REMOTE_TIMEOUT — shortens the limit (fail closed: no
# exclusions). APEXYARD_LEAK_PUSH_TRACE — append-only debug; no verdict change.
_LS_REMOTE_TIMEOUT_SECONDS=5
: > "$TMP/dest_not"
_collect_dest_exclusions() {
  local dest="$1" out rc line sha secs
  [ -n "$dest" ] || return 0
  secs="$_LS_REMOTE_TIMEOUT_SECONDS"
  case "${APEXYARD_LEAK_LS_REMOTE_TIMEOUT:-}" in
    ''|*[!0-9]*) ;;
    *) secs="$APEXYARD_LEAK_LS_REMOTE_TIMEOUT" ;;
  esac

  if [ "${APEXYARD_LEAK_TEST_MODE:-}" = "1" ] \
    && [ -n "${APEXYARD_LEAK_LS_REMOTE_CMD:-}" ]; then
    # TEST ONLY — see comment above. Word-splitting the command is intended.
    # shellcheck disable=SC2086
    out=$(_leak_run_limited "$secs" $APEXYARD_LEAK_LS_REMOTE_CMD "$dest")
  else
    out=$(_leak_run_limited "$secs" git ls-remote --heads --tags "$dest")
  fi
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "note: could not read the destination's refs; scanning the full history reachable from each tip." >&2
    return 0
  fi

  # ls-remote lines: "<sha>\t<ref>" (and peeled "<sha>\t<ref>^{}" for
  # annotated tags). Keep only shas that resolve to a local commit.
  # Pipe (not argv) so a large ref list never hits the Linux argv limit.
  printf '%s\n' "$out" | while IFS= read -r line; do
    [ -n "$line" ] || continue
    sha=${line%%[ 	]*}
    case "$sha" in
      [0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) ;;
      *) continue ;;
    esac
    if git cat-file -e "${sha}^{commit}" 2>/dev/null; then
      printf '^%s\n' "$sha"
    fi
  done >> "$TMP/dest_not"
}

_collect_dest_exclusions "$REMOTE_URL"

# True when this ref's exclusion list used a destination-derived exclusion
# (stdin remote sha that exists locally, or any ls-remote commit). Such a
# scan must not write a clean record for the tip.
_used_dest_exclusion() {
  local remote_sha="$1"
  if [ "$remote_sha" != "$ALL_ZERO_SHA" ] \
    && git cat-file -e "${remote_sha}^{commit}" 2>/dev/null; then
    return 0
  fi
  [ -s "$TMP/dest_not" ]
}

# Print "<sha> <path>" lines of the new objects for one ref update.
_new_objects() {
  local local_sha="$1" remote_sha="$2"
  {
    printf '%s\n' "$local_sha"
    # What the destination reported holding for this ref.
    if [ "$remote_sha" != "$ALL_ZERO_SHA" ] \
      && git cat-file -e "${remote_sha}^{commit}" 2>/dev/null; then
      printf '^%s\n' "$remote_sha"
    fi
    # Tips this hook already scanned clean (full history) for this registry.
    sed 's/^/^/' "$TMP/records"
    # Commits the destination itself currently advertises (ls-remote).
    cat "$TMP/dest_not"
  } > "$TMP/revin" || return 1
  git rev-list --objects --stdin < "$TMP/revin"
}

_trace() {
  [ -n "${APEXYARD_LEAK_PUSH_TRACE:-}" ] && printf '%s\n' "$1" >> "$APEXYARD_LEAK_PUSH_TRACE"
  return 0
}

# Match a whole object (a blob, or a whole commit/tag object including its
# author, committer and tagger headers). $1 file, $2 sha, $3 type.
_check_file() {
  local f="$1" sha="$2" type="$3" path pf_status

  # Cheap prefilter before the precise matcher.
  LC_ALL=C tr 'A-Z' 'a-z' < "$f" | LC_ALL=C grep -a -F -c -f "$TMP/patterns" > "$TMP/hits"
  pf_status=("${PIPESTATUS[@]}")
  [ "${pf_status[0]}" -eq 0 ] || fail_closed "tr failed"
  [ "${pf_status[1]}" -le 1 ] || fail_closed "grep prefilter failed"
  [ "${pf_status[1]}" -eq 1 ] && return 0

  if private_refs_match_text_file "$f"; then
    case "$type" in
      blob)
        path=$(grep -m1 "^$sha " "$TMP/objs" | cut -d' ' -f2-)
        block_push "$sha" "file: ${path:-unknown path}"
        ;;
      commit) block_push "$sha" "commit message or header (author, committer)" ;;
      tag) block_push "$sha" "annotated tag message or header (tagger)" ;;
    esac
  fi
}

_check_object() {
  local sha="$1" type="$2" f="$TMP/obj"
  case "$type" in
    blob|commit|tag)
      git cat-file "$type" "$sha" > "$f" || fail_closed "cannot read $type $sha"
      ;;
    *) return 0 ;;
  esac
  _check_file "$f" "$sha" "$type"
}

_check_ref_names() {
  printf '%s\n%s\n' "$1" "$2" > "$TMP/refnames" || fail_closed "cannot write the ref names"
  if private_refs_match_text_file "$TMP/refnames"; then
    block_push "$1" "ref name"
  fi
}

# Match the path column of the new objects (file and directory names).
_check_paths() {
  local line path
  : > "$TMP/paths"
  while IFS= read -r line; do
    case "$line" in
      *" "*)
        path=${line#* }
        # The registry file's own path names no project.
        [ -n "${PRIVATE_REFS_REGISTRY_REL:-}" ] && [ "$path" = "$PRIVATE_REFS_REGISTRY_REL" ] && continue
        printf '%s\n' "$path" >> "$TMP/paths"
        ;;
    esac
  done < "$TMP/objs"
  [ -s "$TMP/paths" ] || return 0
  if private_refs_match_text_file "$TMP/paths"; then
    # The path itself carries the identifier, so it is not printed.
    block_push "a tree entry" "a file or directory name in the pushed tree (path withheld)"
  fi
}

_scan_ref() {
  local local_sha="$1" remote_sha="$2" st ps_git ps_grep pipe_status
  local chunk sha type line

  _new_objects "$local_sha" "$remote_sha" > "$TMP/objs" 2>/dev/null \
    || fail_closed "git rev-list failed for $local_sha"
  _trace "scan objects=$(wc -l < "$TMP/objs" | tr -d ' ')"
  [ -s "$TMP/objs" ] || return 0

  _check_paths

  # Object ids only (a path with an embedded newline yields a junk line,
  # which is dropped here).
  LC_ALL=C grep -E '^[0-9a-f]{40}([0-9a-f]{24})?( |$)' "$TMP/objs" > "$TMP/objs.ok"
  st=$?
  [ "$st" -le 1 ] || fail_closed "grep failed"
  cut -d' ' -f1 "$TMP/objs.ok" > "$TMP/shas" || fail_closed "cut failed"
  [ -s "$TMP/shas" ] || return 0

  # Keep blobs, commits, and tags. Trees carry only names and ids.
  git cat-file --batch-check='%(objectname) %(objecttype)' < "$TMP/shas" > "$TMP/typed" \
    || fail_closed "git cat-file --batch-check failed"
  LC_ALL=C grep -E ' (blob|commit|tag)$' "$TMP/typed" > "$TMP/typed.keep"
  st=$?
  [ "$st" -le 1 ] || fail_closed "grep failed"
  [ -s "$TMP/typed.keep" ] || return 0

  # The registry file itself names every project and is exempt by path, as in
  # the staged scan. Drop the blob ids listed under exactly that path.
  if [ -n "${PRIVATE_REFS_REGISTRY_REL:-}" ]; then
    : > "$TMP/skip"
    while IFS= read -r line; do
      case "$line" in
        *" "*)
          if [ "${line#* }" = "$PRIVATE_REFS_REGISTRY_REL" ]; then
            printf '%s \n' "${line%% *}" >> "$TMP/skip"
          fi
          ;;
      esac
    done < "$TMP/objs"
    if [ -s "$TMP/skip" ]; then
      LC_ALL=C grep -v -F -f "$TMP/skip" "$TMP/typed.keep" > "$TMP/typed.f"
      st=$?
      [ "$st" -le 1 ] || fail_closed "grep failed"
      mv "$TMP/typed.f" "$TMP/typed.keep" || fail_closed "mv failed"
    fi
  fi
  [ -s "$TMP/typed.keep" ] || return 0

  rm -f "$TMP"/chunk.*
  split -l "$CHUNK_SIZE" "$TMP/typed.keep" "$TMP/chunk." || fail_closed "split failed"

  for chunk in "$TMP"/chunk.*; do
    [ -f "$chunk" ] || continue
    cut -d' ' -f1 "$chunk" > "$TMP/cur.ids" || fail_closed "cut failed"
    # One stream per chunk. A hit only marks the chunk for precise checks.
    # Lowercase with tr, then grep -F: BSD grep -i -F is orders of magnitude
    # slower on large input.
    git cat-file --batch < "$TMP/cur.ids" 2>/dev/null \
      | LC_ALL=C tr 'A-Z' 'a-z' \
      | LC_ALL=C grep -a -F -c -f "$TMP/patterns" > "$TMP/hits"
    pipe_status=("${PIPESTATUS[@]}")
    ps_git=${pipe_status[0]}
    ps_grep=${pipe_status[2]}
    [ "$ps_git" -eq 0 ] || fail_closed "git cat-file --batch failed"
    [ "${pipe_status[1]}" -eq 0 ] || fail_closed "tr failed"
    [ "$ps_grep" -le 1 ] || fail_closed "grep prefilter failed"
    [ "$ps_grep" -eq 1 ] && continue
    while IFS=' ' read -r sha type; do
      [ -n "$sha" ] || continue
      _check_object "$sha" "$type"
    done < "$chunk"
  done
  rm -f "$TMP"/chunk.*
}

: > "$TMP/tips"
while IFS=' ' read -r local_ref local_sha remote_ref remote_sha; do
  [ -n "$local_sha" ] || continue
  # Deletes: no content leaves.
  [ "$local_sha" = "$ALL_ZERO_SHA" ] && continue
  _check_ref_names "$local_ref" "$remote_ref"
  _scan_ref "$local_sha" "${remote_sha:-$ALL_ZERO_SHA}"
  # Record only full-history-clean tips (no destination-derived exclusions).
  if ! _used_dest_exclusion "${remote_sha:-$ALL_ZERO_SHA}"; then
    printf '%s\n' "$local_sha" >> "$TMP/tips"
  fi
done

# Tips whose scan covered full history (minus prior full-history-clean
# records): persist them for reuse on any destination.
if [ -s "$TMP/tips" ]; then
  mkdir -p "$REC_DIR" 2>/dev/null || exit 0
  for _old in "$REC_DIR"/*; do
    [ -f "$_old" ] && [ "$_old" != "$REC_FILE" ] && rm -f "$_old"
  done
  cat "$TMP/tips" >> "$REC_FILE" 2>/dev/null || exit 0
  # Bound the file; the newest tips cover the older ones.
  if tail -n 200 "$REC_FILE" > "$REC_FILE.tmp" 2>/dev/null; then
    mv "$REC_FILE.tmp" "$REC_FILE" 2>/dev/null || rm -f "$REC_FILE.tmp"
  fi
fi

exit 0
