#!/usr/bin/env bash
# Drift and conservative overlay rescue. Sourced by update-files.sh.
# Globals are supplied by that caller.
# shellcheck disable=SC2154

# Read scalar and indented block frontmatter without executing YAML.
drift_metadata() {
  awk -v key="$2" '
    function emit() {
      gsub(/["\047]/, "", value)
      gsub(/[[:space:]]+/, " ", value)
      sub(/^ /, "", value); sub(/ $/, "", value)
      print value
    }
    NR == 1 && $0 == "---" { fm=1; next }
    fm && $0 == "---" { exit }
    block && /^[[:space:]]/ { value=value " " $0; next }
    block { exit }
    fm && index($0, key ":") == 1 {
      sub(/^[^:]*:[[:space:]]*/, "")
      if ($0 ~ /^[|>][-+]?[[:space:]]*$/) { block=1; found=1; next }
      value=$0; found=1; exit
    }
    END { if (found) emit() }' "$1"
}

# A canonical framework agent name can also identify its role in a new
# agent name or description. Do not infer roles from generic word overlap.
drift_role_matches() {
  local role text
  role=$(printf '%s' "$1" | tr '[:upper:]_-' '[:lower:]  ')
  text=$(printf '%s %s' "$2" "$3" | tr '[:upper:]_-' '[:lower:]  ')
  [ -n "$role" ] || return 1
  case " $text " in *" $role "*) return 0 ;; *) return 1 ;; esac
}

