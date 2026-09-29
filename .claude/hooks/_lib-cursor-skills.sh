#!/usr/bin/env bash
# _lib-cursor-skills.sh — list skill names Cursor would load from a workspace.
#
# Models the skill roots Cursor reads when third-party configs are on
# (AgDR-0151) plus sibling custom-skills trees that appear when a parent
# directory is the workspace root (apexyard#1377).
#
# Skill name comes from SKILL.md frontmatter `name:`, then the directory
# basename. A `.framework.bak` suffix is stripped from the basename only
# when frontmatter is missing. That mirrors Cursor listing two entries
# that share one frontmatter name.
#
# Override wins for --unique: an active `.claude/skills/<name>` entry
# beats a bak, a custom-skills source, or a `.cursor/skills` copy.
#
# Bash 3.2 safe. No associative arrays. No mapfile. Writes nothing to
# stderr on the success path of the helpers below.

# shellcheck disable=SC2039

_cursor_skills_read_frontmatter_name() {
  local skill_md="$1"
  [ -f "$skill_md" ] || return 1
  # First YAML block only.
  awk '
    BEGIN { in_fm = 0; found = 0 }
    /^---$/ {
      if (in_fm) exit
      in_fm = 1
      next
    }
    in_fm && $0 ~ /^name:[[:space:]]*/ {
      sub(/^name:[[:space:]]*/, "")
      sub(/[[:space:]]*$/, "")
      if (length($0) > 0) {
        print
        found = 1
        exit
      }
    }
    END { exit found ? 0 : 1 }
  ' "$skill_md"
}

_cursor_skills_entry_name() {
  local skill_md="$1"
  local dir base name
  name=$(_cursor_skills_read_frontmatter_name "$skill_md" 2>/dev/null) || name=""
  if [ -n "$name" ]; then
    printf '%s\n' "$name"
    return 0
  fi
  dir=$(dirname "$skill_md")
  base=$(basename "$dir")
  base=$(printf '%s' "$base" | sed 's/\.framework\.bak$//')
  printf '%s\n' "$base"
}

_cursor_skills_emit_dir() {
  local root="$1"
  local kind="$2"
  local d skill_md name
  [ -d "$root" ] || return 0
  for d in "$root"/*/; do
    [ -d "$d" ] || continue
    skill_md="${d}SKILL.md"
    [ -f "$skill_md" ] || continue
    name=$(_cursor_skills_entry_name "$skill_md")
    [ -n "$name" ] || continue
    # path<TAB>name<TAB>kind
    printf '%s\t%s\t%s\n' "$skill_md" "$name" "$kind"
  done
}

# Print raw discoveries: path<TAB>name<TAB>kind
# kind values: claude-skills | cursor-skills | custom-skills
cursor_skills_discover() {
  local workspace="$1"
  local child
  workspace=$(cd "$workspace" 2>/dev/null && pwd -P) || return 1

  _cursor_skills_emit_dir "$workspace/.claude/skills" "claude-skills"
  _cursor_skills_emit_dir "$workspace/.cursor/skills" "cursor-skills"
  _cursor_skills_emit_dir "$workspace/custom-skills" "custom-skills"

  # Parent-directory workspace: sibling repos with custom-skills/.
  for child in "$workspace"/*/; do
    [ -d "$child" ] || continue
    _cursor_skills_emit_dir "${child}custom-skills" "custom-skills"
  done
}

# Priority for override-wins unique selection (lower = better).
_cursor_skills_kind_rank() {
  local path="$1"
  local kind="$2"
  local base
  base=$(basename "$(dirname "$path")")
  case "$base" in
    *.framework.bak) printf '90\n'; return 0 ;;
  esac
  case "$kind" in
    claude-skills) printf '10\n' ;;
    cursor-skills) printf '20\n' ;;
    custom-skills) printf '30\n' ;;
    *) printf '50\n' ;;
  esac
}

# Print unique winners: path<TAB>name (override wins).
cursor_skills_unique() {
  local workspace="$1"
  local tmp sorted path name kind rank
  tmp=$(mktemp "${TMPDIR:-/tmp}/cursor-skills.XXXXXX")
  cursor_skills_discover "$workspace" > "$tmp" || {
    rm -f "$tmp"
    return 1
  }

  # Decorate with rank, sort by name then rank, keep first per name.
  sorted=$(mktemp "${TMPDIR:-/tmp}/cursor-skills-sorted.XXXXXX")
  while IFS="$(printf '\t')" read -r path name kind; do
    [ -n "$name" ] || continue
    rank=$(_cursor_skills_kind_rank "$path" "$kind")
    printf '%s\t%s\t%s\t%s\n' "$name" "$rank" "$path" "$kind"
  done < "$tmp" | sort -t "$(printf '\t')" -k1,1 -k2,2n > "$sorted"

  awk -F '\t' '
    NF >= 3 {
      if ($1 != prev) {
        printf "%s\t%s\n", $3, $1
        prev = $1
      }
    }
  ' "$sorted"

  rm -f "$tmp" "$sorted"
}

# Print duplicate skill names (one per line). Exit 1 when any exist.
cursor_skills_duplicate_names() {
  local workspace="$1"
  local tmp dups
  tmp=$(mktemp "${TMPDIR:-/tmp}/cursor-skills.XXXXXX")
  cursor_skills_discover "$workspace" > "$tmp" || {
    rm -f "$tmp"
    return 1
  }

  dups=$(awk -F '\t' 'NF >= 2 { print $2 }' "$tmp" | sort | uniq -d)
  rm -f "$tmp"
  if [ -n "$dups" ]; then
    printf '%s\n' "$dups"
    return 1
  fi
  return 0
}

# True when workspace looks like a parent that holds a fork + custom-skills.
cursor_skills_parent_workspace_risk() {
  local workspace="$1"
  local child has_fork has_custom
  workspace=$(cd "$workspace" 2>/dev/null && pwd -P) || return 1
  has_fork=0
  has_custom=0

  if [ -d "$workspace/custom-skills" ]; then
    has_custom=1
  fi

  for child in "$workspace"/*/; do
    [ -d "$child" ] || continue
    if [ -f "${child}.apexyard-fork" ] \
      || { [ -f "${child}onboarding.yaml" ] && [ -f "${child}apexyard.projects.yaml" ]; }; then
      has_fork=1
    fi
    if [ -d "${child}custom-skills" ]; then
      has_custom=1
    fi
  done

  [ "$has_fork" -eq 1 ] && [ "$has_custom" -eq 1 ]
}
