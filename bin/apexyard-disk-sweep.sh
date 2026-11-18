#!/usr/bin/env bash
# apexyard-disk-sweep.sh - propose and run a sweep of old ApexYard copies.
# me2resh/apexyard#2070 step 4. Design: docs/agdr/AgDR-0306-disk-budget-at-session-start.md
#
# Usage (run from inside the ops fork):
#   bin/apexyard-disk-sweep.sh                  Dry run. List what a sweep removes and
#                                               what it keeps, with the reason. Save a plan.
#   bin/apexyard-disk-sweep.sh --measure        Print the size of each owned folder.
#   bin/apexyard-disk-sweep.sh --apply <plan>   Check each item in the plan again.
#                                               Remove the items that still qualify.
#                                               Log each result.
#
# Run --apply only after the user says yes to the dry-run list.
#
# A sweep looks only at the direct children of these folders:
#   <ops>/.claude/worktrees, <workspace>/*.worktrees,
#   <workspace>/*/.claude/worktrees, the review-copy root of
#   .claude/skills/code-review/review-copy.sh (AgDR-0305), and each
#   .disk_budget.review_copy_roots entry.
#
# An item qualifies only when all of these are true:
#   - It is a real folder, not a symbolic link, and not the current folder.
#   - It has no uncommitted or untracked changes (a git worktree or clone).
#   - No live session owns it (a worktree owner lease, AgDR-0284).
#   - Its age is .disk_budget.sweep_min_age_days or more.
#   - Its PR is MERGED or CLOSED.
#   - Its HEAD is on a remote, is the recorded PR head, or is in the PR head.
#   - A review copy that is not a linked worktree has a review-copy record.
#
# Review-copy record (AgDR-0305; optional for a worktree, required for a clone):
#   <git-dir>/apexyard-review-copy.json, for example <copy>/.git/apexyard-review-copy.json,
#   with the fields repo, pr, head_sha, session and created_at (UTC ISO 8601).
#   When "repo" has no owner, the owner comes from the copy's origin URL.
#   With no record, a linked worktree uses its branch and git admin file
#   times. Any other copy is kept.
#
# Removal: "git worktree remove" for a linked worktree. The sweep never uses
# --force. Git refuses a worktree with changes, and the sweep keeps it.
# A review-copy clone is removed with rm only when its parent is a
# review-copy root. The record is inside the clone and goes with it.
#
# Files: plans and the log live in <ops>/.claude/session/disk-sweep/.
#   removed.log  one tab-separated line for each item that --apply checked.

# --json (plan or --apply): one JSON object on stdout.
# Plan schema: apexyard.disk-sweep-plan/1.
# Fields: schema, plan_id, items [{path, kind, bytes, reason}], kept [{path, reason}].
# Apply schema: apexyard.disk-sweep-apply/1, removed and skipped [{path, reason}].
# The schema version changes only on a breaking change.
set -uo pipefail

JSON=false
args=()
for arg in "$@"; do
  if [ "$arg" = --json ]; then JSON=true; else args+=("$arg"); fi
done
set -- "${args[@]+"${args[@]}"}"
if $JSON; then
  command -v jq >/dev/null 2>&1 || { echo 'apexyard-disk-sweep: --json requires jq' >&2; exit 2; }
fi

_json_entry() {
  jq -cn --arg path "$1" --arg reason "$2" '{path:$path,reason:$reason}'
}

SELF_DIR=$(cd "$(dirname "$0")" && pwd -P) || exit 2
HOOKS="$SELF_DIR/../.claude/hooks"

die() {
  printf 'apexyard-disk-sweep: %s\n' "$*" >&2
  exit 2
}

# shellcheck source=/dev/null
. "$HOOKS/_lib-ops-root.sh" || die "cannot load _lib-ops-root.sh"
OPS=$(resolve_ops_root "$PWD" 2>/dev/null || true)
{ [ -n "$OPS" ] && _ops_root_anchor_valid "$OPS"; } || die "run this command inside an ApexYard ops fork"
OPS=$(cd -P -- "$OPS" && pwd -P) || die "cannot open the ops root"
START_DIR=$(pwd -P)
cd "$OPS" || die "cannot open the ops root"

