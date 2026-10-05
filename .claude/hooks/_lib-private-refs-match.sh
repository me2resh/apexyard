#!/bin/bash
# _lib-private-refs-match.sh — shared private-portfolio identifier matcher
# for the staged commit gate and the push-time leak scan (#1528 / AgDR-0220).
#
# Semantics match check-private-refs-staged.sh exactly:
#   - registered names, repo slugs, workspace paths
#   - public: true entries exempt
#   - whole-haystack, case-insensitive word-boundary match
#   - origin identity exemptions require offline public proof (#1477)
#   - upstream citation exemptions (#1431)
#   - owner-login bare-mention rules (#1400 / #1431)
#
# Callers:
#   private_refs_match_init
#     Load registry + remotes into globals. Exit codes via
#     PRIVATE_REFS_MATCH_INIT_RC: 0=ready, 1=nothing to scan, 2=fail-closed.
#   private_refs_match_text_file <path>
#     Return 0 if the file content matches a private identifier.
#   private_refs_match_staged_blob <index-path>
#     Return 0 if `git show :<path>` matches a private identifier.

# shellcheck disable=SC2034

PRIVATE_REFS_MATCH_INIT_RC=0

private_refs_escape_regex() {
  printf '%s' "$1" | sed -E 's/[][\\/.^$*+?(){}|]/\\&/g'
}

