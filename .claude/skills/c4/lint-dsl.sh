#!/usr/bin/env bash
# /c4 lint-dsl.sh — validate a Structurizr DSL workspace file emitted by
# the `/c4 --dsl` escape hatch. Thin wrapper around the shared
# _lib-structurizr-lint.sh — see that file for full flag + exit-code
# semantics. Sibling to lint.sh (which validates the Mermaid L1/L2 output).
#
# Usage:
#   lint-dsl.sh <workspace.dsl> [--skip-lint]

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec "$SCRIPT_DIR/../_lib-structurizr-lint.sh" "$@"
