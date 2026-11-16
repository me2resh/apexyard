#!/usr/bin/env bash
# disk-usage.sh - one-line ApexYard disk use for /status (me2resh/apexyard#2070, step 5).
#
# Output (one line, always exit 0):
#   ApexYard is using 12.3 GB; 9.1 GB can be reclaimed
#   ApexYard is using 12.3 GB; reclaimable size unknown
#   ApexYard disk use is unknown (measurement timed out)
#
# --json prints one object: schema (apexyard.disk-usage/1), used_bytes,
# reclaimable_bytes, reclaimable_is_lower_bound, timed_out, max_owned_bytes.
# Sizes are integer bytes, or null when measurement cannot run.
# The schema version changes only on a breaking change.
# Read-only. It never deletes, never fetches, never blocks for long.
# Folders measured (only folders that ApexYard owns):
#   - <workspace>/*.worktrees       (worktrees of managed projects)
#   - review-copy folders           (review-copy.sh root, plus disk_budget.review_copy_roots)
#   - <ops>/.claude/session         (session state)
#   - build output in <workspace>/*/ (node_modules, target, build, dist, coverage)
#
# Reclaimable = worktrees and review copies older than sweep_min_age_days,
# with no uncommitted, untracked or stashed work, no commits that are not on
# a remote, and a merged or closed PR. A blocked check gives "at least X".
#
# Inputs (env, all optional; tests use them):
#   APEXYARD_OPS_ROOT      ops-fork root (default: walk up from this script)
#   APEXYARD_GH            gh binary (default: gh)
#   APEXYARD_DISK_TIMEBOX  total seconds for the whole measurement (default 6)

set -u

json=false
[ "${1:-}" != --json ] || json=true
max_gb=10
usage_json() {
  printf '{"schema":"apexyard.disk-usage/1","used_bytes":%s,"reclaimable_bytes":%s,"reclaimable_is_lower_bound":%s,"timed_out":%s,"max_owned_bytes":%s}\n' \
    "$1" "$2" "$3" "$4" "$(awk -v g="$max_gb" 'BEGIN { printf "%.0f", g * 1073741824 }')"
}
unknown() {
  if $json; then usage_json null null false "${2:-false}"
  else echo "ApexYard disk use is unknown ($1)"; fi
}

ops_root="${APEXYARD_OPS_ROOT:-}"
if [ -z "$ops_root" ]; then
  ops_root=$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/../../.." 2>/dev/null && pwd -P) || ops_root=""
fi
[ -n "$ops_root" ] || { unknown "no ops root"; exit 0; }

gh_bin="${APEXYARD_GH:-gh}"
timebox="${APEXYARD_DISK_TIMEBOX:-6}"
case "$timebox" in ''|*[!0-9]*) timebox=6 ;; esac

# The config library finds the repo from the working directory.
cd "$ops_root" 2>/dev/null || { unknown "no ops root"; exit 0; }
# Step 4 owns the disk_budget keys. Built-in defaults apply until they exist.
max_gb=10; age_days=7
review_roots_cfg=""; extra_paths=""
workspace_dir=""
if [ -f "$ops_root/.claude/hooks/_lib-read-config.sh" ]; then
  # shellcheck source=/dev/null
  . "$ops_root/.claude/hooks/_lib-read-config.sh" 2>/dev/null
  if command -v config_get_or >/dev/null 2>&1; then
    max_gb=$(config_get_or '.disk_budget.max_owned_gb' 10 2>/dev/null)
    age_days=$(config_get_or '.disk_budget.sweep_min_age_days' 7 2>/dev/null)
    cfg_timeout=$(config_get_or '.disk_budget.measure_timeout_seconds' '' 2>/dev/null)
    [ -n "${APEXYARD_DISK_TIMEBOX:-}" ] || timebox="$cfg_timeout"
    review_roots_cfg=$(config_get '.disk_budget.review_copy_roots[]?' 2>/dev/null)
    extra_paths=$(config_get '.disk_budget.extra_paths[]?' 2>/dev/null)
  fi
fi
case "$timebox" in ''|*[!0-9]*) timebox=6 ;; esac
if [ -f "$ops_root/.claude/hooks/_lib-portfolio-paths.sh" ]; then
  # shellcheck source=/dev/null
  . "$ops_root/.claude/hooks/_lib-portfolio-paths.sh" 2>/dev/null
  command -v portfolio_workspace_dir >/dev/null 2>&1 &&
    workspace_dir=$(cd "$ops_root" 2>/dev/null && portfolio_workspace_dir 2>/dev/null)
