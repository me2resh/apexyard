#!/usr/bin/env bash
# Update the shipped files of an ops repo by ownership class
# (me2resh/apexyard#1887, AgDR-0275).
#
# Usage:
#   bin/update-files.sh --drift [--repo DIR] [--base REF]
#   bin/update-files.sh --plan  [--repo DIR] [--base REF] [--target REF]
#   bin/update-files.sh --apply [--repo DIR] [--base REF] [--target REF] [--confirm-security]
#
# BASE is the last-synced framework ref. The default is the tag in
# <repo>/.claude/framework-version. TARGET is the new framework ref. The
# default is upstream/main. The engine needs no shared history between the
# ops repo and the framework. It reads blobs from the two refs and the file
# in the work tree, and does a three-way merge for each file.
#
# The TARGET manifest (.claude/ownership-manifest.yaml) gives each path its
# class, through bin/_lib-ownership.sh. Only paths in BASE or TARGET are
# candidates. A local path in neither tree is never read or written.
#
# Status of each path:
#   unchanged  Nothing to do.
#   updated    No local edit. The engine writes the TARGET blob (or deletes).
#   kept       The engine keeps the local file: an adopter path, an
#              unclassified path, an overlay (a symlink in the path), or a
#              local edit where upstream did not change the file.
#   merged     A local edit and an upstream change merge cleanly.
#   conflict   A local edit and an upstream change do not merge.
#
# A routed agent's `model:` line (written by apply-agent-routing.sh) is not
# a local edit. The engine takes upstream's line, and the hook routes the
# agent again at the next session start. See AgDR-0275.
#
# --plan prints the status of each path that is not unchanged and writes
# nothing. --apply computes the same plan, then:
#   1. shows each local edit to a security path and asks for confirmation;
#   2. stops with the diffs and an overlay suggestion when a conflict exists;
#   3. saves each local edit as a patch under .claude/session/update-backup/;
#   4. writes the updated and merged files;
#   5. writes the TARGET release tag to .claude/framework-version.
#
# --drift uses BASE as TARGET. It lists local edits to framework files,
# skips overlays, and writes nothing. Exit: 0 no drift; 1 drift; 2 error.
#
# Exit for --plan and --apply: 0 ok; 1 conflict (nothing written); 2 usage or environment error;
#       3 security confirmation missing (nothing written).
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd) || exit 2
# shellcheck source=bin/_lib-ownership.sh
. "$root/bin/_lib-ownership.sh"

fail() { echo "$*" >&2; exit 2; }
usage() { fail 'Usage: bin/update-files.sh --plan|--apply [--repo DIR] [--base REF] [--target REF] [--confirm-security]
       bin/update-files.sh --drift [--repo DIR] [--base REF]'; }

mode='' repo='' base='' target=upstream/main confirm=false target_set=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    --plan|--apply|--drift) [ -z "$mode" ] || usage; mode=${1#--}; shift ;;
    --repo|--base|--target)
      [ "$#" -ge 2 ] && [ -n "$2" ] || usage
      case "$1" in --repo) repo=$2 ;; --base) base=$2 ;; --target) target=$2; target_set=true ;; esac
      shift 2 ;;
    --confirm-security) confirm=true; shift ;;
    *) usage ;;
  esac
done
[ -n "$mode" ] || usage
if [ "$mode" = drift ]; then
  [ "$target_set" = false ] && [ "$confirm" = false ] || usage
fi
[ -n "$repo" ] || repo=$(git -C "$PWD" rev-parse --show-toplevel) || exit 2
repo=$(cd "$repo" && pwd -P) || exit 2

