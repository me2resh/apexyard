#!/usr/bin/env bash
# Dispatch Claude Code Bash calls to the matching existing ApexYard hooks.
set -euo pipefail

# PR metadata snapshot (AgDR-0256, me2resh/apexyard#1759). Remove every
# inherited snapshot value and every control variable before any hook runs.
# Bash imports an environment variable as a shell variable, so an inherited
# _dispatch_complete=1 could turn a crash into exit 0, and an inherited
# _prmeta_dir could aim the cleanup at a directory that another process
# chose. `unset` also removes an inherited export attribute.
for _prmeta_var in $(compgen -A variable APEXYARD_PRMETA_ 2>/dev/null || true); do
  unset "$_prmeta_var"
done
unset APEXYARD_PRMETA_OWNER_PID APEXYARD_PRMETA_REPO APEXYARD_PRMETA_PR \
  APEXYARD_PRMETA_HEAD APEXYARD_PRMETA_BRANCH APEXYARD_PRMETA_BASE \
  APEXYARD_PRMETA_COUNT APEXYARD_PRMETA_DIR APEXYARD_PRMETA_FILES_SHA256 \
  _prmeta_var _dispatch_complete _prmeta_have_snapshot _prmeta_dir _rc
_dispatch_complete=0
_prmeta_have_snapshot=0
_prmeta_dir=
_rc=0

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
#
# Check [ -r ], not [ -f ] (A1, me2resh/apexyard#1403 review): under
# `set -e`, sourcing a file that EXISTS but is unreadable makes the `.`
# builtin fail, and the whole dispatcher then exits with that failure's
# code (1) before any merge gate has run. Claude Code only blocks a tool
# call on exit 2, so an unreadable library used to let every Bash command
# through unblocked, not just merges — a silent fail-open, not a fail-closed
# exit 1 as the exit code alone might suggest.
#
# If the file is missing, is_merge_command stays undefined. The fail-closed
# path below then runs the merge gates on every Bash command. In a real
# install, each gate blocks because its required library is missing. The
# dispatcher adds no separate absence block. If the file exists but cannot
# be read, block here and name the file instead of attempting to source it.
if [ -e "$HOOK_DIR/_lib-extract-pr.sh" ] && [ ! -r "$HOOK_DIR/_lib-extract-pr.sh" ]; then
  echo "BLOCKED: dispatcher found _lib-extract-pr.sh but cannot read it." >&2
  echo "Unreadable: $HOOK_DIR/_lib-extract-pr.sh" >&2
  echo "A dispatcher that cannot load its own merge-shape parser fails" >&2
  echo "closed instead of silently skipping the check. Restore read" >&2
  echo "permissions on the file and retry." >&2
  exit 2
fi
# The merge parser and continuation router require the shared awk helper.
if [ ! -r "$HOOK_DIR/_lib-awk-fallback.sh" ] || ! . "$HOOK_DIR/_lib-awk-fallback.sh"; then
  echo "BLOCKED: dispatcher cannot load _lib-awk-fallback.sh. Restore the library and retry." >&2
  exit 2
fi
for fn in _run_awk_or_fallback join_shell_continuations _join_shell_continuations_fallback; do
  if ! declare -F "$fn" >/dev/null 2>&1; then
    printf 'BLOCKED: dispatcher missing required awk helper %s. Restore the library and retry.\n' "$fn" >&2
    exit 2
  fi
done
if [ -r "$HOOK_DIR/_lib-extract-pr.sh" ]; then
  # shellcheck source=/dev/null
  . "$HOOK_DIR/_lib-extract-pr.sh"
fi
# Per-call forge time limit for prefetch / recheck (#1796).
if [ -r "$HOOK_DIR/_lib-gh-timeout.sh" ]; then
  # shellcheck source=/dev/null
  . "$HOOK_DIR/_lib-gh-timeout.sh"
fi
if ! command -v apexyard_gh >/dev/null 2>&1; then
  apexyard_gh() { gh "$@"; }
fi

