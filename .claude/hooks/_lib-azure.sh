#!/bin/bash
# Azure DevOps Services adapter. Sourced on demand by _lib-tracker.sh.
# Context is explicit. Responses never become shell code. See AgDR-0323.

_azure_call() {
  # Prefer a native timeout for installed CLIs. Shell-function fixtures use
  # the existing portable watchdog because timeout cannot execute a function.
  if ! declare -F az >/dev/null 2>&1; then
    if command -v timeout >/dev/null 2>&1; then
      timeout -k 2 30 az "$@" --only-show-errors --output json
      return $?
    fi
    if command -v gtimeout >/dev/null 2>&1; then
      gtimeout -k 2 30 az "$@" --only-show-errors --output json
      return $?
    fi
  fi
  _apexyard_gh_watchdog 30 az "$@" --only-show-errors --output json
}

_azure_setting() {
  local value=""
  if [ -n "$1" ]; then
    value=$(_tracker_project_value "$1" "azure_$2") || value=""
  fi
  if [ -z "$value" ] || [ "$value" = null ]; then
    value=$(_tracker_config_get_or ".tracker.azure_$2" "${3:-}") || return 1
  fi
  [ "$value" != null ] || return 1
  printf '%s\n' "$value"
}

_azure_context() {
  local alias="$1" need_repo="${2:-false}" raw
  AZ_ORG=$(_azure_setting "$alias" organization) || return 1
  AZ_PROJECT=$(_azure_setting "$alias" project) || return 1
  if ! printf '%s' "$AZ_ORG" | grep -qE '^https://dev\.azure\.com/[A-Za-z0-9][A-Za-z0-9_-]*/?$'; then
    echo 'Azure adapter: configure an explicit https://dev.azure.com/<organization> URL.' >&2
    return 1
  fi
  AZ_ORG=${AZ_ORG%/}
  [ -n "$AZ_PROJECT" ] && ! printf '%s' "$AZ_PROJECT" | LC_ALL=C grep -q '[[:cntrl:]]' || return 1
  raw=$(_azure_call devops project show --organization "$AZ_ORG" --project "$AZ_PROJECT" --detect false) || return 1
  printf '%s' "$raw" | jq -e --arg p "$AZ_PROJECT" '
    type == "object" and (.id | type == "string" and length > 0) and
    (.name | type == "string" and length > 0) and (.id == $p or .name == $p)' >/dev/null || return 1
  AZ_PROJECT_ID=$(printf '%s' "$raw" | jq -r .id)
  AZ_PROJECT_NAME=$(printf '%s' "$raw" | jq -r .name)
  if [ "$need_repo" = true ]; then
    AZ_REPO=$(_azure_setting "$alias" repository) || return 1
    [ -n "$AZ_REPO" ] && ! printf '%s' "$AZ_REPO" | LC_ALL=C grep -q '[[:cntrl:]]' || return 1
    raw=$(_azure_call repos show --organization "$AZ_ORG" --project "$AZ_PROJECT_ID" --repository "$AZ_REPO" --detect false) || return 1
    printf '%s' "$raw" | jq -e --arg r "$AZ_REPO" --arg p "$AZ_PROJECT_ID" '
      type == "object" and (.id | type == "string" and length > 0) and
      (.name | type == "string" and length > 0) and (.id == $r or .name == $r) and .project.id == $p' >/dev/null || return 1
    AZ_REPO_ID=$(printf '%s' "$raw" | jq -r .id)
  fi
}

_azure_id() {
  local id="${1#AB-}"
  case "$id" in ''|0|0*|*[!0-9]*) return 1 ;; esac
  [ "${#id}" -le 10 ] || return 1
  [ "$id" -le 2147483647 ] || return 1
  printf '%s\n' "$id"
}

