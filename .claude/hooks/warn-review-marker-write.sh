#!/bin/bash
# PreToolUse hook — fires when a Write tool call or a Bash command targets a
# review-marker file (*-rex.approved, *-ceo.approved, *-security.approved,
# *-architecture.approved) under .claude/session/reviews/.
#
# HISTORY
# -------
# #728 made this hook's banner "unmissable" (VIOLATION framing, per-marker-type
# messaging) but kept it purely advisory (exit 0 always) — reasoning that the
# harness provides no per-agent-type signal (CLAUDE_CODE_CHILD_SESSION is set
# identically for every sub-agent, sanctioned reviewer or not), so a shell
# hook cannot reliably distinguish "the real code-reviewer is writing this"
# from "a build agent is impersonating the code-reviewer".
#
# #843 found the residual gap: the banner alone doesn't stop the write, and
# twice (PRs #835, #842) a build-class sub-agent — which cannot nest the
# Agent tool to spawn the real reviewer — resolved auto-code-review.sh's
# "Invoke Rex NOW" instruction by impersonating Rex itself: posting a fake
# review and writing the *-rex.approved marker.
#
# THE FIX (#843): rather than trying to distinguish agent *identity* (the
# #728 blocker), gate on agent *provenance via session state* instead — a
# **active-reviewer session marker** at .claude/session/active-reviewer that
# the orchestrator (or one of /code-review, /security-review, /design-review)
# writes immediately before spawning the sanctioned reviewer, one line:
# `<owner>/<repo>#<pr>:<kind>`. A write to *-rex.approved / *-security.approved
# / *-architecture.approved is now BLOCKED (exit 2) unless that marker exists
# and matches the (repo, pr, kind) being written:
#
#   .claude/session/active-reviewer contains:  me2resh/apexyard#843:rex
#   allows a write to:                         me2resh__apexyard__843-rex.approved
#   blocks a write to:                         me2resh__apexyard__843-security.approved  (kind mismatch)
#   blocks a write to:                         me2resh__apexyard__844-rex.approved        (pr mismatch)
#
# A build-class sub-agent — spawned to implement a ticket, with no reason to
# ever see an active-reviewer marker set for its own PR — is blocked with a
# message telling it to stop and hand back to the orchestrator.
#
# KNOWN LIMITATION (scope of the block, honestly stated)
# ------------------------------------------------------
# This gate fires only when the LITERAL marker path (e.g. a `*-rex.approved`
# suffix) appears in the Write tool's file_path or in the Bash command text —
# it inherits the `_is_marker_target` match surface that predates #843. The
# sanctioned reviewers write the marker via a shell VARIABLE
# (`printf '%s\n' "$SHA" > "$REX_MARKER"`, path from `review_marker_path`),
# where the literal suffix never appears in the command text; a shell hook
# cannot expand that variable to know the target, so the variable form is NOT
# intercepted. Consequence: this blocks the common "just create the file"
# literal-path forgery vector (real value), but an agent that forges by
# copying the reviewers' own documented variable-form idiom is NOT stopped by
# this hook. So #843 *narrows* the induced-impersonation surface; it does not
# claim to mechanically block every forgery. The load-bearing defences remain
# the per-PR CEO nod (`/approve-merge`) and the orchestrator running a real,
# separate reviewer pass — this gate is a backstop, not a complete fence.
#
# *-ceo.approved KEEPS its original #728 advisory-only behaviour (never
# blocks) — it has its own structured-field defence in
# block-unreviewed-merge.sh (sha= / approved_by=user / skill_version=) and is
# written by a human-invoked skill (/approve-merge), not a reviewer agent.
#
# Legacy bare-number marker filenames (pre-#485 repo-qualifier, e.g.
# `843-rex.approved` with no `<owner>__<repo>__` prefix) are still
# recognised — the repo component of the active-reviewer check is skipped
# for those (can't recover a repo from a bare filename), but the pr + kind
# match still applies.
#
# THREAT MODEL: same as every other marker in this framework (see
# .claude/rules/pr-workflow.md). Local session state, gitignored, converts
# invisible inference into visible, checkable file existence. Claude can
# still fabricate the active-reviewer marker by hand — that is a visible,
# auditable, grep-able rule violation, same order of magnitude as forging
# the marker directly used to be. The mechanical gate exists to remove the
# INDUCED failure mode (auto-code-review.sh's banner telling a build agent
# to do the impossible), not to defend against a deliberately adversarial
# agent.
#
# #873 trimmed the BLOCKED banner's orchestrator branch: since the sanctioned
# reviewer writes the marker via the variable form (untouched by this gate,
# see KNOWN LIMITATION above), the only caller who ever lands on this banner
# is doing a literal-path write — the induced-forgery case. Printing a
# copy-pasteable `printf > active-reviewer` recipe there handed a working
# marker-set command to the agent we least want holding one. The banner now
# points the orchestrator at the matching skill (/code-review,
# /security-review, /design-review) instead — same skills that already own
# the marker's set/clear lifecycle (see auto-code-review.sh's #843 banner for
# the sibling fix this mirrors).
#
# Wired in .claude/settings.json PreToolUse for:
#   matcher: Write    (catches direct file writes)
#   matcher: Bash     (catches shell redirections, echo >, printf, tee, etc.)
#
# References: #728, #843, #873, AgDR-0062, .claude/rules/pr-workflow.md
#             § "Build agents cannot self-review"

