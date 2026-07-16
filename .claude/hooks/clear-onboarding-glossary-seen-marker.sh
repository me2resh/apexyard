#!/bin/bash
# SessionStart hook: clear any stale onboarding glossary-seen marker from a
# previous session.
#
# The marker at .claude/session/onboarding-glossary-seen tracks which of
# the five core glossary terms have already been surfaced as a
# just-in-time aside this session (terse/guided depth mode — see
# docs/technical-designs/onboarding-increment-2.md § D3, ticket
# me2resh/apexyard#913). It is per-session by design: a returning adopter
# should get the refresher again, not have it silently suppressed by a
# seen-set left over from a previous, unrelated session. If a flow is
# interrupted mid-session (terminal closed, agent killed), the marker can
# be left behind, silently carrying a prior session's "already explained"
# state into the next one.
#
# This hook runs at SessionStart and removes the marker if present, so
# every session starts with a clean slate — the next /onboard run
# re-glosses each term on its first encounter, per the design's
# per-session (not per-fork) scope.
#
# Silent on the no-marker path (the common case). Logs a one-line note to
# stderr when clearing a stale marker so the operator sees what happened.
# Same shape as clear-bootstrap-marker.sh / clear-active-reviewer-marker.sh
# / clear-onboarding-depth-mode-marker.sh.

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
    parent=$(dirname "$cur"); [ "$parent" = "$cur" ] && break; cur="$parent"
  done
fi

if [ -z "$ROOT" ]; then
  exit 0
fi

MARKER="$ROOT/.claude/session/onboarding-glossary-seen"
if [ -f "$MARKER" ]; then
  stale_count=$(wc -l < "$MARKER" 2>/dev/null | tr -d '[:space:]')
  [ -n "$stale_count" ] || stale_count="(unreadable)"
  rm -f "$MARKER"
  echo "ApexYard: cleared stale onboarding glossary-seen marker ($stale_count term(s)) from a previous session." >&2
fi

exit 0
