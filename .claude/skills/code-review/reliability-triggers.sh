#!/usr/bin/env bash
# Read a unified diff from stdin or the first argument.
# Print the reliability checklist items whose trigger matches the diff.
# The ops root is the root of the checkout that holds this script, so the
# loader finds the private handbook layer from any working directory.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
source "$ROOT/.claude/hooks/_lib-read-config.sh"
source "$ROOT/.claude/hooks/_lib-portfolio-paths.sh"
CUSTOM=$(cd "$ROOT" && portfolio_custom_handbooks_dir)
case "$CUSTOM" in
  /*) ;;
  *) CUSTOM="$ROOT/$CUSTOM" ;;
esac
if [ ! -d "$CUSTOM" ]; then
  echo "reliability-triggers: private handbook layer not found at $CUSTOM; only public items were checked." >&2
fi
exec python3 "$(dirname "${BASH_SOURCE[0]}")/reliability_triggers.py" "$ROOT" "$CUSTOM" "$@"
