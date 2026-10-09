#!/bin/bash
# Require a merged ORBIT slice for Feature, Task, and ORBIT Slice issues.
# Use the same command matcher as require-skill-for-issue-create.sh.

set -u

input=$(cat)
if ! command -v jq >/dev/null 2>&1; then
  # The dispatcher cannot recover a title or target from JSON without jq.
  # A create-shaped payload must wait until the gate can parse it.
  case "$input" in
    *'issue create'*|*'tracker_create'*|*'api repos/'*)
      echo 'BLOCKED: Cannot check an ORBIT ticket while jq is unavailable.' >&2
      exit 2 ;;
  esac
  exit 0
fi
tool=$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null)
[ "$tool" = Bash ] || exit 0
command=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)
[ -n "$command" ] || exit 0
case "$command" in *create*|*'api repos/'*) : ;; *) exit 0 ;; esac

hook_dir=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=/dev/null
. "$hook_dir/_lib-read-config.sh"
patterns=$(config_get '.ticket.create_command_patterns[]' 2>/dev/null)
[ -n "$patterns" ] || exit 0
norm=$(printf '%s' "$command" | tr -s '[:space:]' ' ')
matched=""
# Boundary list matches require-skill-for-issue-create.sh, plus `$(pat…)` so
# ORBIT still sees `result="$(tracker_create …)"` when planning is on. The
# skill gate deliberately omits that form (AgDR-0217 / #1565).
while IFS= read -r pat; do
  [ -n "$pat" ] || continue
  case "$norm" in
    "$pat"*|*"; $pat"*|*"&& $pat"*|*"|| $pat"*|*"| $pat"*|*'$('"$pat"*) matched=$pat; break ;;
  esac
done <<EOF
$patterns
EOF
# Shell wrappers can place the create command inside a quoted argument. The
# skill gate intentionally does not inspect those forms; this guard must
# still see them when ORBIT is enabled.
if [ -z "$matched" ]; then
  case "$norm" in
    *'tracker_create '*) matched=tracker_create ;;
    *'gh api repos/'*) matched='gh api repos/' ;;
    *'gh issue create '*) matched=wrapped ;;
  esac
fi
[ -n "$matched" ] || exit 0
is_issue_create=0
case "$norm" in *'gh issue create '*) is_issue_create=1 ;; esac
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
      if (!match(s, /tracker_create[[:space:]]+/)) exit
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

shell_words() {
  printf '%s' "$command" | awk '
    { s=s (NR==1 ? "" : "\n") $0 }
    END {
      word=""; quote=""; escape=0
      for (i=1; i<=length(s); i++) {
        c=substr(s,i,1)
        if (escape) { word=word c; escape=0; continue }
        if (c=="\\" && quote!="\047") { escape=1; continue }
        if (quote!="") {
          if (c==quote) quote=""; else word=word c
          continue
        }
        if (c=="\047" || c=="\"") { quote=c; continue }
        if (c ~ /[[:space:];&|()<>]/) {
          if (word!="") { printf "%s%c",word,0; word="" }
          continue
        }
        word=word c
      }
      if (word!="") printf "%s%c",word,0
    }'
}

