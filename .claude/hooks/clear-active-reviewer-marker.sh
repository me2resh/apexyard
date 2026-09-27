#!/bin/bash
# SessionStart hook: clear a stale active-reviewer marker left behind by an
# earlier run of THIS SAME Claude Code session.
#
# The marker signals to warn-review-marker-write.sh and
# block-reviewer-repo-mutation.sh that a sanctioned reviewer agent (Rex, the
# security reviewer, or the solution architect) is currently in flight for a
# specific (repo, pr, kind) — see those hooks' headers for the full gate
# design (me2resh/apexyard#843, #1233). The orchestrator (or one of
# /code-review, /security-review, /design-review) is responsible for writing
# the marker right before spawning the reviewer and clearing it once the
# review is posted — but if the session is interrupted (terminal closed,
# agent killed, network failure) mid-review, the marker can be left behind.
#
# SESSION-SCOPED (me2resh/apexyard#1376): the marker path is keyed on
# CLAUDE_CODE_SESSION_ID (active_reviewer_marker_path, _lib-review-markers.sh),
# so this hook only ever removes the marker THIS session's own id would have
# written. It never touches a marker another, concurrently-running session
# set for its own review — sweeping a live marker out from under a review in
# a different worktree would silently disable block-reviewer-repo-mutation.sh
# for that review mid-flight, trading one cross-session bug for another.
#
# A resumed session (same CLAUDE_CODE_SESSION_ID as a previous, interrupted
# run) can still have a stale marker of its own; this hook clears exactly
# that one. When no session id is available at all (the pre-#1376 fixed
# path — see active_reviewer_marker_path's fallback), the legacy behaviour is
# unchanged: clear the single shared marker if present.
#
# If a review genuinely needs to resume, the orchestrator re-sets the marker
# before re-spawning the reviewer.
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

if [ -f "$HOOK_DIR/_lib-review-markers.sh" ]; then
  # shellcheck source=/dev/null
  . "$HOOK_DIR/_lib-review-markers.sh"
fi
if command -v active_reviewer_marker_path >/dev/null 2>&1; then
  MARKER=$(active_reviewer_marker_path "$ROOT")
else
  # Defensive fallback if the lib is missing — pre-#1376 fixed path.
  MARKER="$ROOT/.claude/session/active-reviewer"
fi
if [ -f "$MARKER" ]; then
  stale_value=$(tr -d '[:space:]' < "$MARKER" 2>/dev/null || echo "(unreadable)")
  rm -f "$MARKER"
  echo "ApexYard: cleared stale active-reviewer marker (was: $stale_value) from a previous session." >&2
fi

exit 0