# shellcheck source=/dev/null
. "$HOOKS/_lib-read-config.sh" || die "cannot load _lib-read-config.sh"
# shellcheck source=/dev/null
. "$HOOKS/_lib-gh-timeout.sh" || die "cannot load _lib-gh-timeout.sh"
# shellcheck source=/dev/null
. "$HOOKS/_lib-disk-budget.sh" || die "cannot load _lib-disk-budget.sh"
if [ -f "$HOOKS/_lib-worktree-owner.sh" ]; then
  # shellcheck source=/dev/null
  . "$HOOKS/_lib-worktree-owner.sh"
fi

disk_budget_load_config
TRACKER_KIND=$(config_get_or '.tracker.kind' 'gh')
: "${APEXYARD_GH_CALL_TIMEOUT:=15}"
export APEXYARD_GH_CALL_TIMEOUT

STATE_DIR="$OPS/.claude/session/disk-sweep"
LOG_FILE="$STATE_DIR/removed.log"
NOW=$(date +%s)
PLAN_MAX_AGE_SECONDS=86400

ROOTS=()
while IFS= read -r r; do
  [ -n "$r" ] && ROOTS+=("$r")
done < <(disk_budget_sweep_roots "$OPS")

REVIEW_ROOTS=()
while IFS= read -r r; do
  [ -n "$r" ] || continue
  r=$(_db_safe_review_root "$r") || continue
  REVIEW_ROOTS+=("$r")
done < <(_db_review_roots "$OPS")

_mtime() {
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null
}

_size_kb() {
  du -sk "$1" 2>/dev/null | awk 'NR == 1 { print $1 }'
}

_in_list() {
  local needle="$1" item
  shift
  for item in "$@"; do
    [ "$item" = "$needle" ] && return 0
  done
  return 1
}

_is_sweep_child() {
  local parent
  parent=$(dirname "$1")
  [ "${#ROOTS[@]}" -gt 0 ] && _in_list "$parent" "${ROOTS[@]}"
}

_is_review_child() {
  local parent
  parent=$(dirname "$1")
  [ "${#REVIEW_ROOTS[@]}" -gt 0 ] && _in_list "$parent" "${REVIEW_ROOTS[@]}" || return 1
  [ ! -L "$1" ] || return 1
  local root real
  root=$(_db_safe_review_root "$parent") || return 1
  real=$(disk_budget_real "$1") || return 1
  [ "$(dirname "$real")" = "$root" ]
}

_slug_from_url() {
  local u="$1"
  case "$u" in
    *github.com[:/]*) ;;
    *) return 1 ;;
  esac
  u=${u#*github.com}
  u=${u#[:/]}
  u=${u%/}
  u=${u%.git}
  case "$u" in
    */*/*|/*|*/) return 1 ;;
    ?*/?*) printf '%s\n' "$u" ;;
    *) return 1 ;;
  esac
}

# Record fields of the item under evaluation.
R_REPO=""
R_PR=""
R_CREATED=""
R_HEAD_SHA=""
RECORD_NAME="apexyard-review-copy.json"

