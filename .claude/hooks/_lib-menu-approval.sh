#!/bin/bash
# _lib-menu-approval.sh — parse an approval menu and write its record.
#
# The PostToolUse hook record-menu-approval.sh is the only supported writer
# of approval_channel=menu. A guard blocks other writers by text match only,
# so a menu record has the same trust level as a typed marker (AgDR-0234).
# The question text must name the repo, the PR,
# and the full 40-hex head SHA. The selected option must be the exact
# approve label. See AgDR-0234 and me2resh/apexyard#1391.
#
# Question shapes (the whole string, one line):
#   Approve and merge <owner>/<repo>#<pr> at <40-hex>?
#   Approve design review for <owner>/<repo>#<pr> at <40-hex>?
#   Approve architecture review for <owner>/<repo>#<pr> at <40-hex>?
#
# Approve labels, exact:
#   ceo           Approve and merge
#   design        Approve design review
#   architecture  Approve architecture review
#
# Bash 3.2. Sourced. Not executed.

[ -n "${_LIB_MENU_APPROVAL_SOURCED:-}" ] && return 0
_LIB_MENU_APPROVAL_SOURCED=1

# menu_approval_field <file> <key>
# Print the value of one key= line. Strip one pair of wrapping quotes.
menu_approval_field() {
  local file="$1" key="$2" line
  line=$(grep -E "^${key}=" "$file" 2>/dev/null | head -1) || true
  line=${line#"${key}="}
  case "$line" in
    \"*\")
      line=${line#\"}
      line=${line%\"}
      ;;
  esac
  printf '%s' "$line"
}

# menu_approval_record_sha <file>
# Print the sha when the file is a valid menu record. Return 1 otherwise.
# A valid record has approval_channel=menu, skill_version=3, approved_by=user,
# a 40-hex sha, an ISO-8601 UTC approved_at, and a non-empty summary.
menu_approval_record_sha() {
  local file="$1" channel sha by ver at sum
  [ -n "$file" ] && [ -f "$file" ] || return 1
  channel=$(grep '^approval_channel=' "$file" 2>/dev/null)
  [ "$channel" = "approval_channel=menu" ] || return 1
  sha=$(menu_approval_field "$file" sha)
  by=$(menu_approval_field "$file" approved_by)
  ver=$(menu_approval_field "$file" skill_version)
  at=$(menu_approval_field "$file" approved_at)
  sum=$(menu_approval_field "$file" approval_summary)
  printf '%s' "$sha" | grep -Eq '^[0-9a-f]{40}$' || return 1
  [ "$by" = "user" ] || return 1
  [ "$ver" = "3" ] || return 1
  printf '%s' "$at" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' || return 1
  [ -n "$sum" ] || return 1
  printf '%s' "$sha"
  return 0
}

# menu_approval_parse <question>
# On success print four lines: role, repo, pr, sha.
# role is ceo, design, or architecture.
menu_approval_parse() {
  local q="$1" parsed prefix repo pr sha role
  [ -n "$q" ] || return 1
  case "$q" in
    *$'\n'*) return 1 ;;
  esac
  parsed=$(printf '%s\n' "$q" | sed -nE \
    's/^(Approve and merge|Approve design review for|Approve architecture review for) ([A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+)#([1-9][0-9]*) at ([0-9a-f]{40})\?$/\1|\2|\3|\4/p')
  [ -n "$parsed" ] || return 1
  prefix=${parsed%%|*}
  parsed=${parsed#*|}
  repo=${parsed%%|*}
  parsed=${parsed#*|}
  pr=${parsed%%|*}
  sha=${parsed#*|}
  case "$prefix" in
    "Approve and merge") role=ceo ;;
    "Approve design review for") role=design ;;
    "Approve architecture review for") role=architecture ;;
    *) return 1 ;;
  esac
  [ -n "$role" ] && [ -n "$repo" ] && [ -n "$pr" ] && [ -n "$sha" ] || return 1
  printf '%s\n%s\n%s\n%s\n' "$role" "$repo" "$pr" "$sha"
}

# menu_approval_label <role>
menu_approval_label() {
  case "$1" in
    ceo) printf '%s' "Approve and merge" ;;
    design) printf '%s' "Approve design review" ;;
    architecture) printf '%s' "Approve architecture review" ;;
    *) return 1 ;;
  esac
}

# menu_approval_selected <question> <json>
# Print the selected label for that question. Print nothing when absent.
# Accepts tool_response.answers as an object keyed by the question text,
# a JSON string of that object, or a questions[] item with answer/selected.
menu_approval_selected() {
  local question="$1" json="$2"
  [ -n "$question" ] && [ -n "$json" ] || return 0
  printf '%s' "$json" | jq -r --arg q "$question" '
    def response:
      if (.tool_response | type) == "object" then .tool_response
      elif (.tool_response | type) == "string" then (.tool_response | fromjson? // null)
      elif (.answers | type) == "object" then {answers: .answers}
      else null end;
    def pick($r):
      if $r == null then empty
      elif ($r | type) == "object" and ($r.answers | type) == "object" then $r.answers[$q]
      elif ($r | type) == "object" and ($r.answers | type) == "array" then
        ([$r.answers[]? | select((.question // "") == $q) | (.answer // .selected // .label // empty)] | .[0])
      elif ($r | type) == "object" and ($r.questions | type) == "array" then
        ([$r.questions[]? | select((.question // "") == $q) | (.answer // .selected // empty)] | .[0])
      else empty end;
    (pick(response) // empty) as $v
    | if ($v | type) == "string" then $v
      elif ($v | type) == "array" and ($v | length) == 1 and ($v[0] | type) == "string" then $v[0]
      else empty end
  ' 2>/dev/null || true
}

# menu_approval_write_record <path> <sha> <summary>
# Write the skill_version=3 menu record. Return 1 when the write fails.
menu_approval_write_record() {
  local path="$1" sha="$2" summary="$3" ts clean dir
  [ -n "$path" ] && [ -n "$sha" ] || return 1
  printf '%s' "$sha" | grep -Eq '^[0-9a-f]{40}$' || return 1
  clean=$(printf '%s' "$summary" | tr '\n' ' ' | tr -d '"`$\\' | cut -c1-200)
  [ -n "$clean" ] || return 1
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  dir=$(dirname "$path")
  mkdir -p "$dir" || return 1
  {
    printf 'sha=%s\n' "$sha"
    printf 'approved_by=user\n'
    printf 'skill_version=3\n'
    printf 'approval_channel=menu\n'
    printf 'approved_at=%s\n' "$ts"
    printf 'approval_summary="%s"\n' "$clean"
  } > "$path" || return 1
  return 0
}