set -u

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"

_is_marker_target() {
  local text="$1"
  # Match any path ending with a review-marker filename under the reviews dir:
  #   *-rex.approved          — Rex gate marker (BLOCKING, #843)
  #   *-security.approved     — Security Reviewer gate marker (BLOCKING, #843)
  #   *-architecture.approved — Solution Architect gate marker (BLOCKING, #843)
  #   *-ceo.approved          — CEO gate marker (advisory-only, unchanged)
  echo "$text" | grep -qE '\.claude/session/reviews/[^[:space:]"'"'"']+-(rex|ceo|security|architecture)\.approved'
}

MATCHED=0
MARKER_TYPE=""
TARGET=""

case "$TOOL_NAME" in
  Write)
    FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
    if _is_marker_target "$FILE_PATH"; then
      MATCHED=1
      TARGET="$FILE_PATH"
    fi
    ;;
  Bash)
    COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
    if _is_marker_target "$COMMAND"; then
      MATCHED=1
      TARGET=$(echo "$COMMAND" | grep -oE '\.claude/session/reviews/[^[:space:]"'"'"']+-(rex|ceo|security|architecture)\.approved' | head -1)
    fi
    ;;
esac

if [ "$MATCHED" != "1" ]; then
  exit 0
fi

MARKER_BASENAME=$(basename "$TARGET")
MARKER_TYPE=$(printf '%s' "$MARKER_BASENAME" | sed -E 's/^.*-(rex|ceo|security|architecture)\.approved$/\1/')

# --- CEO marker: unchanged #728 advisory-only behaviour (never blocks). ---
if [ "$MARKER_TYPE" = "ceo" ]; then
  cat >&2 <<'BANNER'
======================================================================
[apexyard] VIOLATION WARNING: Unauthorized review-marker write detected
======================================================================

You are about to write a *-ceo.approved review marker.

  *-ceo.approved must be written ONLY by the /approve-merge skill
  on an explicit per-PR CEO approval. It carries structured provenance
  fields (approved_by=user, skill_version=2) that cannot be fabricated
  casually.

  Who may write this marker:
    /approve-merge skill, invoked by the orchestrator on an explicit CEO nod

WHY THIS MATTERS
  Writing this file yourself satisfies the merge gate's FILENAME check
  but NOT its INTENT. block-unreviewed-merge.sh independently validates
  the structured fields before any merge is allowed, so a hand-written
  marker without those fields is still rejected at merge time — but
  don't write this file yourself. Invoke /approve-merge <pr>.

======================================================================
BANNER
  exit 0
fi

# --- rex / security / architecture: BLOCKING gate on the active-reviewer marker (#843). ---

# Resolve MARKER_HOME the same way every other review-marker hook does
# (ops fork root, not necessarily the current repo's git toplevel — see
# me2resh/apexyard#229/#230).
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
OPS_ROOT=""
if [ -f "$HOOK_DIR/_lib-ops-root.sh" ]; then
  # shellcheck source=/dev/null
  . "$HOOK_DIR/_lib-ops-root.sh"
  OPS_ROOT=$(resolve_ops_root "${REPO_ROOT:-$PWD}")