_azure_normalise_item() {
  local raw="$1" id="${2:-}" project_url
  project_url=$(jq -rn --arg p "$AZ_PROJECT_NAME" '$p|@uri') || return 1
  printf '%s' "$raw" | jq -ce --arg id "$id" --arg project "$AZ_PROJECT_NAME" \
    --arg base "$AZ_ORG/$project_url" '
    select(type == "object" and (.id | type == "number" and . > 0 and floor == .)) |
    select($id == "" or (.id | tostring) == $id) |
    select(.fields["System.TeamProject"] == $project) |
    select((.fields["System.Title"] | type) == "string" and (.fields["System.State"] | type) == "string") |
    {number:.id, state:(.fields["System.State"] | ascii_upcase),
     title:.fields["System.Title"], url:($base + "/_workitems/edit/" + (.id|tostring)),
     labels:((.fields["System.Tags"] // "") | split(";") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))),
     body:(.fields["System.Description"] // ""), updatedAt:(.fields["System.ChangedDate"] // "")}'
}

_azure_view() {
  local alias="$1" id raw
  id=$(_azure_id "$2") || return 1
  _azure_context "$alias" || return 1
  raw=$(_azure_call boards work-item show --id "$id" --organization "$AZ_ORG" --detect false) || return 1
  _azure_normalise_item "$raw" "$id"
}

_azure_create() {
  local alias="$1" title="$2" body_file="${3:-}" labels="${4:-}" milestone="${5:-}" raw item kind body=""
  # Azure iterations differ from GitHub milestones. Do not silently ignore one.
  [ -z "$milestone" ] || { echo 'Azure adapter: milestones are unsupported.' >&2; return 1; }
  _azure_context "$alias" || return 1
  kind=$(_azure_setting "$alias" work_item_type Task) || return 1
  [ -n "$kind" ] || return 1
  if [ -n "$body_file" ]; then
    [ -f "$body_file" ] && [ -r "$body_file" ] || return 1
    body=$(cat "$body_file") || return 1
  fi
  raw=$(_azure_call boards work-item create --organization "$AZ_ORG" --project "$AZ_PROJECT_ID" \
    --type "$kind" --title "$title" --description "$body" --fields "System.Tags=${labels//,/;}" --detect false) || {
    echo 'Azure adapter: creation outcome is uncertain. Reconcile before retrying.' >&2
    return 1
  }
  item=$(_azure_normalise_item "$raw") || return 1
  printf '%s' "$item" | jq -c '{ref:("AB-" + (.number|tostring)),url}'
}

_azure_wiql_quote() { printf '%s' "$1" | sed "s/'/''/g"; }

_azure_list() {
  local alias="$1" state="$2" assignee="$3" author="$4" labels="$5" search="$6" since="$7" limit="$8"
  local query project raw result='[]' row item
  # Filters without an equivalent contract must not silently broaden a query.
  [ -z "$assignee$author$labels$search" ] || { echo 'Azure adapter: assignee, author, labels and search list filters are unsupported.' >&2; return 1; }
  case "$limit" in ''|*[!0-9]*) return 1 ;; esac
  [ "$limit" -gt 0 ] && [ "$limit" -le 200 ] || return 1
  _azure_context "$alias" || return 1
  project=$(_azure_wiql_quote "$AZ_PROJECT_NAME")
  query="SELECT [System.Id], [System.Title], [System.State], [System.TeamProject], [System.Tags], [System.Description], [System.ChangedDate] FROM WorkItems WHERE [System.TeamProject] = '$project'"
  case "$state" in
    ''|all) ;;
    open) query="$query AND [System.State] NOT IN ('Closed', 'Done', 'Removed', 'Resolved')" ;;
    closed) query="$query AND [System.State] IN ('Closed', 'Done', 'Removed', 'Resolved')" ;;
    *) return 1 ;;
  esac
  query="$query ORDER BY [System.ChangedDate] DESC"
  raw=$(_azure_call boards query --organization "$AZ_ORG" --project "$AZ_PROJECT_ID" --wiql "$query" --detect false) || return 1
  # Microsoft's query_work_items returns None for an empty successful query.
  # Azure CLI can render that as null or suppress output entirely.
  case "$raw" in ''|null) printf '[]\n'; return 0 ;; esac
  # The CLI query command has no top option. Fetch the complete server response,
  # validate it, then bound output. Azure rejects WIQL over its result limit.
  printf '%s' "$raw" | jq -e 'type == "array"' >/dev/null || return 1
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    item=$(_azure_normalise_item "$row") || return 1
    result=$(printf '%s' "$result" | jq -c --argjson item "$item" '. + [$item]') || return 1
  done <<EOF
