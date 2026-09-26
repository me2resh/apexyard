#!/usr/bin/env bash
# Dispatch Claude Code Bash calls to the matching existing ApexYard hooks.
set -euo pipefail

HOOK_DIR="$(cd "$(dirname "$0")" && pwd -P)"
INPUT=$(cat)
# Do not let a missing or broken jq abort dispatch with exit 127. Claude
# Code only blocks on exit 2. Merge gates already fail closed on a raw
# merge-shaped payload when they cannot parse the command (T13).
COMMAND=""
if command -v jq >/dev/null 2>&1; then
  COMMAND=$(jq -r '.tool_input.command // empty' <<<"$INPUT" 2>/dev/null) || COMMAND=""
fi
if [ "$COMMAND" = "null" ]; then
  COMMAND=""
fi

# Merge-shape detection for wrapped commands (AgDR-0162, me2resh/apexyard#1338).
# Prefix case arms still handle the one-line forms. is_merge_command scans the
# full payload command, so `bash -c` around tracker_pr_merge still routes.
if [ -f "$HOOK_DIR/_lib-extract-pr.sh" ]; then
  # shellcheck source=/dev/null
  . "$HOOK_DIR/_lib-extract-pr.sh"
fi

run_hook() {
  local script="$1" rc=0
  # A hook may warn or fail for an unrelated reason, but only exit 2 blocks
  # the tool call. Keep running the remaining gates so one failed hook cannot
  # suppress a later safety or merge gate.
  case "$script" in
    block-main-push.sh)
      if APEXYARD_OPS_SCOPE_GUARD=1 "$HOOK_DIR/$script" <<<"$INPUT"; then :; else rc=$?; fi
      ;;
    block-reviewer-repo-mutation.sh)
      if APEXYARD_REVIEW_OPS_ROOT="$(cd "$HOOK_DIR/../.." && pwd -P)" "$HOOK_DIR/$script" <<<"$INPUT"; then :; else rc=$?; fi
      ;;
    *)
      if "$HOOK_DIR/$script" <<<"$INPUT"; then :; else rc=$?; fi
      ;;
  esac
  if [ "$rc" -eq 2 ]; then
    exit 2
  fi
  if [ "$rc" -ne 0 ]; then
    printf 'WARN: %s exited %s; continuing with remaining gates.\n' "$script" "$rc" >&2
  fi
}

# run_merge_gate_hook: the four MERGE-GATE hooks fail CLOSED, not open, on
# any exit other than 0 or 2 (me2resh/apexyard#1403, AgDR-0169).
#
# run_hook above WARNS and continues past a non-2 non-zero exit, which is
# right for an advisory check but wrong for a gate whose only job is to
# decide whether a merge may proceed. A merge gate that cannot run its own
# check (a missing sourced library under POSIX mode, for one) still exits
# non-zero, just not 2 — and a normal Claude Code session never sets
# POSIXLY_CORRECT, but other harnesses and CI shells may. `run_hook` would
# log that as a WARN and let the merge through unreviewed. This wrapper
# treats it as a BLOCKED instead.
run_merge_gate_hook() {
  local script="$1" rc=0
  if "$HOOK_DIR/$script" <<<"$INPUT"; then :; else rc=$?; fi
  if [ "$rc" -eq 2 ]; then
    exit 2
  fi
  if [ "$rc" -ne 0 ]; then
    printf 'BLOCKED: %s exited %s instead of a normal PASS. A merge gate that cannot run its own check fails closed, not open.\n' "$script" "$rc" >&2
    exit 2
  fi
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

_push_hooks_ran=0
run_push_hooks() {
  if [ "${_push_hooks_ran}" -eq 1 ]; then
    return 0
  fi
  _push_hooks_ran=1
  run_hook block-main-push.sh
  run_hook validate-branch-name.sh
  run_hook pre-push-gate.sh
  run_hook block-agent-routing-drift.sh
}

# is_push_command: recognises `git push` and `git -C <dir> push` anywhere in
# the command text, not only as a literal prefix (me2resh/apexyard#1366,
# #1405 review items 1 / H1 item 3). Mirrors pre-push-gate.sh's own
# push-clause regex, which the hook needs anyway to resolve the pushed
# repo — two independent copies of the same pattern, the same shape as the
# other `\bgit\s+push\b` checks already duplicated across this framework's
# hooks (block-main-push.sh, validate-branch-name.sh, and others each carry
# their own).
is_push_command() {
  local cmd="$1"
  echo "$cmd" | grep -qE '\bgit[[:space:]]+(-C[[:space:]]+("[^"]*"|'"'"'[^'"'"']*'"'"'|[^[:space:];&|]+)[[:space:]]+)?push\b'
}

_merge_gates_ran=0
run_merge_gates() {
  if [ "${_merge_gates_ran}" -eq 1 ]; then
    return 0
  fi
  _merge_gates_ran=1
  run_merge_gate_hook block-unreviewed-merge.sh
  run_merge_gate_hook require-design-review-for-ui.sh
  run_merge_gate_hook block-merge-on-red-ci.sh
  run_merge_gate_hook require-architecture-review.sh
}

case "$COMMAND" in
  "git add "*) run_hook block-git-add-all.sh ;;
  "git push "*) run_push_hooks ;;
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
    run_merge_gates
    ;;
  "gh pr merge "*)
    run_hook block-private-refs-in-public-repos.sh
    run_merge_gates
    ;;
  "glab mr merge "*)
    run_merge_gates
    ;;
  "glab api "*)
    run_merge_gates
    ;;
  "tracker_pr_merge "*)
    run_merge_gates
    ;;
esac

# A `cd <dir> && git push` or `git -C <dir> push` command misses the literal
# "git push "* case arm above — the exact gap me2resh/apexyard#1405's review
# reported (Rex item 1, Hakim H1 item 3): the #1366 pre-push-gate.sh fix
# never runs for either reported shape in production. Route those payloads
# with the same push detector pre-push-gate.sh needs anyway to resolve its
# own target. `is_push_command` is defined in this file, not sourced from an
# optional lib, so — unlike the merge parser below — there is no missing-
# detector case to fail closed on here.
#
# The `if` wrapper is load-bearing under `set -e`: a bare `A && B` statement
# where B is the LAST command in the list still aborts the whole dispatcher
# on B's non-zero exit — is_push_command returning 1 for the common,
# non-push case would otherwise kill every unrelated Bash call.
if [ "${_push_hooks_ran}" -eq 0 ]; then
  if is_push_command "$COMMAND"; then
    run_push_hooks
  fi
fi

# A wrapper such as `bash -c '… tracker_pr_merge …'` misses the prefix case.
# Route those payloads with the same parser the merge-gate bodies use.
# If the parser is missing, run the merge gates. A missing control must
# not fail open (AgDR-0162, Hakim review of me2resh/apexyard#1339).
if [ "${_merge_gates_ran}" -eq 0 ]; then
  if ! command -v is_merge_command >/dev/null 2>&1; then
    printf 'WARN: merge parser missing; running merge gates fail-closed.\n' >&2
    run_merge_gates
  elif is_merge_command "$COMMAND"; then
    run_merge_gates
  fi
fi

# Command parse failed. Route the raw payload to the merge gates so their
# jq-independent fallback still blocks merge-shaped commands.
if [ -z "$COMMAND" ]; then
  printf 'WARN: dispatcher could not parse the Bash command; running merge gates fail-closed.\n' >&2
  run_merge_gates
fi
