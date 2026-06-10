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
run block-git-add-all.sh
run block-main-push.sh
run validate-branch-name.sh
run check-secrets.sh
run block-onboarding-in-git.sh
run verify-commit-refs.sh
run validate-commit-format.sh
run require-agdr-for-arch-changes.sh
run pre-push-gate.sh
run block-agent-routing-drift.sh
run warn-bootstrap-scope.sh
run require-skill-for-issue-create.sh
run suggest-ticket-template.sh
run validate-issue-structure.sh
run block-private-refs-in-public-repos.sh
run validate-pr-create.sh
run require-agdr-for-arch-pr.sh
run block-unreviewed-merge.sh
run require-design-review-for-ui.sh
run block-merge-on-red-ci.sh
run require-architecture-review.sh
run require-migration-ticket.sh
run require-active-ticket.sh
run suggest-mcp-search.sh
run warn-review-marker-write.sh
run detect-role-trigger.sh