# run_hook is the FAIL-OPEN path, for advisory checks and cost guards. A crash
# or timeout in one of these hooks warns and the dispatcher carries on.
# Gates that must fail closed use run_fail_closed_hook instead. The dispatch
# loop and the gate functions below choose between the two by script name.
run_hook() {
  local script="$1" rc=0
  # A hook may warn or fail for an unrelated reason, but only exit 2 blocks
  # the tool call. Keep running the remaining gates so one failed hook cannot
  # suppress a later safety or merge gate.
  case "$script" in
    block-main-push.sh)
      if APEXYARD_OPS_SCOPE_GUARD=1 "$HOOK_DIR/$script" <<<"$INPUT"; then :; else rc=$?; fi
      ;;
    block-reviewer-repo-mutation.sh|block-reviewer-ci-wait.sh)
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

# run_fail_closed_hook: the FAIL-CLOSED path (me2resh/apexyard#1403,
# AgDR-0169; extended to ticket-first by me2resh/apexyard#1623).
#
# run_hook above WARNS and continues past a non-2 non-zero exit, which is
# right for an advisory check but wrong for a gate whose only job is to
# decide whether a tool call may proceed. A gate that cannot run its own
# check (a missing sourced library under POSIX mode, a crash, a syntax
# error, a kill signal) still exits non-zero, just not 2. run_hook would log
# that as a WARN and let the call through unchecked. This wrapper treats it
# as a BLOCKED instead.
#
# A gate that hangs is not caught here. The dispatcher sets no timer of its
# own. The "timeout" and "onFailure": "block" fields on the dispatcher entry
# in .claude/settings.json end a hung gate and block the call. See
# docs/hooks-fail-closed.md.
#
# Fail-closed gates: the four merge gates (run_merge_gate_hook) and
# require-active-ticket.sh (ticket-first).
run_fail_closed_hook() {
  local script="$1" rc=0
  if "$HOOK_DIR/$script" <<<"$INPUT"; then :; else rc=$?; fi
  if [ "$rc" -eq 2 ]; then
    exit 2
  fi
  if [ "$rc" -ne 0 ]; then
    printf 'BLOCKED: %s exited %s instead of a normal PASS. A gate that cannot run its own check fails closed, not open.\n' "$script" "$rc" >&2
    exit 2
  fi
}

# The four merge gates keep their own name for readers of the AgDR-0169 trail.
run_merge_gate_hook() {
  run_fail_closed_hook "$1"
}

# run_cost_guard_hook: the explicit FAIL-OPEN exception. block-reviewer-ci-wait.sh
# is a cost guard (me2resh/apexyard#1625). If it crashes, the reviewer pays for
# a CI poll. No safety property is lost. A crash must not block a whole review
# run, so a crash warns and the dispatcher continues. Its own exit 2 still
# blocks. Do not move this hook to run_fail_closed_hook.
run_cost_guard_hook() {
  run_hook "$1"
}

# Text-match backstop for direct calls to the menu record writers (AgDR-0104).
if printf '%s' "$COMMAND" | grep -qE 'record-menu-approval|_lib-menu-approval|menu_approval_write_record'; then
  echo "BLOCKED: model Bash calls must not invoke menu approval writers." >&2
  exit 2
fi

