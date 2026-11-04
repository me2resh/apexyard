#!/usr/bin/env bash
# Check the npm package copy before release.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cmp "$root/install.sh" "$root/packaging/npm/create-apexyard/install.sh"
