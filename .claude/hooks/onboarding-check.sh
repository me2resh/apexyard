#!/bin/bash
# SessionStart hook: checks whether this ApexYard fork has been configured.
#
# Detection: reads onboarding.yaml and checks if company.name is still the
# placeholder value "Your Company Name". If so, the fork hasn't been set up
# yet and the user should run /setup.
#
# Why onboarding.yaml and not a session marker: onboarding.yaml is COMMITTED,
# so the setup state persists across clones and team members. A fresh clone
# of a configured fork already has real values — no per-machine marker needed.

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
CONFIG="${REPO_ROOT:-.}/onboarding.yaml"

# No onboarding.yaml at all — not an apexyard fork, skip silently
if [ ! -f "$CONFIG" ]; then
  exit 0
fi

# Check if the placeholder is still present
if grep -q '"Your Company Name"' "$CONFIG" 2>/dev/null; then
  cat <<MSG
APEXYARD SETUP NOT RUN

This fork hasn't been configured yet. onboarding.yaml still has
placeholder values ("Your Company Name").

Run /setup to configure your fork in ~2 minutes:

  1. Describe your company and tech stack (one question)
  2. Review the proposed defaults
  3. Accept or customize

The config is committed to onboarding.yaml so it persists across
clones and team members — you only need to do this once per fork.
MSG
fi

exit 0
