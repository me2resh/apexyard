#!/bin/bash
# Blocks direct pushes and commits to long-lived integration branches.
# All changes must go through pull requests.
#
# Protected branches (default): main / master / dev / develop.
# `dev` was added in apexyard#116 (release-cut model — see AgDR-0007). Forks
# that legitimately use `dev` as a daily-work trunk under their own
# convention can override the protected list via
# `.claude/project-config.json` → `.git.protected_branches[]`.
#
# WORKTREE-SAFE (me2resh/apexyard#549)
# -------------------------------------
# Previously both the push-check and the commit-check resolved the current
# branch via `git branch --show-current` against the hook's cwd (the harness's
# primary checkout). When the operator runs a command in a separate git worktree
# while the primary checkout sits on a protected branch, the old code
# false-blocked legitimate feature-branch work.
#
# Fix:
#   Push:   reuse `_lib-extract-push-ref.sh` (already used by
#           validate-branch-name.sh for the same reason) to read the DESTINATION
#           branch directly from the push command. Tag pushes are no-ops. Falls
#           back to local HEAD only when no ref is present in the command (e.g.
#           bare `git push` relying on upstream tracking).
#   Commit: detect the `cd <path> && git commit` shell compound pattern and run
#           `git -C <path> branch --show-current` against the TARGET worktree.
#           Falls back to the session cwd for plain `git commit` (no `cd`
#           prefix) — preserving the original behaviour for the normal case.

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)

if [ -z "$COMMAND" ]; then
  exit 0
fi

