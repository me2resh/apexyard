#!/bin/bash
# Require a merged ORBIT slice for Feature and Task issue creation.
# Use the same command matcher as require-skill-for-issue-create.sh.

set -u

input=$(cat)
tool=$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null)
[ "$tool" = Bash ] || exit 0
command=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)
[ -n "$command" ] || exit 0

hook_dir=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=/dev/null
. "$hook_dir/_lib-read-config.sh"
patterns=$(config_get '.ticket.create_command_patterns[]' 2>/dev/null)
[ -n "$patterns" ] || exit 0
norm=$(printf '%s' "$command" | tr -s '[:space:]' ' ')
matched=""
# Keep this boundary list aligned with require-skill-for-issue-create.sh.
while IFS= read -r pat; do
  [ -n "$pat" ] || continue
  case "$norm" in
    "$pat"*|*"; $pat"*|*"&& $pat"*|*"|| $pat"*|*"| $pat"*|*'$('"$pat"*) matched=$pat; break ;;
  esac
done <<EOF
$patterns
EOF
[ -n "$matched" ] || exit 0
case "$matched" in
  'gh api'*)
    case "$norm" in *'/issues'*) : ;; *) exit 0 ;; esac
    case "$norm" in
      *' -X POST'*|*' -XPOST'*|*' --method POST'*|*' --method=POST'*|*' -f '*|*' -F '*|*' --field '*|*' --raw-field '*|*' --input '*) : ;;
      *) exit 0 ;;
    esac ;;
esac

# Extract one shell flag value. This follows validate-issue-structure.sh's
# quoted flag handling and keeps multiline bodies on stdin, not argv.
flag_value() {
  printf '%s' "$command" | awk -v flag="$1" -v sq="'" '
    { s = s (NR == 1 ? "" : "\n") $0 }
    END {
      re = "(" flag ")[[:space:]]+\"(.*)\"([[:space:]]+-{1,2}[a-zA-Z]|[[:space:]]*$)"
      if (match(s, re)) {
        v=substr(s,RSTART,RLENGTH); sub("^(" flag ")[[:space:]]+\"","",v)
        sub("\"([[:space:]]+-{1,2}[a-zA-Z].*)?$","",v); sub("\"[[:space:]]*$","",v)
        print v; exit
      }
      re = "(" flag ")[[:space:]]+" sq "(.*)" sq "([[:space:]]+-{1,2}[a-zA-Z]|[[:space:]]*$)"
      if (match(s, re)) {
        v=substr(s,RSTART,RLENGTH); sub("^(" flag ")[[:space:]]+" sq,"",v)
        sub(sq "([[:space:]]+-{1,2}[a-zA-Z].*)?$","",v); sub(sq "[[:space:]]*$","",v)
        print v; exit
      }
      re = "(" flag ")[[:space:]]+[^[:space:]]+"
      if (match(s, re)) { v=substr(s,RSTART,RLENGTH); sub("^(" flag ")[[:space:]]+","",v); print v }
    }'
}

# tracker_create takes repo, title, body_file as positional arguments.
tracker_arg() {
  printf '%s' "$command" | awk -v wanted="$1" '
    { s = s (NR == 1 ? "" : "\n") $0 }
    END {
      if (!match(s, /(^|[;&|][[:space:]]*|\$\()tracker_create[[:space:]]+/)) exit
      s=substr(s,RSTART+RLENGTH)
      for (i=1; i<=wanted; i++) {
        sub(/^[[:space:]]+/,"",s)
        q=substr(s,1,1)
        if (q=="\"" || q=="\047") {
          s=substr(s,2); p=index(s,q); if (!p) exit
          v=substr(s,1,p-1); s=substr(s,p+1)
        } else {
          eq=index(s,"="); q=substr(s,eq+1,1)
          if (eq && (q=="\"" || q=="\047")) {
            rest=substr(s,eq+2); p=index(rest,q); if (!p) exit
            v=substr(s,1,eq) substr(rest,1,p-1); s=substr(rest,p+1)
          } else {
            p=match(s,/[[:space:];&|]/)
            if (!p) { v=s; s="" } else { v=substr(s,1,p-1); s=substr(s,p) }
          }
        }
      }
      print v
    }'
}

api_field() {
  printf '%s' "$command" | awk -v wanted="$1" '
    { s = s (NR == 1 ? "" : "\n") $0 }
    END {
      while (match(s, /(^|[[:space:]])(-f|-F|--field|--raw-field)[[:space:]]+/)) {
        s=substr(s,RSTART+RLENGTH)
        q=substr(s,1,1)
        if (q=="\"" || q=="\047") {
          s=substr(s,2); p=index(s,q); if (!p) exit
          v=substr(s,1,p-1); s=substr(s,p+1)
        } else {
          eq=index(s,"="); q=substr(s,eq+1,1)
          if (eq && (q=="\"" || q=="\047")) {
            rest=substr(s,eq+2); p=index(rest,q); if (!p) exit
            v=substr(s,1,eq) substr(rest,1,p-1); s=substr(rest,p+1)
          } else {
            p=match(s,/[[:space:];&|]/)
            if (!p) { v=s; s="" } else { v=substr(s,1,p-1); s=substr(s,p) }
          }
        }
        if (index(v,wanted "=")==1) {
          v=substr(v,length(wanted)+2)
          if (substr(v,1,1)=="\"" || substr(v,1,1)=="\047") v=substr(v,2,length(v)-2)
          print v; exit
        }
      }
    }'
}

repo=$(flag_value '--repo|-R')
title=$(flag_value '--title|-t')
if [ "$matched" = tracker_create ]; then
  repo=$(tracker_arg 1)
  title=$(tracker_arg 2)
fi
case "$matched" in
  'gh api'*)
    repo=$(printf '%s' "$norm" | sed -nE 's#.*gh api repos/([^/[:space:]]+/[^/[:space:]]+)/issues.*#\1#p' | head -1)
    title=$(api_field title)
    ;;