repo_flags=0
title_flags=0
repo_from_words=""
title_from_words=""
pending_flag=""
while IFS= read -r -d '' word; do
  if [ -n "$pending_flag" ]; then
    case "$pending_flag" in
      repo) repo_from_words=$word ;;
      title) title_from_words=$word ;;
    esac
    pending_flag=""
    continue
  fi
  case "$word" in
    --repo|-R) repo_flags=$((repo_flags+1)); pending_flag=repo ;;
    --repo=*) repo_flags=$((repo_flags+1)); repo_from_words=${word#--repo=} ;;
    -R?*) repo_flags=$((repo_flags+1)); repo_from_words=${word#-R} ;;
    --title|-t) title_flags=$((title_flags+1)); pending_flag=title ;;
    --title=*) title_flags=$((title_flags+1)); title_from_words=${word#--title=} ;;
    -t?*) title_flags=$((title_flags+1)); title_from_words=${word#-t} ;;
  esac
done < <(shell_words)
if [ "$repo_flags" -gt 1 ]; then
  echo 'BLOCKED: ORBIT ticket has ambiguous repo flags.' >&2
  exit 2
fi
repo=$(flag_value '--repo|-R')
title=$(flag_value '--title|-t')
if [ "$repo_flags" -gt 0 ]; then repo=$repo_from_words; fi
if [ "$title_flags" -gt 0 ]; then title=$title_from_words; fi
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
api_title_fields=0
if [ "$matched" = 'gh api repos/' ]; then
  field_next=0
  while IFS= read -r -d '' word; do
    if [ "$field_next" -eq 1 ]; then
      case "$word" in title=*) api_title_fields=$((api_title_fields+1)) ;; esac
      field_next=0
      continue
    fi
    case "$word" in
      -f|-F|--field|--raw-field) field_next=1 ;;
      -ftitle=*|-Ftitle=*) api_title_fields=$((api_title_fields+1)) ;;
    esac
  done < <(shell_words)
fi
config_root=$(_config_repo_root)
if [ -z "$config_root" ] || [ ! -r "$config_root/.claude/project-config.defaults.json" ] ||
   ! jq -e 'type == "object"' "$config_root/.claude/project-config.defaults.json" >/dev/null 2>&1; then
  echo 'BLOCKED: Cannot read the ORBIT project configuration.' >&2
  exit 2
fi
if [ -e "$config_root/.claude/project-config.json" ] &&
   { [ ! -r "$config_root/.claude/project-config.json" ] ||
     ! jq -e 'type == "object"' "$config_root/.claude/project-config.json" >/dev/null 2>&1; }; then
  echo 'BLOCKED: Cannot read the ORBIT project configuration.' >&2
  exit 2
fi
if [ -z "$repo" ]; then
  remote_url=$(git remote get-url origin 2>/dev/null)
  repo=$remote_url
fi