# APEXYARD_DISPATCH_GATE: Bash|*|block-protected-target-writes.sh
# APEXYARD_DISPATCH_GATE: Bash|*|block-ambient-tracker-repo.sh
# APEXYARD_DISPATCH_GATE: Bash|*|block-privileged-escalation.sh
# APEXYARD_DISPATCH_GATE: Bash|*|require-skill-for-issue-create.sh
# APEXYARD_DISPATCH_GATE: Bash|*|require-orbit-slice-for-ticket.sh
# APEXYARD_DISPATCH_GATE: Bash|*|require-migration-ticket.sh
# APEXYARD_DISPATCH_GATE: Bash|*|require-active-ticket.sh
# APEXYARD_DISPATCH_GATE: Bash|*|warn-review-marker-write.sh
# APEXYARD_DISPATCH_GATE: Bash|*|warn-isolated-build-risk.sh
# APEXYARD_DISPATCH_GATE: Bash|*|block-reviewer-repo-mutation.sh
# APEXYARD_DISPATCH_GATE: Bash|*|block-reviewer-ci-wait.sh
# APEXYARD_DISPATCH_GATE: Bash|*|block-forged-menu-approval.sh
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
  block-protected-target-writes.sh \
  block-ambient-tracker-repo.sh \
  block-privileged-escalation.sh \
  require-skill-for-issue-create.sh \
  require-orbit-slice-for-ticket.sh \
  require-migration-ticket.sh \
  require-active-ticket.sh \
  warn-review-marker-write.sh \
  warn-isolated-build-risk.sh \
  block-reviewer-repo-mutation.sh \
  block-reviewer-ci-wait.sh \
  block-forged-menu-approval.sh; do
  case "$script" in
    # Ticket-first fails closed (me2resh/apexyard#1623).
    block-protected-target-writes.sh|require-active-ticket.sh) run_fail_closed_hook "$script" ;;
    # Menu-record forgery guard fails closed too (AgDR-0234). A crash must
    # not let a Bash write of approval_channel=menu through unchecked.
    block-forged-menu-approval.sh) run_fail_closed_hook "$script" ;;
    # Cost guard: fails open on purpose. See run_cost_guard_hook.
    block-reviewer-ci-wait.sh) run_cost_guard_hook "$script" ;;
    *) run_hook "$script" ;;
  esac
done

