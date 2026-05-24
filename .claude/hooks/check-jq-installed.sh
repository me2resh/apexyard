#!/bin/bash
# SessionStart advisory: warn once per session when `jq` is missing on a
# fork that has any project-config file present.
#
# Many framework hooks call `jq` to read `.claude/project-config.json`
# and `.claude/project-config.defaults.json` for adopter overrides
# (`.ui_paths`, `.ui_paths_exclude`, `.tracker.*`, `.migration_paths`,
# `.ticket.bootstrap_skills`, etc.). Without jq those reads silently
# return empty (`jq … 2>/dev/null`), the hook falls back to the
# framework default, and the adopter's override has zero effect. No
# error, no warning — a silently-degraded fork.
#
# Surfacing the gap at SessionStart turns the failure into a one-line
# banner the operator can act on, instead of a buried, invisible
# fallback. Same advisory shape as check-upstream-drift.sh:
# non-blocking, exit 0 always.
#
# Silent exit paths (no output, no error):
#   - jq is on PATH (the happy path — most adopters)
#   - No ops fork can be located (caller isn't inside an apexyard tree)
#   - No project-config file is present at the resolved ops root (so
#     there's literally nothing for hooks to read overrides from; the
#     fork is on framework defaults regardless of jq's presence)
#
# Banner emits only when jq is genuinely missing AND a project-config
# file exists, i.e. the silently-degraded state the rule is trying to
# surface.

# Skip silently when jq is already installed — the common case.
if command -v jq >/dev/null 2>&1; then
  exit 0
fi

# Resolve the ops-fork root via the shared helper. Falls back to a small
# inline walk-up if the helper is missing (older forks, or this hook
# running against an unrelated git repo where the helper hasn't been
# copied in yet).
HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
ops_root=""
if [ -f "$HOOK_DIR/_lib-ops-root.sh" ]; then
  # shellcheck source=/dev/null
  . "$HOOK_DIR/_lib-ops-root.sh"
  ops_root=$(resolve_ops_root "$PWD")
else
  r="$PWD"
  while [ -n "$r" ] && [ "$r" != "/" ]; do
    if [ -f "$r/.apexyard-fork" ]; then
      ops_root="$r"; break
    fi
    if [ -f "$r/onboarding.yaml" ] && [ -f "$r/apexyard.projects.yaml" ]; then
      ops_root="$r"; break
    fi
    r=$(dirname "$r")
  done
fi

# If we couldn't find an ops fork, this session isn't an apexyard
# session — stay silent.
if [ -z "$ops_root" ]; then
  exit 0
fi

# If neither project-config file exists at the ops root, hooks have
# nothing to read overrides from and the missing jq is harmless. Stay
# silent — surfacing it would be noise.
if [ ! -f "$ops_root/.claude/project-config.json" ] && \
   [ ! -f "$ops_root/.claude/project-config.defaults.json" ]; then
  exit 0
fi

cat >&2 <<'MSG'
ApexYard: jq is not installed. Hooks that read project-config overrides
(`.ui_paths`, `.ui_paths_exclude`, `.tracker.*`, `.migration_paths`,
`.ticket.bootstrap_skills`, etc.) will silently fall back to framework
defaults. Install jq to make overrides take effect:
  brew install jq        # macOS
  apt-get install jq     # Debian / Ubuntu
  dnf install jq         # Fedora
  https://jqlang.org/download/   # other platforms
Or skip if you don't override any defaults.
MSG

exit 0