# Lowercase owner/name. Strip URL scheme, git@host:, host/, trailing .git, /.
# gh accepts Owner/Name, https://…, and github.com/…; the registry stores slugs.
normalize_repo_target() {
  # awk /regex/ delimiters cannot host an unescaped / inside [^/], so host
  # stripping uses split + a hostname-shaped first segment (contains a dot).
  printf '%s' "$1" | LC_ALL=C awk '
    {
      s = $0
      sub(/[[:space:]]+#.*/, "", s)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
      gsub(/^["\047]|["\047]$/, "", s)
      s = tolower(s)
      while (s ~ /\/$/) sub(/\/$/, "", s)
      if (s ~ /\.git$/) sub(/\.git$/, "", s)
      while (s ~ /\/$/) sub(/\/$/, "", s)
      if (match(s, /^[a-z][a-z0-9+.-]*:\/\//)) s = substr(s, RLENGTH + 1)
      if (match(s, /^git@[^:]+:/)) s = substr(s, RLENGTH + 1)
      n = split(s, p, "/")
      start = 1
      if (n >= 3 && index(p[1], ".") > 0) start = 2
      if (n - start + 1 >= 2) print p[n - 1] "/" p[n]
      else if (n >= start) {
        out = p[start]
        for (i = start + 1; i <= n; i++) out = out "/" p[i]
        print out
      } else print s
    }
  '
}

# Resolve the target registry entry. A per-project flag wins over the global
# default. No registered target means the project has no ORBIT gate.
# shellcheck source=/dev/null
. "$hook_dir/_lib-portfolio-paths.sh"
# shellcheck source=/dev/null
. "$hook_dir/_lib-registry-parser.sh"
registry=$(portfolio_registry)
[ -f "$registry" ] || exit 0
if ! declare -F registry_parse_entries >/dev/null 2>&1; then
  echo 'BLOCKED: Cannot read the ORBIT project registry.' >&2
  exit 2
fi
parsed=$(registry_parse_entries "$registry") || {
  echo 'BLOCKED: Cannot read the ORBIT project registry.' >&2
  exit 2
}
target=$(normalize_repo_target "$repo")
if [ -z "$target" ]; then
  if [ -n "$repo" ]; then
    echo 'BLOCKED: Cannot normalise the ORBIT ticket repo target.' >&2
    exit 2
  fi
  exit 0
fi
project=""
while IFS= read -r entry; do
  case "$entry" in
    PAIR=*)
      pair=${entry#PAIR=}
      pname=$(printf '%s' "$pair" | cut -f1)
      prepo=$(printf '%s' "$pair" | cut -f2)
      if [ "$(normalize_repo_target "$prepo")" = "$target" ]; then
        project=$pname
        break
      fi
      ;;
  esac
done <<EOF
$parsed
EOF
[ -n "$project" ] || exit 0
# Workspace and orbit.default_planning stay on the named entry; the shared
# parser correlates tokens for leak scrubbing and does not emit those fields.
fields=$(awk -v want="$project" '
  function clean(v) {
    sub(/^[^:]*:[[:space:]]*/, "", v)
    sub(/[[:space:]]+#.*/, "", v)
    gsub(/^["\047]|["\047]$/, "", v)
    gsub(/[[:space:]]+$/, "", v)
    return v
  }
  function emit() { if (found) print workspace "\t" orbit }
  /^[[:space:]]*- name:/ {
    emit()
    name = clean($0); found = (name == want)
    workspace = ""; orbit = ""; in_orbit = 0; next
  }
  found && /^[[:space:]]*workspace:/ { workspace = clean($0); in_orbit = 0; next }
  found && /^[[:space:]]*orbit:[[:space:]]*$/ { in_orbit = 1; next }
  found && /^[[:space:]]*[a-zA-Z_]+:/ {
    if (in_orbit && $1 ~ /^default_planning:/) orbit = clean($0)
    in_orbit = 0
  }
  END { emit() }
' "$registry" | head -1)
workspace=$(printf '%s' "$fields" | cut -f1)
enabled=$(printf '%s' "$fields" | cut -f2 | LC_ALL=C tr '[:upper:]' '[:lower:]')
# The registry is hand-edited YAML. Accept the YAML 1.1 boolean spellings,
# so that "True" or "yes" does not turn the gate off without notice.
case "$enabled" in
  true|yes|on) enabled=true ;;
  false|no|off|'') : ;;
  *)
    echo "WARNING: orbit.default_planning for '$project' has an unknown value '$enabled'. The global default applies." >&2
    enabled= ;;
esac
[ -n "$enabled" ] || enabled=$(config_get '.orbit.default_planning' 2>/dev/null)
[ "$enabled" = true ] || exit 0
case "$norm" in
  *' -c '*|*' -lc '*|*'xargs '*)
    echo 'BLOCKED: Wrapped ORBIT ticket creation cannot be verified. Use a direct create call.' >&2
    exit 2 ;;
esac
if [ "$title_flags" -gt 1 ] || [ "$api_title_fields" -gt 1 ]; then
  echo 'BLOCKED: ORBIT ticket has ambiguous title flags.' >&2
  exit 2
fi
# Treat malformed bracketed variants as governed tickets too. Otherwise a
# leading space or changed case skips this gate.
lower_title=$(printf '%s' "$title" | LC_ALL=C tr '[:upper:]' '[:lower:]')
case "$lower_title" in
  *'[feature]'*|*'[task]'*|*'[slice]'*|*'［feature］'*|*'［task］'*|*'［slice］'*|*'【feature】'*|*'【task】'*|*'【slice】'*) : ;;
  '') : ;; # An interactive title cannot prove this is a Bug or Spike.
  *) exit 0 ;;
esac
if [ -z "$title" ]; then
  echo 'BLOCKED: ORBIT ticket title cannot be read.' >&2
  exit 2
fi

