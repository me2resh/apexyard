#!/bin/bash
# SessionStart hook: checks whether this ApexYard fork has been configured.
#
# Detection: reads the resolved onboarding.yaml path (via
# portfolio_onboarding_path — handles both single-fork mode where
# onboarding.yaml lives in the fork AND split-portfolio v2 mode where it
# lives in the private sibling repo) and checks if company.name is still
# the placeholder value "Your Company Name". If so, the fork hasn't been
# set up yet and the user should run /setup.
#
# Why onboarding.yaml and not a session marker: onboarding.yaml is COMMITTED
# (to the fork in single-fork mode, to the private portfolio repo in
# split-portfolio v2 mode), so the setup state persists across clones and
# team members. A fresh clone of a configured fork already has real
# values — no per-machine marker needed.

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
if [ -z "$REPO_ROOT" ]; then
  exit 0
fi

# Resolve onboarding path through the portfolio helper so split-portfolio
# v2 adopters (onboarding.yaml in the private sibling repo) get the right
# file. Falls back to the in-fork default for single-fork mode.
HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG=""
if [ -f "$HOOK_DIR/_lib-portfolio-paths.sh" ] && [ -f "$HOOK_DIR/_lib-read-config.sh" ]; then
  # shellcheck source=/dev/null
  . "$HOOK_DIR/_lib-read-config.sh"
  # shellcheck source=/dev/null
  . "$HOOK_DIR/_lib-portfolio-paths.sh"
  CONFIG=$(portfolio_onboarding_path 2>/dev/null)
fi
if [ -z "$CONFIG" ]; then
  CONFIG="$REPO_ROOT/onboarding.yaml"
fi

# No onboarding.yaml at the resolved path — not an apexyard fork (or
# split-portfolio v2 misconfigured); skip silently. check-portfolio-config.sh
# handles broken paths.
if [ ! -f "$CONFIG" ]; then
  exit 0
fi

# Check if the placeholder is still present
if grep -q '"Your Company Name"' "$CONFIG" 2>/dev/null; then
  echo "ApexYard: onboarding.yaml is unconfigured (placeholder still present). Run /setup to configure this fork."
fi

exit 0
