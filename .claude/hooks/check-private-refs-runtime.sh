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
upstream=$(git remote get-url upstream 2>/dev/null || true)
upstream=$(printf '%s' "$upstream" | sed -nE 's|.*github\.com[:/]([^/]+/[^/]+)(\.git)?$|\1|p' | sed 's/\.git$//')
[ -n "$upstream" ] && public_repos="$public_repos $upstream"

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
[ -n "$body_file" ] && haystack="$(printf '%s\n' "$haystack"; cat "$body_file")"

escape_regex() { printf '%s' "$1" | sed -E 's/[][\\/.^$*+?(){}|]/\\&/g'; }
block() {
  echo "BLOCKED: tracker wrapper content contains a private portfolio reference. The matched identifier is intentionally withheld." >&2
  exit 2
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

current_public=0
while IFS= read -r entry; do
  case "$entry" in
    PUBLIC=*)
      current_public=${entry#PUBLIC=}
      ;;
    NAME=*)
      [ "$current_public" = "1" ] && continue
      token=${entry#NAME=}; [ -n "$token" ] || continue
      [ "$token" = "${repo##*/}" ] && continue
      escaped=$(escape_regex "$token")
      printf '%s' "$haystack" | grep -qiE "(^|[^[:alnum:]_])${escaped}([^[:alnum:]_]|$)" && block
      ;;
    REPO=*)
      [ "$current_public" = "1" ] && continue
      token=${entry#REPO=}; [ -n "$token" ] || continue
      [ "$token" = "$repo" ] && continue
      escaped=$(escape_regex "$token")
      printf '%s' "$haystack" | grep -qiE "(^|[^A-Za-z0-9_/-])${escaped}(#[0-9]+)?([^A-Za-z0-9_/-]|$)" && block
      ;;
    WORKSPACE=*)
      [ "$current_public" = "1" ] && continue
      token=${entry#WORKSPACE=}; [ -n "$token" ] || continue
      escaped=$(escape_regex "$token")
      printf '%s' "$haystack" | grep -qE "(^|[^A-Za-z0-9_-])${escaped}([^A-Za-z0-9_-]|$)" && block
      ;;
  esac
done <<EOF
$registry_parsed
EOF

exit 0
