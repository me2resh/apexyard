#!/bin/bash
# Blocks a commit when a staged file contains a private portfolio identifier.
#
# Git invokes this from the repository that owns the index. The scanner reads
# indexed blobs, not a rendered diff, so it protects every commit version.
#
# Matching lives in _lib-private-refs-match.sh (shared with the push-time
# scan — me2resh/apexyard#1528 / AgDR-0220). Behaviour is unchanged except:
# when origin is confirmed private by the same remote classification the
# push scan uses, this staged scan exits 0. The protected-branch guard in
# .githooks/pre-commit still runs. Origins that are public, unknown, or
# only proven public via the #1477 offline path still run this scan.

set -u

ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || {
  echo "BLOCKED: cannot resolve the Git root for the staged private-reference scan." >&2
  exit 2
}

HOOK_DIR="$ROOT/.claude/hooks"
_SELF_DIR=$(CDPATH="" cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)

_source_lib() {
  local name="$1" path
  for path in "$_SELF_DIR/$name" "$HOOK_DIR/$name"; do
    if [ -f "$path" ]; then
      # shellcheck source=/dev/null
      . "$path"
      return 0
    fi
  done
  return 1
}

if ! _source_lib "_lib-private-refs-match.sh"; then
  echo "BLOCKED: _lib-private-refs-match.sh is missing. Cannot safely scan staged content for a private portfolio reference." >&2
  exit 2
fi

# Load the registry first: a repo with nothing to scan never needs a
# visibility lookup (and never calls gh).
private_refs_match_init
init_rc=$?
[ "$init_rc" -eq 1 ] && exit 0
[ "$init_rc" -eq 2 ] && exit 2

# #1528 — skip the staged content scan only when origin is confirmed
# private (fresh cache or live lookup). Failure / unknown / public-class
# → scan as before. Missing visibility lib → scan (fail closed toward
# scanning). The push-time scan covers content leaving for another remote.
if _source_lib "_lib-leak-remote-visibility.sh"; then
  origin_url=$(leak_remote_url origin)
  if [ -n "$origin_url" ] && leak_remote_is_confirmed_private "$origin_url"; then
    exit 0
  fi
fi

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
  [ -n "${PRIVATE_REFS_REGISTRY_REL:-}" ] && [ "$path" = "$PRIVATE_REFS_REGISTRY_REL" ] && continue
  git show ":$path" >/dev/null 2>&1 || continue

  if private_refs_match_staged_blob "$path"; then
    block "$path"
  fi
done < <(git diff --cached --name-only --diff-filter=ACMR -z 2>/dev/null)

exit 0
