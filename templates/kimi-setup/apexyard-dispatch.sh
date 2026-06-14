#!/bin/bash
# Dispatcher for ApexYard Kimi Code CLI hooks.
#
# Kimi Code CLI runs hook commands from the session's project directory. That
# directory may be the ApexYard ops fork or a managed-project workspace clone
# underneath it. This script walks up from $PWD until it finds the requested
# hook, then execs it with the original stdin preserved.
#
# Usage in ~/.kimi-code/config.toml:
#   command = "bash ~/.kimi-code/hooks/apexyard-dispatch.sh <hook-name>.sh"
#
# Resolution order (first match wins):
#   1. <dir>/.apexyard/hooks/<hook-name>   (canonical, model-neutral source)
#   2. <dir>/.kimi-code/hooks/<hook-name>  (generated copy, fallback)
#
# If no hook is found, the dispatcher exits 0 (fail-open), matching the
# fail-open design of the ApexYard hooks themselves.

set -u

HOOK_NAME="${1:-}"
if [ -z "$HOOK_NAME" ]; then
  echo "Usage: $0 <hook-name>.sh" >&2
  exit 1
fi

dir="$PWD"
while [ -n "$dir" ] && [ "$dir" != "/" ]; do
  candidate="$dir/.apexyard/hooks/$HOOK_NAME"
  if [ -f "$candidate" ] && [ -x "$candidate" ]; then
    exec "$candidate"
  fi
  candidate="$dir/.kimi-code/hooks/$HOOK_NAME"
  if [ -f "$candidate" ] && [ -x "$candidate" ]; then
    exec "$candidate"
  fi
  dir=$(dirname "$dir")
done

# Not found inside an ApexYard-shaped tree — fail open.
exit 0
