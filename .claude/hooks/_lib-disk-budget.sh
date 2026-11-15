#!/bin/bash
# The DB_* globals are read by the scripts that source this file.
# shellcheck disable=SC2034
# _lib-disk-budget.sh - disk budget for the folders that ApexYard owns.
# me2resh/apexyard#2070 step 4. Design: docs/agdr/AgDR-0306-disk-budget-at-session-start.md
#
# Read-only helpers. This file never removes a file or a folder.
# check-disk-budget.sh (SessionStart) and bin/apexyard-disk-sweep.sh use it.
# Only bin/apexyard-disk-sweep.sh --apply removes items, after the user says yes.
#
# Callers source _lib-read-config.sh and _lib-gh-timeout.sh first, and run
# from the ops root so that config_get reads the ops root's config.
#
# PUBLIC:
#   disk_budget_load_config
#       Sets DB_ENABLED (true|false), DB_MAX_GB, DB_MIN_FREE_PCT,
#       DB_MIN_AGE_DAYS and DB_TIMEOUT from .disk_budget in the merged
#       project config. A missing or bad value gets the shipped default.
#   disk_budget_owned_paths <ops-root>
#       Prints each owned folder that exists, one per line. The SessionStart
#       check measures these folders.
#   disk_budget_sweep_roots <ops-root>
#       Prints each folder whose direct children a sweep can propose to
#       remove, one per line. A root that is /, HOME, the ops root or the
#       workspace folder is never printed.
#   disk_budget_measure_kb <seconds> <path>...
#       Prints the total size in KB. Returns 124 when the time limit stops
#       the measurement.
#   disk_budget_free_percent <seconds> <path>
#       Prints the free space of the disk that holds <path>, in whole percent.
#   disk_budget_format_kb <kb>
#       Prints a size such as "12.3 GB".
#   disk_budget_real <path>
#       Prints the physical path of an existing folder.
#
# Shipped defaults (.claude/project-config.defaults.json, .disk_budget):
#   max_owned_gb 10, min_free_percent 10, sweep_min_age_days 7,
#   measure_timeout_seconds 3.

DB_DEFAULT_MAX_GB=10
DB_DEFAULT_MIN_FREE_PCT=10
DB_DEFAULT_MIN_AGE_DAYS=7
DB_DEFAULT_TIMEOUT=3

_db_warn() {
  printf 'WARN: disk_budget: %s\n' "$*" >&2
}

# _db_number <value> <default> <key> - a non-negative decimal number.
_db_number() {
  local value="$1" fallback="$2" key="$3" re='^[0-9]+([.][0-9]+)?$'
  if [ "$value" = "-" ]; then
    printf '%s\n' "$fallback"
  elif [[ $value =~ $re ]]; then
    printf '%s\n' "$value"
  else
    _db_warn "$key is not a number ($value). Using $fallback."
    printf '%s\n' "$fallback"
  fi
}

# _db_integer <value> <default> <key> <min> <max>
_db_integer() {
  local value="$1" fallback="$2" key="$3" min="$4" max="$5" re='^[0-9]+$'
  if [ "$value" = "-" ]; then
    printf '%s\n' "$fallback"
  elif [[ $value =~ $re ]] && [ "${#value}" -le 6 ] && [ "$value" -ge "$min" ] && [ "$value" -le "$max" ]; then
    printf '%s\n' "$value"
  else
    _db_warn "$key must be a whole number from $min to $max ($value). Using $fallback."
    printf '%s\n' "$fallback"
  fi
}

disk_budget_load_config() {
  local raw enabled max_gb min_free min_age timeout
  # One jq call. A null value becomes "-" so that tab splitting keeps the
  # field positions. $d is a jq variable, not a shell expansion.
  # shellcheck disable=SC2016
  raw=$(config_get '(.disk_budget // {}) as $d
    | [ $d.enabled, $d.max_owned_gb, $d.min_free_percent,
        $d.sweep_min_age_days, $d.measure_timeout_seconds ]
    | map(if . == null then "-" else tostring end) | @tsv' 2>/dev/null)
  [ -n "$raw" ] || raw=$(printf '%s\t%s\t%s\t%s\t%s' - - - - -)
  IFS=$'\t' read -r enabled max_gb min_free min_age timeout <<<"$raw"

  case "${enabled:--}" in
    false) DB_ENABLED=false ;;
    *) DB_ENABLED=true ;;
  esac
  DB_MAX_GB=$(_db_number "${max_gb:--}" "$DB_DEFAULT_MAX_GB" max_owned_gb)
  DB_MIN_FREE_PCT=$(_db_number "${min_free:--}" "$DB_DEFAULT_MIN_FREE_PCT" min_free_percent)
  if awk -v p="$DB_MIN_FREE_PCT" 'BEGIN { exit !(p > 100) }'; then
    _db_warn "min_free_percent is more than 100 ($DB_MIN_FREE_PCT). Using $DB_DEFAULT_MIN_FREE_PCT."
    DB_MIN_FREE_PCT=$DB_DEFAULT_MIN_FREE_PCT
  fi
  DB_MIN_AGE_DAYS=$(_db_integer "${min_age:--}" "$DB_DEFAULT_MIN_AGE_DAYS" sweep_min_age_days 0 36500)
  DB_TIMEOUT=$(_db_integer "${timeout:--}" "$DB_DEFAULT_TIMEOUT" measure_timeout_seconds 1 60)
}

disk_budget_real() {
  [ -n "${1:-}" ] || return 1
  (cd -P -- "$1" 2>/dev/null && pwd -P)
}