# --- PR metadata prefetch (AgDR-0256, me2resh/apexyard#1759) ---
#
# The four merge gates used to make 9 to 13 serial forge calls. Several
# calls fetched the same data. The prefetch fetches the PR metadata one
# time and exports the trusted scalars to the gate processes. Only the file
# list is on disk, and its SHA-256 digest is in the environment. Each gate
# reads the snapshot through the readers in _lib-extract-pr.sh. A miss makes
# the gate fetch, as before. After the four gates pass, the dispatcher reads
# the head SHA again (recheck_pr_head).
#
# The prefetch runs only for a merge command with a literal PR number and a
# literal, valid --repo (or a repo in the API path or the wrapper), on the
# gh path. Any other merge gets no snapshot and no recheck.
#
# The prefetch does not depend on `set -e`. It checks each step with `if`.
# The caller runs it as `prefetch_pr_metadata || true`, so a failure only
# means that the gates fetch.
prefetch_pr_metadata() {
  local cmd="${COMMAND:-}" pr="" repo="" host="" api_repo="" json="" fields=""
  local head="" branch="" base="" count="" list="" lines="" sum="" dir=""
  local -a host_args=()
  if ! command -v is_merge_command >/dev/null 2>&1 \
    || ! command -v prmeta_sha256 >/dev/null 2>&1 \
    || ! command -v merge_repo_is_valid >/dev/null 2>&1; then
    return 1
  fi
  if ! is_merge_command "$cmd"; then
    return 1
  fi
  if has_conflicting_repo_flags "$cmd"; then
    return 1
  fi
  if merge_command_uses_variable "$cmd"; then
    return 1
  fi
  if ! repo=$(extract_explicit_repo_from_command "$cmd") || [ -z "$repo" ]; then
    return 1
  fi
  if ! merge_repo_is_valid "$repo"; then
    return 1
  fi
  if ! pr=$(extract_pr_number "$cmd" text-only) || [[ ! "$pr" =~ ^[0-9]+$ ]]; then
    return 1
  fi
  if [ "$(_forge_from_command "$cmd")" != gh ] || [ "$(_forge_kind_for "$repo")" != gh ]; then
    return 1
  fi

  # Call 1: the scalars. All or none.
  if ! json=$(apexyard_gh pr view "$pr" --repo "$repo" --json headRefOid,headRefName,baseRefName,changedFiles 2>/dev/null); then
    return 1
  fi
  if ! fields=$(printf '%s' "$json" | jq -r '
      select(type == "object"
        and (.headRefOid | type == "string")
        and (.headRefName | type == "string") and .headRefName != ""
        and (.baseRefName | type == "string") and .baseRefName != ""
        and (.changedFiles | type == "number"))
      | [.headRefOid, .headRefName, .baseRefName, (.changedFiles | tostring)]
      | join("\n")' 2>/dev/null) || [ -z "$fields" ]; then
    return 1
  fi
  head=$(printf '%s\n' "$fields" | sed -n 1p)
  branch=$(printf '%s\n' "$fields" | sed -n 2p)
  base=$(printf '%s\n' "$fields" | sed -n 3p)
  count=$(printf '%s\n' "$fields" | sed -n 4p)
  if [ "$(printf '%s\n' "$fields" | wc -l | tr -d ' ')" != 4 ]; then
    return 1
  fi
  if [[ ! "$head" =~ ^[0-9a-f]{40}$ ]]; then
    return 1
  fi
  if [ -z "$branch" ] || [ -z "$base" ] \
    || [[ "$branch" == *[[:cntrl:]]* ]] || [[ "$base" == *[[:cntrl:]]* ]]; then
    return 1
  fi
  if [[ ! "$count" =~ ^(0|[1-9][0-9]*)$ ]] || [ "${#count}" -gt 4 ] || [ "$count" -gt 3000 ]; then
    return 1
  fi
  export APEXYARD_PRMETA_OWNER_PID="$$" APEXYARD_PRMETA_REPO="$repo" \
    APEXYARD_PRMETA_PR="$pr" APEXYARD_PRMETA_HEAD="$head" \
    APEXYARD_PRMETA_BRANCH="$branch" APEXYARD_PRMETA_BASE="$base" \
    APEXYARD_PRMETA_COUNT="$count"
  _prmeta_have_snapshot=1

  # Call 2: the file list. Optional. A failure leaves the scalars in use,
  # and the gates fetch only the list. COUNT=0 writes no file.
  if [ "$count" -lt 1 ]; then
    return 0
  fi
  api_repo="$repo"
  if [[ "$repo" == */*/* ]]; then
    host="${repo%%/*}"
    api_repo="${repo#*/}"
    host_args=(--hostname "$host")
  fi
  if ! list=$(apexyard_gh api ${host_args[@]+"${host_args[@]}"} --paginate "repos/${api_repo}/pulls/${pr}/files?per_page=100" --jq '.[].filename' 2>/dev/null); then
    return 0
  fi
  if [ -z "$list" ]; then
    return 0
  fi
  lines=$(printf '%s\n' "$list" | wc -l | tr -d ' ')
  if [ "$lines" != "$count" ]; then
    return 0
  fi
  if ! sum=$(printf '%s\n' "$list" | prmeta_sha256); then
    return 0
  fi
  if ! dir=$(mktemp -d "${TMPDIR:-/tmp}/apexyard-prmeta.XXXXXX" 2>/dev/null) || [ -z "$dir" ]; then
    return 0
  fi
  _prmeta_dir="$dir"
  # noclobber in a subshell, so it does not leak into the dispatcher. The
  # writer never reads the file back.
  if ! chmod 700 "$dir" 2>/dev/null \
    || ! ( set -C; printf '%s\n' "$list" >"$dir/files" ) 2>/dev/null; then
    rm -rf -- "$dir" 2>/dev/null || true
    _prmeta_dir=
    return 0
  fi
  export APEXYARD_PRMETA_DIR="$dir" APEXYARD_PRMETA_FILES_SHA256="$sum"
  return 0
}

# Reads the head SHA again after the four gates pass. Every failure path
# exits 2. A bare failing capture would exit 1 under `set -e`, and exit 1
# lets the call run on a client older than 2.1.295 (AgDR-0256 D4).
recheck_pr_head() {
  local h="" pr="${APEXYARD_PRMETA_PR:-}" repo="${APEXYARD_PRMETA_REPO:-}" want="${APEXYARD_PRMETA_HEAD:-}"
  # stderr open so a per-call timeout BLOCKED line reaches the operator (#1796).
  if ! h=$(apexyard_gh pr view "$pr" --repo "$repo" --json headRefOid -q .headRefOid); then
    printf 'BLOCKED: could not confirm PR #%s HEAD after the merge gates passed. Retry the merge.\n' "$pr" >&2
    exit 2
  fi
  if [[ ! "$h" =~ ^[0-9a-f]{40}$ ]]; then
    printf 'BLOCKED: could not confirm PR #%s HEAD after the merge gates passed. Retry the merge.\n' "$pr" >&2
    exit 2
  fi
  if [ -z "$want" ] || [ "$h" != "$want" ]; then
    printf 'BLOCKED: PR #%s HEAD moved during gate evaluation (gates saw %s, forge now reports %s). Retry the merge so the gates check the new head.\n' \
      "$pr" "${want:-<none>}" "$h" >&2
    exit 2
  fi
}

# Removes the snapshot from the environment, so a later hook does not see it.
clear_pr_metadata() {
  unset APEXYARD_PRMETA_OWNER_PID APEXYARD_PRMETA_REPO APEXYARD_PRMETA_PR \
    APEXYARD_PRMETA_HEAD APEXYARD_PRMETA_BRANCH APEXYARD_PRMETA_BASE \
    APEXYARD_PRMETA_COUNT APEXYARD_PRMETA_DIR APEXYARD_PRMETA_FILES_SHA256
  _prmeta_have_snapshot=0
}

_merge_gates_ran=0
run_merge_gates() {
  # Completion-flag EXIT trap (AgDR-0256 D5). Every exit before the last
  # statement of this file sets _dispatch_complete=1 becomes exit 2,
  # whatever its status. A crash with status 0, 1 or any other value then
  # blocks on every client. The trap also removes the snapshot directory.
  # Every planned exit after this point is `exit 2`. A new planned exit
  # must set _dispatch_complete=1 first (test_prmeta_1759.sh checks this).
  trap '_rc=$?; if [ -n "${_prmeta_dir:-}" ]; then rm -rf -- "$_prmeta_dir" 2>/dev/null || true; fi; if [ "${_dispatch_complete:-0}" != 1 ]; then _rc=2; fi; exit "$_rc"' EXIT
  if [ "${_merge_gates_ran}" -eq 1 ]; then
    return 0
  fi
  _merge_gates_ran=1
  prefetch_pr_metadata || true
  run_merge_gate_hook block-unreviewed-merge.sh
  run_merge_gate_hook require-design-review-for-ui.sh
  run_merge_gate_hook block-merge-on-red-ci.sh
  run_merge_gate_hook require-architecture-review.sh
  if [ "${_prmeta_have_snapshot:-0}" = 1 ]; then
    recheck_pr_head
  fi
  clear_pr_metadata
}

# The push and commit arms are run-once functions. The prefix case below and
# the whole-command scan after it can both reach them (me2resh/apexyard#1527).
_push_gates_ran=0
run_push_gates() {
  if [ "${_push_gates_ran}" -eq 1 ]; then
    return 0
  fi
  _push_gates_ran=1
  run_hook block-main-push.sh
  run_hook validate-branch-name.sh
  run_hook pre-push-gate.sh
  run_hook block-agent-routing-drift.sh
}

_commit_gates_ran=0
run_commit_gates() {
  if [ "${_commit_gates_ran}" -eq 1 ]; then
    return 0
  fi
  _commit_gates_ran=1
  run_hook check-secrets.sh
  run_hook block-onboarding-in-git.sh
  run_hook verify-commit-refs.sh
  run_hook validate-commit-format.sh
  run_hook require-agdr-for-arch-changes.sh
  run_hook block-agent-routing-drift.sh
  run_hook warn-bootstrap-scope.sh
}

case "$COMMAND" in
  "git add "*) run_hook block-git-add-all.sh ;;
  "git push "*) run_push_gates ;;
  "git commit "*) run_commit_gates ;;
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

