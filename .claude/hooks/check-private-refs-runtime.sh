#!/bin/bash
# Checks resolved tracker-wrapper values for private portfolio references.

set -u

repo="${1:-}"
text="${2:-}"
body_file="${3:-}"
[ -n "$repo" ] || exit 2

hook_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ops_root=$(cd "$hook_dir/../.." && pwd)
cd "$ops_root" || exit 2

public_repos="me2resh/apexyard"
if [ -f "$hook_dir/_lib-read-config.sh" ]; then
  # shellcheck source=/dev/null
  . "$hook_dir/_lib-read-config.sh"
  configured=$(config_get '.leak_protection.public_framework_repos[]' 2>/dev/null | tr '\n' ' ')
  [ -n "$configured" ] && public_repos="$configured"
fi
# #1477 — snapshot the configured public list BEFORE appending upstream.
# Origin identity exemptions may use only this proven list (or a registry
# public:true match). Auto-appending upstream would circularly "prove"
# any upstream public and reopen the private-origin exemption.
known_public_repos="$public_repos"
origin=$(git remote get-url origin 2>/dev/null || true)
origin=$(printf '%s' "$origin" | sed -nE 's|.*github\.com[:/]([^/]+/[^/]+)(\.git)?$|\1|p' | sed 's/\.git$//')
origin_name=${origin##*/}
origin_owner=${origin%%/*}
upstream=$(git remote get-url upstream 2>/dev/null || true)
upstream=$(printf '%s' "$upstream" | sed -nE 's|.*github\.com[:/]([^/]+/[^/]+)(\.git)?$|\1|p' | sed 's/\.git$//')
[ -n "$upstream" ] && public_repos="$public_repos $upstream"
upstream_name=${upstream##*/}
upstream_owner=${upstream%%/*}

# #1477 — origin identity (slug, bare name, owner login) is exempt only when
# offline proof says origin is public or a fork of a public repo. Keep in
# parity with check-private-refs-staged.sh. Fail closed otherwise.
origin_identity_exempt=0
if [ -n "$origin" ]; then
  for known in $known_public_repos; do
    if [ "$origin" = "$known" ]; then
      origin_identity_exempt=1
      break
    fi
  done
  if [ "$origin_identity_exempt" -eq 0 ] && [ -n "$upstream" ]; then
    for known in $known_public_repos; do
      if [ "$upstream" = "$known" ]; then
        origin_identity_exempt=1
        break
      fi
    done
  fi
fi

is_public=0
for public_repo in $public_repos; do
  [ "$repo" = "$public_repo" ] && is_public=1 && break
done
[ "$is_public" -eq 1 ] || exit 0

registry="$ops_root/apexyard.projects.yaml"
if [ -f "$hook_dir/_lib-portfolio-paths.sh" ]; then
  # shellcheck source=/dev/null
  . "$hook_dir/_lib-portfolio-paths.sh"
  resolved_registry=$(portfolio_registry 2>/dev/null || true)
  [ -n "$resolved_registry" ] && registry="$resolved_registry"
fi
[ -f "$registry" ] || exit 0

if [ -n "$body_file" ] && [ ! -f "$body_file" ]; then
  echo "BLOCKED: tracker wrapper body file cannot be read for private-reference scanning." >&2
  exit 2
fi
haystack="$text"
if [ -n "$body_file" ]; then
  body_content=$(cat "$body_file") || {
    echo "BLOCKED: tracker wrapper body file cannot be read for private-reference scanning." >&2
    exit 2
  }
  haystack="$(printf '%s\n%s' "$haystack" "$body_content")"
fi

escape_regex() { printf '%s' "$1" | LC_ALL=C sed -E 's/[][\\/.^$*+?(){}|#]/\\&/g'; }
block() {
  echo "BLOCKED: tracker wrapper content contains a private portfolio reference. The matched identifier is intentionally withheld." >&2
  exit 2
}

haystack_matches() {
  local regex="$1" case_sensitive="$2" rc
  if [ "$case_sensitive" = "1" ]; then
    printf '%s' "$haystack" | LC_ALL=C grep -qE "$regex"
  else
    printf '%s' "$haystack" | LC_ALL=C grep -qiE "$regex"
  fi
  rc=$?
  [ "$rc" -gt 1 ] && block
  [ "$rc" -eq 0 ]
}

if [ -f "$hook_dir/_lib-registry-parser.sh" ]; then
  # shellcheck source=/dev/null
  . "$hook_dir/_lib-registry-parser.sh"
fi

# apexyard#1457 review round 2 (Rex B1 / Hakim HIGH-2) — fail closed if the
# shared parser is missing or its parse fails; never treat that as "no
# registered projects".
if ! declare -F registry_parse_entries >/dev/null 2>&1; then
  echo "BLOCKED: shared registry parser (_lib-registry-parser.sh) is missing or failed to load. Cannot safely scan tracker-wrapper content for a private portfolio reference." >&2
  exit 2
fi
registry_parsed=$(registry_parse_entries "$registry" runtime)
registry_parse_rc=$?
if [ "$registry_parse_rc" -ne 0 ]; then
  echo "BLOCKED: registry parse failed (exit $registry_parse_rc) while scanning tracker-wrapper content for a private portfolio reference." >&2
  exit 2
fi

# apexyard#1457 review round 3 (Hakim MEDIUM, elevated to blocking) — a
# registry that plainly looks like it registers projects (a `projects:`
# key AND at least one `name:` key) but produced zero tokens means the
# parse missed a shape, not that nothing is registered. Fail closed.
if ! printf '%s\n' "$registry_parsed" | grep -qE '^(NAME|REPO|WORKSPACE)='; then
  if registry_has_project_shape "$registry"; then
    echo "BLOCKED: registry parse produced no tokens despite a projects: key and a name: key being present in $registry. Cannot safely scan tracker-wrapper content for a private portfolio reference." >&2
    exit 2
  fi
fi

# PAIR records bind a registered name to its own repo. A name equal to the
# upstream bare name is safe only when that entry actually names upstream.
registry_name_repo_matches() {
  local target_name="$1" target_repo="$2" entry
  while IFS= read -r entry; do
    [ "$entry" = "PAIR=${target_name}"$'\t'"${target_repo}" ] && return 0
  done <<EOF
$registry_parsed
EOF
  return 1
}

# Ignore an owner login only in @owner or owner/repo form. A standalone
# mention of the same registered name remains a private reference.
owner_bare_mention_remains() {
  local owner_name="$1" escaped lowered stripped rc
  escaped=$(printf '%s' "$owner_name" | LC_ALL=C tr '[:upper:]' '[:lower:]')
  rc=$?
  [ "$rc" -eq 0 ] || return 0
  escaped=$(escape_regex "$escaped")
  rc=$?
  [ "$rc" -eq 0 ] || return 0
  lowered=$(printf '%s' "$haystack" | LC_ALL=C tr '[:upper:]' '[:lower:]')
  rc=$?
  [ "$rc" -eq 0 ] || return 0
  stripped=$(printf '%s' "$lowered" | LC_ALL=C sed -E \
    -e "s/@${escaped}([^A-Za-z0-9_-]|\$)/\\1/g" \
    -e "s#(^|[^A-Za-z0-9_-])${escaped}/[a-z0-9_-]+#\\1#g")
  rc=$?
  [ "$rc" -eq 0 ] || return 0
  printf '%s' "$stripped" | LC_ALL=C grep -qE "(^|[^A-Za-z0-9_])${escaped}([^A-Za-z0-9_]|\$)"
  rc=$?
  [ "$rc" -eq 1 ] && return 1
  return 0
}

current_public=0
# First pass: a registry public:true entry whose repo equals origin also
# proves origin is public (#1477). Must run before the scrub loop so a
# later private token that shares the origin owner login is still scrubbed.
while IFS= read -r entry; do
  case "$entry" in
    PUBLIC=*)
      current_public=${entry#PUBLIC=}
      ;;
    REPO=*)
      if [ "$current_public" = "1" ] && [ "$origin_identity_exempt" -eq 0 ] \
        && [ -n "$origin" ] && [ "${entry#REPO=}" = "$origin" ]; then
        origin_identity_exempt=1
      fi
      ;;
  esac
done <<EOF
$registry_parsed
EOF

current_public=0
while IFS= read -r entry; do
  case "$entry" in
    PUBLIC=*)
      current_public=${entry#PUBLIC=}
      ;;
    NAME=*)
      [ "$current_public" = "1" ] && continue
      token=${entry#NAME=}; [ -n "$token" ] || continue
      if [ "$origin_identity_exempt" -eq 1 ] && [ "$token" = "$origin_name" ]; then
        continue
      fi
      if [ "$token" = "$upstream_name" ] && [ -n "$upstream" ] \
        && registry_name_repo_matches "$token" "$upstream"; then
        continue
      fi
      # Preserve the existing target-name exemption for configured public
      # repos other than upstream. Upstream requires the registry pairing.
      if [ "$token" = "${repo##*/}" ] && [ "$repo" != "$upstream" ]; then
        continue
      fi
      if { [ "$origin_identity_exempt" -eq 1 ] && [ "$token" = "$origin_owner" ]; } \
        || [ "$token" = "$upstream_owner" ] \
        || [ "$token" = "${repo%%/*}" ]; then
        owner_bare_mention_remains "$token" || continue
      fi
      escaped=$(escape_regex "$token") || block
      haystack_matches "(^|[^[:alnum:]_])${escaped}([^[:alnum:]_]|$)" 0 && block
      ;;
    REPO=*)
      [ "$current_public" = "1" ] && continue
      token=${entry#REPO=}; [ -n "$token" ] || continue
      [ "$token" = "$repo" ] && continue
      if [ "$origin_identity_exempt" -eq 1 ] && [ "$token" = "$origin" ]; then
        continue
      fi
      [ -n "$upstream" ] && [ "$token" = "$upstream" ] && continue
      escaped=$(escape_regex "$token") || block
      haystack_matches "(^|[^A-Za-z0-9_-])${escaped}(#[0-9]+)?([^A-Za-z0-9_-]|$)" 0 && block
      ;;
    WORKSPACE=*)
      [ "$current_public" = "1" ] && continue
      token=${entry#WORKSPACE=}; [ -n "$token" ] || continue
      escaped=$(escape_regex "$token") || block
      haystack_matches "(^|[^A-Za-z0-9_-])${escaped}([^A-Za-z0-9_-]|$)" 1 && block
      ;;
  esac
done <<EOF
$registry_parsed
EOF

exit 0
