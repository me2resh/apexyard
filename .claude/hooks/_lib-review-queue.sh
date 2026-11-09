#!/bin/bash
# _lib-review-queue.sh - human review queue counter.
# me2resh/apexyard#1995 / AgDR-0292
#
# A PR counts when: a Rex marker exists whose recorded SHA equals the open PR
# head (prefix match) and no current CEO approval exists for that head.
#
# Public functions:
#   review_queue_line [ops_root]
#       Print the waiting line to stdout.
#       Set REVIEW_QUEUE_COUNT (empty string if unknown).
#       Return the count capped at 254, or 255 if unknown.
#
#   review_queue_check [ops_root]
#       If the queue count is at or above review_queue.limit, print a
#       warning or refuse message to stderr. Return 2 on refuse; 0
#       otherwise. Unknown tracker count never refuses.

[ -n "${_LIB_REVIEW_QUEUE_SOURCED:-}" ] && return 0
_LIB_REVIEW_QUEUE_SOURCED=1

# Self-location (bash only). Used by the lazy dep loader.
_REVIEW_QUEUE_LIB_DIR=""
if [ -n "${BASH_VERSION:-}" ]; then
  _REVIEW_QUEUE_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-}")" 2>/dev/null && pwd) || true
fi

# _review_queue_load_deps
# Source review-markers, config, and tracker libs when not yet loaded.
# Returns 0 when all deps are available; 1 otherwise.
_review_queue_load_deps() {
  if [ -z "$_REVIEW_QUEUE_LIB_DIR" ]; then return 1; fi

  if ! command -v review_markers_dir >/dev/null 2>&1; then
    # shellcheck source=/dev/null
    . "$_REVIEW_QUEUE_LIB_DIR/_lib-review-markers.sh" 2>/dev/null || return 1
  fi
  if ! command -v config_get_or >/dev/null 2>&1; then
    # shellcheck source=/dev/null
    . "$_REVIEW_QUEUE_LIB_DIR/_lib-read-config.sh" 2>/dev/null || return 1
  fi
  if ! command -v tracker_open_pr_heads >/dev/null 2>&1; then
    # shellcheck source=/dev/null
    . "$_REVIEW_QUEUE_LIB_DIR/_lib-tracker.sh" 2>/dev/null || return 1
  fi
  return 0
}

REVIEW_QUEUE_COUNT=""

