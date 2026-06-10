#!/bin/bash
set -u
INPUT_FILE=$(mktemp)
trap 'rm -f "$INPUT_FILE"' EXIT
cat > "$INPUT_FILE"
HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
run() {
  local hook="$1"
  [ -x "$HOOK_DIR/$hook" ] || [ -f "$HOOK_DIR/$hook" ] || return 0
  "$HOOK_DIR/$hook" < "$INPUT_FILE" || exit $?
}
run pin-ops-root.sh
run onboarding-check.sh
run check-upstream-drift.sh
run check-jq-installed.sh
run check-portfolio-config.sh
run clear-bootstrap-marker.sh
run clear-issue-skill-marker.sh
run link-custom-skills.sh
run apply-agent-routing.sh
run remind-mcp-tools.sh
