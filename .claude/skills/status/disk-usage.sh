#!/usr/bin/env bash
# disk-usage.sh - one-line ApexYard disk use for /status (me2resh/apexyard#2070, step 5).
#
# Output (one line, always exit 0):
#   ApexYard is using 12.3 GB; 9.1 GB can be reclaimed
#   ApexYard is using 12.3 GB; reclaimable size unknown
#   ApexYard disk use is unknown (measurement timed out)
#
# Read-only. It never deletes, never fetches, never blocks for long.
# Folders measured (only folders that ApexYard owns):
#   - <workspace>/*.worktrees       (worktrees of managed projects)
#   - the review-copy folder        (config disk_budget.review_copy_dir)
#   - <ops>/.claude/session         (session state)
#   - build output in <workspace>/*/ (node_modules, target, build, dist, coverage)
#
# Reclaimable = worktree folders that are older than disk_budget.age_days, are
# clean, and whose branch PR is merged or closed. Any doubt -> "unknown".
#
# Inputs (env, all optional; tests use them):
#   APEXYARD_OPS_ROOT      ops-fork root (default: walk up from this script)
#   APEXYARD_GH            gh binary (default: gh)
#   APEXYARD_DISK_TIMEBOX  total seconds for the whole measurement (default 6)

set -u

ops_root="${APEXYARD_OPS_ROOT:-}"
if [ -z "$ops_root" ]; then
  ops_root=$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/../../.." 2>/dev/null && pwd -P) || ops_root=""
fi
[ -n "$ops_root" ] || { echo "ApexYard disk use is unknown (no ops root)"; exit 0; }

gh_bin="${APEXYARD_GH:-gh}"
timebox="${APEXYARD_DISK_TIMEBOX:-6}"
case "$timebox" in ''|*[!0-9]*) timebox=6 ;; esac

# The config library finds the repo from the working directory.
cd "$ops_root" 2>/dev/null || { echo "ApexYard disk use is unknown (no ops root)"; exit 0; }
max_gb=10; age_days=7; review_dir=""
workspace_dir=""
if [ -f "$ops_root/.claude/hooks/_lib-read-config.sh" ]; then
  # shellcheck source=/dev/null
  . "$ops_root/.claude/hooks/_lib-read-config.sh" 2>/dev/null
  if command -v config_get_or >/dev/null 2>&1; then
    max_gb=$(config_get_or '.disk_budget.max_gb' 10 2>/dev/null)
    age_days=$(config_get_or '.disk_budget.age_days' 7 2>/dev/null)
    review_dir=$(config_get_or '.disk_budget.review_copy_dir' '' 2>/dev/null)
  fi
fi
if [ -f "$ops_root/.claude/hooks/_lib-portfolio-paths.sh" ]; then
  # shellcheck source=/dev/null
  . "$ops_root/.claude/hooks/_lib-portfolio-paths.sh" 2>/dev/null
  command -v portfolio_workspace_dir >/dev/null 2>&1 &&
    workspace_dir=$(cd "$ops_root" 2>/dev/null && portfolio_workspace_dir 2>/dev/null)
fi
[ -n "$workspace_dir" ] || workspace_dir="$ops_root/workspace"
case "$max_gb" in ''|*[!0-9]*) max_gb=10 ;; esac
case "$age_days" in ''|*[!0-9]*) age_days=7 ;; esac
[ -n "$review_dir" ] || review_dir="${TMPDIR:-/tmp}/apexyard-review"

start=$SECONDS
deadline=$((start + timebox))

# run_timed <seconds> <outfile> <cmd...>: run in background, kill at the limit.
# Return 0 when the command finished in time, 1 when it was killed.
run_timed() {
  local limit=$1 out=$2 pid waited=0
  shift 2
  "$@" >"$out" 2>/dev/null &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge $((limit * 5)) ]; then
      kill "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      return 1
    fi
    sleep 0.2
    waited=$((waited + 1))
  done
  wait "$pid" 2>/dev/null
  return 0
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