fi
[ -n "$workspace_dir" ] || workspace_dir="$ops_root/workspace"
# Sourcing this library only defines constants and functions. The ops root
# is resolved above; use the SessionStart parser without loading other settings.
if [ -f "$ops_root/.claude/hooks/_lib-disk-budget.sh" ]; then
  # shellcheck source=/dev/null
  . "$ops_root/.claude/hooks/_lib-disk-budget.sh"
  max_gb=$(_db_number "$max_gb" "$DB_DEFAULT_MAX_GB" max_owned_gb)
else
  max_gb=10
fi
case "$age_days" in ''|*[!0-9]*) age_days=7 ;; esac
# Review-copy root: same rule as review-copy.sh (step 3).
if [ -n "${APEXYARD_REVIEW_COPY_ROOT:-}" ]; then
  default_root="${APEXYARD_REVIEW_COPY_ROOT%/}"
else
  [ -d "${TMPDIR:-/tmp}" ] && tbase="${TMPDIR:-/tmp}" || tbase=/tmp
  tbase=$(CDPATH='' cd -- "$tbase" 2>/dev/null && pwd -P) || tbase="${TMPDIR:-/tmp}"
  default_root="${tbase%/}/apexyard-review-copies"
fi
# disk_budget.review_copy_roots ADDS folders; it never replaces the step-3
# root (me2resh/apexyard#2078 review finding C). A relative entry resolves
# against ops_root; a leading ~/ expands to $HOME, matching _db_resolve in
# _lib-disk-budget.sh (step 4). Dedupe by physical path so a root listed
# twice (or already equal to the default) is never measured twice.
resolve_review_root() {
  local raw="${1%/}" resolved metadata owner mode
  # The case patterns match a literal ~ on purpose.
  # shellcheck disable=SC2088
  case "$raw" in
    '~') raw="$HOME" ;;
    '~/'*) raw="$HOME/${raw#\~/}" ;;
    /*) ;;
    *) raw="$ops_root/${raw#./}" ;;
  esac
  [ -d "$raw" ] && [ ! -L "$raw" ] || return 1
  metadata=$(stat -c '%u %a' "$raw" 2>/dev/null) ||
    metadata=$(stat -f '%u %Lp' "$raw" 2>/dev/null) || return 1
  read -r owner mode <<< "$metadata"
  [ "$owner" = "$(id -u)" ] || return 1
  [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
  (( (8#$mode & 0022) == 0 )) || return 1
  if [ -d "$raw" ]; then
    resolved=$(CDPATH='' cd -- "$raw" 2>/dev/null && pwd -P) || resolved="$raw"
  else
    resolved="$raw"
  fi
  printf '%s\n' "$resolved"
}
review_roots=$(
  { printf '%s\n' "$default_root"; printf '%s\n' "$review_roots_cfg"; } |
    while IFS= read -r r; do [ -n "$r" ] && resolve_review_root "$r"; done |
    awk 'NF && !seen[$0]++'
)

start=$SECONDS
deadline=$((start + timebox))

# run_timed <seconds> <outfile> <cmd...>: run in background, kill at the limit.
# Preserve command failures; return 124 when the time limit expires.
run_timed() {
  local limit=$1 out=$2 pid waited=0
  shift 2
  [ "$SECONDS" -lt "$deadline" ] || return 124
  "$@" >"$out" 2>/dev/null &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge $((limit * 5)) ]; then
      kill "$pid" 2>/dev/null
      kill -KILL "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      return 124
    fi
    sleep 0.2
    waited=$((waited + 1))
  done
  wait "$pid" 2>/dev/null
}

remaining() {
  local r=$((deadline - SECONDS))
  [ "$r" -lt 1 ] && r=1
  echo "$r"
}

fmt_kb() {
  awk -v k="$1" 'BEGIN{ if (k >= 1048576) printf "%.1f GB", k/1048576;
    else if (k >= 1024) printf "%.0f MB", k/1024; else printf "%d KB", k }'
}

tmp=$(mktemp -d 2>/dev/null) || { unknown "no temp folder"; exit 0; }
trap 'rm -rf "$tmp"' EXIT

# --- 1. Collect the folders ApexYard owns (only those that exist).
targets=()
for d in "$workspace_dir"/*.worktrees; do [ -d "$d" ] && targets+=("$d"); done
while IFS= read -r r; do
  [ -n "$r" ] && [ -d "$r" ] && targets+=("$r")
done <<EOF_ROOTS
$review_roots
EOF_ROOTS
while IFS= read -r r; do
  [ -n "$r" ] && [ -d "$r" ] && targets+=("$r")
done <<EOF_EXTRA
$extra_paths
EOF_EXTRA
[ -d "$ops_root/.claude/session" ] && targets+=("$ops_root/.claude/session")
for proj in "$workspace_dir"/*/; do
  [ -d "$proj" ] || continue
  for b in node_modules target build dist coverage; do
    [ -d "${proj}${b}" ] && targets+=("${proj}${b}")
  done
