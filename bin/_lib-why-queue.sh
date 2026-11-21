#!/usr/bin/env bash
# Read PR gate results without changing repository state.
# Variables come from the CLI and the shared repository resolver.
# shellcheck disable=SC2154,SC2034
# shellcheck source=bin/_lib-repo-resolve.sh
source "$(dirname "$cli_path")/_lib-repo-resolve.sh"

# Check the evaluator JSON. The queue also needs the awaiting_owner_only field.
wq_valid() {
  printf '%s' "$1" | jq -se '
    length == 1 and (.[0] | type == "object" and
    (.next_action | type == "string") and (.items | type == "array" and length > 0) and
    all(.items[]; (.section | type == "string") and (.name | type == "string") and
      (.status | IN("satisfied", "not required", "missing", "stale", "not verified")) and
      (.detail | type == "string")))' >/dev/null 2>&1
}

# Run the evaluator in the clone. Write its JSON to <outfile>. Print a reason on failure.
wq_run() {
  local root=$1 clone=$2 target=$3 out=$4 helper
  helper=${APEXYARD_PR_STATUS:-$root/bin/apexyard-pr-status}
  if [ ! -d "$clone" ]; then
    echo 'repository clone is unavailable'
  elif [ ! -f "$helper" ]; then
    echo "PR status helper is missing at $helper. Update the ops repo with /update."
  elif ! (cd "$clone" && APEXYARD_DISABLE_RESOLUTION_CACHE=1 bash "$helper" "$target" --json 2>/dev/null) > "$out"; then
    echo 'PR status check failed'
  elif ! wq_valid "$(cat "$out")"; then
    echo 'invalid PR status JSON'
  fi
}

wq_read() {
  local tmp reason
  tmp=$(mktemp "${TMPDIR:-/tmp}/apexyard-why.XXXXXX") || { wq_reason='cannot create a temporary file'; return 1; }
  reason=$(wq_run "$1" "$2" "$3" "$tmp")
  wq_data=$(cat "$tmp"); rm -f "$tmp"
  wq_reason=$reason
  [ -z "$wq_reason" ]
}

why_usage() { echo 'Usage: apexyard why <PR> [--repo <name|owner/name>] [--json]' >&2; }

