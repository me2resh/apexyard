#!/usr/bin/env bash
# /dfd lint.sh — validate the Mermaid flowchart block in a generated DFD
# markdown file. Thin wrapper around the shared _lib-mermaid-lint.sh —
# see that file for full flag + exit-code semantics.
#
# Usage:
#   lint.sh <generated-dfd.md> [--skip-lint] [--max-blocks=N]

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec "$SCRIPT_DIR/../_lib-mermaid-lint.sh" "$@"
