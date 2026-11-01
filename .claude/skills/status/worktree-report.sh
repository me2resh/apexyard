#!/bin/bash
# Read-only linked worktree inventory. No state or temporary files are written.

# Apply these settings to library calls too, including calls in subshells.
git() { GIT_OPTIONAL_LOCKS=0 GIT_NO_LAZY_FETCH=1 command git -c core.fsmonitor=false "$@"; }
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE
git_vars=$(git rev-parse --local-env-vars 2>/dev/null)
for git_var in $git_vars; do
  case "$git_var" in GIT_*) case "$git_var" in *[!A-Z0-9_]*) ;; *) unset "$git_var" ;; esac ;; esac
done

ROOT=$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)
owner_available=0 ticket_available=0
if command -v jq >/dev/null 2>&1 && [ -r "$ROOT/.claude/hooks/_lib-worktree-owner.sh" ]; then
  # shellcheck source=/dev/null
  if . "$ROOT/.claude/hooks/_lib-worktree-owner.sh" 2>/dev/null; then owner_available=1; fi
fi
if [ -r "$ROOT/.claude/hooks/_lib-active-ticket.sh" ]; then
  # shellcheck source=/dev/null
  if . "$ROOT/.claude/hooks/_lib-active-ticket.sh" 2>/dev/null; then ticket_available=1; fi
fi

report_work() {
  local path=$1 status ahead config_rc promisors
  if [ ! -d "$path" ]; then
    printf 'unknown:path unavailable\n'
    return
  fi
  # Older Git can ignore GIT_NO_LAZY_FETCH, so refuse partial clones before
  # either content inspection or revision traversal can request objects.
  if git -C "$path" config --get extensions.partialClone >/dev/null 2>&1; then
    printf 'unknown:partial clone\n'
    return
  else config_rc=$?; fi
  [ "$config_rc" -eq 1 ] || { printf 'unknown:checkout unknown\n'; return; }
  config_rc=0
  promisors=$(git -C "$path" config --bool --get-regexp '^remote\..*\.promisor$' 2>/dev/null) || config_rc=$?
  case "$config_rc" in 0|1) ;; *) printf 'unknown:checkout unknown\n'; return ;; esac
  case $'\n'"$promisors"$'\n' in
    *' true'$'\n'*) printf 'unknown:partial clone\n'; return ;;
  esac
  # Even status can execute configured clean/process commands. Do not blank
  # them with overrides: skip content inspection entirely when they exist.
  if git -C "$path" config --get-regexp '^filter\..*\.(clean|process)$' >/dev/null 2>&1; then
    printf 'unknown:filters configured\n'
    return
  else config_rc=$?; fi
  [ "$config_rc" -eq 1 ] || { printf 'unknown:checkout unknown\n'; return; }
  if ! status=$(git -C "$path" status --porcelain --untracked-files=normal --ignore-submodules=all 2>/dev/null); then
    printf 'unknown:checkout unknown\n'
  elif [ -n "$status" ]; then
    printf 'dirty\n'
  elif ! ahead=$(git -C "$path" rev-list --count HEAD --not --remotes 2>/dev/null); then
    printf 'unknown:commits unknown\n'
  else
    case "$ahead" in
      ''|*[!0-9]*) printf 'unknown:commits unknown\n' ;;
      *)
        if [ -z "${ahead//0/}" ]; then printf 'preserved\n'
        else printf 'unpushed\n'; fi ;;
    esac
  fi
}

