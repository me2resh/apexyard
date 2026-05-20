#!/usr/bin/env bash
# Link your existing KoraID clone into ApexYard workspace/ (gitignored).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KORAID="${KORAID_PATH:-$HOME/Documents/koraid}"
mkdir -p "$ROOT/workspace"
ln -sfn "$KORAID" "$ROOT/workspace/koraid"
echo "Linked $KORAID -> $ROOT/workspace/koraid"