esac
case "$title" in '[Feature]'*|'[Task]'*) : ;; *) exit 0 ;; esac
if [ -z "$repo" ]; then
  remote_url=$(git remote get-url origin 2>/dev/null)
  repo=$(printf '%s' "$remote_url" | sed -E 's#^.*[:/]([^/:]+/[^/:]+)(\.git)?$#\1#; s#\.git$##')
fi

# Resolve the target registry entry. A per-project flag wins over the global
# default. No registered target means the project has no ORBIT gate.
# shellcheck source=/dev/null
. "$hook_dir/_lib-portfolio-paths.sh"
registry=$(portfolio_registry)
[ -f "$registry" ] || exit 0
entry=$(awk -v target="$repo" '
  function clean(v) { sub(/^[^:]*:[[:space:]]*/,"",v); gsub(/^["\047]|["\047]$/,"",v); return v }
  function emit() { if (found) print name "\t" workspace "\t" orbit }
  /^[[:space:]]*- name:/ { emit(); name=clean($0); workspace=""; orbit=""; found=0; in_orbit=0; in_repos=0; next }
  /^[[:space:]]*repo:/ { if (clean($0)==target) found=1; in_orbit=0; next }
  /^[[:space:]]*repos:[[:space:]]*$/ { in_repos=1; in_orbit=0; next }
  /^[[:space:]]*-[[:space:]]*[^:]+\/[^:]+[[:space:]]*$/ {
    v=$0; sub(/^[[:space:]]*-[[:space:]]*/,"",v); gsub(/^["\047]|["\047]$/,"",v)
    if (in_repos && v==target) found=1; next
  }
  /^[[:space:]]*workspace:/ { workspace=clean($0); in_orbit=0; next }
  /^[[:space:]]*orbit:[[:space:]]*$/ { in_orbit=1; next }
  /^[[:space:]]*[a-zA-Z_]+:/ { in_repos=0; if (in_orbit && $1 ~ /^default_planning:/) orbit=clean($0); else in_orbit=0 }
  END { emit() }
' "$registry" | head -1)
[ -n "$entry" ] || exit 0
project=$(printf '%s' "$entry" | cut -f1)
workspace=$(printf '%s' "$entry" | cut -f2)
enabled=$(printf '%s' "$entry" | cut -f3)
[ -n "$enabled" ] || enabled=$(config_get '.orbit.default_planning' 2>/dev/null)
[ "$enabled" = true ] || exit 0

body=$(flag_value '--body|-b')
body_file=$(flag_value '--body-file')
if [ "$matched" = tracker_create ]; then body_file=$(tracker_arg 3); fi
case "$matched" in
  'gh api'*)
    body=$(api_field body)
    body_file=$(api_field body@)
    if [ -z "$body_file" ]; then
      case "$body" in @*) body_file=${body#@}; body="" ;; esac
    fi
    ;;
esac
if [ -z "$body_file" ]; then
  body_file=$(flag_value '-F')
  case "$body_file" in *=*) body_file="" ;; esac
fi
if [ -n "$body_file" ]; then
  if [ ! -f "$body_file" ] || [ ! -r "$body_file" ]; then
    echo "BLOCKED: ORBIT is on for $project, but ticket body file cannot be read: $body_file. Run /orbit slice." >&2
    exit 2
  fi
  body=$(cat "$body_file") || {
    echo "BLOCKED: ORBIT is on for $project, but ticket body file cannot be read. Run /orbit slice." >&2
    exit 2
  }
fi
if [ -z "$body" ]; then
  echo "BLOCKED: ORBIT is on for $project, but the ticket body cannot be read. Run /orbit slice." >&2
  exit 2
fi

directive=$(printf '%s\n' "$body" | awk '
  /^[[:space:]]*(\*\*ORBIT slice:\*\*|ORBIT slice:)[[:space:]]*/ {
    sub(/^[[:space:]]*(\*\*ORBIT slice:\*\*|ORBIT slice:)[[:space:]]*/, "")
    gsub(/^`|`$/, ""); print; exit
  }')
case "$directive" in
  none*)
    reason=$(printf '%s' "$directive" | sed -nE 's/^none[[:space:]]*(—|--|-)[[:space:]]*(.*)$/\2/p')
    if [ -n "$(printf '%s' "$reason" | tr -d '[:space:]')" ]; then
      printf 'ORBIT slice exception for %s: %s\n' "$project" "$reason" >&2
      exit 0
    fi ;;
esac
if ! printf '%s' "$directive" | LC_ALL=C grep -Eq '^slice-[a-z0-9]+(-[a-z0-9]+)*$'; then
  echo "BLOCKED: [Feature] and [Task] tickets for $project need ORBIT slice: <id> or ORBIT slice: none — <reason>. Run /orbit slice." >&2
  exit 2
fi

if [ -z "$workspace" ]; then
  workspace="$(portfolio_workspace_dir)/$project"
elif [ "${workspace#/}" = "$workspace" ]; then
  workspace="$(dirname "$registry")/$workspace"
fi
if [ ! -d "$workspace" ]; then
  echo "BLOCKED: Cannot read the project checkout for $project. Run /orbit slice." >&2
  exit 2
fi
branch=$(git -C "$workspace" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null)
if [ -z "$branch" ] || ! git -C "$workspace" cat-file -e "refs/remotes/$branch:docs/orbit/slices/$directive.json" 2>/dev/null; then
  echo "BLOCKED: ORBIT slice $directive is not on $project's default branch. Merge its record, then file the ticket with /orbit slice." >&2
  exit 2
fi
