#!/bin/bash
# SessionStart hook: surface broken portfolio config at session start.
#
# Calls portfolio_validate() from _lib-portfolio-paths.sh and prints a
# one-line banner if the config is broken. Silent when:
#   - not inside an apexyard fork
#   - the helper or config lib is missing
#   - validate returns OK
#
# This is the self-healing banner described in #145. The intent is that an
# adopter who mistyped a path in `.claude/project-config.json` (or moved
# their sibling portfolio repo) sees the failure at session start, before
# they invoke a portfolio-aware skill that would fail with a less specific
# error.
#
# Cost on the OK path: ~10-30ms (one yq parse of the registry). Cheap
# enough to run on every SessionStart.

set -u

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
if [ -z "$REPO_ROOT" ]; then
  exit 0
fi

# Walk up to find the apexyard fork root (dir with both onboarding.yaml +
# apexyard.projects.yaml). If we can't find one, this hook has nothing to
# say.
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

CONFIG_LIB="$ROOT/.claude/hooks/_lib-read-config.sh"
PORTFOLIO_LIB="$ROOT/.claude/hooks/_lib-portfolio-paths.sh"

if [ ! -f "$CONFIG_LIB" ] || [ ! -f "$PORTFOLIO_LIB" ]; then
  # Helpers not present — no validation possible. Silent.
  exit 0
fi

# shellcheck source=/dev/null
. "$CONFIG_LIB"
# shellcheck source=/dev/null
. "$PORTFOLIO_LIB"

result=$(portfolio_validate 2>&1)
rc=$?

if [ "$rc" -eq 0 ]; then
  # All good — silent.
  exit 0
fi

# Broken. Surface a single-line banner with the specific failure and the
# fix suggestion. Mirrors the shape of check-upstream-drift.sh's banner.
cat <<MSG
ApexYard: portfolio config is broken — $result
  Fix .claude/project-config.json (key: portfolio.{registry, projects_dir, ideas_backlog}),
  or run /split-portfolio --verify for a structured state report.
MSG

# Don't fail the session start. The banner is informational; portfolio
# skills will still surface their own errors when they try to read the
# registry. Exit 0 so SessionStart proceeds.
exit 0