# _read_record <copy-path> - read <git-dir>/apexyard-review-copy.json
# (AgDR-0305). Sets R_REPO (owner/name), R_PR, R_CREATED (epoch seconds)
# and R_HEAD_SHA. A missing, linked or bad record sets nothing.
_read_record() {
  local copy="$1" gitdir rec fields repo pr sha created url
  R_REPO=""
  R_PR=""
  R_CREATED=""
  R_HEAD_SHA=""
  if [ -d "$copy/.git" ] && [ ! -L "$copy/.git" ]; then
    gitdir="$copy/.git"
  elif [ -f "$copy/.git" ]; then
    gitdir=$(git -C "$copy" rev-parse --absolute-git-dir 2>/dev/null) || return 1
  else
    return 1
  fi
  rec="$gitdir/$RECORD_NAME"
  [ -f "$rec" ] && [ ! -L "$rec" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  fields=$(jq -r '[ (.repo // "" | tostring), (.pr // "" | tostring), (.head_sha // "" | tostring),
      ((.created_at // "") | (try fromdateiso8601 catch "") | tostring) ]
    | map(if . == "" then "-" else . end) | @tsv' "$rec" 2>/dev/null) || return 1
  IFS=$'\t' read -r repo pr sha created <<<"$fields"
  case "$pr" in ''|-|*[!0-9]*) return 1 ;; esac
  case "$repo" in
    -|''|*[!A-Za-z0-9._/-]*) return 1 ;;
    */*/*) return 1 ;;
    */*) ;;
    *)
      # Step 3 stores the repo name only. Take the owner from origin.
      url=$(git -C "$copy" remote get-url origin 2>/dev/null) || return 1
      repo=$(_slug_from_url "$url") || return 1
      ;;
  esac
  R_REPO=$repo
  R_PR=$pr
  case "$created" in -|*[!0-9]*) ;; *) R_CREATED=$created ;; esac
  case "$sha" in -|*[!0-9a-f]*) ;; *) R_HEAD_SHA=$sha ;; esac
  return 0
}

# PR state of the item under evaluation.
PR_STATE=""
PR_HEAD=""
PR_REF=""
PR_WHY=""

