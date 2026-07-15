#!/bin/bash
# SessionStart hook: split-portfolio v2 primer banner.
#
# Adopter feedback (me2resh/apexyard#900): in split-portfolio v2 mode
# (a public ops fork sitting beside a private `<company>-portfolio`
# repo), agents repeatedly looked in the WRONG place for a managed
# project's workspace clone and missed the sibling repo entirely —
# reproduced across both Claude Code and Codex. Nothing told the agent
# at session start where things actually live, so every session
# re-guessed. This hook closes that gap: it prints a concise banner,
# with absolute paths, naming the ops-fork root, the sibling portfolio
# dir, the workspace dir, and the registry — the four paths every
# portfolio-aware skill needs and that adopters kept having to point
# out by hand.
#
# Detection (per the ticket): BOTH of —
#   1. the `.apexyard-fork` marker is present at the resolved ops root
#   2. the resolved `portfolio.*` paths (registry / workspace_dir /
#      onboarding) actually point OUTSIDE the ops-fork root — i.e. at a
#      sibling repo, not just the in-fork defaults.
#
# Condition 1 alone is NOT sufficient — the marker is written by /setup
# for single-fork adopters too (see _lib-ops-root.sh's header comment),
# so single-fork-but-migrated forks must stay silent. Only the
# combination of "v2 marker present" AND "portfolio paths resolve to a
# sibling directory" means the banner has something useful to say.
#
# Silent (no output, exit 0) when:
#   - not a git repo
#   - no ops-fork root can be resolved (not an apexyard fork at all)
#   - the portfolio-paths / config helper libs are missing
#   - the `.apexyard-fork` marker is absent (not on v2 at all)
#   - the marker is present but every portfolio path still resolves
#     in-fork (single-fork mode, just carrying the v2 marker)
#
# Always exits 0 — this is a pure informational primer, never a gate.
#
# Runtime: a few ms (no network, one JSON parse of project-config.json
# via the already-shared _lib-read-config.sh cache).

set -u

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
if [ -z "$REPO_ROOT" ]; then
  exit 0
fi

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"

# Resolve the ops-fork root via the shared pin-first/walk-up resolver so
# this hook behaves consistently with every other portfolio-aware hook.
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

# Condition 1: the v2 marker must be present. Its absence means either a
# legacy un-migrated fork or a v1 layout — neither is split-portfolio v2,
# so there is nothing to primer.
if [ ! -f "$ROOT/.apexyard-fork" ]; then
  exit 0
fi

CONFIG_LIB="$ROOT/.claude/hooks/_lib-read-config.sh"
PORTFOLIO_LIB="$ROOT/.claude/hooks/_lib-portfolio-paths.sh"

if [ ! -f "$CONFIG_LIB" ] || [ ! -f "$PORTFOLIO_LIB" ]; then
  # Helpers not present — can't resolve paths safely. Silent.
  exit 0
fi

# shellcheck source=/dev/null
. "$CONFIG_LIB"
# shellcheck source=/dev/null
. "$PORTFOLIO_LIB"

REGISTRY=$(portfolio_registry)
WORKSPACE_DIR=$(portfolio_workspace_dir)
ONBOARDING=$(portfolio_onboarding_path)

# Condition 2: at least one of the portfolio paths must resolve OUTSIDE
# the ops-fork root. Compare against the real (symlink-resolved) root so
# this matches portfolio_validate's own outside-fork check.
ROOT_REAL=$(cd "$ROOT" 2>/dev/null && pwd -P) || ROOT_REAL="$ROOT"

_outside_root() {
  case "$1" in
    "$ROOT_REAL"|"$ROOT_REAL"/*) return 1 ;;
  esac
  return 0
}

IS_SPLIT=1
if ! _outside_root "$REGISTRY" && ! _outside_root "$WORKSPACE_DIR" && ! _outside_root "$ONBOARDING"; then
  IS_SPLIT=0
fi

if [ "$IS_SPLIT" -ne 1 ]; then
  # Marker present but every path still resolves in-fork — single-fork
  # mode that merely carries the v2 marker. Silent.
  exit 0
fi

# The sibling `<company>-portfolio` dir is the directory that holds the
# registry file — that's the private repo every split-portfolio v2
# adopter is told to create in docs/multi-project.md. Fall back to the
# workspace dir's parent if the registry itself is (unusually) in-fork
# but the workspace isn't, so the banner still names a sibling path.
if _outside_root "$REGISTRY"; then
  SIBLING_DIR=$(dirname "$REGISTRY")
else
  SIBLING_DIR=$(dirname "$WORKSPACE_DIR")
fi

cat <<MSG
ApexYard: split-portfolio v2 detected — here's where things live (absolute paths):
  Ops-fork root:     $ROOT
  Portfolio (sibling): $SIBLING_DIR
  Workspace dir:      $WORKSPACE_DIR
  Registry:            $REGISTRY
MSG

exit 0
