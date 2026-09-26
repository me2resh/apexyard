#!/usr/bin/env bash
# /plan-initiative lint.sh — validate the Mermaid DAG block in a generated
# initiative doc. Thin wrapper around the shared _lib-mermaid-lint.sh —
# see that file for full flag + exit-code semantics.
#
# Usage:
#   lint.sh <generated-initiative.md> [--skip-lint] [--max-blocks=N]

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec "$SCRIPT_DIR/../_lib-mermaid-lint.sh" "$@"
