#!/bin/bash
# SessionStart hook: checks whether this ApexYard fork has been configured.
#
# Detection lives in the shared _lib-fresh-fork.sh (AgDR-0098) — this hook
# is now a thin caller so there is exactly one fresh-fork detector shared
# with /onboard (the guided first-run orchestrator). See
# docs/technical-designs/onboarding-increment-1.md § D2.
#
# Detection model (#517): in single-fork mode `onboarding.yaml` is now
# GITIGNORED (real config stays local) and `onboarding.example.yaml` is the
# tracked placeholder template. "Configured" = a real onboarding.yaml exists
# with a non-placeholder company.name. A fresh clone has only the example (no
# onboarding.yaml) → unconfigured → prompt /onboard, which walks the adopter
# through a tour + /setup + a guided first win. In split-portfolio v2 mode
# the real onboarding.yaml lives (committed) in the private sibling repo,
# which portfolio_onboarding_path resolves — that path still reads as
# configured.

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
if [ -z "$REPO_ROOT" ]; then
  exit 0
fi

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ ! -f "$HOOK_DIR/_lib-fresh-fork.sh" ]; then
  exit 0
fi
# shellcheck source=/dev/null
. "$HOOK_DIR/_lib-fresh-fork.sh"

STATE=$(fresh_fork_state)

case "$STATE" in
  fresh)
    # Check the SAME resolved config path fresh_fork_state() checked (via
    # fresh_fork_config_path()) — not a hardcoded $REPO_ROOT/onboarding.yaml.
    # In split-portfolio v2 the real onboarding.yaml lives in the sibling
    # repo; hardcoding the in-fork path here would print "no onboarding.yaml"
    # even when a placeholder sibling file is what actually made this fresh.
    CONFIG="$(fresh_fork_config_path)"
    if [ -n "$CONFIG" ] && [ -f "$CONFIG" ]; then
      # Config file exists but still carries the placeholder.
      echo "ApexYard: onboarding.yaml is unconfigured (placeholder still present). Run /onboard for the guided tour, or /setup to configure directly."
    else
      # No onboarding.yaml yet — fresh clone, example present.
      echo "ApexYard: not configured yet (no onboarding.yaml). Run /onboard for the guided first-run tour, or /setup for just the config bootstrap."
    fi
    ;;
  configured|not-a-fork)
    # configured: fork is set up, nothing to prompt.
    # not-a-fork: no onboarding.yaml and no example — not an apexyard fork
    # (or split-portfolio v2 misconfigured); check-portfolio-config.sh
    # handles that case. Stay silent here either way.
    ;;
esac

exit 0