# A case glob matches only the start of the command. A push or commit that
# follows `cd <dir> &&`, a `;`, or a git global option such as `-C <dir>`
# missed every push and commit gate (me2resh/apexyard#1527). Scan the whole
# command, as the merge gates do (AgDR-0162). Any non-word character ends
# the subcommand, so `git push;`, `git push&&` and `(git push)` also route.
#
# The scan adds routing when its join succeeds. If awk fails, run the push
# and commit gates unconditionally. #1780 / AgDR-0262: strip a confirmed
# quoted heredoc body before push/commit routing only when the whole
# command is one allow-listed data sink, so prose mentions do not start
# those gates. Any other command keeps the raw command, so text that only
# mentions a push or commit (an echo, a commit message) still routes. The
# alias check and push/commit routing read the stripped text. The
# merge-shape scan reads the raw command. If the strip fails, run both gate
# groups (fail closed). Unquoted heredocs and here-strings are not stripped.
#
# Line continuations are joined, because grep reads one line at a
# time and `git \<newline> push` would otherwise put git and push on
# different lines. Bash 3.2's whole-string substitution is superlinear on
# thousands of continuations, so use one awk pass. The sentinel preserves
# trailing newlines through command substitution and a final lone backslash.
# The conditional awk substitution cannot abort dispatch under set -e.
# The option list accepts `-C`, `-c` and the long options that take a
# separate-word value, plus any `-x`, `--opt` or `--opt=value`.
_scan_failed=0
_scan_bash_cmd=""
# Preserve broad routing for git\<newline>push and quoted/commented pairs.
# Bash removal could hide verbs that the existing dispatcher routes.
_dispatch_join_failure() { return 1; }
# A join failure here fails closed before the alias library loads. The
# route text is joined again after the quoted-heredoc strip below
# (#1829 B1b).
if [ -r "$HOOK_DIR/_lib-awk-fallback.sh" ]; then
  . "$HOOK_DIR/_lib-awk-fallback.sh"
  if _scan_cmd=$(join_shell_continuations "$COMMAND" broad-space _dispatch_join_failure); then
    :
  else
    _scan_failed=1
  fi
