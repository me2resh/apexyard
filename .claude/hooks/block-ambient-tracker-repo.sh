#!/bin/bash
# CLASS: CONTROL — require an explicit repository for tracker commands when
# the active ticket belongs to a different repository than the current
# checkout (me2resh/apexyard#1268).

INPUT=$(cat)
COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
[ -n "$COMMAND" ] || exit 0

# This guard covers raw GitHub issue and pull-request commands. Commands that
# already name --repo/-R are explicit by definition and may intentionally cross
# repository boundaries.
if ! printf '%s' "$COMMAND" | grep -qE '(^|[;&|])[[:space:]]*gh[[:space:]]+(issue|pr)[[:space:]]+'; then
  exit 0
fi
if printf '%s' "$COMMAND" | grep -qE '(^|[[:space:]])(--repo|-R)(=|[[:space:]])'; then
  exit 0
fi

HOOK_DIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd) || exit 0
if [ -f "$HOOK_DIR/_lib-ops-root.sh" ]; then
  # shellcheck source=/dev/null
  . "$HOOK_DIR/_lib-ops-root.sh"
else
  exit 0
fi

OPS_ROOT=$(resolve_ops_root "$PWD")
[ -n "$OPS_ROOT" ] || exit 0

# Read the repo pins from active ticket markers. A marker without repo= is the
# legacy/framework fallback and cannot establish a managed-project target.
MARKER_DIR="$OPS_ROOT/.claude/session"
REPOS=""
for marker in "$MARKER_DIR/current-ticket" "$MARKER_DIR/tickets"/* "$MARKER_DIR/tickets"/*/*; do
  [ -f "$marker" ] || continue
  repo=$(sed -n 's/^repo=//p' "$marker" | head -1)
  [ -n "$repo" ] && REPOS="${REPOS}${repo}\n"
done
[ -n "$REPOS" ] || exit 0

UNIQUE_REPOS=$(printf '%b' "$REPOS" | sed '/^$/d' | sort -u)
COUNT=$(printf '%s\n' "$UNIQUE_REPOS" | sed '/^$/d' | wc -l | tr -d ' ')

# If exactly one active target matches the checkout's origin, ambient gh is
# safe. Otherwise require the caller to state the repository explicitly.
ORIGIN_URL=$(git remote get-url origin 2>/dev/null || true)
ORIGIN_REPO=$(printf '%s' "$ORIGIN_URL" | sed -nE 's|.*[:/]([^/:]+/[^/]+)\.git$|\1|p; s|.*[:/]([^/:]+/[^/]+)$|\1|p' | head -1)
if [ "$COUNT" -eq 1 ] && [ "$(printf '%s' "$UNIQUE_REPOS" | tr '[:upper:]' '[:lower:]')" = "$(printf '%s' "$ORIGIN_REPO" | tr '[:upper:]' '[:lower:]')" ]; then
  exit 0
fi

if [ "$COUNT" -eq 1 ]; then
  TARGET=$(printf '%s' "$UNIQUE_REPOS" | head -1)
  echo "BLOCKED: tracker command has no explicit repository, but the active ticket targets $TARGET while this checkout resolves to ${ORIGIN_REPO:-no origin}. Add --repo $TARGET (or -R $TARGET)." >&2
else
  echo "BLOCKED: tracker command has no explicit repository, and active tickets target multiple repositories. Add --repo <owner/repo> (or -R <owner/repo>)." >&2
fi
exit 2
