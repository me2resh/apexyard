#!/bin/bash
# SessionStart hook: advisory disk budget (me2resh/apexyard#2070 step 4).
# Design: docs/agdr/AgDR-0306-disk-budget-at-session-start.md
#
# What it does:
#   - Measures the folders that ApexYard owns (worktrees, review copies,
#     session state and configured extra folders).
#   - Reads the free space of the disk that holds the ops root.
#   - When the owned folders use more than .disk_budget.max_owned_gb, or the
#     disk has less than .disk_budget.min_free_percent free, it prints a
#     proposal: run bin/apexyard-disk-sweep.sh for a dry-run list.
#
# Safety:
#   - Advisory only. It never removes a file or a folder, and never blocks.
#   - The size measurement has a time limit (.disk_budget.measure_timeout_seconds).
#     On a slow disk the limit stops the measurement and the hook skips the
#     size check. A good result is cached for 6 hours under .claude/session.
#   - Every exit path exits 0.
#   - It does not run after compaction (source "compact").

HOOK_DIR=$(cd "$(dirname "$0")" && pwd -P) || exit 0
input=$(cat 2>/dev/null || true)

source_kind=""
cwd=""
if command -v jq >/dev/null 2>&1; then
  source_kind=$(printf '%s' "$input" | jq -r '.source // empty' 2>/dev/null || true)
  cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null || true)
fi
[ "$source_kind" = "compact" ] && exit 0
if [ -z "$cwd" ] || [ ! -d "$cwd" ]; then
  cwd=$PWD
fi

# shellcheck source=/dev/null
. "$HOOK_DIR/_lib-ops-root.sh" 2>/dev/null || exit 0
ops=$(resolve_ops_root "$cwd" 2>/dev/null || true)
[ -n "$ops" ] || exit 0
_ops_root_anchor_valid "$ops" || exit 0
cd "$ops" 2>/dev/null || exit 0

# shellcheck source=/dev/null
. "$HOOK_DIR/_lib-read-config.sh" 2>/dev/null || exit 0
# shellcheck source=/dev/null
. "$HOOK_DIR/_lib-gh-timeout.sh" 2>/dev/null || exit 0
# shellcheck source=/dev/null
. "$HOOK_DIR/_lib-disk-budget.sh" 2>/dev/null || exit 0

disk_budget_load_config
[ "$DB_ENABLED" = "true" ] || exit 0

paths=()
while IFS= read -r p; do
  [ -n "$p" ] && paths+=("$p")
done < <(disk_budget_owned_paths "$ops")
[ "${#paths[@]}" -gt 0 ] || exit 0

CACHE_TTL_SECONDS=21600
cache="$ops/.claude/session/disk-budget-size"
now=$(date +%s)
kb=""
if [ -f "$cache" ] && [ ! -L "$cache" ]; then
  cached_ts=""
  cached_kb=""
  read -r cached_ts cached_kb < "$cache" 2>/dev/null || true
  case "$cached_ts$cached_kb" in
    ''|*[!0-9]*) ;;
    *)
      if [ $((now - cached_ts)) -ge 0 ] && [ $((now - cached_ts)) -lt "$CACHE_TTL_SECONDS" ]; then
        kb=$cached_kb
      fi
      ;;
  esac
fi

if [ -z "$kb" ]; then
  rc=0
  kb=$(disk_budget_measure_kb "$DB_TIMEOUT" "${paths[@]}") || rc=$?
  if [ "$rc" -ne 0 ]; then
    # Slow disk: skip the size check for this session.
    kb=""
  elif [ -n "$kb" ] && mkdir -p "$ops/.claude/session" 2>/dev/null; then
    tmp="$cache.tmp.$$"
    if printf '%s %s\n' "$now" "$kb" > "$tmp" 2>/dev/null; then
      mv -f "$tmp" "$cache" 2>/dev/null || rm -f "$tmp" 2>/dev/null
    fi
  fi
fi

free=$(disk_budget_free_percent 2 "$ops" 2>/dev/null || true)

over_size=0
low_free=0
if [ -n "$kb" ] && disk_budget_over_size "$kb"; then
  over_size=1
fi
if [ -n "$free" ] && disk_budget_low_free "$free"; then
  low_free=1
fi
[ "$over_size" -eq 1 ] || [ "$low_free" -eq 1 ] || exit 0

facts=""
if [ -n "$kb" ]; then
  facts="owned folders use $(disk_budget_format_kb "$kb") (limit ${DB_MAX_GB} GB)"
else
  facts="owned folder size not measured (time limit)"
fi
if [ -n "$free" ]; then
  facts="$facts, free disk space is ${free}% (limit ${DB_MIN_FREE_PCT}%)"
fi

sweep="$ops/bin/apexyard-disk-sweep.sh"
printf 'ApexYard disk budget: %s.\n' "$facts"
printf 'Propose a sweep to the user. Run %s for a dry-run list of copies older than %s days whose PR is merged or closed.\n' "$sweep" "$DB_MIN_AGE_DAYS"
printf 'Show the list. Remove nothing until the user says yes. Then run %s --apply <plan-id>.\n' "$sweep"
exit 0
