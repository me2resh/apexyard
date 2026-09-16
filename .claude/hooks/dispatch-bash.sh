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
      APEXYARD_REVIEW_OPS_ROOT="$(cd "$HOOK_DIR/../.." && pwd -P)" "$HOOK_DIR/$script" <<<"$INPUT" ;;
    *) "$HOOK_DIR/$script" <<<"$INPUT" ;;
  esac
}

# APEXYARD_DISPATCH_GATE: Bash|*|block-ambient-tracker-repo.sh
# APEXYARD_DISPATCH_GATE: Bash|*|block-privileged-escalation.sh
# APEXYARD_DISPATCH_GATE: Bash|*|require-skill-for-issue-create.sh
# APEXYARD_DISPATCH_GATE: Bash|*|require-migration-ticket.sh
# APEXYARD_DISPATCH_GATE: Bash|*|require-active-ticket.sh
# APEXYARD_DISPATCH_GATE: Bash|*|suggest-mcp-search.sh
# APEXYARD_DISPATCH_GATE: Bash|*|warn-review-marker-write.sh
# APEXYARD_DISPATCH_GATE: Bash|*|warn-isolated-build-risk.sh
# APEXYARD_DISPATCH_GATE: Bash|*|block-reviewer-repo-mutation.sh
# APEXYARD_DISPATCH_GATE: Bash|git add *|block-git-add-all.sh
# APEXYARD_DISPATCH_GATE: Bash|git push *|block-main-push.sh
# APEXYARD_DISPATCH_GATE: Bash|git push *|validate-branch-name.sh
# APEXYARD_DISPATCH_GATE: Bash|git push *|pre-push-gate.sh
# APEXYARD_DISPATCH_GATE: Bash|git push *|block-agent-routing-drift.sh
# APEXYARD_DISPATCH_GATE: Bash|git commit *|check-secrets.sh
# APEXYARD_DISPATCH_GATE: Bash|git commit *|block-onboarding-in-git.sh
# APEXYARD_DISPATCH_GATE: Bash|git commit *|verify-commit-refs.sh
# APEXYARD_DISPATCH_GATE: Bash|git commit *|validate-commit-format.sh
# APEXYARD_DISPATCH_GATE: Bash|git commit *|require-agdr-for-arch-changes.sh
# APEXYARD_DISPATCH_GATE: Bash|git commit *|block-agent-routing-drift.sh
# APEXYARD_DISPATCH_GATE: Bash|git commit *|warn-bootstrap-scope.sh
# APEXYARD_DISPATCH_GATE: Bash|gh issue create *|suggest-ticket-template.sh
# APEXYARD_DISPATCH_GATE: Bash|gh issue create *|validate-issue-structure.sh
# APEXYARD_DISPATCH_GATE: Bash|gh issue create *|block-private-refs-in-public-repos.sh
# APEXYARD_DISPATCH_GATE: Bash|gh pr create *|validate-pr-create.sh
# APEXYARD_DISPATCH_GATE: Bash|gh pr create *|block-private-refs-in-public-repos.sh
# APEXYARD_DISPATCH_GATE: Bash|gh pr create *|require-agdr-for-arch-pr.sh
# APEXYARD_DISPATCH_GATE: Bash|gh pr create *|nudge-control-adversarial-test.sh
# APEXYARD_DISPATCH_GATE: Bash|gh issue comment *|block-private-refs-in-public-repos.sh
# APEXYARD_DISPATCH_GATE: Bash|gh pr comment *|block-private-refs-in-public-repos.sh
# APEXYARD_DISPATCH_GATE: Bash|gh pr review *|block-private-refs-in-public-repos.sh
# APEXYARD_DISPATCH_GATE: Bash|gh issue edit *|detect-role-trigger.sh
# APEXYARD_DISPATCH_GATE: Bash|gh api *|block-private-refs-in-public-repos.sh
# APEXYARD_DISPATCH_GATE: Bash|gh api *|block-unreviewed-merge.sh
# APEXYARD_DISPATCH_GATE: Bash|gh api *|require-design-review-for-ui.sh
# APEXYARD_DISPATCH_GATE: Bash|gh api *|block-merge-on-red-ci.sh
# APEXYARD_DISPATCH_GATE: Bash|gh api *|require-architecture-review.sh
# APEXYARD_DISPATCH_GATE: Bash|gh pr merge *|block-private-refs-in-public-repos.sh
# APEXYARD_DISPATCH_GATE: Bash|gh pr merge *|block-unreviewed-merge.sh
# APEXYARD_DISPATCH_GATE: Bash|gh pr merge *|require-design-review-for-ui.sh
# APEXYARD_DISPATCH_GATE: Bash|gh pr merge *|block-merge-on-red-ci.sh
# APEXYARD_DISPATCH_GATE: Bash|gh pr merge *|require-architecture-review.sh
# APEXYARD_DISPATCH_GATE: Bash|glab mr merge *|block-unreviewed-merge.sh
# APEXYARD_DISPATCH_GATE: Bash|glab mr merge *|require-design-review-for-ui.sh
# APEXYARD_DISPATCH_GATE: Bash|glab mr merge *|block-merge-on-red-ci.sh
# APEXYARD_DISPATCH_GATE: Bash|glab mr merge *|require-architecture-review.sh
# APEXYARD_DISPATCH_GATE: Bash|glab api *|block-unreviewed-merge.sh
# APEXYARD_DISPATCH_GATE: Bash|glab api *|require-design-review-for-ui.sh
# APEXYARD_DISPATCH_GATE: Bash|glab api *|block-merge-on-red-ci.sh
# APEXYARD_DISPATCH_GATE: Bash|glab api *|require-architecture-review.sh
# APEXYARD_DISPATCH_GATE: Bash|tracker_pr_merge *|block-unreviewed-merge.sh
# APEXYARD_DISPATCH_GATE: Bash|tracker_pr_merge *|require-design-review-for-ui.sh
# APEXYARD_DISPATCH_GATE: Bash|tracker_pr_merge *|block-merge-on-red-ci.sh
# APEXYARD_DISPATCH_GATE: Bash|tracker_pr_merge *|require-architecture-review.sh

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
