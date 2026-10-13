#!/usr/bin/env bash
# Check Node, write access, network, and install scripts.
# Print the driver. Exit 0. A failed check selects the fallback.
set -euo pipefail

root=${CHECK_ENV_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}
node_bin=${CHECK_ENV_NODE:-node}
failed=""

add() {
  if [ -n "$failed" ]; then
    failed="$failed,$1"
  else
    failed=$1
  fi
}

node_ok=false
if out=$("$node_bin" -p 'const [maj,min]=process.versions.node.split(".").map(Number); (maj>22)||(maj===22&&min>=12)' 2>/dev/null); then
  node_ok=$out
fi
if [ "$node_ok" != true ]; then
  add node
fi

probe=$root/data
if ! mkdir -p "$probe" 2>/dev/null || ! touch "$probe/.write-probe" 2>/dev/null; then
  add write
else
  rm -f "$probe/.write-probe"
  rmdir "$probe" 2>/dev/null || true
fi

if [ "${CHECK_ENV_INSTALL_SCRIPTS:-}" = blocked ] || [ "${npm_config_ignore_scripts:-}" = true ]; then
  add install-scripts
fi

if [ "${CHECK_ENV_NETWORK:-}" = down ]; then
  add network
elif [ "${CHECK_ENV_NETWORK:-}" != up ]; then
  if ! command -v curl >/dev/null 2>&1 || ! curl -fsS --head --max-time 5 -o /dev/null https://registry.npmjs.org/; then
    add network
  fi
fi

if [ -z "$failed" ]; then
  printf 'check=pass\n'
  printf 'driver=sql.js\n'
  exit 0
fi

printf 'check=fail\n'
printf 'failed=%s\n' "$failed"
printf 'fallback=sql.js\n'
printf 'action=Fix the failed check. Then run npm ci --ignore-scripts.\n'
exit 0