# Return 0 when the path, or a parent directory of it in the repo, is a
# symlink. Such a path is an adopter overlay. The engine never reads or
# writes through the link.
# On return 0, overlay_link holds the repo-relative path of the link.
overlay_link=''
overlay() {
  local part="$1"
  while :; do
    if [ -L "$repo/$part" ]; then overlay_link=$part; return 0; fi
    case "$part" in */*) part=${part%/*} ;; *) return 1 ;; esac
  done
}
semver() { printf '%s\n' "$1" | LC_ALL=C grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$'; }

if [ -z "$base" ]; then
  anchor="$repo/.claude/framework-version"
  overlay .claude/framework-version && fail 'Cannot read .claude/framework-version through a link. Use --base.'
  [ -f "$anchor" ] || fail 'Missing .claude/framework-version. Use --base <tag>. Run git fetch upstream --tags.'
  base=$(cat "$anchor") || exit 2
  semver "$base" && [ "$(awk 'END { print NR }' "$anchor")" = 1 ] ||
    fail 'Invalid .claude/framework-version (want one line vMAJOR.MINOR.PATCH). Use --base <tag>.'
fi
base=$(git -C "$repo" rev-parse --verify --quiet "$base^{commit}") || fail "Cannot resolve base '$base'. Run git fetch upstream --tags."
[ "$mode" != drift ] || target=$base
target_name=$target
target=$(git -C "$repo" rev-parse --verify --quiet "$target^{commit}") || fail "Cannot resolve target '$target_name'. Run git fetch upstream --tags."

# Scratch space is outside the repo, so --plan writes nothing in it.
scratch=$(mktemp -d "${TMPDIR:-/tmp}/apexyard-update.XXXXXXXX") || exit 2
trap 'rm -rf "$scratch"' EXIT

# Fail closed on every git read. One ls-tree call for each ref, into a raw
# file first: a pipe would hide the ls-tree exit status behind tr's status,
# and a partial tree would then look like upstream deletes.
# Tree line: "<mode> <type> <blob>\t<path>".
for side in base target; do
  if [ "$side" = base ]; then ref=$base; else ref=$target; fi
  git -C "$repo" ls-tree -r -z "$ref" > "$scratch/$side.raw" || fail "Cannot read the $side tree. Nothing is written."
  tr '\000' '\n' < "$scratch/$side.raw" > "$scratch/$side.tree" || exit 2
done
bad=$(awk '$1 != "100644" && $1 != "100755" { sub(/^[^\t]*\t/, ""); print; exit }' "$scratch/base.tree" "$scratch/target.tree") || exit 2
[ -z "$bad" ] || fail "Unsupported tree entry (only regular files are supported): $bad"
cut -f2- "$scratch/base.tree" "$scratch/target.tree" | LC_ALL=C sort -u > "$scratch/paths" || exit 2
# Refuse a hostile tree path: a ".." or ".git" segment, or an absolute path.
bad=$(awk '/^\// || /(^|\/)\.\.(\/|$)/ || /(^|\/)\.git(\/|$)/ { print; exit }' "$scratch/paths") || exit 2
[ -z "$bad" ] || fail "Refused tree path with a '..' or '.git' segment: $bad"

# The manifest comes from the target tree. Use the base copy only when the
# target tree has no manifest entry. A failed read is an error, never a
# reason to fall back.
manifest_blob() {
  awk -F '\t' '$2 == ".claude/ownership-manifest.yaml" { split($1, m, " "); print m[3]; exit }' "$scratch/$1.tree"
}
export OWNERSHIP_MANIFEST="$scratch/manifest"
mblob=$(manifest_blob target) || exit 2
[ -n "$mblob" ] || { mblob=$(manifest_blob base) || exit 2; }
[ -n "$mblob" ] || fail 'No ownership manifest in base or target.'
git -C "$repo" cat-file blob "$mblob" > "$OWNERSHIP_MANIFEST" || fail 'Cannot read the ownership manifest. Nothing is written.'
ownership_classify_stream < "$scratch/paths" > "$scratch/classes" || exit 2

# Join: class, flag, base blob, target blob, target mode, path.
awk -F '\t' '
  FILENAME == ARGV[1] { split($1, m, " "); bb[$2] = m[3]; next }
  FILENAME == ARGV[2] { split($1, m, " "); tb[$2] = m[3]; tm[$2] = m[1]; next }
  {
    b = ($3 in bb) ? bb[$3] : "-"; t = ($3 in tb) ? tb[$3] : "-"; md = ($3 in tm) ? tm[$3] : "-"
    printf "%s\t%s\t%s\t%s\t%s\t%s\n", $1, $2, b, t, md, $3
  }' "$scratch/base.tree" "$scratch/target.tree" "$scratch/classes" > "$scratch/joined" || exit 2

# Routed agents. The SessionStart hook apply-agent-routing.sh rewrites the
# frontmatter `model:` line of each agent that the routing file names. That
# rewrite is not an adopter edit: the update takes upstream's file, and the
# hook applies the routing again at the next session start. The routing file
# is `.portfolio.agent_routing` in .claude/project-config.json (read with jq
# when it is present), else ./agent-routing.yaml. A relative path resolves
# against the repo root.
routing_file() {
  local value=''
  if command -v jq >/dev/null 2>&1 && ! overlay .claude/project-config.json && [ -f "$repo/.claude/project-config.json" ]; then
    value=$(jq -r '.portfolio.agent_routing // empty | select(type == "string")' \
      "$repo/.claude/project-config.json" 2>/dev/null) || value=''
  fi
  value=${value:-./agent-routing.yaml}
  case "$value" in /*) printf '%s' "$value" ;; *) printf '%s/%s' "$repo" "${value#./}" ;; esac
}
# Print each key of the top-level `agents:` map, one for each line.
routed_agents() {
  local file
  file=$(routing_file)
  [ -f "$file" ] || return 0
  awk '
    /^agents:[ \t]*(#.*)?$/ { on = 1; indent = ""; next }
    on && /^[^ \t#]/ { on = 0 }
    !on || /^[ \t]*(#.*)?$/ { next }
    {
      match($0, /^[ \t]*/); lead = substr($0, 1, RLENGTH)
      if (indent == "") indent = lead
      if (lead != indent) next
      key = substr($0, RLENGTH + 1)
      if (key !~ /:/) next
      sub(/:.*/, "", key); gsub(/"/, "", key); gsub(sprintf("%c", 39), "", key)
      if (key != "") print key
    }' "$file"
}
routed_agents > "$scratch/routed" || exit 2
is_routed_agent() {
  local name
  case "$1" in .claude/agents/*/*) return 1 ;; .claude/agents/*.md) ;; *) return 1 ;; esac
  name=${1#.claude/agents/}; name=${name%.md}
  grep -Fxq -- "$name" "$scratch/routed"
}
# Write <file> with its frontmatter `model:` line set to the line from the
# base blob <b> (or removed when the base has none) to <out>.
normalize_model() {
  local file=$1 b=$2 out=$3 base_model
  blob "$b" > "$out.base" || return 2
  base_model=$(awk 'NR == 1 && $0 == "---" { fm = 1; next } fm && $0 == "---" { exit } fm && /^model:/ { print; exit }' "$out.base") || return 2
  BASE_MODEL=$base_model awk '
    NR == 1 && $0 == "---" { fm = 1; print; next }
    fm && $0 == "---" { fm = 0; print; next }
    fm && /^model:/ { if (ENVIRON["BASE_MODEL"] != "") print ENVIRON["BASE_MODEL"]; next }
    { print }' "$file" > "$out"
}
blob() { if [ "$1" = - ]; then : ; else git -C "$repo" cat-file blob "$1"; fi; }

# Local state: "-" absent, "link" overlay, "dir" a directory, else a regular
# file whose blob id comes from one bulk hash-object call. For a routed
# agent, the engine hashes and merges a copy whose model line matches the
# base (see normalize_model), so a routed model line is not a local edit.
: > "$scratch/local-kind"; : > "$scratch/local-files"
i=0
while IFS=$'\t' read -r class _ b _ _ path; do
  i=$((i + 1))
  if overlay "$path"; then kind="link"
  elif [ -d "$repo/$path" ]; then kind=dir
  elif [ -f "$repo/$path" ]; then
    kind="file"
    if [ "$class" = framework ] && [ "$b" != - ] && is_routed_agent "$path"; then
      normalize_model "$repo/$path" "$b" "$scratch/local.$i" || exit 2
      printf '%s\n' "$scratch/local.$i" >> "$scratch/local-files"
    else
      printf '%s\n' "$path" >> "$scratch/local-files"
    fi
  else kind=-
  fi
  printf '%s\n' "$kind" >> "$scratch/local-kind"
done < "$scratch/joined"
# The local copy to compare and merge: the normalised copy, else the file.
local_src() { if [ -f "$scratch/local.$1" ]; then printf '%s' "$scratch/local.$1"; else printf '%s' "$repo/$2"; fi; }
if [ -s "$scratch/local-files" ]; then
  (cd "$repo" && git hash-object --stdin-paths) < "$scratch/local-files" > "$scratch/local-blobs" || exit 2
  [ "$(awk 'END { print NR }' "$scratch/local-blobs")" = "$(awk 'END { print NR }' "$scratch/local-files")" ] ||
    fail 'Cannot hash the local files. Nothing is written.'
else
  : > "$scratch/local-blobs"
fi

# Build one record for each path. All modes use these records.
# Record: n, status, class, security, edit, target blob, target mode, note, path.
: > "$scratch/records"
unchanged=0 updated=0 kept=0 merged=0 conflict=0 security_count=0
n=0
exec 3< "$scratch/local-kind" 4< "$scratch/local-blobs"
while IFS=$'\t' read -r class flag b t tmode path; do
  n=$((n + 1)); note=none; sec=false; edit=false
  IFS= read -r kind <&3
  case "$kind" in
    file) IFS= read -r l <&4 ;;
    -) l=- ;;
    *) l=$kind ;;
  esac
  if [ "$kind" = link ]; then
    status=kept; note=overlay
    # A gate file behind a link is never kept silently. The banner shows
    # the link, and the apply needs confirmation.
    if [ "$flag" = true ]; then sec=true; security_count=$((security_count + 1)); fi
  else
    [ "$l" = "$b" ] || edit=true
    if [ "$flag" = true ] && [ "$edit" = true ]; then sec=true; security_count=$((security_count + 1)); fi
    if [ "$class" = adopter ]; then status=kept
    elif [ "$class" = unmatched ]; then status=kept; note=unclassified
    elif [ "$kind" = dir ]; then status=conflict; note=directory
    elif [ "$t" = "$b" ]; then
      if [ "$l" = "$b" ]; then status=unchanged; else status=kept; fi
    elif [ "$l" = "$t" ]; then status=unchanged
    elif [ "$l" = "$b" ]; then status=updated
    elif [ "$l" = - ] || [ "$t" = - ]; then status=conflict
    else
      mkdir "$scratch/$n" || exit 2
      blob "$b" > "$scratch/$n/b" || exit 2
      blob "$t" > "$scratch/$n/t" || exit 2
      cp "$(local_src "$n" "$path")" "$scratch/$n/l" || exit 2
      if git merge-file -p --diff3 "$scratch/$n/l" "$scratch/$n/b" "$scratch/$n/t" > "$scratch/$n/result" 2>/dev/null; then
        status=merged
      else
        status=conflict
      fi
    fi
  fi
  case "$status" in
    unchanged) unchanged=$((unchanged + 1)) ;;
    updated) updated=$((updated + 1)) ;;
    kept) kept=$((kept + 1)) ;;
    merged) merged=$((merged + 1)) ;;
    conflict) conflict=$((conflict + 1)) ;;
  esac
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$n" "$status" "$class" "$sec" "$edit" "$b" "$t" "$tmode" "$kind" "$note" "$path" >> "$scratch/records"
done < "$scratch/joined"
exec 3<&- 4<&-

report() {
  while IFS=$'\t' read -r _ status class sec _ _ _ _ _ note path; do
    [ "$status" != unchanged ] || continue
    printf '%s\t%s\t%s' "$status" "$class" "$path"
    [ "$sec" != true ] || printf '\tsecurity'
    [ "$note" = none ] || printf '\t%s' "$note"
    printf '\n'
  done < "$scratch/records"
  printf '%s: %s unchanged, %s updated, %s kept, %s merged, %s conflict\n' \
    "$1" "$unchanged" "$updated" "$kept" "$merged" "$conflict"
}

# show_diff <label-a> <blob-a|-> <label-b> <blob-b|-|LOCAL> <path>
show_diff() {
  local a="$scratch/diff-a" b="$scratch/diff-b"
  blob "$2" > "$a" || return 2
  if [ "$4" = LOCAL ]; then
    if [ -f "$repo/$5" ]; then cp "$repo/$5" "$b" || return 2; else : > "$b"; fi
  else
    blob "$4" > "$b" || return 2
  fi
  diff -u --label "$1/$5" --label "$3/$5" "$a" "$b"
  [ "$?" -le 1 ] || return 2
}

custom_dir() {
  local value='' key=$1 fallback=$2
  if command -v jq >/dev/null 2>&1 && ! overlay .claude/project-config.json && [ -f "$repo/.claude/project-config.json" ]; then
    value=$(jq -r --arg key "$key" '.portfolio[$key] // empty | select(type == "string")' \
      "$repo/.claude/project-config.json" 2>/dev/null) || value=''
  fi
  printf '%s' "${value:-$fallback}"
}

suggest() {
  local class=$1 path=$2 name
  if [ "$class" = shared ]; then
    echo 'Suggestion: resolve the merge by hand, then run the update again.'
    return
  fi
  case "$path" in
    .claude/skills/*/*)
      name=${path#.claude/skills/}; name=${name%%/*}
      printf 'Suggestion: copy the skill to %s/%s/ and keep your change there. The framework copy then stays unedited.\n' \
        "$(custom_dir custom_skills_dir ./custom-skills)" "$name" ;;
    handbooks/*|.claude/rules/*)
      printf 'Suggestion: move your rule to %s/. The framework copy then stays unedited.\n' \
        "$(custom_dir custom_handbooks_dir ./custom-handbooks)" ;;
    .claude/agents/*)
      echo 'Suggestion: set the model in agent-routing.yaml. Move other changes to .claude/project-config.json.' ;;
    *)
      echo 'Suggestion: set the option in .claude/project-config.json, and do not edit this file.' ;;
  esac
}

if [ "$mode" = drift ]; then
  drift=0
  while IFS=$'\t' read -r _ _ class sec edit _ _ _ _ note path; do
    [ "$class" = framework ] && [ "$edit" = true ] && [ "$note" != overlay ] || continue
    drift=$((drift + 1))
    printf 'drift\t%s' "$path"
    [ "$sec" != true ] || printf '\tsecurity'
    printf '\n  '
    suggest "$class" "$path"
  done < "$scratch/records"
  if [ "$drift" -eq 0 ]; then
    echo 'drift: no local edits to framework-owned files'
    exit 0
  fi
  printf 'drift: %s local edit(s) to framework-owned files\n' "$drift"
  exit 1
fi

if [ "$mode" = plan ]; then
  # A header line starts with "#", so a caller that reads the status
  # columns can skip it.
  echo '# Per-file update by owner class. This is the default. /update --git-merge runs the history merge instead.'
  echo '# Nothing is written. Statuses: unchanged, updated, kept (yours), merged, conflict.'
  report plan
  exit 0
fi

# 1. Security paths: show each local edit loudly, before any write.
if [ "$security_count" -gt 0 ]; then
  echo '!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!'
  echo 'SECURITY: local edits to gate files'
  echo 'These files enforce gates. Read each local edit below.'
  while IFS=$'\t' read -r _ status class sec _ b _ _ kind _ path; do
    [ "$sec" = true ] || continue
    if [ "$kind" = link ] && overlay "$path"; then
      # Show the link only. Never read through it.
      echo "  $path ($status, behind a link)"
      echo "    link: $overlay_link -> $(readlink "$repo/$overlay_link")"
      echo '    The update keeps this link. The gate file it points to is not checked.'
      continue
    fi
    echo "  $path ($status)"
    show_diff base "$b" local LOCAL "$path" || exit 2
  done < "$scratch/records"
  echo '!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!'
  if [ "$confirm" != true ]; then
    if [ ! -t 0 ]; then
      echo 'Stopped. Nothing is written. Read the edits above, then run again with --confirm-security.' >&2
      exit 3
    fi
    printf 'Type yes to continue with these gate edits: '
    IFS= read -r answer || exit 3
    [ "$answer" = yes ] || { echo 'Stopped. Nothing is written.' >&2; exit 3; }
  fi
fi

# 2. Conflicts: write nothing, show both sides and a suggestion.
if [ "$conflict" -gt 0 ]; then
  while IFS=$'\t' read -r _ status class _ _ b t _ _ note path; do
    [ "$status" = conflict ] || continue
    printf '\nCONFLICT (%s): %s' "$class" "$path"
    [ "$note" = none ] || printf ' (%s)' "$note"
    printf '\nYour local edit:\n'
    show_diff base "$b" local LOCAL "$path" || exit 2
    printf 'The upstream change:\n'
    show_diff base "$b" upstream "$t" "$path" || exit 2
    suggest "$class" "$path"
  done < "$scratch/records"
  printf '\nStopped. Nothing is written. %s conflict(s). No local edit is lost.\n' "$conflict" >&2
  exit 1
fi

for path in .claude/framework-version .claude/session .claude/session/update-backup; do
  overlay "$path" && fail "Cannot write through a link: $path"
done

# 3. Save each local edit that the update re-applies or confirms.
backup=''
while IFS=$'\t' read -r _ status _ sec edit b _ _ kind _ path; do
  [ "$edit" = true ] && [ "$kind" = file ] || continue
  case "$status:$sec" in merged:*|*:true) ;; *) continue ;; esac
  if [ -z "$backup" ]; then
    backup="$repo/.claude/session/update-backup/$(date -u +%Y%m%dT%H%M%SZ)-$$"
    echo "Backup of local edits: $backup"
  fi
  mkdir -p "$backup/$(dirname "$path")" || exit 2
  show_diff base "$b" local LOCAL "$path" > "$backup/$path.patch" || exit 2
  cp "$repo/$path" "$backup/$path.local" || exit 2
done < "$scratch/records"

# 4. Write through a temp file in the same directory, then rename.
write_file() {
  local source=$1 dest=$2 fmode=$3 tmp
  mkdir -p "$(dirname "$dest")" || return 2
  tmp=$(mktemp "$(dirname "$dest")/.update.XXXXXXXX") || return 2
  if ! cp "$source" "$tmp" || ! chmod 644 "$tmp"; then rm -f "$tmp"; return 2; fi
  if [ "$fmode" = 100755 ]; then chmod +x "$tmp" || { rm -f "$tmp"; return 2; }; fi
  mv -f "$tmp" "$dest" || { rm -f "$tmp"; return 2; }
}
while IFS=$'\t' read -r n status _ _ _ _ t tmode _ _ path; do
  case "$status" in
    updated)
      if [ "$t" = - ]; then
        rm -f "$repo/$path" || exit 2
      else
        blob "$t" > "$scratch/write" || exit 2
        write_file "$scratch/write" "$repo/$path" "$tmode" || exit 2
      fi ;;
    merged)
      write_file "$scratch/$n/result" "$repo/$path" "$tmode" || exit 2 ;;
  esac
done < "$scratch/records"

# 5. Advance the version anchor when the target is a release tag.
tag=$(git -C "$repo" describe --exact-match --tags "$target" 2>/dev/null) || tag=''
if semver "$tag"; then
  printf '%s\n' "$tag" > "$scratch/anchor"
  write_file "$scratch/anchor" "$repo/.claude/framework-version" 100644 || exit 2
else
  echo 'The target is not a release tag. .claude/framework-version is unchanged.'
fi
report applied
