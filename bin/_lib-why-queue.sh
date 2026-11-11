#!/usr/bin/env bash
# Read PR gate results without changing repository state.
# Variables come from the CLI and the shared repository resolver.
# shellcheck disable=SC2154,SC2034
# shellcheck source=bin/_lib-repo-resolve.sh
source "$(dirname "$cli_path")/_lib-repo-resolve.sh"

wq_read() {
  local root=$1 clone=$2 target=$3 helper
  helper=${APEXYARD_PR_STATUS:-$root/bin/apexyard-pr-status}
  wq_reason=""
  if [ ! -d "$clone" ]; then
    wq_reason='repository clone is unavailable'
  elif [ ! -f "$helper" ]; then
    wq_reason='PR status helper is unavailable'
  elif ! wq_data=$(cd "$clone" && APEXYARD_DISABLE_RESOLUTION_CACHE=1 bash "$helper" "$target" --json 2>/dev/null); then
    wq_reason='PR status check failed'
  elif ! printf '%s' "$wq_data" | jq -se '
    length == 1 and (.[0] | type == "object" and
    (.next_action | type == "string") and (.items | type == "array" and length > 0) and
    all(.items[]; (.section | type == "string") and (.name | type == "string") and
      (.status | IN("satisfied", "not required", "missing", "stale", "not verified")) and
      (.detail | type == "string")))' >/dev/null 2>&1; then
    wq_reason='invalid PR status JSON'
  fi
  [ -z "$wq_reason" ]
}

why_queue() {
  local root=$1 cmd=$2 json=0 selector="" target="" arg number repo clone parsed name ws rest row list
  local resolved_repo resolved_clone wq_data wq_reason ready='[]' unknown='[]' blocked=0 reason
  export APEXYARD_DISABLE_RESOLUTION_CACHE=1
  shift 2
  command -v jq >/dev/null 2>&1 || { echo 'apexyard: jq is required.' >&2; return 2; }
  while [ "$#" -gt 0 ]; do
    arg=$1; shift
    case "$arg" in
      --json) json=1 ;;
      --repo) [ "$#" -gt 0 ] || return 2; selector=$1; shift ;;
      -*) echo "Unknown option: $arg" >&2; return 2 ;;
      *) [ -z "$target" ] || return 2; target=$arg ;;
    esac
  done
  if [ "$cmd" = why ]; then
    if [[ "$target" =~ ^([A-Za-z0-9_.-]+/)?[A-Za-z0-9_.-]+#[0-9]+$ ]]; then
      [ -n "$selector" ] || selector=${target%#*}
      number=${target##*#}
    elif [[ "$target" =~ ^[0-9]+$ ]]; then number=$target
    else echo 'Usage: apexyard why <PR> [--repo <name|owner/name>] [--json]' >&2; return 2
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
  while IFS='|' read -r name repo ws rest; do
    [ -n "$repo" ] || continue
    repo_resolve "$root" "$repo" "$PWD" 1 || return 2
    clone=$resolved_clone
    if ! list=$("${APEXYARD_GH:-gh}" pr list --repo "$repo" --state open --limit 100000 --json number,url,title 2>/dev/null) ||
       ! printf '%s' "$list" | jq -se 'length == 1 and (.[0] | type == "array" and all(.[]; (.number | type == "number" and . > 0 and floor == .) and (.url | type == "string") and (.title | type == "string")))' >/dev/null 2>&1; then
      unknown=$(printf '%s' "$unknown" | jq --arg repo "$repo" '. + [{repo:$repo,pr:null,reason:"cannot list open PRs"}]')
      continue
    fi
    while IFS= read -r row; do
      [ -n "$row" ] || continue
      number=$(printf '%s' "$row" | jq -r .number)
      reason=""
      if ! wq_read "$root" "$clone" "$repo#$number"; then reason=$wq_reason
      elif ! printf '%s' "$wq_data" | jq -e '.head.sha | type == "string" and length > 0 and . != "unknown"' >/dev/null 2>&1; then reason='PR head is unknown'
      elif printf '%s' "$wq_data" | jq -e 'any(.items[]; .name != "ceo" and .status == "not verified")' >/dev/null; then reason='gate items are not verified'
      fi
      if [ -n "$reason" ]; then
        unknown=$(printf '%s' "$unknown" | jq --arg repo "$repo" --argjson pr "$number" --arg reason "$reason" '. + [{repo:$repo,pr:$pr,reason:$reason}]')
      elif printf '%s' "$wq_data" | jq -e 'all(.items[]; .name == "ceo" or .status == "satisfied" or .status == "not required")' >/dev/null; then
        ready=$(printf '%s' "$ready" | jq --arg repo "$repo" --argjson row "$row" --arg next "$(printf '%s' "$wq_data" | jq -r .next_action)" '. + [{repo:$repo,pr:$row.number,url:$row.url,title:$row.title,next_action:$next}]')
      else blocked=$((blocked + 1))
      fi
    done < <(printf '%s' "$list" | jq -c '.[]')
  done <<< "$parsed"
  if [ "$json" = 1 ]; then
    jq -n --argjson ready "$ready" --argjson unknown "$unknown" --argjson blocked "$blocked" '{ready:$ready,not_verified:$unknown,blocked_count:$blocked}'
  else
    [ "$ready" != '[]' ] || echo 'No PRs wait only for your approval.'
    printf '%s' "$ready" | jq -r '.[] | "\(.repo)#\(.pr) \(.title)"'
    printf '%s' "$unknown" | jq -r '.[] | "not verified: \(.repo)#\(.pr // "?") \(.reason)"'
  fi
}