$(printf '%s' "$raw" | jq -c '.[]')
EOF
  result=$(printf '%s' "$result" | jq -c --argjson n "$limit" --arg since "$since" \
    '.[:$n] | map(select($since == "" or .updatedAt == "" or .updatedAt >= $since))') || return 1
  printf '%s\n' "$result"
}

# az devops invoke keeps authentication inside Azure CLI. The resource is a
# library constant, not caller-controlled command text.
_azure_invoke() {
  local resource="$1" pr="$2"
  shift 2
  _azure_call devops invoke --organization "$AZ_ORG" --area git --resource "$resource" \
    --route-parameters "project=$AZ_PROJECT_ID" "repositoryId=$AZ_REPO_ID" "pullRequestId=$pr" \
    --api-version 7.1 "$@"
}

_azure_pr() {
  local id raw
  id=$(_azure_id "$1") || return 1
  raw=$(_azure_call repos pr show --organization "$AZ_ORG" --id "$id" --detect false) || return 1
  printf '%s' "$raw" | jq -ce --argjson id "$id" --arg project "$AZ_PROJECT_ID" --arg repo "$AZ_REPO_ID" '
    select(type == "object" and .pullRequestId == $id and .repository.id == $repo and .repository.project.id == $project) |
    select((.lastMergeSourceCommit.commitId | type) == "string" and (.lastMergeSourceCommit.commitId | test("^[0-9a-fA-F]{40}$"))) |
    select((.sourceRefName | type) == "string" and (.targetRefName | type) == "string")'
}

_azure_pr_field() {
  local alias="$1" id="$2" field="$3" raw
  _azure_context "$alias" true || return 1
  raw=$(_azure_pr "$id") || return 1
  case "$field" in
    head) printf '%s' "$raw" | jq -r '.lastMergeSourceCommit.commitId | ascii_downcase' ;;
    branch) printf '%s' "$raw" | jq -r '.sourceRefName | sub("^refs/heads/"; "")' ;;
    base) printf '%s' "$raw" | jq -r '.targetRefName | sub("^refs/heads/"; "")' ;;
    *) return 1 ;;
  esac
}

_azure_create_pr() {
  local alias="$1" title="$2" body_file="$3" base="$4" head="$5" raw body project repo
  [ -r "$body_file" ] && [ -f "$body_file" ] || return 1
  body=$(cat "$body_file") || return 1
  _azure_context "$alias" true || return 1
  raw=$(_azure_call repos pr create --organization "$AZ_ORG" --project "$AZ_PROJECT_ID" --repository "$AZ_REPO_ID" \
    --title "$title" --description "$body" --source-branch "$head" --target-branch "$base" \
    --auto-complete false --detect false) || {
    echo 'Azure adapter: PR creation outcome is uncertain. Reconcile before retrying.' >&2
    return 1
  }
  project=$(jq -rn --arg p "$AZ_PROJECT_NAME" '$p|@uri') || return 1
  repo=$(jq -rn --arg r "$AZ_REPO_ID" '$r|@uri') || return 1
  printf '%s' "$raw" | jq -ce --arg p "$AZ_PROJECT_ID" --arg r "$AZ_REPO_ID" --arg base "$AZ_ORG/$project/_git/$repo/pullrequest/" '
    select(type == "object" and (.pullRequestId|type == "number" and . > 0) and
      .repository.id == $r and .repository.project.id == $p and .status == "active") |
    {number:.pullRequestId,url:($base + (.pullRequestId|tostring))}'
}