# Tokenize shell words once, without executing command substitutions. A
# quoted multiline body remains one token. Count every body source so a later
# flag cannot replace the value that this hook inspected.
body_sources=0
body_from_words=""
body_file_from_words=""
field_next=0
pending_body=""
while IFS= read -r -d '' word; do
  if [ -n "$pending_body" ]; then
    case "$pending_body" in
      body) body_from_words=$word ;;
      file) body_file_from_words=$word ;;
    esac
    pending_body=""
    continue
  fi
  if [ "$field_next" -eq 1 ]; then
    case "$word" in body=*|body@=*) body_sources=$((body_sources+1)) ;; esac
    field_next=0
  fi
  case "$word" in
    --body|-b) body_sources=$((body_sources+1)); pending_body=body ;;
    --body-file) body_sources=$((body_sources+1)); pending_body='file' ;;
    -F)
      if [ "$is_issue_create" -eq 1 ]; then
        body_sources=$((body_sources+1)); pending_body='file'
      else
        field_next=1
      fi ;;
    --body=*) body_sources=$((body_sources+1)); body_from_words=${word#--body=} ;;
    --body-file=*) body_sources=$((body_sources+1)); body_file_from_words=${word#--body-file=} ;;
    -b?*) body_sources=$((body_sources+1)); body_from_words=${word#-b} ;;
    -Fbody=*|-Fbody@=*|-fbody=*|-fbody@=*)
      body_sources=$((body_sources+1)) ;;
    -F?*)
      if [ "$is_issue_create" -eq 1 ]; then
        body_sources=$((body_sources+1)); body_file_from_words=${word#-F}
      else
        case "$word" in -Fbody=*|-Fbody@=*) body_sources=$((body_sources+1)) ;; esac
      fi ;;
    -f|--field|--raw-field) field_next=1 ;;
  esac
done < <(shell_words)
if [ "$body_sources" -gt 1 ]; then
  echo 'BLOCKED: ORBIT ticket has multiple body sources.' >&2
  exit 2
fi

body=$(flag_value '--body|-b')
body_file=$(flag_value '--body-file')
if [ "$is_issue_create" -eq 1 ]; then
  body=$body_from_words
  body_file=$body_file_from_words
fi
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
  if [ "$body_file" = - ] || [ ! -f "$body_file" ] || [ ! -r "$body_file" ]; then
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
  NR==1 && /^(\*\*ORBIT slice:\*\*|ORBIT slice:)[[:space:]]*/ {
    sub(/^(\*\*ORBIT slice:\*\*|ORBIT slice:)[[:space:]]*/, "")
    gsub(/^`|`$/, ""); first=$0; next
  }
  NR==2 && $0 !~ /^[[:space:]]*$/ { invalid=1 }
  END { if (!invalid) print first }
')
case "$directive" in
  none*)
    reason=$(printf '%s' "$directive" | sed -nE 's/^none[[:space:]]*(—|--|-)[[:space:]]*(.*)$/\2/p')
    if [ -n "$(printf '%s' "$reason" | tr -d '[:space:]')" ]; then
      printf 'ORBIT slice exception for %s: %s\n' "$project" "$reason" >&2
      exit 0
    fi ;;
esac
if ! printf '%s' "$directive" | LC_ALL=C grep -Eq '^slice-[a-z0-9]+(-[a-z0-9]+)*$'; then
  echo "BLOCKED: [Feature], [Task], and [Slice] tickets for $project need ORBIT slice: <id> or ORBIT slice: none — <reason>. Run /orbit slice." >&2
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
record_path="docs/orbit/slices/$directive.json"
record_mode=$(git -C "$workspace" ls-tree "refs/remotes/$branch" -- "$record_path" 2>/dev/null | awk 'NR==1 { print $1 }')
if [ -z "$branch" ] || [ "$record_mode" != 100644 ] && [ "$record_mode" != 100755 ]; then
  echo "BLOCKED: ORBIT slice $directive is not on $project's default branch. Merge its record, then file the ticket with /orbit slice." >&2
  exit 2
fi