done

total_kb=0
if [ "${#targets[@]}" -gt 0 ]; then
  du_status=0
  run_timed "$(remaining)" "$tmp/du" du -sk "${targets[@]}" || du_status=$?
  if [ "$du_status" -eq 124 ]; then
    unknown "measurement timed out" true
    exit 0
  fi
  total_kb=$(awk '{s+=$1} END{print s+0}' "$tmp/du")
fi

line="ApexYard is using $(fmt_kb "$total_kb")"

# --- 2. Reclaimable: old copies with no work at risk and a merged or closed PR.
reclaim_kb=0
blocked=0   # 1 when at least one check could not finish: the figure is a lower bound

# add_size <dir>: add the folder size to the reclaimable total.
add_size() {
  if run_timed "$(remaining)" "$tmp/sz" du -sk "$1"; then
    reclaim_kb=$((reclaim_kb + $(awk '{print $1+0}' "$tmp/sz")))
  else
    blocked=1
  fi
}

# pr_state <dir> <args...>: print the PR state, or fail when it cannot be read.
pr_state() {
  command -v "$gh_bin" >/dev/null 2>&1 || return 1
  # shellcheck disable=SC2016
  run_timed "$(remaining)" "$tmp/pr" bash -c 'cd "$1" && shift && exec "$@"' _ "$@" || return 1
  tr -d '[:space:]' <"$tmp/pr"
}

# iso_epoch <UTC time like 2026-01-02T03:04:05Z>: print epoch seconds.
iso_epoch() {
  date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null || date -u -d "$1" +%s 2>/dev/null
}

now_epoch=$(date +%s)
min_age=$((age_days * 86400))

