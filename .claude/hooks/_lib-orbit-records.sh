#!/bin/bash
# ORBIT records exemptions require both the name and content (#1673).
# Sourcing this library only defines functions.
# Callers read ORBIT_RECORDS_REASON after a failed check.
# shellcheck disable=SC2034

orbit_records_branch_shape() {
  [[ "$1" =~ ^orbit/[a-z0-9]+(-[a-z0-9]+)+$ ]]
}

# Resolve from committed records on the supplied branch, never from filenames.
# The longest matching ID disambiguates initiatives with shared prefixes.
orbit_records_initiative() {
  local repo_dir="$1" ref="$2" path id suffix best="" listing
  ORBIT_INITIATIVE=""
  repo_dir=$(git -C "$repo_dir" rev-parse --show-toplevel) || return 1
  # history/ holds superseded plans too, so a branch that retires an initiative still resolves.
  listing=$(git -C "$repo_dir" ls-tree -r --name-only "$ref" -- docs/orbit/plans/ docs/orbit/history/) || return 1
  while IFS= read -r path; do
    case "$path" in *.json) ;; *) continue ;; esac
    case "$path" in
      docs/orbit/history/*)
        # Only superseded plans count; a reconciliation in history/ carries .planId.
        git -C "$repo_dir" show "$ref:$path" | jq -e 'has("planId") | not' >/dev/null 2>&1 || continue ;;
    esac
    id=$(git -C "$repo_dir" show "$ref:$path" | jq -er '.id | select(type == "string")' 2>/dev/null) || return 1
    [[ "$id" =~ ^plan-[a-z0-9]+(-[a-z0-9]+)*$ ]] || return 1
    suffix=${id#plan-}
    case "$ref" in
      orbit/"$suffix"-?*)
        if [ "${#suffix}" -gt "${#best}" ]; then best=$suffix; fi ;;
    esac
  done <<< "$listing"
  [ -n "$best" ] || return 1
  ORBIT_INITIATIVE="$best"
}

orbit_records_only() {
  local repo_dir="$1" ref="$2" trunks="$3"
  local commit candidates candidate trunk base count best_base="" best_count="" paths path seen=0
  ORBIT_RECORDS_REASON=""
  commit=$(git -C "$repo_dir" rev-parse --verify "refs/heads/$ref^{commit}" 2>/dev/null) ||
    commit=$(git -C "$repo_dir" rev-parse --verify "$ref^{commit}" 2>/dev/null) || {
      ORBIT_RECORDS_REASON="The branch does not resolve to a commit."
      return 1
    }
  candidates=$(git -C "$repo_dir" for-each-ref --format='%(refname)' refs/remotes 2>/dev/null) || {
    ORBIT_RECORDS_REASON="Remote trunk refs could not be read."
    return 1
  }
  while IFS= read -r candidate; do
    case "$candidate" in ""|*/HEAD) continue ;; esac
    trunk=${candidate##*/}
    printf '%s\n' "$trunks" | grep -qxF "$trunk" || continue
    base=$(git -C "$repo_dir" merge-base "$commit" "$candidate" 2>/dev/null) || {
      ORBIT_RECORDS_REASON="The remote trunk merge base could not be read."
      return 1
    }
    count=$(git -C "$repo_dir" rev-list --count "$base..$commit" 2>/dev/null) || {
      ORBIT_RECORDS_REASON="The branch distance could not be read."
      return 1
    }
    case "$count" in ""|*[!0-9]*) ORBIT_RECORDS_REASON="The branch distance is invalid."; return 1 ;; esac
    if [ -z "$best_count" ] || [ "$count" -lt "$best_count" ]; then
      best_count=$count
      best_base=$base
    fi
  done <<EOF_REFS
$candidates
EOF_REFS
  if [ -z "$best_base" ]; then
    ORBIT_RECORDS_REASON="No remote-tracking trunk base exists."
    return 1
  fi
  paths=$(mktemp) || { ORBIT_RECORDS_REASON="The changed-file list could not be created."; return 1; }
  if ! git -C "$repo_dir" diff --name-only --no-renames -z "$best_base" "$commit" > "$paths"; then
    rm -f "$paths"
    ORBIT_RECORDS_REASON="The changed-file list could not be read."
    return 1
  fi
  while IFS= read -r -d '' path; do
    seen=1
    case "$path" in
      docs/orbit/?*) ;;
      *) rm -f "$paths"; ORBIT_RECORDS_REASON="A changed file is outside docs/orbit/."; return 1 ;;
    esac
    case "/$path/" in
      */../*) rm -f "$paths"; ORBIT_RECORDS_REASON="A changed path contains a parent segment."; return 1 ;;
    esac
  done < "$paths"
  rm -f "$paths"
  if [ "$seen" -ne 1 ]; then
    ORBIT_RECORDS_REASON="The branch has no changed files against the base."
    return 1
  fi
  if ! orbit_records_initiative "$repo_dir" "$ref"; then
    ORBIT_RECORDS_REASON="No matching plan record exists for the branch initiative."
    return 1
  fi
  return 0
}

orbit_push_command_simple() {
  local command="$1" occurrences segment token source destination positional=0 skip_next=0
  ORBIT_RECORDS_REASON="The push command is not a single simple records push."
  occurrences=$(printf '%s\n' "$command" | grep -oE '\bgit\s+push\b' | wc -l)
  [ "$occurrences" -eq 1 ] || return 1
  printf '%s\n' "$command" | grep -qE 'git[[:space:]]+-' && return 1
  segment=$(printf '%s\n' "$command" | grep -oE '\bgit\s+push\b[^|;&<>]*')
  segment=${segment#*git}
  segment=${segment#"${segment%%[![:space:]]*}"}
  segment=${segment#push}
  # Deliberately split plain tokens, matching _extract_push_ref_core.
  # shellcheck disable=SC2086
  for token in $segment; do
    token=${token#\"}; token=${token#\'}
    token=${token%\"}; token=${token%\'}
    if [ "$skip_next" -eq 1 ]; then skip_next=0; continue; fi
    case "$token" in
      --all|--mirror|--tags|--follow-tags|--prune|--delete|-d|--all=*|--mirror=*|--tags=*|--follow-tags=*|--prune=*|--delete=*) return 1 ;;
      -o|--push-option|--repo|--receive-pack|--exec|--recurse-submodules|--signed) skip_next=1; continue ;;
      --push-option=*|--repo=*|--receive-pack=*|--exec=*|--recurse-submodules=*|--signed=*) continue ;;
      -u|-f|-n|-v|-q|--force|--force-with-lease*|--atomic|--dry-run|--no-verify|--set-upstream|--porcelain) continue ;;
      -*) return 1 ;;
    esac
    positional=$((positional + 1))
    [ "$positional" -le 2 ] || return 1
    if [ "$positional" -eq 2 ]; then
      token=${token#+}
      case "$token" in
        *:*) source=${token%%:*}; destination=${token#*:}; destination=${destination#refs/heads/}
             [ "$source" = "$destination" ] || return 1 ;;
      esac
    fi
  done
  [ "$skip_next" -eq 0 ] || return 1
  ORBIT_RECORDS_REASON=""
  return 0
}