drift_duplicate() {
  local path=$1 source=$2 meta='' candidate name description bn bd role
  case "$path" in
    .claude/skills/*/*)
      name=${path#.claude/skills/}; name=${name%%/*}
      meta=".claude/skills/$name/SKILL.md" ;;
    .claude/agents/*.md) meta=$path ;;
    *) return 1 ;;
  esac
  [ -f "$source/$meta" ] || return 1
  name=$(drift_metadata "$source/$meta" name)
  description=$(drift_metadata "$source/$meta" description)
  # Recognize the pinned item before comparing it with other framework roles.
  # A second agent at another path must still undergo the role checks.
  if git -C "$repo" show "$base:$meta" > "$scratch/pinned-meta" 2>/dev/null; then
    if cmp -s "$source/$meta" "$scratch/pinned-meta" || {
      [ "$name" = "$(drift_metadata "$scratch/pinned-meta" name)" ] &&
      [ "$description" = "$(drift_metadata "$scratch/pinned-meta" description)" ];
    }; then return 1; fi
  fi
  while IFS=$'\t' read -r candidate bn bd; do
    case "$meta:$candidate" in
      .claude/skills/*:.claude/skills/*|.claude/agents/*:.claude/agents/*) ;;
      *) continue ;;
    esac
    [ "$bn" != - ] || bn=''
    [ "$bd" != - ] || bd=''
    if [ "$candidate" = "$meta" ] || { [ -n "$name" ] && [ "$name" = "$bn" ]; }; then
      if [ -n "$description" ] && [ -n "$bd" ] && [ "$description" != "$bd" ]; then return 0; fi
    fi
    case "$path:$candidate" in
      .claude/agents/*:.claude/agents/*)
        role=${candidate#.claude/agents/}; role=${role%.md}
        if [ "$candidate" != "$meta" ] && {
          { [ -n "$name" ] && [ "$name" = "$bn" ]; } ||
          { [ -n "$description" ] && [ "$description" = "$bd" ]; } ||
          drift_role_matches "$role" "$name" "$description";
        }; then return 0; fi ;;
    esac
  done < "$scratch/framework-metadata"
  return 1
}

drift_destination() {
  case "$1" in
    .claude/skills/*/*)
      local skill=${1#.claude/skills/}
      skill=${skill%%/*}
      case "$skill" in _lib-*) return 1 ;; esac
      [ -f "$source/.claude/skills/$skill/SKILL.md" ] || return 1
      printf '%s/%s' "$skills" "${1#.claude/skills/}" ;;
    templates/*) printf '%s/%s' "$templates" "${1#templates/}" ;;
    handbooks/*) printf '%s/%s' "$handbooks" "${1#handbooks/}" ;;
    *) return 1 ;;
  esac
}

# Refuse links at any ancestor, including destinations outside the ops repo.
drift_no_links() {
  local p=$1
  while [ "$p" != / ] && [ "$p" != . ]; do
    [ ! -L "$p" ] || return 1
    p=$(dirname "$p")
  done
}

drift_report() {
  local drift=0 source=$repo path class edit note dest b result=0
  local skills='' templates='' handbooks='' upstream sec key name description
  if [ "$rescue" = true ]; then
    export APEXYARD_DISABLE_RESOLUTION_CACHE=1
    # shellcheck source=/dev/null
    . "$root/.claude/hooks/_lib-portfolio-paths.sh"
    # shellcheck source=/dev/null
    . "$root/.claude/hooks/_lib-read-config.sh"
    # --repo selects this tree even when the caller has a session pin.
    _PORTFOLIO_ROOT_CACHE=$repo
    _CONFIG_ROOT_CACHE=$repo
    skills=$(cd "$repo" && portfolio_custom_skills_dir) || return 2
    handbooks=$(cd "$repo" && portfolio_custom_handbooks_dir) || return 2
    templates=$(cd "$repo" && portfolio_registry) || return 2
    templates="$(dirname "$templates")/custom-templates"
  fi
  if [ -n "$import_from" ]; then
    [ -d "$import_from" ] || { echo 'Import directory does not exist.' >&2; return 2; }
    source=$(cd "$import_from" && pwd -P) || return 2
    [ "$(basename "$source")" = .claude ] || { echo '--from must name a .claude directory.' >&2; return 2; }
    source=$(dirname "$source")
    : > "$scratch/framework-metadata"
    while IFS=$'\t' read -r _ path; do
      case "$path" in .claude/skills/*/SKILL.md|.claude/agents/*.md) ;; *) continue ;; esac
      git -C "$repo" show "$base:$path" > "$scratch/meta" || return 2
      name=$(drift_metadata "$scratch/meta" name)
      description=$(drift_metadata "$scratch/meta" description)
      printf '%s\t%s\t%s\n' "$path" "${name:--}" "${description:--}" >> "$scratch/framework-metadata"
    done < "$scratch/base.tree"
  fi
  echo 'Your change (against pinned version):'
  : > "$scratch/rescue-plan"
  : > "$scratch/rescue-skills"
  if [ -n "$import_from" ]; then
    find "$source/.claude" -type f -print > "$scratch/import-files" || return 2
    while IFS= read -r path; do
      path=${path#"$source/"}
      drift_no_links "$source/$path" || continue
      if drift_duplicate "$path" "$source"; then
        printf 'duplicate\t%s\tmanual review\n' "$path"; drift=$((drift + 1)); continue
      fi
      b=$(awk -F '\t' -v p="$path" '$2 == p {split($1,m," "); print m[3]}' "$scratch/base.tree")
      if [ -z "$b" ]; then
        printf 'repo-only\t%s\tstay\n' "$path"
        case "$path" in .claude/hooks/*|.claude/settings*.json) printf 'manual review\t%s (hook or settings)\n' "$path" ;; esac
        continue
      fi
      printf 'shared\t%s\n' "$path"
      case "$path" in .claude/hooks/*|.claude/settings*.json)
        printf 'manual review\t%s (hook or settings)\n' "$path"
        [ "$(git -C "$repo" hash-object "$source/$path")" = "$b" ] || drift=$((drift + 1))
        continue ;;
      esac
      [ "$(git -C "$repo" hash-object "$source/$path")" != "$b" ] || continue
      drift=$((drift + 1))
      drift_plan_item "$path" "$source" "$b" || return 2
    done < "$scratch/import-files"
  else
    while IFS=$'\t' read -r _ _ class sec edit b _ _ _ note path; do
      case "$class:$path" in
        framework:*) ;;
        shared:.claude/settings*.json) ;;
        shared:handbooks/*) [ "$rescue" = true ] || continue ;;
        *) continue ;;
      esac
      [ "$edit" = true ] && [ "$note" != overlay ] || continue
      drift=$((drift + 1))
      printf 'drift\t%s' "$path"
      [ "$sec" != true ] || printf '\tsecurity'
      printf '\n  '
      if [ "$rescue" = true ]; then
        drift_plan_item "$path" "$source" "$b" || return 2
      else suggest "$class" "$path"
      fi
    done < "$scratch/records"
  fi
  # Inspect explicit file references, not arbitrary strings or glob patterns.
  if [ -f "$repo/.claude/project-config.json" ]; then
    command -v jq >/dev/null 2>&1 || { echo 'jq required to check config references.' >&2; return 2; }
    jq -r 'paths(strings) as $p | getpath($p) as $v |
      select(($p[-1] | test("(_file|_path|_template)$|^(template|agent_routing|registry|onboarding)$")) and ($v != "")) |
      [($p | map(tostring) | join(".")), $v] | @tsv' "$repo/.claude/project-config.json" > "$scratch/config-paths" || return 2
    while IFS=$'\t' read -r key path; do
      case "$path" in *'*'*|*'?'*) continue ;; /*) dest=$path ;; *) dest="$repo/$path" ;; esac
      if [ ! -e "$dest" ]; then printf 'drift\tconfig %s -> %s (absent file)\n' "$key" "$path"; drift=$((drift + 1)); fi
    done < "$scratch/config-paths"
  fi
  echo 'Upstream change (pinned version to locally available upstream/main):'
  if upstream=$(git -C "$repo" rev-parse --verify --quiet upstream/main); then
    git -C "$repo" diff --name-status "$base" "$upstream" -- > "$scratch/upstream" || return 2
    cat "$scratch/upstream"
    [ -s "$scratch/upstream" ] || echo 'none'
  else echo 'unknown (upstream/main unavailable; no fetch performed)'; fi
  if [ "$rescue_apply" = true ]; then
    # Preflight the complete plan before the first write. Never overwrite an overlay.
    while IFS=$'\t' read -r path dest; do
      if [ -e "$dest" ] || ! drift_no_links "$dest" ||
        [ -n "$(find "$source/$path" -type l -print)" ]; then
        echo "Refused existing overlay or skill link: $dest" >&2; return 2
      fi
    done < "$scratch/rescue-skills"
    while IFS=$'\t' read -r path dest b; do
      if ! drift_no_links "$dest" || ! drift_no_links "$source/$path"; then
        echo "Refused link: $dest" >&2; return 2
      fi
      [ ! -e "$dest" ] || { echo "Overlay already exists: $dest" >&2; return 2; }
    done < "$scratch/rescue-plan"
    while IFS=$'\t' read -r path dest; do
      mkdir -p "$(dirname "$dest")" || return 2
      if [ -z "$import_from" ]; then
        cp -Rp "$source/$path" "$dest" || return 2
      fi
    done < "$scratch/rescue-skills"
    while IFS=$'\t' read -r path dest b; do
      mkdir -p "$(dirname "$dest")" || return 2
      case "$path" in
        .claude/skills/*/*) [ -z "$import_from" ] || cp -p "$source/$path" "$dest" || return 2 ;;
        *) cp -p "$source/$path" "$dest" || return 2 ;;
      esac
      # Import preserves the product repository. Only in-place rescue restores.
      if [ -z "$import_from" ]; then
        blob "$b" > "$source/$path" || return 2
      fi
      printf 'rescued\t%s -> %s\n' "$path" "$dest"
    done < "$scratch/rescue-plan"
  fi
  if [ "$drift" -eq 0 ]; then
    echo 'drift: no local edits to framework-owned files'
  else printf 'drift: %s local edit(s) to framework-owned files or config findings\n' "$drift"; fi
  [ "$drift" -eq 0 ] || result=1
  return "$result"
}

drift_plan_item() {
  local path=$1 source=$2 b=$3 dest skill
  if [ "$b" = - ] || [ ! -f "$source/$path" ] || ! drift_no_links "$source/$path"; then
    printf 'manual review\t%s (missing or unsupported file)\n' "$path"; return 0
  fi
  if dest=$(drift_destination "$path"); then
    case "$path" in .claude/skills/*/*)
      skill=${path#.claude/skills/}; skill=${skill%%/*}
      if ! grep -Fqx -- ".claude/skills/$skill" "$scratch/skill-names" 2>/dev/null; then
        printf '%s\n' ".claude/skills/$skill" >> "$scratch/skill-names"
        printf '%s\t%s\n' ".claude/skills/$skill" "$skills/$skill" >> "$scratch/rescue-skills"
      fi ;;
    esac
    printf 'rescue plan\t%s -> %s\n' "$path" "$dest"
    printf '%s\t%s\t%s\n' "$path" "$dest" "$b" >> "$scratch/rescue-plan"
  else printf 'manual review\t%s (no overlay home)\n' "$path"; fi
}