# 2a. Worktrees (age = folder mtime).
for wt_root in "$workspace_dir"/*.worktrees; do
  [ -d "$wt_root" ] || continue
  while IFS= read -r wt; do
    [ -n "$wt" ] || continue
    [ -e "$wt/.git" ] || continue
    if [ "$SECONDS" -ge "$deadline" ]; then blocked=1; break 2; fi
    branch=$(GIT_OPTIONAL_LOCKS=0 git -C "$wt" branch --show-current 2>/dev/null)
    if [ -z "$branch" ]; then blocked=1; continue; fi
    # Any uncommitted or untracked file keeps the worktree.
    if ! run_timed "$(remaining)" "$tmp/st" env GIT_OPTIONAL_LOCKS=0 git -C "$wt" status --porcelain; then
      blocked=1; continue
    fi
    [ -s "$tmp/st" ] && continue
    # A stash keeps the worktree: it holds uncommitted work.
    if ! run_timed "$(remaining)" "$tmp/stash" env GIT_OPTIONAL_LOCKS=0 git -C "$wt" stash list; then
      blocked=1; continue
    fi
    [ -s "$tmp/stash" ] && continue
    state=$(pr_state "$wt" "$gh_bin" pr list --head "$branch" --state all --json state --jq '.[0].state // "NONE"') || { blocked=1; continue; }
    case "$state" in
      MERGED|CLOSED) ;;
      OPEN|NONE) continue ;;
      *) blocked=1; continue ;;
    esac
    # Unpushed commits keep the copy. A missing upstream blocks the check.
    if run_timed "$(remaining)" "$tmp/ah" env GIT_OPTIONAL_LOCKS=0 git -C "$wt" rev-list --count '@{upstream}..HEAD'; then
      [ "$(tr -d '[:space:]' <"$tmp/ah")" = 0 ] || continue
    else
      blocked=1; continue
    fi
    add_size "$wt"
  done < <(find "$wt_root" -mindepth 1 -maxdepth 1 -type d -mtime "+$age_days" 2>/dev/null)
done

# 2b. Review copies (age and PR come from the record that review-copy.sh
# writes). A copy gets the same "no work at risk" bar as a worktree
# (me2resh/apexyard#2078 review finding B): no uncommitted, untracked or
# stashed work, and no commits that are not on a remote.
if command -v jq >/dev/null 2>&1; then
  while IFS= read -r root; do
    [ -n "$root" ] && [ -d "$root" ] || continue
    for copy in "$root"/*/; do
      copy=${copy%/}
      [ -d "$copy/.git" ] && [ ! -L "$copy/.git" ] || continue
      rec="$copy/.git/apexyard-review-copy.json"
      [ -f "$rec" ] || continue
      if [ "$SECONDS" -ge "$deadline" ]; then blocked=1; break 2; fi
      repo=$(jq -r '.repo // empty' "$rec" 2>/dev/null)
      pr=$(jq -r '.pr // empty' "$rec" 2>/dev/null)
      created=$(jq -r '.created_at // empty' "$rec" 2>/dev/null)
      rec_sha=$(jq -r '.head_sha // empty' "$rec" 2>/dev/null)
      case "$pr" in ''|*[!0-9]*) blocked=1; continue ;; esac
      [ -n "$created" ] || { blocked=1; continue; }
      c_epoch=$(iso_epoch "$created") || c_epoch=""
      case "$c_epoch" in ''|*[!0-9]*) blocked=1; continue ;; esac
      [ $((now_epoch - c_epoch)) -ge "$min_age" ] || continue
      # Old records without an owner cannot identify the PR safely.
      [[ "$repo" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || continue
      full_repo="$repo"
      [ ! -L "$copy" ] || continue
      if ! run_timed "$(remaining)" "$tmp/wt" env GIT_OPTIONAL_LOCKS=0 git -C "$copy" worktree list --porcelain; then
        blocked=1; continue
      fi
      [ "$(awk '/^worktree /{n++} END{print n+0}' "$tmp/wt")" = 1 ] || continue
      # Uncommitted, untracked or stashed work keeps the copy.
      if ! run_timed "$(remaining)" "$tmp/st" env GIT_OPTIONAL_LOCKS=0 git -C "$copy" status --porcelain; then
        blocked=1; continue
      fi
      [ -s "$tmp/st" ] && continue
      if ! run_timed "$(remaining)" "$tmp/stash" env GIT_OPTIONAL_LOCKS=0 git -C "$copy" stash list; then
        blocked=1; continue
      fi
      [ -s "$tmp/stash" ] && continue
      pr_info=$(pr_state "$copy" "$gh_bin" pr view "$pr" --repo "$full_repo" --json state,headRefOid --jq '[.state,(.headRefOid // "")] | join("|")') || { blocked=1; continue; }
      cp_state=${pr_info%%|*}
      cp_pr_head=${pr_info#*|}
      case "$cp_state" in
        MERGED|CLOSED) ;;
        OPEN) continue ;;
        *) blocked=1; continue ;;
      esac
      # Unpushed commits keep the copy, unless HEAD is a remote-tracking
      # commit, the recorded head, or the PR's live head (same rule as the
      # step-4 sweep, bin/apexyard-disk-sweep.sh).
      # Include all local refs, so a saved branch cannot lose unique work.
      exclusions=()
      for sha in "$rec_sha" "$cp_pr_head"; do
        [[ "$sha" =~ ^[0-9a-fA-F]{40,64}$ ]] || continue
        exclusions+=("^$sha")
      done
      if ! run_timed "$(remaining)" "$tmp/local" env GIT_OPTIONAL_LOCKS=0 git -C "$copy" rev-list --count HEAD --all --not --remotes --not "${exclusions[@]}"; then
        blocked=1; continue
      fi
      [ "$(tr -d '[:space:]' <"$tmp/local")" = 0 ] || continue
      add_size "$copy"
    done
  done <<EOF_RROOTS
$review_roots
EOF_RROOTS
else
  blocked=1
fi

if [ "$blocked" = 1 ]; then
  line="$line; at least $(fmt_kb "$reclaim_kb") can be reclaimed"
else
  line="$line; $(fmt_kb "$reclaim_kb") can be reclaimed"
fi

if awk -v k="$total_kb" -v g="$max_gb" 'BEGIN { exit !(k > g * 1048576) }'; then
  line="$line (over the $max_gb GB budget)"
fi
if $json; then
  lower=false
  [ "$blocked" != 1 ] || lower=true
  usage_json "$((total_kb * 1024))" "$((reclaim_kb * 1024))" "$lower" false
else
  echo "$line"
fi
exit 0