# review_queue_line [ops_root]
#
# Print one line to stdout in one of two shapes:
#   "Waiting on you: N PRs, the oldest X hours"   - when count is known
#   "Waiting on you: unknown"                      - on tracker failure
#
# Side effects:
#   Sets REVIEW_QUEUE_COUNT to the integer count, or empty string if unknown.
#
# Return value:
#   The count capped at 254 on success, or 255 on unknown.
#
# A count of zero is returned without any tracker network call.
review_queue_line() {
  local ops="${1:-}"
  local reviews_dir sha repo pr mtime core base safe_repo
  local tmpdir candidate_file repos_file pr_heads_file
  local match_count min_mtime oldest_hours now repo_safe head
  local tracker_ok rex_file ceo_file ceo_sha

  REVIEW_QUEUE_COUNT=""

  _review_queue_load_deps || {
    printf 'Waiting on you: unknown\n'
    return 255
  }

  # Resolve ops root when not supplied.
  if [ -z "$ops" ]; then
    if [ -n "${APEXYARD_OPS_ROOT:-}" ]; then
      ops="$APEXYARD_OPS_ROOT"
    elif command -v resolve_ops_root >/dev/null 2>&1; then
      ops=$(resolve_ops_root "$PWD" 2>/dev/null) || ops=""
    fi
  fi

  if [ -z "$ops" ]; then
    printf 'Waiting on you: unknown\n'
    return 255
  fi

  reviews_dir=$(review_markers_dir "$ops")

  # Portable epoch seconds.
  now=$(date '+%s' 2>/dev/null) || now=0

  tmpdir=$(mktemp -d 2>/dev/null) || {
    printf 'Waiting on you: unknown\n'
    return 255
  }
  candidate_file="$tmpdir/candidates"

  # Collect Rex markers for comparison with open PR heads.
  if [ -d "$reviews_dir" ]; then
    for rex_file in "$reviews_dir"/*-rex.approved; do
      [ -f "$rex_file" ] || continue
      base=$(basename "$rex_file")
      core="${base%-rex.approved}"

      # Parse: <safe_repo>__<pr>  (last __ segment is the PR number).
      pr="${core##*__}"
      safe_repo="${core%__*}"

      # Require a numeric PR and a non-empty safe_repo.
      case "$pr" in *[!0-9]*|'') continue ;; esac
      [ -n "$safe_repo" ] || continue
      # safe_repo must look like owner__repo (at least one __ separator).
      case "$safe_repo" in *__*) ;; *) continue ;; esac

      # Reconstruct the original owner/repo.
      repo=$(printf '%s' "$safe_repo" | sed 's/__/\//g')
      [ -n "$repo" ] || continue

      # Read the recorded SHA from the first line of the rex marker.
      sha=$(head -n 1 "$rex_file" 2>/dev/null | tr -d '\r\n ' | tr '[:upper:]' '[:lower:]')
      [ -n "$sha" ] || continue

      # Portable mtime: GNU stat -c then BSD/macOS stat -f.
      mtime=$(stat -c '%Y' "$rex_file" 2>/dev/null \
              || stat -f '%m' "$rex_file" 2>/dev/null \
              || printf '0')
      mtime="${mtime:-0}"

      printf '%s\t%s\t%s\t%s\n' "$sha" "$repo" "$pr" "$mtime" >> "$candidate_file"
    done
  fi

  # Zero candidates - no network call needed.
  if [ ! -s "${candidate_file:-}" ]; then
    rm -rf "$tmpdir"
    REVIEW_QUEUE_COUNT=0
    printf 'Waiting on you: 0 PRs, the oldest 0 hours\n'
    return 0
  fi

  # Build the unique-repos list.
  repos_file="$tmpdir/repos"
  cut -f2 "$candidate_file" | sort -u > "$repos_file"

  # Fetch open PR heads once per repo.
  tracker_ok=1
  while IFS= read -r repo; do
    repo_safe=$(printf '%s' "$repo" | tr '/' '_' | tr -c 'A-Za-z0-9_' '_')
    pr_heads_file="$tmpdir/heads_${repo_safe}"
    if ! tracker_open_pr_heads "$repo" > "$pr_heads_file" 2>/dev/null; then
      tracker_ok=0
      break
    fi
    # Require parseable JSON.
    if ! jq -e . "$pr_heads_file" >/dev/null 2>&1; then
      tracker_ok=0
      break
    fi
  done < "$repos_file"

  if [ "$tracker_ok" = 0 ]; then
    rm -rf "$tmpdir"
    REVIEW_QUEUE_COUNT=""
    printf 'Waiting on you: unknown\n'
    return 255
  fi

  match_count=0
  min_mtime=0

  # Count PRs whose open head starts with the rex marker SHA.
  while IFS='	' read -r sha repo pr mtime; do
    repo_safe=$(printf '%s' "$repo" | tr '/' '_' | tr -c 'A-Za-z0-9_' '_')
    pr_heads_file="$tmpdir/heads_${repo_safe}"
    [ -f "$pr_heads_file" ] || continue

    # Look up this PR's head SHA in the per-repo JSON.
    head=$(jq -r --arg num "$pr" \
      '.[] | select(.number == ($num | tonumber)) | .head' \
      "$pr_heads_file" 2>/dev/null | head -n 1)
    [ -n "$head" ] && [ "$head" != "null" ] || continue

    # Prefix match (long SHA starts with short marker SHA, or exact).
    case "$head" in
      "${sha}"*) ;;
      *) continue ;;
    esac

    # Only a CEO approval for the current head removes this PR.
    ceo_file=$(review_marker_path "$repo" "$pr" ceo "$ops")
    ceo_sha=$(awk -F= '$1 == "sha" { print $2; exit }' "$ceo_file" 2>/dev/null \
      | tr -d '\r\n ' | tr '[:upper:]' '[:lower:]')
    if [ -n "$ceo_sha" ]; then
      case "$head" in "${ceo_sha}"*) continue ;; esac
    fi

    match_count=$((match_count + 1))
    if [ "$min_mtime" = 0 ] || [ "$mtime" -lt "$min_mtime" ]; then
      min_mtime="$mtime"
    fi
  done < "$candidate_file"

  rm -rf "$tmpdir"

  # Oldest waiting time in hours.
  oldest_hours=0
  if [ "$min_mtime" -gt 0 ] && [ "$now" -gt 0 ] && [ "$now" -ge "$min_mtime" ]; then
    oldest_hours=$(( (now - min_mtime) / 3600 ))
  fi

  REVIEW_QUEUE_COUNT="$match_count"
  printf 'Waiting on you: %s PRs, the oldest %s hours\n' "$match_count" "$oldest_hours"
  [ "$match_count" -lt 254 ] || return 254
  return "$match_count"
}

# review_queue_check [ops_root]
#
# Check the queue against the configured limit.
# Prints a WARN or REFUSE message to stderr when the queue is full.
# Returns 2 when mode is "refuse" and count >= limit; 0 otherwise.
# An unknown tracker count (REVIEW_QUEUE_COUNT empty) never refuses.
review_queue_check() {
  local ops="${1:-}"
  local line limit mode count _rq_tmp

  _review_queue_load_deps || return 0

  # Call review_queue_line in the current shell (not via $()) so that
  # REVIEW_QUEUE_COUNT propagates back to this scope. Capture stdout via
  # a temp file.
  _rq_tmp=$(mktemp 2>/dev/null) || return 0
  review_queue_line "$ops" > "$_rq_tmp" 2>/dev/null || true
  line=$(cat "$_rq_tmp" 2>/dev/null || true)
  rm -f "$_rq_tmp"
  count="${REVIEW_QUEUE_COUNT:-}"

  # Unknown tracker: print the line, never refuse.
  if [ -z "$count" ]; then
    [ -n "$line" ] && printf '%s\n' "$line" >&2
    return 0
  fi

  limit=$(config_get_or '.review_queue.limit' '4')
  # Default to 4 when config returns a non-integer.
  case "$limit" in *[!0-9]*|'') limit=4 ;; esac

  # Queue within limit: nothing to report.
  if [ "$count" -lt "$limit" ]; then
    return 0
  fi

  mode=$(config_get_or '.review_queue.mode' 'warn')

  printf '[review-queue] %s\n' "$line" >&2
  case "$mode" in
    refuse)
      printf '[review-queue] REFUSE: %s PRs await /approve-merge (limit %s). Clear the queue before spawning.\n' \
        "$count" "$limit" >&2
      return 2
      ;;
    *)
      printf '[review-queue] WARN: %s PRs await /approve-merge (limit %s). Consider running /approve-merge.\n' \
        "$count" "$limit" >&2
      return 0
      ;;
  esac
}
