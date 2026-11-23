#!/bin/bash
# shellcheck disable=SC2016 # Literal command syntax verifies inert arguments.
set -uo pipefail
# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
# shellcheck source=/dev/null
. "$ROOT/.claude/hooks/_lib-tracker.sh"
PASS=0 FAIL=0
check() {
  if "$@"; then PASS=$((PASS + 1)); printf 'PASS %s\n' "$*";
  else FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$*" >&2; fi
}
tracker_issue_kind() { echo az; }
tracker_review_kind() { echo az; }
_tracker_project_value() {
  if [ "$1" = mixed/service ]; then
    case "$2" in issue_kind) echo az; return ;; review_kind) echo gh; return ;; esac
  fi
  if [ "$1" = azure/override ] && [ "$2" = azure_organization ]; then
    echo https://dev.azure.com/alternate
    return
  fi
  if [ "$1" = azure/milestone ] && [ "$2" = milestone ]; then echo Sprint1; return; fi
  return 1
}
_tracker_config_get_or() {
  case "$1" in
    .tracker.azure_organization) echo "${AZ_ORG_VALUE:-https://dev.azure.com/example}" ;;
    .tracker.azure_project) echo 'Example Project' ;;
    .tracker.azure_repository) echo service ;;
    *) echo "${2:-}" ;;
  esac
}
_tracker_check_private_refs() { return 0; }
TEST_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
OLD_SHA=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
az() {
  case "$*" in
    'devops project show '*) printf '%s\n' '{"id":"project-id","name":"Example Project"}' ;;
    'repos show '*) printf '%s\n' '{"id":"repo-id","name":"service","project":{"id":"project-id","name":"Example Project"}}' ;;
    'boards work-item show '*)
      [ "${AZ_FAIL:-0}" = 0 ] || return 1
      if [ "${AZ_BAD:-0}" = 1 ]; then echo '{"message":"denied"}'; return; fi
      printf '{"id":42,"fields":{"System.TeamProject":"%s","System.State":"%s","System.Title":"literal $(touch nope)","System.Description":"body","System.Tags":"one; two"}}\n' "${AZ_RESPONSE_PROJECT:-Example Project}" "${AZ_ITEM_STATE:-Active}"
      ;;
    'repos pr show '*)
      local source_sha="$TEST_SHA"
      if [ -n "${AZ_HEAD_FILE:-}" ]; then source_sha=$(cat "$AZ_HEAD_FILE"); fi
      printf '{"pullRequestId":7,"status":"active","repository":{"id":"%s","project":{"id":"project-id"}},"lastMergeSourceCommit":{"commitId":"%s"},"sourceRefName":"refs/heads/feature/AB-42-example","targetRefName":"refs/heads/main"}\n' "${AZ_RESPONSE_REPO:-repo-id}" "$source_sha"
      ;;
    'devops invoke '*pullRequestIterations*)
      printf '{"count":2,"value":[{"id":1,"sourceRefCommit":{"commitId":"%s"}},{"id":2,"sourceRefCommit":{"commitId":"%s"}}]}\n' "$OLD_SHA" "$TEST_SHA"
      ;;
    'devops invoke '*pullRequestThreads*)
      if [[ "$*" == *'--http-method POST'* ]]; then
        local previous="" argument input_file=""
        for argument in "$@"; do
          if [ "$previous" = --in-file ]; then input_file="$argument"; fi
          previous="$argument"
        done
        [ -z "${AZ_PAYLOAD:-}" ] || cp "$input_file" "$AZ_PAYLOAD"
        echo '{"id":10,"pullRequestThreadContext":{"iterationContext":{"secondComparingIteration":2}}}'
        return
      fi
      [ "${AZ_THREADS_FAIL:-0}" = 0 ] || return 1
      if [ "${AZ_THREADS_BAD:-0}" = 1 ]; then echo '{"vote":10}'; return; fi
      printf '{"count":1,"value":[{"id":10,"isDeleted":%s,"pullRequestThreadContext":{"iterationContext":{"secondComparingIteration":%s}},"comments":[{"commentType":"text","content":"review"}]}]}\n' "${AZ_DELETED:-false}" "${AZ_ITERATION:-2}"
      ;;
    'devops invoke '*pullRequestIterationChanges*)
      printf '{"changeEntries":[{"item":{"path":"/%s"},"originalPath":"/%s"}],"nextSkip":%s,"nextTop":0}\n' "${AZ_FILE_PATH:-src/new.ts}" "${AZ_ORIGINAL_PATH:-src/old.ts}" "${AZ_CONTINUATION:-0}"
      ;;
    'devops invoke '*evaluations*)
      if [ "${AZ_POLICY_BAD:-0}" = 1 ]; then
        echo '{"count":2,"value":[{"status":"approved","configuration":{"isEnabled":true,"isBlocking":true}},{"status":"rejected","configuration":{"isEnabled":true}}]}'
        return
      fi
      printf '{"count":1,"value":[{"status":"%s","configuration":{"isEnabled":true,"isBlocking":true}}]}\n' "${AZ_POLICY:-approved}"
      ;;
    'devops invoke '*pullRequestStatuses*)
      if [ "${AZ_STATUS_HISTORY:-0}" = 1 ]; then
        echo '{"count":2,"value":[{"state":"failed","iterationId":1},{"state":"succeeded","iterationId":2}]}'
      else printf '{"count":1,"value":[{"state":"succeeded","iterationId":%s}]}\n' "${AZ_STATUS_ITERATION:-2}"; fi
      ;;
    'boards work-item create '*)
      printf '%s\n' '{"id":43,"fields":{"System.TeamProject":"Example Project","System.State":"New","System.Title":"created"}}'
      ;;
    'boards query '*)
      case "${AZ_LIST_EMPTY:-}" in null) echo null; return ;; array) echo '[]'; return ;; silent) return 0 ;; esac
      echo '[{"id":42,"fields":{"System.TeamProject":"Example Project","System.State":"Active","System.Title":"listed"}}]'
      ;;
    'repos pr create '*)
      printf '%s\n' '{"pullRequestId":8,"status":"active","repository":{"id":"repo-id","project":{"id":"project-id"}}}'
      ;;
    'devops invoke '*diffs*) printf '{"behindCount":%s}\n' "${AZ_BEHIND:-0}" ;;
    'devops invoke '*'--resource items '*)
      [ "${AZ_BASE_FAIL:-0}" = 0 ] || return 1
      echo '{"content":"{\"design_paths\":[\"^specs/\"],\"ui_paths\":[\"^widgets/\"]}"}'
      ;;
    'devops invoke '*'--resource pullRequests '*)
      local previous="" argument input_file=""
      for argument in "$@"; do
        if [ "$previous" = --in-file ]; then input_file="$argument"; fi
        previous="$argument"
      done
      [ -z "${AZ_PAYLOAD:-}" ] || cp "$input_file" "$AZ_PAYLOAD"
      [ -z "${AZ_WRITES:-}" ] || printf 'PATCH\n' >> "$AZ_WRITES"
      [ "${AZ_WRITE_FAIL:-0}" = 0 ] || return 1
      printf '{"status":"completed","mergeStatus":"succeeded","lastMergeSourceCommit":{"commitId":"%s"},"lastMergeCommit":{"commitId":"%s"}}\n' "$TEST_SHA" "$OLD_SHA"
      ;;
    'repos pr set-vote '*) echo '{}' ;;
    *) printf 'unexpected az command: %s\n' "$*" >&2; return 1 ;;
  esac
}
if [ "${AZURE_FIXTURE_ONLY:-0}" = 1 ]; then return 0; fi
view_ok() {
  local out
  out=$(tracker_view AB-42 azure/service) || return 1
  printf '%s' "$out" | jq -e '.state == "ACTIVE" and .body == "body" and .labels == ["one","two"] and (.title | contains("$(touch nope)")) and (.url | endswith("/_workitems/edit/42"))' >/dev/null
}
reject_wrong_project() { ! AZ_RESPONSE_PROJECT=Other tracker_view 42 azure/service >/dev/null; }
reject_bad_json() { ! AZ_BAD=1 tracker_view 42 azure/service >/dev/null; }
reject_cli_failure() { ! AZ_FAIL=1 tracker_view 42 azure/service >/dev/null; }
reject_id() { ! tracker_view '42;echo bad' azure/service >/dev/null; }
reject_organization() { ! AZ_ORG_VALUE=https://attacker.invalid/org tracker_view 42 azure/service >/dev/null; }
mixed_axes() { [ "$(_tracker_axis_kind issue mixed/service)" = az ] && [ "$(_tracker_axis_kind review mixed/service)" = gh ]; }
project_override() { [ "$(_tracker_azure setting azure/override organization)" = https://dev.azure.com/alternate ]; }
closed_state() { AZ_ITEM_STATE=Closed tracker_view AB-42 azure/service | jq -e '.state == "CLOSED"' >/dev/null; }
check view_ok
check reject_wrong_project
check reject_bad_json
check reject_cli_failure
check reject_id
check reject_organization
check mixed_axes
check project_override
check closed_state
review_current() { tracker_review_at_sha azure/service 7 "$TEST_SHA"; }
review_old() { ! AZ_ITERATION=1 tracker_review_at_sha azure/service 7 "$TEST_SHA"; }
review_deleted() { ! AZ_DELETED=true tracker_review_at_sha azure/service 7 "$TEST_SHA"; }
review_vote_only() { local rc=0; AZ_THREADS_BAD=1 tracker_review_at_sha azure/service 7 "$TEST_SHA" || rc=$?; [ "$rc" = 2 ]; }
review_failure() { local rc=0; AZ_THREADS_FAIL=1 tracker_review_at_sha azure/service 7 "$TEST_SHA" || rc=$?; [ "$rc" = 2 ]; }
wrong_repo() { ! AZ_RESPONSE_REPO=other _tracker_azure pr_field azure/service 7 head >/dev/null; }
renamed_files() { _tracker_azure files azure/service 7 | jq -e '.count == 2 and .files == ["src/new.ts","src/old.ts"]' >/dev/null; }
incomplete_files() { ! AZ_CONTINUATION=1 _tracker_azure files azure/service 7 >/dev/null; }
ci_green() { [ "$(_tracker_azure ci azure/service 7)" = success ]; }
ci_failed() { ! AZ_POLICY=rejected _tracker_azure ci azure/service 7 >/dev/null; }
ci_pending() { ! AZ_POLICY=running _tracker_azure ci azure/service 7 >/dev/null; }
ci_stale() { ! AZ_STATUS_ITERATION=1 _tracker_azure ci azure/service 7 >/dev/null; }
ci_history() { [ "$(AZ_STATUS_HISTORY=1 _tracker_azure ci azure/service 7)" = success ]; }
ci_malformed_policy() { ! AZ_POLICY_BAD=1 _tracker_azure ci azure/service 7 >/dev/null; }
up_to_date() { [ "$(_tracker_azure behind azure/service main "$TEST_SHA")" = false ]; }
behind_base() { [ "$(AZ_BEHIND=1 _tracker_azure behind azure/service main "$TEST_SHA")" = true ]; }
base_config() { _tracker_azure base_config azure/service 7 | jq -e '.design_paths == ["^specs/"]' >/dev/null; }
create_item() { tracker_create azure/service 'literal $(touch nope)' | jq -e '.ref == "AB-43"' >/dev/null; }
configured_milestone() { ! tracker_create azure/milestone 'example' >/dev/null; }
list_items() { tracker_list azure/service limit=10 >/dev/null && [ "$TRACKER_LIST_STATUS" = COMPLETE ]; }
empty_list() {
  local file result mode
  file=$(mktemp) || return 1
  for mode in null array; do
    AZ_LIST_EMPTY=$mode tracker_list azure/service limit=10 > "$file" || { rm -f "$file"; return 1; }
    result=$(cat "$file")
    [ "$result" = '[]' ] && [ "$TRACKER_LIST_STATUS" = COMPLETE ] || { rm -f "$file"; return 1; }
  done
  rm -f "$file"
}
silent_empty_list() { AZ_LIST_EMPTY=silent tracker_list azure/service limit=10 >/dev/null && [ "$TRACKER_LIST_STATUS" = COMPLETE ]; }
unsupported_filter() { ! tracker_list azure/service assignee=@me >/dev/null; }
check review_current
check review_old
check review_deleted
check review_vote_only
check review_failure
check wrong_repo
check renamed_files
check incomplete_files
check ci_green
check ci_failed
check ci_pending
check ci_stale
check ci_history
check ci_malformed_policy
check up_to_date
check behind_base
check base_config
check create_item
check configured_milestone
check list_items
check empty_list
check silent_empty_list
check unsupported_filter
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
