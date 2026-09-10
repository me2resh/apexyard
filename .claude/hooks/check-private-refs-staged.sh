#!/bin/bash
# Blocks a commit when a staged file contains a private portfolio identifier.
#
# Git invokes this from the repository that owns the index. The scanner reads
# indexed blobs, not a rendered diff, so it protects every commit version.

set -u

ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || {
  echo "BLOCKED: cannot resolve the Git root for the staged private-reference scan." >&2
  exit 2
}

HOOK_DIR="$ROOT/.claude/hooks"
REGISTRY="$ROOT/apexyard.projects.yaml"
if [ -f "$HOOK_DIR/_lib-portfolio-paths.sh" ]; then
  # shellcheck source=/dev/null
  . "$HOOK_DIR/_lib-portfolio-paths.sh"
  resolved_registry=$(portfolio_registry 2>/dev/null || true)
  [ -n "$resolved_registry" ] && REGISTRY="$resolved_registry"
fi

# A framework checkout without a private portfolio registry has no private
# identifier set to enforce. A split-portfolio registry can live outside this
# Git worktree and is still read through portfolio_registry above.
[ -f "$REGISTRY" ] || exit 0

current_repo=""
origin_url=$(git remote get-url origin 2>/dev/null || true)
current_repo=$(printf '%s' "$origin_url" | sed -nE 's|.*github\.com[:/]([^/]+/[^/]+)(\.git)?$|\1|p' | sed 's/\.git$//')
current_name=${current_repo##*/}

names=()
repos=()
workspaces=()
while IFS= read -r entry; do
  case "$entry" in
    NAME=*) names+=("${entry#NAME=}") ;;
    REPO=*) repos+=("${entry#REPO=}") ;;
    WORKSPACE=*) workspaces+=("${entry#WORKSPACE=}") ;;
  esac
done < <(awk '
  function unquote(value) { gsub(/^['\''\"]|['\''\"]$/, "", value); return value }
  /^[[:space:]]*- name:/ {
    print "NAME=" unquote($3); current_list = ""; next
  }
  /^[[:space:]]*repo:/ {
    print "REPO=" unquote($2); current_list = ""; next
  }
  /^[[:space:]]*workspace:/ {
    print "WORKSPACE=" unquote($2); current_list = ""; next
  }
  /^[[:space:]]*repos:[[:space:]]*\[/ {
    value = $0; sub(/^[^\[]*\[/, "", value); sub(/\].*$/, "", value)
    count = split(value, items, ",")
    for (i = 1; i <= count; i++) {
      item = items[i]; gsub(/^[[:space:]]+|[[:space:]]+$/, "", item)
      if (item != "") print "REPO=" unquote(item)
    }
    current_list = ""; next
  }
  /^[[:space:]]*repos:[[:space:]]*(#.*)?$/ { current_list = "repos"; next }
  /^[[:space:]]*[A-Za-z_][A-Za-z0-9_-]*:/ { current_list = ""; next }
  /^[[:space:]]*-[[:space:]]+/ {
    if (current_list == "repos") {
      value = $0; sub(/^[[:space:]]*-[[:space:]]+/, "", value)
      gsub(/[[:space:]]+$/, "", value); print "REPO=" unquote(value)
    }
  }
' "$REGISTRY")

[ "${#names[@]}" -gt 0 ] || [ "${#repos[@]}" -gt 0 ] || [ "${#workspaces[@]}" -gt 0 ] || exit 0

registry_rel=""
case "$REGISTRY" in
  "$ROOT"/*) registry_rel=${REGISTRY#"$ROOT"/} ;;
esac

escape_regex() {
  printf '%s' "$1" | sed -E 's/[][\\/.^$*+?(){}|]/\\&/g'
}

staged_blob_matches() {
  local path="$1" regex="$2"
  git show ":$path" 2>/dev/null | grep -qiE "$regex"
}

block() {
  local path="$1"
  cat >&2 <<MSG
BLOCKED: staged file content contains a private portfolio reference.

File: $path
The matched identifier is intentionally withheld. Replace it with an abstract
description, unstage the file, and retry. See .claude/rules/leak-protection.md
§ "Remediation" if the identifier has already reached a public repository.
MSG
  exit 2
}

while IFS= read -r -d '' path; do
  [ -n "$path" ] || continue
  [ "$path" = "$registry_rel" ] && continue
  git show ":$path" >/dev/null 2>&1 || continue

  for name in "${names[@]}"; do
    [ -n "$name" ] || continue
    [ "$name" = "$current_name" ] && continue
    escaped=$(escape_regex "$name")
    staged_blob_matches "$path" "(^|[^[:alnum:]_])${escaped}([^[:alnum:]_]|$)" && block "$path"
  done

  for repo in "${repos[@]}"; do
    [ -n "$repo" ] || continue
    [ "$repo" = "$current_repo" ] && continue
    escaped=$(escape_regex "$repo")
    staged_blob_matches "$path" "(^|[^A-Za-z0-9_/-])${escaped}(#[0-9]+)?([^A-Za-z0-9_/-]|$)" && block "$path"
  done

  for workspace in "${workspaces[@]}"; do
    [ -n "$workspace" ] || continue
    escaped=$(escape_regex "$workspace")
    staged_blob_matches "$path" "(^|[^A-Za-z0-9_-])${escaped}([^A-Za-z0-9_-]|$)" && block "$path"
  done
done < <(git diff --cached --name-only --diff-filter=ACMR -z 2>/dev/null)

exit 0