else
  _scan_failed=1
fi
# The matcher lives in _lib-git-global.sh so the gates use the same
# expression (#1730, #1731). A missing library fails closed: run both
# gate groups rather than skip a push or commit the scan cannot see.
_alias_library_loaded=0
if [ "$_scan_failed" -eq 0 ] && [ -r "$HOOK_DIR/_lib-git-global.sh" ]; then
  # Bash 3.2 exits on a sourced failure even inside an if condition.
  # Capture the load status with errexit off, then restore dispatcher policy.
  set +e
  # shellcheck disable=SC1091
  . "$HOOK_DIR/_lib-git-global.sh"
  _alias_load_rc=$?
  set -e
  if [ "$_alias_load_rc" -eq 0 ]; then
    _alias_library_loaded=1
  else
    _scan_failed=1
  fi
else
  _scan_failed=1
fi
if ! command -v command_has_git_subcommand >/dev/null 2>&1; then
  _scan_failed=1
fi
# #1780: strip quoted heredoc bodies before the alias check and push/commit
# routing. The raw COMMAND stays for merge-shape matching below.
if [ "$_scan_failed" -eq 0 ]; then
  if [ -r "$HOOK_DIR/_lib-strip-heredoc.sh" ]; then
    # shellcheck source=/dev/null
    . "$HOOK_DIR/_lib-strip-heredoc.sh"
    if ! declare -F strip_heredoc_bodies >/dev/null 2>&1; then
      _scan_failed=1
    # #1829 B1b: strip the raw command, then join continuations. The
    # stripper must see each backslash-newline, because bash removes it
    # before it reads operators: `<\<newline><` is one `<<`. The joined
    # text hides that operator.
    elif ! _scan_cmd=$(strip_heredoc_bodies "$COMMAND" quoted); then
      _scan_failed=1
    else
      # #1837: the broad join puts a space where bash puts nothing, so a
      # continuation inside a word (the verb, a -C value, a redirection
      # target, a dashed program name) splits that word. Also route on the
      # text that bash runs. Only a pair that comes directly after a
      # character that is not a blank needs it. After a blank, both joins
      # give the same words. The one exception is a comment line, which
      # AgDR-0269 records as a residual. This keeps the cost off the usual
      # ` \` line end.
      case "$_scan_cmd" in
        *[![:space:]]\\$'\n'*)
          _scan_bash_cmd=$(join_shell_continuations "$_scan_cmd" bash _dispatch_join_failure) || _scan_failed=1
          ;;
      esac
      if ! _scan_cmd=$(join_shell_continuations "$_scan_cmd" broad-space _dispatch_join_failure); then
        _scan_failed=1
      fi
    fi
  else
    _scan_failed=1
  fi