tmp=$(mktemp -d 2>/dev/null) || { echo "ApexYard disk use is unknown (no temp folder)"; exit 0; }
trap 'rm -rf "$tmp"' EXIT

# --- 1. Collect the folders ApexYard owns (only those that exist).
targets=()
for d in "$workspace_dir"/*.worktrees; do [ -d "$d" ] && targets+=("$d"); done
[ -d "$review_dir" ] && targets+=("$review_dir")
[ -d "$ops_root/.claude/session" ] && targets+=("$ops_root/.claude/session")
for proj in "$workspace_dir"/*/; do
  [ -d "$proj" ] || continue
  for b in node_modules target build dist coverage; do
    [ -d "${proj}${b}" ] && targets+=("${proj}${b}")
  done
done

total_kb=0
if [ "${#targets[@]}" -gt 0 ]; then
  if run_timed "$(remaining)" "$tmp/du" du -sk "${targets[@]}"; then
    total_kb=$(awk '{s+=$1} END{print s+0}' "$tmp/du")
  else
    echo "ApexYard disk use is unknown (measurement timed out)"
    exit 0
  fi
fi

line="ApexYard is using $(fmt_kb "$total_kb")"

# --- 2. Reclaimable: old, clean worktrees whose PR is merged or closed.
reclaim_kb=0
unknown=0
candidates=0
for wt_root in "$workspace_dir"/*.worktrees; do
  [ -d "$wt_root" ] || continue
  while IFS= read -r wt; do
    [ -n "$wt" ] || continue
    [ -e "$wt/.git" ] || continue
    candidates=$((candidates + 1))
    if [ "$SECONDS" -ge "$deadline" ]; then unknown=1; break 2; fi
    branch=$(GIT_OPTIONAL_LOCKS=0 git -C "$wt" branch --show-current 2>/dev/null)
    if [ -z "$branch" ]; then unknown=1; continue; fi
    # Dirty work is never reclaimable.
    if ! run_timed "$(remaining)" "$tmp/st" env GIT_OPTIONAL_LOCKS=0 git -C "$wt" status --porcelain --untracked-files=no; then
      unknown=1; continue
    fi
    [ -s "$tmp/st" ] && continue
    command -v "$gh_bin" >/dev/null 2>&1 || { unknown=1; continue; }
    if ! run_timed "$(remaining)" "$tmp/pr" bash -c 'cd "$1" && exec "$2" pr list --head "$3" --state all --json state --jq ".[0].state // \"NONE\""' _ "$wt" "$gh_bin" "$branch"; then
      unknown=1; continue
    fi
    state=$(tr -d '[:space:]' <"$tmp/pr")
    case "$state" in
      MERGED|CLOSED) ;;
      OPEN|NONE) continue ;;
      *) unknown=1; continue ;;
    esac
    # Unpushed commits keep the copy.
    if run_timed "$(remaining)" "$tmp/ah" env GIT_OPTIONAL_LOCKS=0 git -C "$wt" rev-list --count '@{upstream}..HEAD'; then
      ahead=$(tr -d '[:space:]' <"$tmp/ah")
      [ "$ahead" = 0 ] || continue
    else
      unknown=1; continue
    fi
    if run_timed "$(remaining)" "$tmp/sz" du -sk "$wt"; then
      reclaim_kb=$((reclaim_kb + $(awk '{print $1+0}' "$tmp/sz")))
    else
      unknown=1
    fi
  done < <(find "$wt_root" -mindepth 1 -maxdepth 1 -type d -mtime "+$age_days" 2>/dev/null)
done

if [ "$unknown" = 1 ]; then
  line="$line; reclaimable size unknown"
else
  line="$line; $(fmt_kb "$reclaim_kb") can be reclaimed"
fi

if [ "$total_kb" -gt $((max_gb * 1048576)) ]; then
  line="$line (over the $max_gb GB budget)"
fi
echo "$line"
exit 0
