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

while IFS= read -r entry; do
  case "$entry" in
    NAME=*)
      token=${entry#NAME=}; [ -n "$token" ] || continue
      [ "$token" = "${repo##*/}" ] && continue
      escaped=$(escape_regex "$token")
      printf '%s' "$haystack" | grep -qiE "(^|[^[:alnum:]_])${escaped}([^[:alnum:]_]|$)" && block
      ;;
    REPO=*)
      token=${entry#REPO=}; [ -n "$token" ] || continue
      [ "$token" = "$repo" ] && continue
      escaped=$(escape_regex "$token")
      printf '%s' "$haystack" | grep -qiE "(^|[^A-Za-z0-9_/-])${escaped}(#[0-9]+)?([^A-Za-z0-9_/-]|$)" && block
      ;;
    WORKSPACE=*)
      token=${entry#WORKSPACE=}; [ -n "$token" ] || continue
      escaped=$(escape_regex "$token")
      printf '%s' "$haystack" | grep -qE "(^|[^A-Za-z0-9_-])${escaped}([^A-Za-z0-9_-]|$)" && block
      ;;
  esac
done < <(awk '
  function unquote(value) { gsub(/^['\''\"]|['\''\"]$/, "", value); return value }
  function emit_repos(value,    n, parts, i, item) {
    gsub(/^[[:space:]]*\[[[:space:]]*/, "", value)
    gsub(/[[:space:]]*\][[:space:]]*$/, "", value)
    n = split(value, parts, ",")
    for (i = 1; i <= n; i++) {
      item = unquote(parts[i])
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", item)
      if (item != "") print "REPO=" item
    }
  }
  in_repos = 0
  /^[[:space:]]*- name:/ { print "NAME=" unquote($3); next }
  /^[[:space:]]*repo:/ { print "REPO=" unquote($2); next }
  /^[[:space:]]*repos:[[:space:]]*\[/ {
    value = $0
    sub(/^[^:]*:[[:space:]]*/, "", value)
    emit_repos(value)
    in_repos = 0
    next
  }
  /^[[:space:]]*repos:[[:space:]]*$/ { in_repos = 1; next }
  in_repos && /^[[:space:]]*-[[:space:]]+/ {
    value = $0
    sub(/^[[:space:]]*-[[:space:]]*/, "", value)
    if (value !~ /^[[:alnum:]_.-]+:/) print "REPO=" unquote(value)
    next
  }
  /^[^[:space:]-]/ { in_repos = 0 }
  /^[[:space:]]*workspace:/ { print "WORKSPACE=" unquote($2); next }
' "$registry")

exit 0
