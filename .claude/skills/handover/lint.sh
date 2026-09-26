#!/usr/bin/env bash
# /handover lint.sh — validate Mermaid blocks in a generated architecture
# stub (container.md, context.md, or a sequence-<flow>.md). Thin wrapper
# around the shared _lib-mermaid-lint.sh — see that file for full flag +
# exit-code semantics.
#
# Usage:
#   lint.sh <generated-stub.md> [--skip-lint] [--max-blocks=N]

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec "$SCRIPT_DIR/../_lib-mermaid-lint.sh" "$@"
