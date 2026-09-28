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
current_owner=${current_repo%%/*}

# #1431 — an ops fork's `origin` is the fork itself. The
# public framework lives at the `upstream` remote. A registry commonly lists
# the framework repo, and an adopter's login often equals a registered
# project name, so a commit that cites an upstream issue as
# `<upstream-owner>/<repo>#N` must not read as a leak either. Resolve
# `upstream` the same way as `origin`. A fork with no `upstream` remote
# leaves these empty and keeps today's origin-only behaviour.
# Hakim advisory: every exemption below trusts that `upstream` IS the public framework repo; a misconfigured `upstream` pointed at a private repo gets the same exemption.
upstream_repo=""
upstream_url=$(git remote get-url upstream 2>/dev/null || true)
if [ -n "$upstream_url" ]; then
  upstream_repo=$(printf '%s' "$upstream_url" | sed -nE 's|.*github\.com[:/]([^/]+/[^/]+)(\.git)?$|\1|p' | sed 's/\.git$//')
fi
upstream_name=""
upstream_owner=""
if [ -n "$upstream_repo" ]; then
  upstream_name=${upstream_repo##*/}
  upstream_owner=${upstream_repo%%/*}
fi

if [ -f "$HOOK_DIR/_lib-registry-parser.sh" ]; then
  # shellcheck source=/dev/null
  . "$HOOK_DIR/_lib-registry-parser.sh"
fi

# apexyard#1457 review round 2 (Rex B1 / Hakim HIGH-2) — the registry exists
# (checked above), so there IS a scrub list to enforce. If the shared
# parser failed to load, or the awk parse itself fails, silently treating
# that as "no registered projects" would fail OPEN on every private
# reference. Fail closed instead: block until the parser is fixed.
if ! declare -F registry_parse_entries >/dev/null 2>&1; then
  echo "BLOCKED: shared registry parser (_lib-registry-parser.sh) is missing or failed to load. Cannot safely scan staged content for a private portfolio reference." >&2
  exit 2
fi
registry_parsed=$(registry_parse_entries "$REGISTRY")
registry_parse_rc=$?
if [ "$registry_parse_rc" -ne 0 ]; then
  echo "BLOCKED: registry parse failed (exit $registry_parse_rc) while scanning staged content for a private portfolio reference." >&2
  exit 2
fi

names=()
names_public=()
repos=()
repos_public=()
workspaces=()
workspaces_public=()
name_repo_pairs=()
current_public=0
pending_name=""
while IFS= read -r entry; do
  case "$entry" in
    PUBLIC=*) current_public=${entry#PUBLIC=}; pending_name="" ;;
    NAME=*)
      names+=("${entry#NAME=}")
      names_public+=("$current_public")
      pending_name="${entry#NAME=}"
      ;;
    REPO=*)
      repos+=("${entry#REPO=}")
      repos_public+=("$current_public")
      if [ -n "$pending_name" ]; then
        name_repo_pairs+=("${pending_name}"$'\t'"${entry#REPO=}")
      fi
      ;;
    WORKSPACE=*)
      workspaces+=("${entry#WORKSPACE=}")
      workspaces_public+=("$current_public")
      ;;
  esac
done <<EOF
$registry_parsed
EOF

[ "${#names[@]}" -gt 0 ] || [ "${#repos[@]}" -gt 0 ] || [ "${#workspaces[@]}" -gt 0 ] || exit 0

# #1431 round 2 (Hakim MEDIUM) — a registered project's `name` can
# coincidentally equal `upstream`'s bare repo name without that entry
# actually BEING upstream (a different, private repo happens to share the
# same bare name). Only exempt the name outright when the SAME registry
# entry's own `repo` field equals `upstream_repo` — a real association, not
# a name-string coincidence. This does not apply to `origin`'s pre-existing
# bare-name exemption, which this PR does not change.
registry_name_repo_matches() {
  local target_name="$1" target_repo="$2" pair
  [ "${#name_repo_pairs[@]}" -gt 0 ] || return 1
  for pair in "${name_repo_pairs[@]}"; do
    [ "$pair" = "${target_name}"$'\t'"${target_repo}" ] && return 0
  done
  return 1
}

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

# #1400's owner-login exemption, ported from
# block-private-refs-in-public-repos.sh. A registered name can coincidentally
# equal the owner login of `origin` or `upstream`. Writing that owner out as
# `owner/repo` or `@owner` must not read as a leak of the unrelated project.
# Strip only those two safe forms from a lower-cased copy of the staged blob,
# then check whether the owner's name still appears as a bare, standalone
# word. A bare mention still blocks, like any other registered name.
#
# #1431 round 2 (Hakim HIGH-1) — a staged blob can hold a raw non-UTF-8 byte
# (a stray Latin-1 byte, say). In a UTF-8 locale, `tr` and BSD `sed` both
# stop with "illegal byte sequence" on that byte, the pipeline's exit code
# goes non-zero, and the old code treated ANY failure here as "no bare
# mention remains" — exempting the file outright on a scan that never ran.
# Two fixes: every `tr`/`sed`/`grep` call below runs under `LC_ALL=C`, so a
# raw byte is just a byte, not an encoding error; and a failure at any step
# (including `git show` itself) now returns 0 — "a bare mention remains" —
# so the caller falls through to the ordinary block instead of exempting an
# unscanned file. Fail closed, not open. `#` also joins the escaped
# characters, because the second `sed` below uses `#` as its own delimiter;
# an unescaped `#` in a registered name would end that pattern early.
owner_bare_mention_remains() {
  local path="$1" owner_name="$2"
  local content esc_lc haystack_lc stripped_lc rc

  content=$(git show ":$path" 2>/dev/null)
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

  for idx in "${!names[@]}"; do
    name="${names[$idx]}"
    [ -n "$name" ] || continue
    [ "${names_public[$idx]}" = "1" ] && continue
    [ "$name" = "$current_name" ] && continue
    if [ -n "$upstream_name" ] && [ "$name" = "$upstream_name" ] \
      && registry_name_repo_matches "$name" "$upstream_repo"; then
      continue
    fi

    if [ "$name" = "$current_owner" ] || { [ -n "$upstream_owner" ] && [ "$name" = "$upstream_owner" ]; }; then
      owner_bare_mention_remains "$path" "$name" || continue
    fi

    escaped=$(escape_regex "$name")
    staged_blob_matches "$path" "(^|[^[:alnum:]_])${escaped}([^[:alnum:]_]|$)" && block "$path"
  done

  for idx in "${!repos[@]}"; do
    repo="${repos[$idx]}"
    [ -n "$repo" ] || continue
    [ "${repos_public[$idx]}" = "1" ] && continue
    [ "$repo" = "$current_repo" ] && continue
    [ -n "$upstream_repo" ] && [ "$repo" = "$upstream_repo" ] && continue
    escaped=$(escape_regex "$repo")
    staged_blob_matches "$path" "(^|[^A-Za-z0-9_/-])${escaped}(#[0-9]+)?([^A-Za-z0-9_/-]|$)" && block "$path"
  done

  for idx in "${!workspaces[@]}"; do
    workspace="${workspaces[$idx]}"
    [ -n "$workspace" ] || continue
    [ "${workspaces_public[$idx]}" = "1" ] && continue
    escaped=$(escape_regex "$workspace")
    staged_blob_matches "$path" "(^|[^A-Za-z0-9_-])${escaped}([^A-Za-z0-9_-]|$)" && block "$path"
  done
done < <(git diff --cached --name-only --diff-filter=ACMR -z 2>/dev/null)

exit 0