_azure_iterations() {
  local raw
  raw=$(_azure_invoke pullRequestIterations "$1" --http-method GET) || return 1
  printf '%s' "$raw" | jq -ce '
    select(type == "object" and (.value | type) == "array" and .count == (.value|length)) |
    .value | select(length > 0) |
    select(all(.[]; (.id | type == "number" and . > 0 and floor == .) and
      (.sourceRefCommit.commitId | type == "string" and test("^[0-9a-fA-F]{40}$")))) |
    select((map(.id)|unique|length) == length)'
}

_azure_review() {
  local alias="$1" id="$2" verdict="$3" body_file="${4:-}" pr iterations iteration body payload raw tmp vote
  _azure_context "$alias" true || return 1
  pr=$(_azure_pr "$id") || return 1
  iterations=$(_azure_iterations "$id") || return 1
  iteration=$(printf '%s' "$iterations" | jq -er --arg sha "$(printf '%s' "$pr" | jq -r .lastMergeSourceCommit.commitId)" \
    'max_by(.id) | select(.sourceRefCommit.commitId == $sha) | .id') || return 1
  [ -n "$body_file" ] && [ -r "$body_file" ] && [ -f "$body_file" ] || return 1
  body=$(cat "$body_file") || return 1
  [ -n "$body" ] || return 1
  payload=$(jq -nc --arg body "$body" --argjson iteration "$iteration" \
    '{comments:[{parentCommentId:0,content:$body,commentType:1}],status:1,
      pullRequestThreadContext:{iterationContext:{firstComparingIteration:1,secondComparingIteration:$iteration}}}') || return 1
  tmp=$(mktemp) || return 1
  printf '%s' "$payload" > "$tmp"
  raw=$(_azure_invoke pullRequestThreads "$id" --http-method POST --in-file "$tmp")
  local rc=$?
  rm -f "$tmp"
  [ "$rc" = 0 ] || return 1
  printf '%s' "$raw" | jq -e --argjson i "$iteration" \
    '(.id | type == "number" and . > 0) and .pullRequestThreadContext.iterationContext.secondComparingIteration == $i' >/dev/null || return 1
  case "$verdict" in approve) vote=approve ;; request-changes) vote=reject ;; *) return 0 ;; esac
  _azure_call repos pr set-vote --organization "$AZ_ORG" --id "$id" --vote "$vote" --detect false
}

_azure_review_at_sha() {
  local alias="$1" id="$2" sha="$3" pr iterations threads
  _azure_context "$alias" true || return 2
  pr=$(_azure_pr "$id") || return 2
  iterations=$(_azure_iterations "$id") || return 2
  threads=$(_azure_invoke pullRequestThreads "$id" --http-method GET) || return 2
  printf '%s' "$threads" | jq -e 'type == "object" and (.value|type) == "array" and .count == (.value|length)' >/dev/null || return 2
  printf '%s' "$threads" | jq -e --arg sha "$sha" --argjson iterations "$iterations" '
    any(.value[]; . as $thread |
      (.id|type == "number" and . > 0) and .isDeleted != true and
      (.pullRequestThreadContext.iterationContext.secondComparingIteration as $i |
        any($iterations[]; .id == $i and (.sourceRefCommit.commitId|ascii_downcase) == ($sha|ascii_downcase))) and
      any(.comments[]?; .isDeleted != true and (.commentType == "text" or .commentType == 1) and (.content|type == "string" and length > 0)))' >/dev/null
}

