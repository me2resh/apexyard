#!/usr/bin/env bash
# Shared helpers for bin/kb-* scripts. Source this file. Do not execute it.
# Bash 3.2 safe. No associative arrays. Portable date helpers.

set -u


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


# Schema keys the migrate step must ensure.
KB_SCHEMA_KEYS="owner verified_by verified_on stale_after sources version status"

# Build default lines for missing schema keys. Echoes lines to append to FM.
kb_missing_schema_lines() {
  local root=$1 rel=$2 body=$3
  local author vdate stale key base_date
  author=$(kb_file_author "$root" "$rel")
  vdate=$(kb_file_commit_date "$root" "$rel")
  # stale_after counts from verified_on: the value in the file, else the commit date.
  base_date=$(kb_fm_scalar "$body" "verified_on")
  if [ -z "$base_date" ]; then
    base_date=$vdate
  fi
  stale=$(kb_add_days "$base_date" 180) || stale=$(kb_add_days "$vdate" 180)

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
