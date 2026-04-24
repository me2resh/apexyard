#!/bin/bash
# PostToolUse hook on `git push`: surfaces invalidated review markers at
# push-time instead of waiting until merge-time.
#
# THE GAP THIS CLOSES
# -------------------
# Review markers at .claude/session/reviews/<pr>-{rex,ceo,design}.approved are
# bound to a specific commit SHA (see block-unreviewed-merge.sh). When the
# author pushes new commits to an already-approved PR, those markers go
# stale — their recorded SHA no longer matches the PR's new HEAD.
#
# The merge-gate hooks eventually catch this, but only at `gh pr merge` time,
# which can be hours or days after the push. The gap creates user-visible
# confusion ("Rex already approved — why is the merge blocked?") and a
# false-start at merge time.
#
# This hook fires immediately after a successful `git push` and prints one
# warning line per stale marker so the author knows to re-invoke the
# reviewer before they try to merge.
#
# CONSTRAINTS
# -----------
# - PostToolUse hook — CANNOT block the push (the push has already happened).
# - Silent when there's no PR for the branch (early push before `gh pr create`).
# - Silent when `gh` is offline / unauthenticated (can't resolve the PR HEAD).
# - Silent when the push failed (nothing changed, markers can't have gone stale
#   from this push). We detect failure heuristically via the tool_response and
#   defensively by comparing against the PR's real HEAD on GitHub — which is
#   the same source-of-truth the merge-gate hooks use post-#55.
# - Never exits non-zero. PostToolUse exit 2 would surface as a nudge to Claude,
#   which is inappropriate here: the rule this hook enforces (re-invoke Rex
#   after new commits) is already enforced mechanically by block-unreviewed-
#   merge.sh. This hook is purely informational.
#
# MODES
# -----
# Config at .claude/project-config.json → review_markers.on_stale:
#   - "warn"   (default): print a warning per stale marker, leave files in place
#   - "delete":          rm the marker file and print a deletion notice
#
# TODO(apexyard#109): switch to the shared project-config reader once it lands.
# For now we inline the default and read from config only if the file exists.

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)

if [ "$TOOL_NAME" != "Bash" ] || [ -z "$COMMAND" ]; then
  exit 0
fi

# Only fire on git push
if ! echo "$COMMAND" | grep -qE '\bgit\s+push\b'; then
  exit 0
fi

# -------- Detect push failure heuristically --------
# git push prints progress to stderr; success output typically includes lines
# like "To <remote>" and "<old>..<new>  branch -> branch" (or "[new branch]"
# for the first push). Failure markers are "error:", "fatal:", "rejected",
# "failed to push".
#
# Triple fallback on the stderr path (newer harness → older), same pattern as
# auto-code-review.sh for stdout.
PUSH_STDERR=$(echo "$INPUT" | jq -r '.tool_response.stderr // .tool_response.error // empty' 2>/dev/null)
PUSH_STDOUT=$(echo "$INPUT" | jq -r '.tool_response.stdout // .tool_response.output // .tool_response // empty' 2>/dev/null)
PUSH_COMBINED="${PUSH_STDOUT}${PUSH_STDERR}"

if [ -n "$PUSH_COMBINED" ] && echo "$PUSH_COMBINED" | grep -qEi '\b(rejected|failed to push|^fatal:|^error:)\b'; then
  # Push failed — the remote HEAD hasn't moved from this push, so any marker
  # that was fresh before is still fresh. Nothing to warn about.
  exit 0
fi

# -------- Resolve repo root + session/reviews dir --------
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
if [ -z "$REPO_ROOT" ]; then
  exit 0
fi

REVIEWS_DIR="${REPO_ROOT}/.claude/session/reviews"
if [ ! -d "$REVIEWS_DIR" ]; then
  # No reviews ever recorded — nothing can be stale.
  exit 0
fi

# -------- Resolve the PR number for the current branch --------
# `gh pr view` with no args looks up the PR for the checked-out branch.
# If no PR exists (early push before `gh pr create`), gh exits non-zero and
# we exit silently — this is the expected path for most first pushes.
PR_NUMBER=$(gh pr view --json number --jq '.number' 2>/dev/null)
if [ -z "$PR_NUMBER" ]; then
  exit 0
fi

# -------- Resolve the PR's HEAD SHA --------
# Prefer `gh pr view --json headRefOid` (same source-of-truth as the merge
# gates, post-#47/#55). Fall back to local HEAD with a visible warning if
# gh fails (offline / rate-limited / auth expired) — matches the fallback
# behaviour in block-unreviewed-merge.sh.
PR_HEAD=$(gh pr view "$PR_NUMBER" --json headRefOid --jq '.headRefOid' 2>/dev/null)
if [ -z "$PR_HEAD" ]; then
  echo "WARN: warn-stale-review-markers.sh could not resolve PR #${PR_NUMBER} HEAD via gh — falling back to local HEAD." >&2
  PR_HEAD=$(git rev-parse HEAD 2>/dev/null)
fi
if [ -z "$PR_HEAD" ]; then
  # Neither gh nor git could give us a HEAD — exit silently rather than spam.
  exit 0
fi

# -------- Load on_stale mode from project-config (via shared lib) --------
# The shared reader (apexyard#109) merges the shipped defaults with any
# per-fork override. Falls back to inline default if the lib is unavailable
# (bare checkout predating #109).
ON_STALE="warn"
if [ -f "$REPO_ROOT/.claude/hooks/_lib-read-config.sh" ]; then
  # shellcheck disable=SC1090,SC1091
  . "$REPO_ROOT/.claude/hooks/_lib-read-config.sh"
  CFG=$(config_get_or '.review_markers.on_stale' 'warn' 2>/dev/null)
  if [ "$CFG" = "delete" ] || [ "$CFG" = "warn" ]; then
    ON_STALE="$CFG"
  fi
fi

# -------- Scan the marker files for staleness --------
# Use a for-loop with a nullglob-equivalent pattern check to handle the
# no-match case cleanly (literal glob vs empty list).
shopt -s nullglob 2>/dev/null
for MARKER in "$REVIEWS_DIR"/"$PR_NUMBER"-*.approved; do
  [ -f "$MARKER" ] || continue

  MARKER_SHA=$(tr -d '[:space:]' < "$MARKER")
  if [ -z "$MARKER_SHA" ]; then
    # Malformed marker (empty file) — treat as stale so it gets surfaced,
    # since the merge gate will reject it anyway.
    MARKER_SHA="(empty)"
  fi

  if [ "$MARKER_SHA" = "$PR_HEAD" ]; then
    # Fresh — no output.
    continue
  fi

  MARKER_NAME=$(basename "$MARKER")
  OLD_SHORT="${MARKER_SHA:0:7}"
  NEW_SHORT="${PR_HEAD:0:7}"

  if [ "$ON_STALE" = "delete" ]; then
    rm -f "$MARKER"
    echo "⚠ Stale review marker deleted: ${MARKER_NAME} (reviewer must re-approve)" >&2
  else
    echo "⚠ Stale review marker: ${MARKER_NAME} (was ${OLD_SHORT}, now ${NEW_SHORT}) — re-invoke the reviewer." >&2
  fi
done

exit 0