# _db_resolve <ops-root> <configured-path> - expand a leading ~/ and resolve
# a relative path against the ops root. Prints nothing for an empty value.
_db_resolve() {
  local ops="$1" value="$2"
  # The case patterns match a literal ~ on purpose.
  # shellcheck disable=SC2088
  case "$value" in
    ''|null) return 0 ;;
    '~') printf '%s\n' "$HOME" ;;
    '~/'*) printf '%s/%s\n' "$HOME" "${value#\~/}" ;;
    /*) printf '%s\n' "$value" ;;
    *) printf '%s/%s\n' "$ops" "${value#./}" ;;
  esac
}

_db_workspace_dir() {
  local ops="$1" value
  value=$(config_get_or '.portfolio.workspace_dir' './workspace')
  _db_resolve "$ops" "$value"
}

# _db_review_roots <ops-root> - the review-copy root that
# .claude/skills/code-review/review-copy.sh uses (AgDR-0305), then each
# configured .disk_budget.review_copy_roots entry.
# Step 3 root: $APEXYARD_REVIEW_COPY_ROOT, else <physical TMPDIR>/apexyard-review-copies.
_db_review_roots() {
  local ops="$1" value base
  if [ -n "${APEXYARD_REVIEW_COPY_ROOT:-}" ]; then
    printf '%s\n' "${APEXYARD_REVIEW_COPY_ROOT%/}"
  else
    base="${TMPDIR:-/tmp}"
    [ -d "$base" ] || base=/tmp
    base=$(cd "$base" 2>/dev/null && pwd -P) && printf '%s/apexyard-review-copies\n' "${base%/}"
  fi
  config_get '.disk_budget.review_copy_roots[]?' 2>/dev/null | while IFS= read -r value; do
    _db_resolve "$ops" "$value"
  done
}

_db_extra_paths() {
  local ops="$1" value
  config_get '.disk_budget.extra_paths[]?' 2>/dev/null | while IFS= read -r value; do
    _db_resolve "$ops" "$value"
  done
}

# _db_existing_dir <path> - print the physical path of a real folder.
# A symbolic link is never followed.
_db_existing_dir() {
  [ -n "${1:-}" ] && [ -d "$1" ] && [ ! -L "$1" ] || return 0
  disk_budget_real "$1"
}

_db_worktree_containers() {
  local ops="$1" ws="$2" dir
  _db_existing_dir "$ops/.claude/worktrees"
  if [ -n "$ws" ] && [ -d "$ws" ]; then
    for dir in "$ws"/*.worktrees "$ws"/*/.claude/worktrees; do
      _db_existing_dir "$dir"
    done
  fi
}

disk_budget_owned_paths() {
  local ops="$1" ws p
  ws=$(_db_workspace_dir "$ops")
  {
    _db_worktree_containers "$ops" "$ws"
    _db_existing_dir "$ops/.claude/session"
    _db_review_roots "$ops" | while IFS= read -r p; do _db_existing_dir "$p"; done
    _db_extra_paths "$ops" | while IFS= read -r p; do _db_existing_dir "$p"; done
  } | awk 'NF && !seen[$0]++'
}

disk_budget_sweep_roots() {
  local ops="$1" ws ws_real ops_real home_real p
  ws=$(_db_workspace_dir "$ops")
  ws_real=$(disk_budget_real "$ws" 2>/dev/null || true)
  ops_real=$(disk_budget_real "$ops" 2>/dev/null || true)
  home_real=$(disk_budget_real "$HOME" 2>/dev/null || true)
  {
    _db_worktree_containers "$ops" "$ws"
    _db_review_roots "$ops" | while IFS= read -r p; do _db_existing_dir "$p"; done
  } | awk -v ws="$ws_real" -v ops="$ops_real" -v home="$home_real" '
      NF && $0 != "/" && $0 != ws && $0 != ops && $0 != home && !seen[$0]++
    '
}

# _db_run_limited <seconds> <cmd...> - run a command with a time limit.
# Returns 124 when the limit stops the command.
_db_run_limited() {
  local secs="$1"
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout -k 1 "$secs" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout -k 1 "$secs" "$@"
  else
    _apexyard_gh_watchdog "$secs" "$@"
  fi
}

disk_budget_measure_kb() {
  local secs="$1" out rc=0
  shift
  if [ "$#" -eq 0 ]; then
    printf '0\n'
    return 0
  fi
  out=$(_db_run_limited "$secs" du -sk "$@" 2>/dev/null) || rc=$?
  # du exits non-zero for an unreadable file but still prints the totals.
  # Only the time limit makes the result unusable.
  [ "$rc" -eq 124 ] && return 124
  [ "$rc" -eq 137 ] && return 124
  printf '%s\n' "$out" | awk '$1 ~ /^[0-9]+$/ { s += $1 } END { printf "%d\n", s }'
}

disk_budget_free_percent() {
  local secs="$1" path="$2" out
  out=$(_db_run_limited "$secs" df -Pk "$path" 2>/dev/null) || return 1
  out=$(printf '%s\n' "$out" | awk 'NR == 2 && $2 > 0 { printf "%d\n", ($4 * 100) / $2 }')
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

disk_budget_format_kb() {
  awk -v k="${1:-0}" 'BEGIN { printf "%.1f GB\n", k / 1048576 }'
}

# disk_budget_over_size <kb> - true when <kb> is more than DB_MAX_GB.
disk_budget_over_size() {
  awk -v k="${1:-0}" -v g="$DB_MAX_GB" 'BEGIN { exit !(k > g * 1048576) }'
}

# disk_budget_low_free <percent> - true when <percent> is less than DB_MIN_FREE_PCT.
disk_budget_low_free() {
  awk -v f="${1:-100}" -v m="$DB_MIN_FREE_PCT" 'BEGIN { exit !(f < m) }'
}
