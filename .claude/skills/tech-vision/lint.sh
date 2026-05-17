#!/usr/bin/env bash
# /tech-vision lint.sh — validate any Mermaid blocks in a generated
# architecture vision markdown file (typically the target-state C4 L1
# block). Thin wrapper around the shared _lib-mermaid-lint.sh — see
# that file for full flag + exit-code semantics.
#
# Usage:
#   lint.sh <generated-vision.md> [--skip-lint] [--max-blocks=N]

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec "$SCRIPT_DIR/../_lib-mermaid-lint.sh" "$@"
