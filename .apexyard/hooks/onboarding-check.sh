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
# Detection model (#517): in single-fork mode `onboarding.yaml` is now
# GITIGNORED (real config stays local) and `onboarding.example.yaml` is the
# tracked placeholder template. "Configured" = a real onboarding.yaml exists
# with a non-placeholder company.name. A fresh clone has only the example (no
# onboarding.yaml) → unconfigured → prompt /setup, which copies the example to
# onboarding.yaml and fills it in. In split-portfolio v2 mode the real
# onboarding.yaml lives (committed) in the private sibling repo, which
# portfolio_onboarding_path resolves — that path still reads as configured.

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

# No onboarding.yaml at the resolved path. Two cases:
#   - A tracked onboarding.example.yaml exists → this IS an apexyard fork that
#     hasn't been configured yet (fresh clone in the #517 model) → prompt /setup.
#   - No example either → not an apexyard fork (or split-portfolio v2
#     misconfigured); skip silently. check-portfolio-config.sh handles paths.
if [ ! -f "$CONFIG" ]; then
  if [ -f "$REPO_ROOT/onboarding.example.yaml" ]; then
    echo "ApexYard: not configured yet (no onboarding.yaml). Run /setup — it copies onboarding.example.yaml → onboarding.yaml (gitignored) and fills it in."
  fi
  exit 0
fi

# onboarding.yaml exists — configured unless the placeholder is still present
if grep -q '"Your Company Name"' "$CONFIG" 2>/dev/null; then
  echo "ApexYard: onboarding.yaml is unconfigured (placeholder still present). Run /setup to configure this fork."
fi

exit 0
