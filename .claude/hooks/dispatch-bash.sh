#!/usr/bin/env bash
# Dispatch Claude Code Bash calls to the matching existing ApexYard hooks.
set -euo pipefail

HOOK_DIR="$(cd "$(dirname "$0")" && pwd -P)"
INPUT=$(cat)
COMMAND=$(jq -r '.tool_input.command // empty' <<<"$INPUT")

run_hook() {
  local script="$1"
  case "$script" in
    block-main-push.sh) APEXYARD_OPS_SCOPE_GUARD=1 "$HOOK_DIR/$script" <<<"$INPUT" ;;
    block-reviewer-repo-mutation.sh)
      APEXYARD_REVIEW_OPS_ROOT="$(cd "$HOOK_DIR/.." && pwd -P)" "$HOOK_DIR/$script" <<<"$INPUT" ;;
    *) "$HOOK_DIR/$script" <<<"$INPUT" ;;
  esac
}

# Hooks without a command predicate are safety checks for every Bash call.
for script in \
  block-ambient-tracker-repo.sh \
  block-privileged-escalation.sh \
  require-skill-for-issue-create.sh \
  require-migration-ticket.sh \
  require-active-ticket.sh \
  suggest-mcp-search.sh \
  warn-review-marker-write.sh \
  warn-isolated-build-risk.sh \
  block-reviewer-repo-mutation.sh; do
  run_hook "$script"
done

case "$COMMAND" in
  "git add "*) run_hook block-git-add-all.sh ;;
  "git push "*)
    run_hook block-main-push.sh
    run_hook validate-branch-name.sh
    run_hook pre-push-gate.sh
    run_hook block-agent-routing-drift.sh
    ;;
  "git commit "*)
    run_hook check-secrets.sh
    run_hook block-onboarding-in-git.sh
    run_hook verify-commit-refs.sh
    run_hook validate-commit-format.sh
    run_hook require-agdr-for-arch-changes.sh
    run_hook block-agent-routing-drift.sh
    run_hook warn-bootstrap-scope.sh
    ;;
  "gh issue create "*)
    run_hook suggest-ticket-template.sh
    run_hook validate-issue-structure.sh
    run_hook block-private-refs-in-public-repos.sh
    ;;
  "gh pr create "*)
    run_hook validate-pr-create.sh
    run_hook block-private-refs-in-public-repos.sh
    run_hook require-agdr-for-arch-pr.sh
    run_hook nudge-control-adversarial-test.sh
    ;;
  "gh issue comment "*) run_hook block-private-refs-in-public-repos.sh ;;
  "gh pr comment "*) run_hook block-private-refs-in-public-repos.sh ;;
  "gh pr review "*) run_hook block-private-refs-in-public-repos.sh ;;
  "gh issue edit "*) run_hook detect-role-trigger.sh ;;
  "gh api "*)
    run_hook block-private-refs-in-public-repos.sh
    run_hook block-unreviewed-merge.sh
    run_hook require-design-review-for-ui.sh
    run_hook block-merge-on-red-ci.sh
    run_hook require-architecture-review.sh
    ;;
  "gh pr merge "*)
    run_hook block-private-refs-in-public-repos.sh
    run_hook block-unreviewed-merge.sh
    run_hook require-design-review-for-ui.sh
    run_hook block-merge-on-red-ci.sh
    run_hook require-architecture-review.sh
    ;;
  "glab mr merge "*)
    run_hook block-unreviewed-merge.sh
    run_hook require-design-review-for-ui.sh
    run_hook block-merge-on-red-ci.sh
    run_hook require-architecture-review.sh
    ;;
  "glab api "*)
    run_hook block-unreviewed-merge.sh
    run_hook require-design-review-for-ui.sh
    run_hook block-merge-on-red-ci.sh
    run_hook require-architecture-review.sh
    ;;
  "tracker_pr_merge "*)
    run_hook block-unreviewed-merge.sh
    run_hook require-design-review-for-ui.sh
    run_hook block-merge-on-red-ci.sh
    run_hook require-architecture-review.sh
    ;;
esac
