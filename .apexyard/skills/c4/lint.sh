#!/usr/bin/env bash
# /c4 lint.sh — validate Mermaid blocks in a generated C4 markdown file
# (C4 Context L1 or C4 Container L2). Thin wrapper around the shared
# _lib-mermaid-lint.sh — see that file for full flag + exit-code semantics.
#
# Usage:
#   lint.sh <generated-c4.md> [--skip-lint] [--max-blocks=N]

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec "$SCRIPT_DIR/../_lib-mermaid-lint.sh" "$@"