_azure_files() {
  local alias="$1" id="$2" pr iterations iteration raw
  _azure_context "$alias" true || return 1
  pr=$(_azure_pr "$id") || return 1
  iterations=$(_azure_iterations "$id") || return 1
  iteration=$(printf '%s' "$iterations" | jq -er --arg sha "$(printf '%s' "$pr" | jq -r .lastMergeSourceCommit.commitId)" \
    'max_by(.id) | select(.sourceRefCommit.commitId == $sha) | .id') || return 1
  # shellcheck disable=SC2016 # Azure query parameter names contain literal $.
  raw=$(_azure_invoke pullRequestIterationChanges "$id" --http-method GET \
    --route-parameters "project=$AZ_PROJECT_ID" "repositoryId=$AZ_REPO_ID" "pullRequestId=$id" "iterationId=$iteration" \
    --query-parameters '$compareTo=0' '$top=3001' '$skip=0') || return 1
  printf '%s' "$raw" | jq -ce '
    select(type == "object" and (.changeEntries|type) == "array") |
    select((.nextSkip // 0) == 0 and (.nextTop // 0) == 0 and (.changeEntries|length) <= 3000) |
    [.changeEntries[] | (.item.path, .originalPath // empty) |
      if type != "string" or length == 0 or test("[\r\n]") then error("invalid path") else sub("^/"; "") end] |
    unique | {count:length,files:.}'
}

_azure_ci() {
  local alias="$1" id="$2" pr raw statuses artifact iterations iteration
  _azure_context "$alias" true || return 1
  pr=$(_azure_pr "$id") || return 1
  iterations=$(_azure_iterations "$id") || return 1
  iteration=$(printf '%s' "$iterations" | jq -er --arg sha "$(printf '%s' "$pr" | jq -r .lastMergeSourceCommit.commitId)" \
    'max_by(.id) | select(.sourceRefCommit.commitId == $sha) | .id') || return 1
  artifact="vstfs:///CodeReview/CodeReviewId/$AZ_PROJECT_ID/$id"
  # shellcheck disable=SC2016 # Azure query parameter names contain literal $.
  raw=$(_azure_call devops invoke --organization "$AZ_ORG" --area policy --resource evaluations \
    --route-parameters "project=$AZ_PROJECT_ID" --query-parameters "artifactId=$artifact" '$top=1000' \
    --api-version 7.1-preview.1 --http-method GET) || return 1
  # Require at least one enabled blocking policy. No evidence is not green.
  printf '%s' "$raw" | jq -e '
    type == "object" and (.value|type) == "array" and .count == (.value|length) and .count < 1000 and
    all(.value[]; (.configuration.isEnabled|type) == "boolean" and
      (.configuration.isBlocking|type) == "boolean" and (.status|type) == "string") and
    ([.value[] | select(.configuration.isEnabled == true and .configuration.isBlocking == true)] as $required |
      ($required|length) > 0 and all($required[]; .status == "approved"))' >/dev/null || return 1
  statuses=$(_azure_invoke pullRequestStatuses "$id" --http-method GET) || return 1
  printf '%s' "$statuses" | jq -e --argjson iteration "$iteration" '
    type == "object" and (.value|type) == "array" and .count == (.value|length) and .count > 0 and
    all(.value[]; (.state|type) == "string" and
      (.iterationId == null or (.iterationId|type == "number" and . > 0 and floor == .))) and
    ([.value[] | select(.iterationId == $iteration)] as $current |
      ($current|length) > 0 and all($current[]; .state == "succeeded" or .state == "notApplicable")) and
    all(.value[] | select(.iterationId == null); .state == "succeeded" or .state == "notApplicable")' >/dev/null || return 1
  printf 'success\n'
}

_azure_base_config() {
  local alias="$1" id="$2" pr branch raw
  _azure_context "$alias" true || return 1
  pr=$(_azure_pr "$id") || return 1
  branch=$(printf '%s' "$pr" | jq -r '.targetRefName | sub("^refs/heads/"; "")') || return 1
  raw=$(_azure_call devops invoke --organization "$AZ_ORG" --area git --resource items \
    --route-parameters "project=$AZ_PROJECT_ID" "repositoryId=$AZ_REPO_ID" \
    --query-parameters path=.claude/project-config.json includeContent=true \
      "versionDescriptor.version=$branch" versionDescriptor.versionType=branch \
    --api-version 7.1 --http-method GET) || return 1
  printf '%s' "$raw" | jq -cer '.content | fromjson | select(type == "object")'
}

_azure_behind() {
  local alias="$1" base="$2" sha="$3" raw
  _azure_context "$alias" true || return 1
  raw=$(_azure_call devops invoke --organization "$AZ_ORG" --area git --resource diffs \
    --route-parameters "project=$AZ_PROJECT_ID" "repositoryId=$AZ_REPO_ID" diffType=commits \
    --query-parameters "baseVersion=$base" baseVersionType=branch "targetVersion=$sha" targetVersionType=commit \
    --api-version 7.1 --http-method GET) || return 1
  printf '%s' "$raw" | jq -er 'select(.behindCount|type == "number" and . >= 0 and floor == .) | (.behindCount > 0) | tostring'
}

_azure_merge() {
  local alias="$1" id="$2" strategy="$3" delete_branch="$4" subject="${5:-}" body_file="${6:-}"
  local pr head base payload gate input tmp result current message="$subject" dir
  _azure_context "$alias" true || return 1
  pr=$(_azure_pr "$id") || return 1
  head=$(printf '%s' "$pr" | jq -r .lastMergeSourceCommit.commitId)
  base=$(printf '%s' "$pr" | jq -r '.targetRefName | sub("^refs/heads/"; "")')
  [ "$(printf '%s' "$pr" | jq -r .status)" = active ] || return 1
  [ "$(_azure_behind "$alias" "$base" "$head")" = false ] || return 1
  [ "$(_azure_ci "$alias" "$id")" = success ] || return 1
  dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  input=$(jq -nc --arg command "tracker_pr_merge '$alias' '$id' '$strategy' '$delete_branch'" --arg cwd "$PWD" \
    '{tool_name:"Bash",cwd:$cwd,tool_input:{command:$command}}') || return 1
  for gate in block-unreviewed-merge.sh block-merge-on-red-ci.sh require-design-review-for-ui.sh require-architecture-review.sh; do
    [ -r "$dir/$gate" ] || return 1
    printf '%s' "$input" | bash "$dir/$gate" || return 1
  done
  current=$(_azure_pr "$id") || return 1
  [ "$(printf '%s' "$current" | jq -r .lastMergeSourceCommit.commitId)" = "$head" ] || return 1
  if [ -n "$body_file" ]; then message="$message"$'\n\n'"$(cat "$body_file")"; fi
  case "$strategy" in squash) strategy=squash ;; rebase) strategy=rebase ;; merge) strategy=noFastForward ;; *) return 1 ;; esac
  payload=$(jq -nc --arg sha "$head" --arg strategy "$strategy" --arg message "$message" --argjson delete "$delete_branch" \
    '{status:"completed",lastMergeSourceCommit:{commitId:$sha},completionOptions:{mergeStrategy:$strategy,
      deleteSourceBranch:$delete,bypassPolicy:false,transitionWorkItems:false}} |
      if $message != "" then .completionOptions.mergeCommitMessage=$message else . end') || return 1
  tmp=$(mktemp) || return 1
  printf '%s' "$payload" > "$tmp"
  result=$(_azure_invoke pullRequests "$id" --http-method PATCH --in-file "$tmp")
  local rc=$?
  rm -f "$tmp"
  [ "$rc" = 0 ] || return 1
  printf '%s' "$result" | jq -ce --arg sha "$head" 'select(.status == "completed" and .lastMergeSourceCommit.commitId == $sha) |
    select(.lastMergeCommit.commitId | type == "string" and test("^[0-9a-fA-F]{40}$")) | {sha:.lastMergeCommit.commitId}'
}