private_refs_match_init() {
  PRIVATE_REFS_MATCH_INIT_RC=0
  PRIVATE_REFS_NAMES=()
  PRIVATE_REFS_NAMES_PUBLIC=()
  PRIVATE_REFS_REPOS=()
  PRIVATE_REFS_REPOS_PUBLIC=()
  PRIVATE_REFS_WORKSPACES=()
  PRIVATE_REFS_WORKSPACES_PUBLIC=()
  PRIVATE_REFS_NAME_REPO_PAIRS=()
  PRIVATE_REFS_ORIGIN_IDENTITY_EXEMPT=0
  PRIVATE_REFS_CURRENT_REPO=""
  PRIVATE_REFS_CURRENT_NAME=""
  PRIVATE_REFS_CURRENT_OWNER=""
  PRIVATE_REFS_UPSTREAM_REPO=""
  PRIVATE_REFS_UPSTREAM_NAME=""
  PRIVATE_REFS_UPSTREAM_OWNER=""
  PRIVATE_REFS_REGISTRY_REL=""

  local root hook_dir registry origin_url known_public_repos
  local origin_verified_public upstream_url configured
  local registry_parsed registry_parse_rc current_public entry
  local resolved_registry

  root=$(git rev-parse --show-toplevel 2>/dev/null) || {
    PRIVATE_REFS_MATCH_INIT_RC=2
    return 2
  }
  hook_dir="$root/.claude/hooks"
  registry="$root/apexyard.projects.yaml"
  if [ -f "$hook_dir/_lib-portfolio-paths.sh" ]; then
    # shellcheck source=/dev/null
    . "$hook_dir/_lib-portfolio-paths.sh"
    resolved_registry=$(portfolio_registry 2>/dev/null || true)
    [ -n "$resolved_registry" ] && registry="$resolved_registry"
  fi

  if [ ! -f "$registry" ]; then
    PRIVATE_REFS_MATCH_INIT_RC=1
    return 1
  fi

  origin_url=$(git remote get-url origin 2>/dev/null || true)
  PRIVATE_REFS_CURRENT_REPO=$(printf '%s' "$origin_url" | sed -nE 's|.*github\.com[:/]([^/]+/[^/]+)(\.git)?$|\1|p' | sed 's/\.git$//')
  PRIVATE_REFS_CURRENT_NAME=${PRIVATE_REFS_CURRENT_REPO##*/}
  PRIVATE_REFS_CURRENT_OWNER=${PRIVATE_REFS_CURRENT_REPO%%/*}

  known_public_repos="me2resh/apexyard"
  origin_verified_public=""
  if [ -f "$hook_dir/_lib-read-config.sh" ]; then
    # shellcheck source=/dev/null
    . "$hook_dir/_lib-read-config.sh"
    configured=$(config_get '.leak_protection.public_framework_repos[]' 2>/dev/null)
    [ -n "$configured" ] && known_public_repos="$configured"
    origin_verified_public=$(config_get_or '.leak_protection.origin_verified_public' '')
    origin_verified_public=$(printf '%s' "$origin_verified_public" | tr -d '[:space:]')
  fi

  upstream_url=$(git remote get-url upstream 2>/dev/null || true)
  if [ -n "$upstream_url" ]; then
    PRIVATE_REFS_UPSTREAM_REPO=$(printf '%s' "$upstream_url" | sed -nE 's|.*github\.com[:/]([^/]+/[^/]+)(\.git)?$|\1|p' | sed 's/\.git$//')
  fi
  if [ -n "$PRIVATE_REFS_UPSTREAM_REPO" ]; then
    PRIVATE_REFS_UPSTREAM_NAME=${PRIVATE_REFS_UPSTREAM_REPO##*/}
    PRIVATE_REFS_UPSTREAM_OWNER=${PRIVATE_REFS_UPSTREAM_REPO%%/*}
  fi

  PRIVATE_REFS_ORIGIN_IDENTITY_EXEMPT=0
  if [ -n "$PRIVATE_REFS_CURRENT_REPO" ]; then
    while IFS= read -r known; do
      [ -n "$known" ] || continue
      if [ "$PRIVATE_REFS_CURRENT_REPO" = "$known" ]; then
        PRIVATE_REFS_ORIGIN_IDENTITY_EXEMPT=1
        break
      fi
    done <<EOF
$known_public_repos
EOF
    if [ "$PRIVATE_REFS_ORIGIN_IDENTITY_EXEMPT" -eq 0 ] \
      && [ -n "$origin_verified_public" ] \
      && [ "$PRIVATE_REFS_CURRENT_REPO" = "$origin_verified_public" ]; then
      PRIVATE_REFS_ORIGIN_IDENTITY_EXEMPT=1
    fi
  fi

  if [ -f "$hook_dir/_lib-registry-parser.sh" ]; then
    # shellcheck source=/dev/null
    . "$hook_dir/_lib-registry-parser.sh"
  fi
  if ! declare -F registry_parse_entries >/dev/null 2>&1; then
    echo "BLOCKED: shared registry parser (_lib-registry-parser.sh) is missing or failed to load. Cannot safely scan for a private portfolio reference." >&2
    PRIVATE_REFS_MATCH_INIT_RC=2
    return 2
  fi
  registry_parsed=$(registry_parse_entries "$registry")
  registry_parse_rc=$?
  if [ "$registry_parse_rc" -ne 0 ]; then
    echo "BLOCKED: registry parse failed (exit $registry_parse_rc) while scanning for a private portfolio reference." >&2
    PRIVATE_REFS_MATCH_INIT_RC=2
    return 2
  fi

  current_public=0
  while IFS= read -r entry; do
    case "$entry" in
      PUBLIC=*) current_public=${entry#PUBLIC=} ;;
      NAME=*)
        PRIVATE_REFS_NAMES+=("${entry#NAME=}")
        PRIVATE_REFS_NAMES_PUBLIC+=("$current_public")
        ;;
      REPO=*)
        PRIVATE_REFS_REPOS+=("${entry#REPO=}")
        PRIVATE_REFS_REPOS_PUBLIC+=("$current_public")
        ;;
      WORKSPACE=*)
        PRIVATE_REFS_WORKSPACES+=("${entry#WORKSPACE=}")
        PRIVATE_REFS_WORKSPACES_PUBLIC+=("$current_public")
        ;;
      PAIR=*)
        PRIVATE_REFS_NAME_REPO_PAIRS+=("${entry#PAIR=}")
        ;;
    esac
  done <<EOF
$registry_parsed
EOF

  if [ "${#PRIVATE_REFS_NAMES[@]}" -eq 0 ] && [ "${#PRIVATE_REFS_REPOS[@]}" -eq 0 ] && [ "${#PRIVATE_REFS_WORKSPACES[@]}" -eq 0 ]; then
    if declare -F registry_has_project_shape >/dev/null 2>&1 && registry_has_project_shape "$registry"; then
      echo "BLOCKED: registry parse produced no tokens despite a projects: key and a name: key being present in $registry. Cannot safely scan for a private portfolio reference." >&2
      PRIVATE_REFS_MATCH_INIT_RC=2
      return 2
    fi
    PRIVATE_REFS_MATCH_INIT_RC=1
    return 1
  fi

  if [ "$PRIVATE_REFS_ORIGIN_IDENTITY_EXEMPT" -eq 0 ] && [ -n "$PRIVATE_REFS_CURRENT_REPO" ]; then
    local idx
    for idx in "${!PRIVATE_REFS_REPOS[@]}"; do
      if [ "${PRIVATE_REFS_REPOS_PUBLIC[$idx]}" = "1" ] && [ "${PRIVATE_REFS_REPOS[$idx]}" = "$PRIVATE_REFS_CURRENT_REPO" ]; then
        PRIVATE_REFS_ORIGIN_IDENTITY_EXEMPT=1
        break
      fi
    done
  fi

  case "$registry" in
    "$root"/*) PRIVATE_REFS_REGISTRY_REL=${registry#"$root"/} ;;
  esac

  PRIVATE_REFS_MATCH_INIT_RC=0
  return 0
}

_private_refs_name_repo_matches() {
  local target_name="$1" target_repo="$2" pair
  [ "${#PRIVATE_REFS_NAME_REPO_PAIRS[@]}" -gt 0 ] || return 1
  for pair in "${PRIVATE_REFS_NAME_REPO_PAIRS[@]}"; do
    [ "$pair" = "${target_name}"$'\t'"${target_repo}" ] && return 0
  done
  return 1
}

# Fail closed: any pipeline error returns 0 ("bare mention remains").
_private_refs_owner_bare_mention_remains_stream() {
  local owner_name="$1"
  local content esc_lc haystack_lc stripped_lc rc

  content=$(cat)
  rc=$?
  [ "$rc" -eq 0 ] || return 0

  esc_lc=$(printf '%s' "$owner_name" | LC_ALL=C tr '[:upper:]' '[:lower:]')
  rc=$?
  [ "$rc" -eq 0 ] || return 0
  esc_lc=$(printf '%s' "$esc_lc" | LC_ALL=C sed -E 's/[][\\/.^$*+?(){}|#]/\\&/g')
  rc=$?
  [ "$rc" -eq 0 ] || return 0

  haystack_lc=$(printf '%s' "$content" | LC_ALL=C tr '[:upper:]' '[:lower:]')
  rc=$?
  [ "$rc" -eq 0 ] || return 0

  stripped_lc=$(printf '%s' "$haystack_lc" | LC_ALL=C sed -E \
    -e "s/@${esc_lc}([^A-Za-z0-9_-]|\$)/\\1/g" \
    -e "s#(^|[^A-Za-z0-9_-])${esc_lc}/[a-z0-9_-]+#\\1#g")
  rc=$?
  [ "$rc" -eq 0 ] || return 0

  printf '%s' "$stripped_lc" | LC_ALL=C grep -qE "(^|[^A-Za-z0-9_])${esc_lc}([^A-Za-z0-9_]|\$)"
  rc=$?
  [ "$rc" -eq 1 ] && return 1
  return 0
}

_private_refs_stream_matches_regex() {
  local regex="$1"
  LC_ALL=C grep -qiE "$regex"
}

# Scan stdin haystack. Return 0 on a private-ref match.
_private_refs_match_stream() {
  local idx name repo workspace escaped
  local tmp
  tmp=$(mktemp -t private-refs-match.XXXXXX) || return 0
  cat > "$tmp"

  for idx in "${!PRIVATE_REFS_NAMES[@]}"; do
    name="${PRIVATE_REFS_NAMES[$idx]}"
    [ -n "$name" ] || continue
    [ "${PRIVATE_REFS_NAMES_PUBLIC[$idx]}" = "1" ] && continue
    if [ "$PRIVATE_REFS_ORIGIN_IDENTITY_EXEMPT" -eq 1 ] && [ "$name" = "$PRIVATE_REFS_CURRENT_NAME" ]; then
      continue
    fi
    if [ -n "$PRIVATE_REFS_UPSTREAM_NAME" ] && [ "$name" = "$PRIVATE_REFS_UPSTREAM_NAME" ] \
      && _private_refs_name_repo_matches "$name" "$PRIVATE_REFS_UPSTREAM_REPO"; then
      continue
    fi

    if { [ "$PRIVATE_REFS_ORIGIN_IDENTITY_EXEMPT" -eq 1 ] && [ "$name" = "$PRIVATE_REFS_CURRENT_OWNER" ]; } \
      || { [ -n "$PRIVATE_REFS_UPSTREAM_OWNER" ] && [ "$name" = "$PRIVATE_REFS_UPSTREAM_OWNER" ]; }; then
      if ! _private_refs_owner_bare_mention_remains_stream "$name" < "$tmp"; then
        continue
      fi
    fi

    escaped=$(private_refs_escape_regex "$name")
    if _private_refs_stream_matches_regex "(^|[^[:alnum:]_])${escaped}([^[:alnum:]_]|$)" < "$tmp"; then
      rm -f "$tmp"
      return 0
    fi
  done

  for idx in "${!PRIVATE_REFS_REPOS[@]}"; do
    repo="${PRIVATE_REFS_REPOS[$idx]}"
    [ -n "$repo" ] || continue
    [ "${PRIVATE_REFS_REPOS_PUBLIC[$idx]}" = "1" ] && continue
    if [ "$PRIVATE_REFS_ORIGIN_IDENTITY_EXEMPT" -eq 1 ] && [ "$repo" = "$PRIVATE_REFS_CURRENT_REPO" ]; then
      continue
    fi
    [ -n "$PRIVATE_REFS_UPSTREAM_REPO" ] && [ "$repo" = "$PRIVATE_REFS_UPSTREAM_REPO" ] && continue
    escaped=$(private_refs_escape_regex "$repo")
    if _private_refs_stream_matches_regex "(^|[^A-Za-z0-9_-])${escaped}(#[0-9]+)?([^A-Za-z0-9_-]|$)" < "$tmp"; then
      rm -f "$tmp"
      return 0
    fi
  done

  for idx in "${!PRIVATE_REFS_WORKSPACES[@]}"; do
    workspace="${PRIVATE_REFS_WORKSPACES[$idx]}"
    [ -n "$workspace" ] || continue
    [ "${PRIVATE_REFS_WORKSPACES_PUBLIC[$idx]}" = "1" ] && continue
    escaped=$(private_refs_escape_regex "$workspace")
    if _private_refs_stream_matches_regex "(^|[^A-Za-z0-9_-])${escaped}([^A-Za-z0-9_-]|$)" < "$tmp"; then
      rm -f "$tmp"
      return 0
    fi
  done

  rm -f "$tmp"
  return 1
}

private_refs_match_text_file() {
  local path="$1"
  [ -f "$path" ] || return 1
  _private_refs_match_stream < "$path"
}

private_refs_match_staged_blob() {
  local path="$1"
  git show ":$path" 2>/dev/null | _private_refs_match_stream
}

# Write a fixed-string prefilter pattern file (one lowercase token per line;
# the caller lowercases the haystack with tr). Every real match of
# private_refs_match_text_file contains one of these tokens as a literal
# case-insensitive substring, so `grep -a -F -f` over a lowercased stream is a
# safe superset test: no hit means no match is possible.
# Returns 0 when the file holds tokens, 1 when there is nothing to look for
# (every entry is public: true), 2 on an I/O error. Callers must treat 2 as
# fail closed, never as "nothing to scan".
private_refs_write_prefilter() {
  local out="$1" idx tok
  : > "$out" || return 2
  for idx in "${!PRIVATE_REFS_NAMES[@]}"; do
    tok="${PRIVATE_REFS_NAMES[$idx]}"
    if [ -n "$tok" ] && [ "${PRIVATE_REFS_NAMES_PUBLIC[$idx]}" != "1" ]; then
      printf '%s\n' "$tok" >> "$out" || return 2
    fi
  done
  for idx in "${!PRIVATE_REFS_REPOS[@]}"; do
    tok="${PRIVATE_REFS_REPOS[$idx]}"
    if [ -n "$tok" ] && [ "${PRIVATE_REFS_REPOS_PUBLIC[$idx]}" != "1" ]; then
      printf '%s\n' "$tok" >> "$out" || return 2
    fi
  done
  for idx in "${!PRIVATE_REFS_WORKSPACES[@]}"; do
    tok="${PRIVATE_REFS_WORKSPACES[$idx]}"
    if [ -n "$tok" ] && [ "${PRIVATE_REFS_WORKSPACES_PUBLIC[$idx]}" != "1" ]; then
      printf '%s\n' "$tok" >> "$out" || return 2
    fi
  done
  [ -s "$out" ] || return 1
  LC_ALL=C tr 'A-Z' 'a-z' < "$out" > "$out.lc" || return 2
  mv "$out.lc" "$out" || return 2
  return 0
}

PRIVATE_REFS_MATCH_VERSION=2

# Print a hash of every input that decides a match: the registry tokens and
# their public flags, the name/repo pairs, the origin and upstream identity,
# the registry path, and the matcher version. A clean-scan record is valid
# only for the same hash, so a registry change invalidates it. Returns
# non-zero on failure.
private_refs_match_fingerprint() {
  local idx n
  {
    printf 'version\t%s\n' "$PRIVATE_REFS_MATCH_VERSION"
    for idx in "${!PRIVATE_REFS_NAMES[@]}"; do
      printf 'N\t%s\t%s\n' "${PRIVATE_REFS_NAMES[$idx]}" "${PRIVATE_REFS_NAMES_PUBLIC[$idx]}"
    done
    for idx in "${!PRIVATE_REFS_REPOS[@]}"; do
      printf 'R\t%s\t%s\n' "${PRIVATE_REFS_REPOS[$idx]}" "${PRIVATE_REFS_REPOS_PUBLIC[$idx]}"
    done
    for idx in "${!PRIVATE_REFS_WORKSPACES[@]}"; do
      printf 'W\t%s\t%s\n' "${PRIVATE_REFS_WORKSPACES[$idx]}" "${PRIVATE_REFS_WORKSPACES_PUBLIC[$idx]}"
    done
    n=${#PRIVATE_REFS_NAME_REPO_PAIRS[@]}
    idx=0
    while [ "$idx" -lt "$n" ]; do
      printf 'P\t%s\n' "${PRIVATE_REFS_NAME_REPO_PAIRS[$idx]}"
      idx=$((idx + 1))
    done
    printf 'E\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$PRIVATE_REFS_ORIGIN_IDENTITY_EXEMPT" "$PRIVATE_REFS_CURRENT_REPO" \
      "$PRIVATE_REFS_CURRENT_NAME" "$PRIVATE_REFS_CURRENT_OWNER" \
      "$PRIVATE_REFS_UPSTREAM_REPO" "$PRIVATE_REFS_UPSTREAM_NAME" \
      "$PRIVATE_REFS_UPSTREAM_OWNER" "$PRIVATE_REFS_REGISTRY_REL"
  } | git hash-object --stdin
}