why_queue() {
  local root=$1 cmd=$2 json=0 selector="" target="" arg number repo clone parsed name ws rest row list
  local resolved_repo resolved_clone wq_data wq_reason ready='[]' unknown='[]' blocked=0 reason
  local tmp seen="" pending jobs n file
  export APEXYARD_DISABLE_RESOLUTION_CACHE=1
  shift 2
  command -v jq >/dev/null 2>&1 || { echo 'apexyard: jq is required.' >&2; return 2; }
  while [ "$#" -gt 0 ]; do
    arg=$1; shift
    case "$arg" in
      --json) json=1 ;;
      --repo) [ "$#" -gt 0 ] || { echo '--repo requires a value.' >&2; [ "$cmd" = why ] && why_usage; return 2; }; selector=$1; shift ;;
      -*) echo "Unknown option: $arg" >&2; return 2 ;;
      *) [ -z "$target" ] || { echo 'Give one PR.' >&2; return 2; }; target=$arg ;;
    esac
  done
  if [ "$cmd" = why ]; then
    if [[ "$target" =~ ^([A-Za-z0-9_.-]+/)?[A-Za-z0-9_.-]+#[0-9]+$ ]]; then
      if [ -n "$selector" ] && [ "$selector" != "${target%#*}" ]; then
        printf 'apexyard: --repo %s conflicts with %s. Use one of them.\n' "$selector" "$target" >&2
        return 2
      fi
      selector=${target%#*}
      number=${target##*#}
    elif [[ "$target" =~ ^[0-9]+$ ]]; then number=$target
    else why_usage; return 2
    fi
    number=$(printf '%s' "$number" | sed 's/^0*//'); number=${number:-0}
    repo_resolve "$root" "$selector" "$PWD" "$json" || return 2
    repo=$resolved_repo; clone=$resolved_clone
    if ! wq_read "$root" "$clone" "$repo#$number"; then
      if [ "$json" = 1 ]; then
        jq -n --arg repo "$repo" --argjson pr "$number" --arg reason "$wq_reason" \
          '{repo:$repo,pr:$pr,next_action:null,verified:false,reason:$reason}'
      else printf 'not verified: %s\n' "$wq_reason"; fi
      return 1
    fi
    if [ "$json" = 1 ]; then
      printf '%s' "$wq_data" | jq --arg repo "$repo" --argjson pr "$number" \
        '{repo:$repo,pr:$pr,next_action,verified:true,items}'
    else
      printf '%s' "$wq_data" | jq -r '.next_action, "SECTION\tITEM\tSTATUS\tDETAIL", (.items[] | [.section,.name,.status,.detail] | @tsv)'
    fi
    return
  fi
  [ -z "$target" ] && [ -z "$selector" ] || { echo 'Usage: apexyard queue [--json]' >&2; return 2; }
  # Load the registry parser through the same libraries as repo_resolve.
  # shellcheck source=/dev/null
  source "$root/.claude/hooks/_lib-read-config.sh"
  # shellcheck source=/dev/null
  source "$root/.claude/hooks/_lib-portfolio-paths.sh"
  # shellcheck source=/dev/null
  source "$root/.claude/hooks/_lib-multi-repo-trace.sh"
  parsed=$(cd "$root" && _mrt_parse_registry) || return 2
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/apexyard-queue.XXXXXX") || return 2
  jobs=${APEXYARD_QUEUE_JOBS:-6}
  while IFS='|' read -r name repo ws rest; do
    [ -n "$repo" ] || continue
    case " $seen " in *" $repo "*) continue ;; esac
    seen="$seen $repo"
    repo_resolve "$root" "$repo" "$PWD" 1 || { rm -rf "$tmp"; return 2; }
    clone=$resolved_clone
    # One listing call per repository. The rollup lets the loop skip drafts and red CI.
    if ! list=$("${APEXYARD_GH:-gh}" pr list --repo "$repo" --state open --limit 100000 --json number,url,title,isDraft,statusCheckRollup 2>/dev/null) ||
       ! printf '%s' "$list" | jq -se 'length == 1 and (.[0] | type == "array" and all(.[]; (.number | type == "number" and . > 0 and floor == .) and (.url | type == "string") and (.title | type == "string")))' >/dev/null 2>&1; then
      unknown=$(printf '%s' "$unknown" | jq --arg repo "$repo" '. + [{repo:$repo,pr:null,reason:"cannot list open PRs"}]')
      continue
    fi
    pending=""
    while IFS= read -r row; do
      [ -n "$row" ] || continue
      number=$(printf '%s' "$row" | jq -r .number)
      # Skip the full evaluation when the PR is a draft or a check already failed.
      if printf '%s' "$row" | jq -e '(.isDraft == true) or any((.statusCheckRollup // [])[]; (.conclusion // "") | IN("FAILURE","TIMED_OUT","CANCELLED","STARTUP_FAILURE","ACTION_REQUIRED")) or any((.statusCheckRollup // [])[]; (.state // "") | IN("FAILURE","ERROR"))' >/dev/null 2>&1; then
        blocked=$((blocked + 1))
        continue
      fi
      pending="$pending $number"
      printf '%s' "$row" > "$tmp/row-$number"
    done < <(printf '%s' "$list" | jq -c '.[]')
    # Evaluate the remaining PRs in small parallel batches.
    n=0
    for number in $pending; do
      ( wq_run "$root" "$clone" "$repo#$number" "$tmp/data-$number" > "$tmp/reason-$number" ) &
      n=$((n + 1))
      if [ "$n" -ge "$jobs" ]; then wait; n=0; fi
    done
    wait
    for number in $pending; do
      row=$(cat "$tmp/row-$number")
      reason=$(cat "$tmp/reason-$number")
      file="$tmp/data-$number"
      if [ -z "$reason" ] && ! jq -e '.head.sha | type == "string" and length > 0 and . != "unknown"' "$file" >/dev/null 2>&1; then reason='PR head is unknown'; fi
      if [ -z "$reason" ] && ! jq -e 'has("awaiting_owner_only")' "$file" >/dev/null 2>&1; then
        reason='the PR status helper is too old. Update the ops repo with /update.'
      fi
      # Only the evaluator's own words decide. Other items that cannot be checked stay unverified.
      if [ -z "$reason" ] && jq -e 'any(.items[]; .name != "ceo" and .name != "review gate" and .status == "not verified")' "$file" >/dev/null; then reason='gate items are not verified'; fi
      if [ -z "$reason" ] && jq -e '.awaiting_owner_only != true and any(.items[]; .name == "review gate" and .status == "not verified")' "$file" >/dev/null; then reason='the review gate is not verified'; fi
      if [ -n "$reason" ]; then
        unknown=$(printf '%s' "$unknown" | jq --arg repo "$repo" --argjson pr "$number" --arg reason "$reason" '. + [{repo:$repo,pr:$pr,reason:$reason}]')
      elif jq -e '.awaiting_owner_only == true' "$file" >/dev/null; then
        ready=$(printf '%s' "$ready" | jq --arg repo "$repo" --argjson row "$row" --arg next "$(jq -r .next_action "$file")" '. + [{repo:$repo,pr:$row.number,url:$row.url,title:$row.title,next_action:$next}]')
      else blocked=$((blocked + 1))
      fi
    done
  done <<< "$parsed"
  rm -rf "$tmp"
  if [ "$json" = 1 ]; then
    jq -n --argjson ready "$ready" --argjson unknown "$unknown" --argjson blocked "$blocked" '{ready:$ready,not_verified:$unknown,blocked_count:$blocked}'
  else
    [ "$ready" != '[]' ] || echo 'No PRs wait only for your approval.'
    printf '%s' "$ready" | jq -r '.[] | "\(.repo)#\(.pr) \(.title)"'
    printf '%s' "$unknown" | jq -r '.[] | "not verified: \(.repo)#\(.pr // "?") \(.reason)"'
  fi
}
