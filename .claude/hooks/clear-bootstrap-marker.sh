#!/bin/bash
# SessionStart hook: clear any stale bootstrap-skill marker from a
# previous session.
#
# The marker at .claude/session/active-bootstrap signals to
# require-active-ticket.sh that an in-progress bootstrap skill (e.g.
# /setup, /handover, /update, /split-portfolio) is exempt from the
# ticket-first gate. Skills are responsible for writing the marker on
# entry and removing it on completion — but if a skill is interrupted
# (terminal closed, agent killed, network failure), the marker can be
# left behind, silently exempting the next session from the ticket gate.
#
# This hook runs at SessionStart and removes the marker if present, so
# every session starts with a clean slate. If the user is genuinely
# resuming a bootstrap skill, they re-invoke it and the skill writes
# the marker again.
#
# Silent on the no-marker path (the common case). Logs a one-line note
# to stderr when clearing a stale marker so the operator sees what
# happened.

set -u

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
if [ -z "$REPO_ROOT" ]; then
  exit 0
fi

# Walk up to find the apexyard fork root.
ROOT=""
cur="$REPO_ROOT"
while [ -n "$cur" ] && [ "$cur" != "/" ]; do
  if [ -f "$cur/onboarding.yaml" ] && [ -f "$cur/apexyard.projects.yaml" ]; then
    ROOT="$cur"
    break
  fi
  cur=$(dirname "$cur")
done

if [ -z "$ROOT" ]; then
  exit 0
fi

MARKER="$ROOT/.claude/session/active-bootstrap"
if [ -f "$MARKER" ]; then
  stale_skill=$(tr -d '[:space:]' < "$MARKER" 2>/dev/null || echo "(unreadable)")
  rm -f "$MARKER"
  echo "ApexYard: cleared stale bootstrap marker (was: $stale_skill) from a previous session." >&2
fi

exit 0