fi
MARKER_HOME="${OPS_ROOT:-${REPO_ROOT:-.}}"

ACTIVE_REVIEWER_MARKER="$MARKER_HOME/.claude/session/active-reviewer"

# Parse the (repo, pr) this write targets from the marker's own filename.
# Repo-qualified (post-#485): <owner>__<repo>__<pr>-<role>.approved
# Legacy bare:                <pr>-<role>.approved
PREFIX="${MARKER_BASENAME%-${MARKER_TYPE}.approved}"
if printf '%s' "$PREFIX" | grep -qE '^[0-9]+$'; then
  TARGET_PR="$PREFIX"
  TARGET_REPO=""
else
  TARGET_PR=$(printf '%s' "$PREFIX" | grep -oE '[0-9]+$')
  TARGET_REPO=$(printf '%s' "$PREFIX" | sed -E "s/__${TARGET_PR}\$//" | sed 's/__/\//')
fi

_active_reviewer_allows() {
  # Returns 0 (allow) iff the active-reviewer marker exists and its
  # <repo>#<pr>:<kind> content matches this write's (repo, pr, role).
  [ -f "$ACTIVE_REVIEWER_MARKER" ] || return 1
  local content
  content=$(tr -d '[:space:]' < "$ACTIVE_REVIEWER_MARKER" 2>/dev/null)
  [ -n "$content" ] || return 1

  case "$content" in
    *'#'*':'*) : ;;
    *) return 1 ;;
  esac

  local c_repo c_rest c_pr c_kind
  c_repo="${content%%#*}"
  c_rest="${content#*#}"
  c_pr="${c_rest%%:*}"
  c_kind="${c_rest#*:}"

  [ "$c_kind" = "$MARKER_TYPE" ] || return 1
  [ -n "$TARGET_PR" ] && [ "$c_pr" != "$TARGET_PR" ] && return 1
  # Repo check only when the target filename encodes a repo (post-#485
  # qualified marker). Legacy bare markers skip this comparison.
  if [ -n "$TARGET_REPO" ] && [ -n "$c_repo" ] && [ "$c_repo" != "$TARGET_REPO" ]; then
    return 1
  fi
  return 0
}

if _active_reviewer_allows; then
  exit 0
fi

# Map the marker role to the skill that manages its active-reviewer marker
# lifecycle (set at skill entry, cleared after the review is posted — see
# .claude/skills/{code-review,security-review,design-review}/SKILL.md § 0).
case "$MARKER_TYPE" in
  rex) REVIEW_SKILL="code-review" ;;
  security) REVIEW_SKILL="security-review" ;;
  architecture) REVIEW_SKILL="design-review" ;;
  *) REVIEW_SKILL="code-review" ;;
esac

cat >&2 <<MSG
======================================================================
[apexyard] BLOCKED: Unauthorized review-marker write
======================================================================

You are about to write a *-${MARKER_TYPE}.approved review marker with no
matching active-reviewer session marker.

Target:  ${TARGET}
Expected active-reviewer marker: ${ACTIVE_REVIEWER_MARKER}
  (must contain: <owner>/<repo>#${TARGET_PR:-<pr>}:${MARKER_TYPE})

This marker may ONLY be written by the sanctioned reviewer agent for this
role (code-reviewer / security-reviewer / solution-architect), immediately
after the orchestrator sets the active-reviewer marker and spawns it.

IF YOU ARE A BUILD-CLASS SUB-AGENT (backend-engineer, frontend-engineer,
platform-engineer, product-manager, data-engineer, ui-designer, ux-designer,
tech-lead, etc.): STOP. Do NOT write this file. You cannot nest the Agent
tool to spawn the real reviewer, so any "review" you produce here is the
author reviewing their own work — the exact failure this gate exists to
stop (see .claude/rules/pr-workflow.md § "Build agents cannot self-review").
Report your build results plainly and hand back to the orchestrator.

IF YOU ARE THE ORCHESTRATOR: run the review through the /${REVIEW_SKILL}
skill on this PR:

     /${REVIEW_SKILL} ${TARGET_PR:-<pr>}

The skill sets the active-reviewer session marker, spawns the sanctioned
reviewer, and clears the marker for you — you should NOT set that marker
by hand. A SessionStart sweep also clears stale markers left by an
interrupted session.
======================================================================
MSG
exit 2