_pr_pick() {
  # Read a JSON array of {number,state,headRefOid}. Prefer OPEN, then MERGED.
  jq -r 'if type != "array" or length == 0 then empty else
      (map(select(.state == "OPEN")) + map(select(.state == "MERGED")) + map(select(.state == "CLOSED")))
      | .[0] | [(.number | tostring), .state, (.headRefOid // "")] | @tsv end' 2>/dev/null
}

_pr_lookup() {
  local path="$1" branch remote url slug out all="[]" picked
  PR_STATE=""
  PR_HEAD=""
  PR_REF=""
  PR_WHY=""
  if [ "$TRACKER_KIND" != "gh" ]; then
    PR_WHY="PR state unknown (tracker kind is $TRACKER_KIND, not gh)"
    return 0
  fi
  if ! command -v gh >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    PR_WHY="PR state unknown (gh or jq is not installed)"
    return 0
  fi
  if [ -n "$R_REPO" ] && [ -n "$R_PR" ]; then
    out=$(apexyard_gh pr view "$R_PR" --repo "$R_REPO" --json number,state,headRefOid 2>/dev/null) || {
      PR_WHY="PR state unknown (lookup of $R_REPO#$R_PR failed)"
      return 0
    }
    picked=$(printf '[%s]' "$out" | _pr_pick)
    slug=$R_REPO
  else
    branch=$(git -C "$path" symbolic-ref -q --short HEAD 2>/dev/null) || {
      PR_WHY="no branch and no copy record"
      return 0
    }
    for remote in $(git -C "$path" remote 2>/dev/null); do
      url=$(git -C "$path" remote get-url "$remote" 2>/dev/null) || continue
      slug=$(_slug_from_url "$url") || continue
      out=$(apexyard_gh pr list --repo "$slug" --head "$branch" --state all \
        --json number,state,headRefOid --limit 20 2>/dev/null) || {
        PR_WHY="PR state unknown (lookup on $slug failed)"
        return 0
      }
      all=$(jq -c --arg s "$slug" --argjson a "$all" \
        '$a + (if type == "array" then map(. + {repo: $s}) else [] end)' <<<"$out" 2>/dev/null) || all="[]"
    done
    picked=$(printf '%s' "$all" | _pr_pick)
    slug=$(jq -r '(map(select(.state == "OPEN")) + map(select(.state == "MERGED")) + map(select(.state == "CLOSED"))) | .[0].repo // empty' <<<"$all" 2>/dev/null)
  fi
  if [ -z "$picked" ]; then
    PR_WHY="no PR found"
    return 0
  fi
  IFS=$'\t' read -r _num PR_STATE PR_HEAD <<<"$picked"
  PR_REF="$slug#$_num"
}

# Verdict of the item under evaluation.
V_ACTION=""
V_REASON=""
V_KIND=""
V_AGE=""
V_MAIN=""

_keep() {
  V_ACTION=keep
  V_REASON="$1"
}

_worktree_main() {
  git -C "$1" worktree list --porcelain 2>/dev/null | awk '/^worktree / { sub(/^worktree /, ""); print; exit }'
}

_worktree_locked() {
  local path="$1" locked
  while IFS= read -r locked; do
    [ -n "$locked" ] || continue
    [ "$(disk_budget_real "$locked" 2>/dev/null)" = "$path" ] && return 0
  done < <(git -C "$path" worktree list --porcelain 2>/dev/null | awk '
    /^worktree / { cur = substr($0, 10) }
    /^locked/ { print cur }')
  return 1
}

evaluate() {
  local path="$1" real created adm t f head ahead owner st
  V_ACTION=""
  V_REASON=""
  V_KIND=""
  V_AGE=""
  V_MAIN=""
  PR_REF=""
  PR_STATE=""
  if [ -L "$path" ]; then _keep "symbolic link, not followed"; return; fi
  if [ "${#REVIEW_ROOTS[@]}" -gt 0 ] && _in_list "$(dirname "$path")" "${REVIEW_ROOTS[@]}"; then
    _is_review_child "$path" || { _keep "unsafe review-copy root or path"; return; }
  fi
  real=$(disk_budget_real "$path") || { _keep "folder is missing"; return; }
  if ! _is_sweep_child "$real"; then _keep "outside the folders that ApexYard owns"; return; fi
  case "$START_DIR/" in
    "$real"/*) _keep "current working folder"; return ;;
  esac

  if [ -f "$real/.git" ]; then
    V_KIND=worktree
  elif [ -d "$real/.git" ]; then
    V_KIND=clone
  else
    V_KIND="export"
  fi

  _read_record "$real" || true
  if [ "$V_KIND" != "worktree" ]; then
    if ! _is_review_child "$real"; then _keep "not a linked worktree"; return; fi
    if [ "$V_KIND" != "clone" ]; then _keep "not a git clone"; return; fi
    if [ -z "$R_REPO" ] || [ -z "$R_PR" ]; then _keep "no review-copy record"; return; fi
  fi

  if [ "$V_KIND" = "worktree" ]; then
    V_MAIN=$(_worktree_main "$real")
    if [ -z "$V_MAIN" ]; then _keep "git cannot read the worktree"; return; fi
    if [ "$(disk_budget_real "$V_MAIN" 2>/dev/null)" = "$real" ]; then _keep "main checkout"; return; fi
    if _worktree_locked "$real"; then _keep "worktree is locked"; return; fi
    if command -v worktree_owner_status >/dev/null 2>&1; then
      owner=$(worktree_owner_status "$real" 2>/dev/null || true)
      case "$owner" in
        alive) _keep "a live session owns the worktree"; return ;;
        unknown) _keep "owner state unknown"; return ;;
      esac
    fi
  fi

  if [ "$V_KIND" != "export" ]; then
    st=$(git -C "$real" status --porcelain --untracked-files=all 2>/dev/null) || { _keep "git status failed"; return; }
    if [ -n "$st" ]; then _keep "uncommitted or untracked changes"; return; fi
  fi

  if [ "$V_KIND" = "clone" ]; then
    st=$(git -C "$real" stash list 2>/dev/null) || { _keep "git cannot read stashes"; return; }
    if [ -n "$st" ]; then _keep "stash contains saved work"; return; fi
    st=$(git -C "$real" rev-list --all "^$R_HEAD_SHA" --not --remotes 2>/dev/null) ||
      { _keep "git cannot check local commits"; return; }
    if [ -n "$st" ]; then _keep "commits that are not pushed"; return; fi
    st=$(git -C "$real" worktree list --porcelain 2>/dev/null) ||
      { _keep "git cannot list worktrees"; return; }
    if [ "$(printf '%s\n' "$st" | awk '/^worktree / { n++ } END { print n+0 }')" -ne 1 ]; then
      _keep "clone has additional worktrees"; return
    fi
  fi

  created=$R_CREATED
  if [ -z "$created" ] && [ "$V_KIND" = "worktree" ]; then
    adm=$(git -C "$real" rev-parse --absolute-git-dir 2>/dev/null) || adm=""
    for f in "$adm/gitdir" "$adm/HEAD" "$adm/logs/HEAD"; do
      [ -n "$adm" ] && [ -f "$f" ] || continue
      t=$(_mtime "$f") || continue
      case "$t" in ''|*[!0-9]*) continue ;; esac
      if [ -z "$created" ] || [ "$t" -gt "$created" ]; then created=$t; fi
    done
  fi
  if [ -z "$created" ] && [ "$V_KIND" = "clone" ] && [ -f "$real/.git/$RECORD_NAME" ]; then
    created=$(_mtime "$real/.git/$RECORD_NAME" || true)
  fi
  case "$created" in ''|*[!0-9]*) _keep "age unknown"; return ;; esac
  V_AGE="$(( (NOW - created) / 86400 ))d"
  if [ $(( (NOW - created) / 86400 )) -lt "$DB_MIN_AGE_DAYS" ]; then
    _keep "newer than $DB_MIN_AGE_DAYS days"
    return
  fi

  _pr_lookup "$real"
  case "$PR_STATE" in
    MERGED|CLOSED) ;;
    OPEN) _keep "PR is open"; return ;;
    *) _keep "${PR_WHY:-PR state unknown}"; return ;;
  esac

  if [ "$V_KIND" != "export" ]; then
    head=$(git -C "$real" rev-parse HEAD 2>/dev/null) || { _keep "git cannot read HEAD"; return; }
    ahead=$(git -C "$real" rev-list --count HEAD --not --remotes 2>/dev/null) || ahead=""
    # A HEAD equal to the recorded PR head came from the forge, not from local work.
    if [ "$ahead" != "0" ] && [ "$head" != "$PR_HEAD" ] && [ "$head" != "$R_HEAD_SHA" ]; then
      if [ -z "$PR_HEAD" ] || ! git -C "$real" merge-base --is-ancestor "$head" "$PR_HEAD" 2>/dev/null; then
        _keep "commits that are not pushed"
        return
      fi
    fi
  fi

  V_ACTION=remove
}

candidates() {
  local root child seen=()
  [ "${#ROOTS[@]}" -gt 0 ] || return 0
  for root in "${ROOTS[@]}"; do
    if [ "${#REVIEW_ROOTS[@]}" -gt 0 ] && _in_list "$root" "${REVIEW_ROOTS[@]}"; then
      _db_safe_review_root "$root" >/dev/null || continue
    fi
    for child in "$root"/*; do
      [ -e "$child" ] || [ -L "$child" ] || continue
      [ -d "$child" ] || [ -L "$child" ] || continue
      if $JSON; then
        if [ "${#seen[@]}" -gt 0 ] && _in_list "$child" "${seen[@]}"; then continue; fi
        seen+=("$child")
        printf '%s\0' "$child"
      else
        printf '%s\n' "$child"
      fi
    done
  done | { if $JSON; then cat; else awk '!seen[$0]++'; fi; }
}

# _shown_path <item> - the physical path, or the item itself for a symbolic
# link, so that the output never names the link target.
_shown_path() {
  if [ -L "$1" ]; then
    printf '%s\n' "$1"
  else
    disk_budget_real "$1" 2>/dev/null || printf '%s\n' "$1"
  fi
}

_log() {
  mkdir -p "$STATE_DIR" 2>/dev/null || return 0
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" "$3" "$4" "$5" "$6" >> "$LOG_FILE"
}

remove_item() {
  local real="$1" out
  case "$V_KIND" in
    worktree)
      out=$(git -C "$V_MAIN" worktree remove "$real" 2>&1) || {
        printf '%s\n' "$out" | head -1
        return 1
      }
      ;;
    clone)
      _is_review_child "$real" || { printf 'parent is not a review-copy root\n'; return 1; }
      [ -L "$real" ] && { printf 'symbolic link\n'; return 1; }
      [ -f "$real/.git/$RECORD_NAME" ] || { printf 'no review-copy record\n'; return 1; }
      rm -rf -- "$real" 2>&1 | head -1
      [ ! -e "$real" ] || return 1
      ;;
    *) printf 'unknown kind\n'; return 1 ;;
  esac
  return 0
}

cmd_measure() {
  local p kb total=0 free
  printf 'ApexYard owned folders:\n'
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    kb=$(_size_kb "$p")
    kb=${kb:-0}
    total=$((total + kb))
    printf '  %10s  %s\n' "$(disk_budget_format_kb "$kb")" "$p"
  done < <(disk_budget_owned_paths "$OPS")
  printf 'Total: %s (limit %s GB)\n' "$(disk_budget_format_kb "$total")" "$DB_MAX_GB"
  free=$(disk_budget_free_percent 10 "$OPS" 2>/dev/null || true)
  if [ -n "$free" ]; then
    printf 'Free disk space: %s%% (limit %s%%)\n' "$free" "$DB_MIN_FREE_PCT"
  fi
}

cmd_dry_run() {
  local item real kb total=0 count=0 keep_lines="" remove_lines="" plan_id plan
  local plan_entries="" items="" kept_json="" bytes delim=$'\n'
  $JSON && delim=''

  while IFS= read -r -d "$delim" item; do
    [ -n "$item" ] || continue
    evaluate "$item"
    real=$(_shown_path "$item")
    if [ "$V_ACTION" = "remove" ]; then
      kb=$(_size_kb "$real")
      bytes=null
      case "$kb" in ''|*[!0-9]*) ;; *) bytes=$((kb * 1024)) ;; esac
      if $JSON; then
        items="$items$(jq -cn --arg path "$real" --arg kind "$V_KIND" --argjson bytes "$bytes" \
          --arg reason "$PR_REF $PR_STATE age $V_AGE" '{path:$path,kind:$kind,bytes:$bytes,reason:$reason}')"$'\n'
      fi
      kb=${kb:-0}
      total=$((total + kb))
      count=$((count + 1))
      remove_lines="$remove_lines$(printf '  %10s  %-8s  %s  %s %s  age %s' "$(disk_budget_format_kb "$kb")" "$V_KIND" "$real" "$PR_REF" "$PR_STATE" "$V_AGE")"$'\n'
      plan_entries="$plan_entries$real"$'\n'
    else
      $JSON && kept_json="$kept_json$(_json_entry "$real" "$V_REASON")"$'\n'
      keep_lines="$keep_lines$(printf '  %-8s  %s  (%s)' "${V_KIND:--}" "$real" "$V_REASON")"$'\n'
    fi
  done < <(candidates)

  if $JSON; then
    mkdir -p "$STATE_DIR" || die "cannot create $STATE_DIR"
    plan_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
    plan="$STATE_DIR/plan-$plan_id"
    # NUL-delimited paths preserve newlines. Legacy text plans remain accepted.
    { printf 'apexyard-nul-plan/1\n'; printf '%s' "$items" | jq -j '.path, "\u0000"'; } > "$plan" || die "cannot write $plan"
    jq -cn --arg id "$plan_id" --argjson items "$(printf '%s' "$items" | jq -s .)" \
      --argjson kept "$(printf '%s' "$kept_json" | jq -s .)" \
      '{schema:"apexyard.disk-sweep-plan/1",plan_id:$id,items:$items,kept:$kept}'
    return
  fi
  printf 'ApexYard disk sweep - dry run. Nothing was removed.\n'
  printf 'Rules: copies older than %s days whose PR is merged or closed.\n\n' "$DB_MIN_AGE_DAYS"
  if [ "$count" -eq 0 ]; then
    printf 'Remove: none.\n'
  else
    printf 'Remove (%s items, %s):\n%s' "$count" "$(disk_budget_format_kb "$total")" "$remove_lines"
  fi
  if [ -n "$keep_lines" ]; then
    printf '\nKeep:\n%s' "$keep_lines"
  fi
  [ "$count" -gt 0 ] || return 0

  mkdir -p "$STATE_DIR" || die "cannot create $STATE_DIR"
  plan_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
  plan="$STATE_DIR/plan-$plan_id"
  printf '%s' "$plan_entries" > "$plan" || die "cannot write $plan"
  printf '\nPlan: %s\n' "$plan_id"
  printf 'Ask the user. After the user says yes, run: %s/bin/apexyard-disk-sweep.sh --apply %s\n' "$OPS" "$plan_id"
}

cmd_apply() {
  local plan_id="$1" plan item real kb removed=0 kept=0 failed=0 why mtime
  local removed_json="" skipped_json="" delim=$'\n' header
  case "$plan_id" in
    ''|*[!A-Za-z0-9-]*) die "plan id is not valid: $plan_id" ;;
  esac
  plan="$STATE_DIR/plan-$plan_id"
  [ -f "$plan" ] && [ ! -L "$plan" ] || die "no plan $plan_id. Run a dry run first."
  mtime=$(_mtime "$plan")
  case "$mtime" in ''|*[!0-9]*) mtime=0 ;; esac
  if [ $((NOW - mtime)) -gt "$PLAN_MAX_AGE_SECONDS" ]; then
    die "plan $plan_id is older than 24 hours. Run a new dry run."
  fi

  $JSON || printf 'ApexYard disk sweep - apply plan %s.\n' "$plan_id"
  IFS= read -r header < "$plan"
  [ "$header" != apexyard-nul-plan/1 ] || delim=''

  while IFS= read -r -d "$delim" item; do
    case "$item" in /*) ;; *) continue ;; esac
    evaluate "$item"
    real=$(_shown_path "$item")
    if [ "$V_ACTION" != "remove" ]; then
      kept=$((kept + 1))
      $JSON && skipped_json="$skipped_json$(_json_entry "$real" "$V_REASON")"$'\n'
      $JSON || printf '  kept     %s (%s)\n' "$real" "$V_REASON"
      _log kept "${V_KIND:--}" "$real" "${PR_REF:--} ${PR_STATE:--}" "-" "$V_REASON"
      continue
    fi
    kb=$(_size_kb "$real")
    kb=${kb:-0}
    if why=$(remove_item "$real"); then
      removed=$((removed + 1))
      $JSON && removed_json="$removed_json$(_json_entry "$real" "removed")"$'\n'
      $JSON || printf '  removed  %s (%s)\n' "$real" "$(disk_budget_format_kb "$kb")"
      _log removed "$V_KIND" "$real" "$PR_REF $PR_STATE" "${kb}KB" "age $V_AGE"
    else
      failed=$((failed + 1))
      $JSON && skipped_json="$skipped_json$(_json_entry "$real" "${why:-removal failed}")"$'\n'
      $JSON || printf '  failed   %s (%s)\n' "$real" "${why:-removal failed}"
      _log failed "$V_KIND" "$real" "$PR_REF $PR_STATE" "${kb}KB" "${why:-removal failed}"
    fi
  done < <(if [ "$header" = apexyard-nul-plan/1 ]; then tail -n +2 "$plan"; else cat "$plan"; fi)
  rm -f -- "$plan" "$OPS/.claude/session/disk-budget-size"
  $JSON || printf 'Removed %s, kept %s, failed %s. Log: %s\n' "$removed" "$kept" "$failed" "$LOG_FILE"
  if $JSON; then
    jq -cn --argjson removed "$(printf '%s' "$removed_json" | jq -s .)" \
      --argjson skipped "$(printf '%s' "$skipped_json" | jq -s .)" \
      '{schema:"apexyard.disk-sweep-apply/1",removed:$removed,skipped:$skipped}'
  fi
  [ "$failed" -eq 0 ]
}

case "${1:-}" in
  ''|--dry-run) cmd_dry_run ;;
  --measure) cmd_measure ;;
  --apply)
    [ "$#" -eq 2 ] || die "usage: --apply <plan-id>"
    cmd_apply "$2"
    ;;
  -h|--help)
    sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
    ;;
  *) die "unknown option: $1 (use --help)" ;;
esac