report_ticket() {
  local path=$1 gitdir marker repo number
  [ "$ticket_available" -eq 1 ] || { printf '%s\n' '-'; return; }
  if gitdir=$(git -C "$path" rev-parse --absolute-git-dir 2>/dev/null); then
    marker="$gitdir/apexyard-ticket"
    if [ ! -L "$marker" ] && active_ticket_read_field "$marker" repo 2>/dev/null; then
      repo=$REPLY
      if active_ticket_read_field "$marker" number 2>/dev/null; then
        number=${REPLY#\#}
        if [[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] && [[ "$number" =~ ^[0-9]+$ ]]; then
          printf '%s#%s\n' "$repo" "$number"
          return
        fi
      fi
    fi
  fi
  printf '%s\n' '-'
}

report_row() {
  local path=$1 branch=$2 prunable=$3 admin=$4 owner=unknown work ticket actual
  case "$path" in
    *$'\t'*|*$'\n'*)
      path=${path//$'\t'/?}
      path=${path//$'\n'/?}
      branch=${branch//$'\t'/?}
      branch=${branch//$'\n'/?}
      printf '%s\t%s\tunknown\tunknown:unprintable path\t-\n' "$path" "$branch"
      return ;;
  esac
  if [ -z "$admin" ] || ! actual=$(git -C "$path" rev-parse --absolute-git-dir 2>/dev/null) || [ ! "$actual" -ef "$admin" ]; then
    work='unknown:path unavailable' ticket='-'
  else
    if [ "$owner_available" -eq 1 ]; then
      owner=$(worktree_owner_status "$path" 2>/dev/null) || :
      case "$owner" in alive|dead|unknown|none|released) ;; *) owner=unknown ;; esac
    fi
    ticket=$(report_ticket "$path")
    case "$path$branch" in
      *$'\t'*|*$'\n'*) work='unknown:unprintable path' ;;
      *)
        if [ "$prunable" -eq 1 ]; then work='unknown:path unavailable'
        else work=$(report_work "$path"); fi ;;
    esac
  fi
  path=${path//$'\t'/?}
  path=${path//$'\n'/?}
  branch=${branch//$'\t'/?}
  branch=${branch//$'\n'/?}
  printf '%s\t%s\t%s\t%s\t%s\n' "$path" "$branch" "$owner" "$work" "$ticket"
}

# Legacy porcelain emits literal newline bytes in paths. Its record boundaries
# are ambiguous, so recover exact paths from Git's existing administrative
# backpointers and confirm each path occurs in the successful listing.
report_normalize_path() {
  local rest=$1 component result=''
  while [ -n "$rest" ]; do
    component=${rest%%/*}
    if [ "$component" = "$rest" ]; then rest=''; else rest=${rest#*/}; fi
    case "$component" in
      ''|.) ;;
      ..) result=${result%/*} ;;
      *) result="$result/$component" ;;
    esac
  done
  REPLY=${result:-/}
}

report_unreadable_metadata() {
  local label=$1
  label=${label//$'\t'/?}
  label=${label//$'\n'/?}
  printf '%s\tdetached\tunknown\tunknown:metadata unavailable\t-\n' "$label"
}

report_common_dir() {
  local common
  if ! common=$(git -C "$repo" rev-parse --git-common-dir 2>/dev/null && printf '.'); then
    return 1
  fi
  common=${common%.}
  common=${common%$'\n'}
  case "$common" in /*) ;; *) common="$repo/$common" ;; esac
  if ! common=$(CDPATH='' cd -P -- "$common" 2>/dev/null && printf '%s.' "$PWD"); then
    return 1
  fi
  REPLY=${common%.}
}

report_registered_path() {
  local admin=$1 pointer=''
  if [ -r "$admin/gitdir" ]; then
    IFS= read -r -d '' pointer 2>/dev/null < "$admin/gitdir" || :
  fi
  # Remove exactly the file's terminating newline, preserving path newlines.
  case "$pointer" in *$'\n') pointer=${pointer%$'\n'} ;; esac
  case "$pointer" in */.git) pointer=${pointer%/.git} ;; *) return 1 ;; esac
  case "$pointer" in
    /*) ;;
    *) pointer="$admin/$pointer" ;;
  esac
  if [ -e "$pointer" ]; then
    # Git follows symlinks before resolving a subsequent .. component.
    # Preserve trailing path newlines across command substitution.
    if ! pointer=$(CDPATH='' cd -P -- "$pointer" 2>/dev/null && pwd -P && printf '.'); then
      return 1
    fi
    pointer=${pointer%.}
    REPLY=${pointer%$'\n'}
  else
    report_normalize_path "$pointer"
  fi
}

report_registration() {
  local common=$1 path=$2 admin
  [ -n "$common" ] || return 1
  for admin in "$common"/worktrees/*; do
    [ -d "$admin" ] || continue
    if report_registered_path "$admin" && [ "$REPLY" = "$path" ]; then
      REPLY=$admin
      return
    fi
  done
  return 1
}

report_legacy() {
  local listing=$1 common admin path branch head
  if ! report_common_dir; then
    report_unreadable_metadata '-'
    return
  fi
  common=$REPLY
  for admin in "$common"/worktrees/*; do
    [ -d "$admin" ] || continue
    if ! report_registered_path "$admin"; then
      report_unreadable_metadata "<unreadable worktree: ${admin##*/}>"
      continue
    fi
    path=$REPLY
    case "$listing"$'\n' in *"worktree $path"$'\n'*) ;; *) continue ;; esac
    branch=detached head=''
    if IFS= read -r head 2>/dev/null < "$admin/HEAD" || [ -n "$head" ]; then
      case "$head" in ref:\ refs/heads/*) branch=${head#ref: refs/heads/} ;; esac
    fi
    report_row "$path" "$branch" 0 "$admin"
  done
}

report_parse() {
  local field path='' branch=detached prunable=0 first=1 have=0 common='' admin
  if report_common_dir; then common=$REPLY; fi
  while IFS= read -r -d '' field; do
    case "$field" in
      '')
        if [ "$have" -eq 1 ]; then
          if [ "$first" -eq 0 ]; then
            admin=''
            if report_registration "$common" "$path"; then admin=$REPLY; fi
            report_row "$path" "$branch" "$prunable" "$admin"
          fi
          first=0
        fi
        path='' branch=detached prunable=0 have=0 ;;
      worktree\ *) path=${field#worktree }; have=1 ;;
      branch\ *) branch=${field#branch refs/heads/} ;;
      prunable|prunable\ *) prunable=1 ;;
    esac
  done
  if [ "$have" -eq 1 ] && [ "$first" -eq 0 ]; then
    admin=''
    if report_registration "$common" "$path"; then admin=$REPLY; fi
    report_row "$path" "$branch" "$prunable" "$admin"
  fi
}

repo=${1:-.}
# Capture rendered rows, not raw NUL bytes. Bash variables cannot hold NUL.
rows=$(
  git -C "$repo" worktree list --porcelain -z 2>/dev/null | report_parse
  exit "${PIPESTATUS[0]}"
)
list_rc=$?
if [ "$list_rc" -ne 0 ]; then
  listing=$(git -C "$repo" worktree list --porcelain 2>/dev/null)
  list_rc=$?
  if [ "$list_rc" -eq 0 ]; then rows=$(report_legacy "$listing"); fi
fi
if [ "$list_rc" -ne 0 ]; then
  reason=$(git -C "$repo" worktree list --porcelain 2>&1 >/dev/null) || :
  printf 'worktree report: git worktree list failed: %s\n' "${reason:-listing unavailable}" >&2
  exit 2
fi
printf 'path\tbranch\towner\twork\tticket\n'
[ -z "$rows" ] || printf '%s\n' "$rows"
exit 0