# Resolve the hook's own directory so we can source sibling libs reliably
# regardless of the harness's $PWD.
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Resolve protected-branch list from project config (shared reader, #109).
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
PROTECTED=""
if [ -n "$REPO_ROOT" ] && [ -f "$REPO_ROOT/.claude/hooks/_lib-read-config.sh" ]; then
  # shellcheck disable=SC1090,SC1091
  . "$REPO_ROOT/.claude/hooks/_lib-read-config.sh"
  PROTECTED=$(config_get '.git.protected_branches[]' 2>/dev/null | paste -sd'|' -)
fi
if [ -z "$PROTECTED" ]; then
  PROTECTED="main|master|dev|develop"
fi

# ---------------------------------------------------------------------------
# Block: git push <remote> <protected>
#
# Use _lib-extract-push-ref.sh to read the DESTINATION branch from the actual
# push command rather than from the session cwd's HEAD. This is the same
# worktree-safe approach validate-branch-name.sh uses (#194, #547).
#
# Fallback: when no ref is found in the command (bare `git push` / `git push
# origin` relying on upstream tracking), fall back to local HEAD so the hook
# still catches pushes on protected branches made without an explicit ref.
# ---------------------------------------------------------------------------
if echo "$COMMAND" | grep -qE '\bgit\s+push\b'; then
  # Source the shared push-ref extractor if available.
  if [ -f "$HOOK_DIR/_lib-extract-push-ref.sh" ]; then
    # shellcheck disable=SC1090,SC1091
    . "$HOOK_DIR/_lib-extract-push-ref.sh"

    # Tag pushes are never subject to a branch-protection check.
    if is_tag_push "$COMMAND"; then
      exit 0
    fi

    PUSH_DST=$(extract_push_ref "$COMMAND")
  else
    # Lib missing — best-effort fallback: no explicit ref extracted.
    PUSH_DST=""
  fi

  # Determine which branch to check against the protected list.
  if [ -n "$PUSH_DST" ]; then
    TARGET_PUSH_BRANCH="$PUSH_DST"
  else
    # Bare `git push` / no explicit ref — fall back to local HEAD.
    TARGET_PUSH_BRANCH=$(git branch --show-current 2>/dev/null)
  fi

  if [ -n "$TARGET_PUSH_BRANCH" ] && echo "$TARGET_PUSH_BRANCH" | grep -qE "^(${PROTECTED})$"; then
    cat >&2 <<MSG
BLOCKED: Cannot push directly to a protected branch ('${TARGET_PUSH_BRANCH}').

All changes must go through a PR (.claude/rules/git-conventions.md
§ "No Direct Main"). Protected branches: ${PROTECTED//|/, }.

To unblock:
  1. Create a feature branch from your current work:
       git checkout -b feature/GH-<ticket>-<short-description>
  2. Push the feature branch:
       git push -u origin feature/GH-<ticket>-<short-description>
  3. Open a PR via /feature → /start-ticket → gh pr create, OR if the
     ticket exists, just: gh pr create --base <protected-branch> --head <feature-branch>

Customise (rare): .claude/project-config.json → .git.protected_branches[]
REPLACES the default list (main / master / dev / develop). To REMOVE
protection from a default-protected branch (e.g. you legitimately use
'dev' as your trunk), write the array with that branch OMITTED. To ADD
protection to a new branch, write the array INCLUDING it. The hook
trusts whichever list you provide — get the direction right.
MSG
    exit 2
  fi
fi

# ---------------------------------------------------------------------------
# Block: git commit on a protected branch
#
# For the `cd <path> && git commit …` compound shell pattern, resolve the
# branch of the TARGET worktree (the `cd` destination) rather than the
# session cwd. This is the exact failure mode reported in #549: the harness
# resets cwd to the primary checkout (on e.g. `dev`), but the actual commit
# targets a feature-branch worktree reached via `cd ../wt && git commit`.
#
# For plain `git commit` (no `cd` prefix) fall back to the session cwd —
# preserving the original behaviour for the normal single-worktree case.
# ---------------------------------------------------------------------------
if echo "$COMMAND" | grep -qE '\bgit\s+commit\b'; then
  # Detect `cd <path>` prefix in compound commands, e.g.:
  #   cd ../wt && git commit -m "msg"
  #   cd /abs/path && git commit …
  # Match `cd` as the first meaningful token before any separator.
  WORKTREE_PATH=""
  if echo "$COMMAND" | grep -qE '(^|[;&|[:space:]])cd[[:space:]]+\S'; then
    # Resolve the LAST `cd <path>` in the chain (so `cd a && cd b && git commit`
    # targets b, not a) and STRIP surrounding quotes. Quote-stripping is the
    # security-critical part: without it, `cd "path" && git commit` would pass
    # `"path"` (quotes included) to `git -C`, which errors → empty branch → the
    # protected-branch check is skipped and a commit into a protected-branch
    # worktree slips through. That false-negative was caught in the #580 review
    # of this fix (#549). Handles double-quoted, single-quoted (incl. spaces),
    # and bare paths.
    WORKTREE_PATH=$(echo "$COMMAND" \
      | grep -oE "cd[[:space:]]+(\"[^\"]*\"|'[^']*'|[^[:space:];&|]+)" \
      | tail -n 1 \
      | sed -E "s/^cd[[:space:]]+//; s/^[\"']//; s/[\"']\$//")
  fi

  if [ -n "$WORKTREE_PATH" ]; then
    # Resolve branch in the target worktree, not the session cwd.
    CURRENT_BRANCH=$(git -C "$WORKTREE_PATH" branch --show-current 2>/dev/null)
  else
    # Plain `git commit` with no `cd` — use session cwd (original behaviour).
    CURRENT_BRANCH=$(git branch --show-current 2>/dev/null)
  fi

  if [ -n "$CURRENT_BRANCH" ] && echo "$CURRENT_BRANCH" | grep -qE "^(${PROTECTED})$"; then
    cat >&2 <<MSG
BLOCKED: Cannot commit directly on protected branch '${CURRENT_BRANCH}'.

All changes must go through a PR (.claude/rules/git-conventions.md
§ "No Direct Main").

To unblock:
  1. Create a feature branch from your current state (preserves your
     in-progress edits):
       git checkout -b feature/GH-<ticket>-<short-description>
  2. Retry the commit on the feature branch
  3. Push and open a PR when ready

If you've already committed locally to '${CURRENT_BRANCH}' by accident,
the recovery is a three-step rescue (NOT a separate To-unblock — the
gate is still the one above): create a recovery branch pointing at the
current commit, reset ${CURRENT_BRANCH} to drop the accidental commit
locally, then check out the recovery branch.

       git branch feature/GH-<ticket>-recovery
       git reset --hard HEAD~1   # drops the commit from ${CURRENT_BRANCH}
       git checkout feature/GH-<ticket>-recovery
MSG
    exit 2
  fi
fi

exit 0
