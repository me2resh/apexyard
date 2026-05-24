#!/bin/bash
# SessionStart hook: clear any stale ticket-skill marker from a previous
# session.
#
# The marker at .claude/session/active-issue-skill signals to
# require-skill-for-issue-create.sh that a structured ticket-creating skill
# (/task, /feature, /bug, /spike, /migration, /investigation, /idea) is in
# progress and that raw ticket-create CLI calls should be allowed through.
# Skills are responsible for writing the marker on entry and removing it on
# completion — but if a skill is interrupted (terminal closed, agent killed,
# network failure), the marker can be left behind, silently exempting the
# next session from the skill-gate.
#
# This hook runs at SessionStart and removes the marker if present. If the
# user is genuinely resuming a ticket skill, they re-invoke it and the skill
# writes the marker again.
#
# Mirror of clear-bootstrap-marker.sh. See AgDR-0030 and me2resh/apexyard#268.

set -u

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
if [ -z "$REPO_ROOT" ]; then
  exit 0
fi

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

MARKER="$ROOT/.claude/session/active-issue-skill"
if [ -f "$MARKER" ]; then
  stale_skill=$(tr -d '[:space:]' < "$MARKER" 2>/dev/null || echo "(unreadable)")
  rm -f "$MARKER"
  echo "ApexYard: cleared stale ticket-skill marker (was: $stale_skill) from a previous session." >&2
fi

exit 0
