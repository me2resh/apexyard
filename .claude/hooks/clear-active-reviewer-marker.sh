#!/bin/bash
# SessionStart hook: clear any stale active-reviewer marker from a previous
# session.
#
# The marker at .claude/session/active-reviewer signals to
# warn-review-marker-write.sh that a sanctioned reviewer agent (Rex, the
# security reviewer, or the solution architect) is currently in flight for
# a specific (repo, pr, kind) — see that hook's header for the full gate
# design (me2resh/apexyard#843). The orchestrator (or one of /code-review,
# /security-review, /design-review) is responsible for writing the marker
# right before spawning the reviewer and clearing it once the review is
# posted — but if the session is interrupted (terminal closed, agent
# killed, network failure) mid-review, the marker can be left behind,
# silently authorising the NEXT review-marker write in a future session
# regardless of which (repo, pr, kind) it's actually for.
#
# This hook runs at SessionStart and removes the marker if present, so
# every session starts with a clean slate. If a review genuinely needs to
# resume, the orchestrator re-sets the marker before re-spawning the
# reviewer.
#
# Silent on the no-marker path (the common case). Logs a one-line note to
# stderr when clearing a stale marker so the operator sees what happened.
# Same shape as clear-bootstrap-marker.sh / clear-issue-skill-marker.sh.

set -u

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
if [ -z "$REPO_ROOT" ]; then
  exit 0
fi

# Walk up to find the apexyard fork root. Honours both the v2
# `.apexyard-fork` marker and the legacy v1 anchor.
HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT=""
if [ -f "$HOOK_DIR/_lib-ops-root.sh" ]; then
  # shellcheck source=/dev/null
  . "$HOOK_DIR/_lib-ops-root.sh"
  ROOT=$(resolve_ops_root "$REPO_ROOT")
else
  cur="$REPO_ROOT"
  while [ -n "$cur" ] && [ "$cur" != "/" ]; do
    if [ -f "$cur/.apexyard-fork" ]; then
      ROOT="$cur"
      break
    fi
    if [ -f "$cur/onboarding.yaml" ] && [ -f "$cur/apexyard.projects.yaml" ]; then
      ROOT="$cur"
      break
    fi
    cur=$(dirname "$cur")
  done
fi

if [ -z "$ROOT" ]; then
  exit 0
fi

MARKER="$ROOT/.claude/session/active-reviewer"
if [ -f "$MARKER" ]; then
  stale_value=$(tr -d '[:space:]' < "$MARKER" 2>/dev/null || echo "(unreadable)")
  rm -f "$MARKER"
  echo "ApexYard: cleared stale active-reviewer marker (was: $stale_value) from a previous session." >&2
fi

exit 0
