#!/usr/bin/env bash
# Shared helpers for bin/kb-* scripts. Source this file. Do not execute it.
# Bash 3.2 safe. No associative arrays. Portable date and hash helpers.

set -u

# Resolve repo root from --root args or git. Echoes the absolute path.
# Usage: root=$(kb_resolve_root "$@") then shift past --root if present via kb_strip_root.
kb_resolve_root() {
  local root=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --root)
        if [ $# -lt 2 ]; then
          echo "kb: --root needs a directory" >&2
          return 2
        fi
        root=$2
        shift 2
        ;;
      --root=*)
        root=${1#--root=}
        shift
        ;;
      *)
        shift
        ;;
    esac
  done
  if [ -n "$root" ]; then
    # Absolute path without relying on readlink -f (macOS).
    (cd "$root" && pwd)
    return
  fi
  git rev-parse --show-toplevel
}

# Print remaining argv with --root / --root=DIR removed.
kb_strip_root() {
  local out=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --root)
        shift
        if [ $# -gt 0 ]; then shift; fi
        ;;
      --root=*)
        shift
        ;;
      *)
        out[${#out[@]}]=$1
        shift
        ;;
    esac
  done
  if [ ${#out[@]} -eq 0 ]; then
    return 0
  fi
  printf '%s\n' "${out[@]}"
}

kb_sha256() {
  local f=$1
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$f" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$f" | awk '{print $1}'
  else
    echo "kb: need shasum or sha256sum" >&2
    return 1
  fi
}

kb_today() {
  date +%Y-%m-%d
}

# Add N days to YYYY-MM-DD. Works with BSD date and GNU date.
kb_add_days() {
  local base=$1 n=$2 out
  if out=$(date -j -v+"${n}d" -f '%Y-%m-%d' "$base" +%Y-%m-%d 2>/dev/null); then
    printf '%s\n' "$out"
    return 0
  fi
  if out=$(date -d "$base +${n} days" +%Y-%m-%d 2>/dev/null); then
    printf '%s\n' "$out"
    return 0
  fi
  echo "kb: cannot add days (need BSD or GNU date)" >&2
  return 1
}

# Epoch seconds for YYYY-MM-DD at local midnight.
kb_date_epoch() {
  local d=$1 out
  if out=$(date -j -f '%Y-%m-%d' "$d" +%s 2>/dev/null); then
    printf '%s\n' "$out"
    return 0
  fi
  if out=$(date -d "$d" +%s 2>/dev/null); then
    printf '%s\n' "$out"
    return 0
  fi
  return 1
}

# Days from date A to date B (B - A). Both YYYY-MM-DD.
kb_days_between() {
  local a=$1 b=$2 ea eb
  ea=$(kb_date_epoch "$a") || return 1
  eb=$(kb_date_epoch "$b") || return 1
  printf '%s\n' $(( (eb - ea) / 86400 ))
}

# Author name for a path. Falls back to GIT_AUTHOR_IDENT name or unknown.
kb_file_author() {
  local root=$1 rel=$2 name ident
  name=$(git -C "$root" log -1 --format='%an' -- "$rel" 2>/dev/null || true)
  if [ -n "$name" ]; then
    printf '%s\n' "$name"
    return 0
  fi
  ident=$(git -C "$root" var GIT_AUTHOR_IDENT 2>/dev/null || true)
  if [ -n "$ident" ]; then
    # "Name <email> epoch tz"
    printf '%s\n' "$ident" | awk '{
      sub(/ <[^>]*>.*/, "")
      print
    }'
    return 0
  fi
  printf '%s\n' "unknown"
}

# Commit date YYYY-MM-DD for a path, or today when no commit.
kb_file_commit_date() {
  local root=$1 rel=$2 d
  d=$(git -C "$root" log -1 --format='%cs' -- "$rel" 2>/dev/null || true)
  if [ -n "$d" ]; then
    printf '%s\n' "$d"
    return 0
  fi
  kb_today
}

# True (0) when file starts with a YAML front matter block.
kb_has_front_matter() {
  local f=$1
  awk 'NR==1 { if ($0 ~ /^---[[:space:]]*$/) exit 0; exit 1 }' "$f"
}

# Print interior of leading front matter (no --- lines). Empty if none.
kb_front_matter_body() {
  local f=$1
  awk '
    BEGIN { in_fm = 0 }
    NR == 1 && /^---[[:space:]]*$/ { in_fm = 1; next }
    in_fm && /^---[[:space:]]*$/ { exit }
    in_fm { print }
  ' "$f"
}

# Print body after front matter. If no FM, print whole file.
kb_body_after_front_matter() {
  local f=$1
  awk '
    BEGIN { in_fm = 0; done = 0; saw = 0 }
    NR == 1 && /^---[[:space:]]*$/ { in_fm = 1; saw = 1; next }
    in_fm && /^---[[:space:]]*$/ { in_fm = 0; done = 1; next }
    in_fm { next }
    done || !saw { print }
  ' "$f"
}

# Return 0 if key is present as a top-level FM key.
kb_fm_has_key() {
  local body=$1 key=$2
  printf '%s\n' "$body" | awk -v k="$key" '
    BEGIN { found = 0 }
    $0 ~ ("^" k ":") { found = 1; exit }
    END { exit (found ? 0 : 1) }
  '
}

# Scalar value for key: value. Strips one layer of quotes. Empty if missing.
kb_fm_scalar() {
  local body=$1 key=$2
  printf '%s\n' "$body" | awk -v k="$key" '
    $0 ~ ("^" k ":") {
      line = $0
      sub("^" k ":", "", line)
      sub(/^[[:space:]]+/, "", line)
      sub(/[[:space:]]+$/, "", line)
      if (line ~ /^"/) {
        sub(/^"/, "", line)
        sub(/"$/, "", line)
      } else if (line ~ /^'\''/) {
        sub(/^'\''/, "", line)
        sub(/'\''$/, "", line)
      }
      print line
      exit
    }
  '
}

# Emit sources as JSON array from FM body. Default [].
kb_fm_sources_json() {
  local body=$1
  local line inline inner items
  if ! printf '%s\n' "$body" | grep -q '^sources:'; then
    printf '%s\n' '[]'
    return 0
  fi
  line=$(printf '%s\n' "$body" | awk '/^sources:/ { print; exit }')
  inline=${line#sources:}
  inline=$(printf '%s' "$inline" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  if [ -n "$inline" ]; then
    if [ "$inline" = '[]' ]; then
      printf '%s\n' '[]'
      return 0
    fi
    # Strip [ ] then split on commas. Works for [a, b] and ["a", "b"].
    inner=$inline
    case "$inner" in
      \[*\])
        inner=${inner#\[}
        inner=${inner%\]}
        ;;
    esac
    items=$(printf '%s\n' "$inner" | awk -F',' '{
      for (i = 1; i <= NF; i++) {
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", $i)
        gsub(/^["'\'']|["'\'']$/, "", $i)
        if (length($i) > 0) print $i
      }
    }')
    if [ -z "$items" ]; then
      printf '%s\n' '[]'
      return 0
    fi
    printf '%s\n' "$items" | jq -R . | jq -s -c .
    return 0
  fi
  # Block list under sources:
  items=$(printf '%s\n' "$body" | awk '
    BEGIN { take = 0 }
    /^sources:[[:space:]]*$/ { take = 1; next }
    take && /^[^[:space:]-]/ { exit }
    take && /^[[:space:]]*-[[:space:]]*/ {
      line = $0
      sub(/^[[:space:]]*-[[:space:]]*/, "", line)
      gsub(/^"/, "", line)
      gsub(/"$/, "", line)
      print line
    }
  ')
  if [ -z "$items" ]; then
    printf '%s\n' '[]'
    return 0
  fi
  printf '%s\n' "$items" | jq -R . | jq -s -c .
}

# First markdown H1 title, or fallback.
kb_md_title() {
  local f=$1 fallback=$2 title
  title=$(awk '/^# / { sub(/^# /,""); print; exit }' "$f")
  if [ -n "$title" ]; then
    printf '%s\n' "$title"
  else
    printf '%s\n' "$fallback"
  fi
}

# Fill default KB fields for a source path. Sets globals:
#   KB_OWNER KB_VERIFIED_BY KB_VERIFIED_ON KB_STALE_AFTER KB_SOURCES_JSON
#   KB_VERSION KB_STATUS KB_TITLE
# kind=handbook|rule|agdr|orbit
# shellcheck disable=SC2034
kb_apply_defaults() {
  local root=$1 rel=$2 kind=$3 abspath=$4
  local body author vdate agent title_fb
  body=""
  if kb_has_front_matter "$abspath"; then
    body=$(kb_front_matter_body "$abspath")
  fi

  author=$(kb_file_author "$root" "$rel")
  vdate=$(kb_file_commit_date "$root" "$rel")

  KB_OWNER=$(kb_fm_scalar "$body" "owner")
  if [ -z "$KB_OWNER" ]; then
    if [ "$kind" = "agdr" ] || [ "$kind" = "orbit" ]; then
      agent=$(kb_fm_scalar "$body" "agent")
      if [ -n "$agent" ]; then
        KB_OWNER=$agent
      else
        KB_OWNER=$author
      fi
    else
      KB_OWNER=$author
    fi
  fi

  KB_VERIFIED_BY=$(kb_fm_scalar "$body" "verified_by")
  if [ -z "$KB_VERIFIED_BY" ]; then
    KB_VERIFIED_BY=$author
  fi

  KB_VERIFIED_ON=$(kb_fm_scalar "$body" "verified_on")
  if [ -z "$KB_VERIFIED_ON" ]; then
    KB_VERIFIED_ON=$vdate
  fi

  KB_STALE_AFTER=$(kb_fm_scalar "$body" "stale_after")
  if [ "$kind" = "agdr" ] || [ "$kind" = "orbit" ]; then
    KB_STALE_AFTER=""
  elif [ -z "$KB_STALE_AFTER" ]; then
    KB_STALE_AFTER=$(kb_add_days "$KB_VERIFIED_ON" 180)
  fi

  if kb_fm_has_key "$body" "sources"; then
    KB_SOURCES_JSON=$(kb_fm_sources_json "$body")
  else
    KB_SOURCES_JSON='[]'
  fi

  KB_VERSION=$(kb_fm_scalar "$body" "version")
  if [ -z "$KB_VERSION" ]; then
    KB_VERSION=1
  fi

  KB_STATUS=$(kb_fm_scalar "$body" "status")
  if [ -z "$KB_STATUS" ]; then
    KB_STATUS=active
  fi

  title_fb=$(basename "$rel")
  title_fb=${title_fb%.*}
  case "$rel" in
    *.json)
      KB_TITLE=$(jq -r '.id // .title // empty' "$abspath" 2>/dev/null || true)
      if [ -z "$KB_TITLE" ] || [ "$KB_TITLE" = "null" ]; then
        KB_TITLE=$title_fb
      fi
      ;;
    *)
      KB_TITLE=$(kb_md_title "$abspath" "$title_fb")
      ;;
  esac
}

# Schema keys the migrate step must ensure.
KB_SCHEMA_KEYS="owner verified_by verified_on stale_after sources version status"

# Build default lines for missing schema keys. Echoes lines to append to FM.
kb_missing_schema_lines() {
  local root=$1 rel=$2 body=$3
  local author vdate stale line key
  author=$(kb_file_author "$root" "$rel")
  vdate=$(kb_file_commit_date "$root" "$rel")
  stale=$(kb_add_days "$vdate" 180)

  for key in $KB_SCHEMA_KEYS; do
    if kb_fm_has_key "$body" "$key"; then
      continue
    fi
    case "$key" in
      owner)
        printf 'owner: %s\n' "$author"
        ;;
      verified_by)
        printf 'verified_by: %s\n' "$author"
        ;;
      verified_on)
        printf 'verified_on: %s\n' "$vdate"
        ;;
      stale_after)
        printf 'stale_after: %s\n' "$stale"
        ;;
      sources)
        printf 'sources: []\n'
        ;;
      version)
        printf 'version: 1\n'
        ;;
      status)
        printf 'status: active\n'
        ;;
    esac
  done
}

# True when body already has every schema key.
kb_fm_complete() {
  local body=$1 key
  for key in $KB_SCHEMA_KEYS; do
    if ! kb_fm_has_key "$body" "$key"; then
      return 1
    fi
  done
  return 0
}