fi
if [ "$_alias_library_loaded" = 1 ] && command -v git_alias_check >/dev/null 2>&1; then
  # cmd and cwd are read by git_alias_check in this shell.
  # Use the stripped route text, so quoted heredoc prose is not scanned
  # (#1780). Use the raw command when the strip failed closed.
  # shellcheck disable=SC2034
  if [ "$_scan_failed" -eq 0 ]; then
    cmd="$_scan_cmd"
  else
    cmd="$COMMAND"
  fi
  # shellcheck disable=SC2034
  cwd=$(jq -r '.cwd // .tool_input.cwd // empty' <<<"$INPUT" 2>/dev/null) || cwd=""
  git_alias_check push commit || exit 2
else
  _alias_fallback_re='[gG][iI][tT].*([aA][lL][iI][aA][sS]\.|--[cC][oO][nN][fF][iI][gG]-[eE][nN][vV])'
  if [[ "$COMMAND" =~ $_alias_fallback_re ]]; then
    echo "BLOCKED: dispatcher cannot load its git alias check." >&2
    exit 2
  fi
fi
if [ "$_scan_failed" -eq 1 ]; then
  run_push_gates
  run_commit_gates
else
  # #1816 G2/G3: expansion hides the command word or verb — fail closed.
  # #1837: each check reads the broad-join text and, when the command holds
  # a continuation, the bash-join text too. A route from either one counts.
  if command -v git_uncertain_protected_shape >/dev/null 2>&1 \
    && { git_uncertain_protected_shape "$_scan_cmd" \
      || { [ -n "${_scan_bash_cmd:-}" ] && git_uncertain_protected_shape "$_scan_bash_cmd"; }; }; then
    run_push_gates
    run_commit_gates
  else
    if command_has_git_subcommand "$_scan_cmd" push \
      || { [ -n "${_scan_bash_cmd:-}" ] && command_has_git_subcommand "$_scan_bash_cmd" push; }; then
      run_push_gates
    fi
    if command_has_git_subcommand "$_scan_cmd" commit \
      || { [ -n "${_scan_bash_cmd:-}" ] && command_has_git_subcommand "$_scan_bash_cmd" commit; }; then
      run_commit_gates
    fi
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
  # #1748: no jq means the raw git command cannot be checked safely.
  if [ ! -r "$HOOK_DIR/_lib-fail-closed-json.sh" ] || ! . "$HOOK_DIR/_lib-fail-closed-json.sh"; then
    echo "BLOCKED: dispatcher cannot load its raw-payload parser." >&2
    exit 2
  fi
  if ! command -v git_subcommand_payload_pattern >/dev/null 2>&1; then
    # shellcheck disable=SC1091
    { [ -r "$HOOK_DIR/_lib-git-global.sh" ] && . "$HOOK_DIR/_lib-git-global.sh"; } || {
      echo "BLOCKED: dispatcher cannot load its git matcher." >&2
      exit 2
    }
  fi
  if raw_payload_command_matches "$INPUT" "$(git_subcommand_payload_pattern '(-c[[:space:]]+[^[:space:]]*[Aa][Ll][Ii][Aa][Ss]\.[^[:space:]]+|--config-env)')" \
    || raw_payload_command_matches "$INPUT" "$(git_subcommand_payload_pattern push)" \
    || raw_payload_command_matches "$INPUT" "$(git_subcommand_payload_pattern commit)" \
    || raw_payload_command_matches "$INPUT" "$(git_redir_uncertain_payload_pattern)" \
    || raw_payload_command_matches "$INPUT" "$(git_dashed_payload_pattern)"; then
    echo "BLOCKED: dispatcher cannot parse this git command. Restore jq and retry." >&2
    exit 2
  fi
  printf 'WARN: dispatcher could not parse the Bash command; running merge gates fail-closed.\n' >&2
  run_merge_gates
fi

# Last statement. The completion-flag trap in run_merge_gates turns every
# exit before this line into exit 2 (AgDR-0256 D5). Keep this line last.
_dispatch_complete=1
