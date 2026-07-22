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
# #962 — RESOLVED-TARGET DETECTION (closes the prior KNOWN LIMITATION)
# ----------------------------------------------------------------------
# #843's detection matched the LITERAL marker suffix as a plain substring of
# the Bash command TEXT. Two consequences fell out of that:
#
#   1. FALSE NEGATIVE (security-relevant): the sanctioned reviewers' own
#      documented idiom builds the marker path via a shell variable —
#      `REX_MARKER=$(review_marker_path "$REPO" "$PR" rex "$MARKER_HOME")`
#      then `printf '%s\n' "$SHA" > "$REX_MARKER"` — where the literal
#      `-rex.approved` suffix never appears anywhere in the command text.
#      A build agent forging by copying that exact idiom evaded the gate
#      entirely: no active-reviewer marker required, no block.
#   2. FALSE POSITIVE: a harmless READ of a marker path that happens to
#      spell out the literal filename (`cat .claude/session/reviews/…
#      -security.approved`) tripped the same substring match and was
#      wrongly refused, even though nothing was being written.
#
# THE FIX: detect on the RESOLVED WRITE, not a literal-path substring —
# reusing `_lib-detect-bash-write.sh` (the same helper require-active-
# ticket.sh's Bash matcher already uses for the identical class of problem,
# see me2resh/apexyard#151):
#
#   - `bash_command_appears_to_write` distinguishes a genuine write
#     (redirection, tee, sed -i, an embedded interpreter with a write
#     keyword, …) from a plain read (cat/grep/head) — closing the false
#     positive. A literal-path match is now gated ONLY when the command is
#     also an actual write.
#   - When the command performs a write but carries no literal marker path,
#     `_is_marker_plausible_indirect` looks for the documented indirection
#     idiom itself — a `review_marker_path` call, a `.claude/session/
#     reviews/` mention, an `active-reviewer` mention, or a write target
#     whose variable NAME follows the established *_MARKER convention
#     (REX_MARKER, CEO_MARKER, SECURITY_MARKER, ARCH_MARKER, …). Any of
#     those, combined with a real write, is treated as a plausible marker
#     write and gated — closing the false negative.
#   - Best-effort role (`_extract_marker_role`) and PR-number
#     (`_extract_marker_pr`) extraction reads the SAME `review_marker_path`
#     call's own positional arguments — the role and PR-number arguments
#     are conventionally literal in the reviewers' documented usage (see
#     code-reviewer.md / solution-architect.md), even though the RESULT of
#     the call is assigned to a variable. When the role can't be resolved
#     at all, the write is still gated — no literal `c_kind` in a
#     well-formed `active-reviewer` marker can ever equal an unresolved
#     empty string, so an unresolvable marker write FAILS CLOSED by
#     construction rather than by a special case.
#
# This does NOT weaken the pre-#962 literal-path detection — it remains the
# first check tried, unchanged — it only (a) requires that check to
# co-occur with an actual write (fixing the read false-positive) and (b)
# adds a second, indirection-aware detection path alongside it (fixing the
# write false-negative). If `_lib-detect-bash-write.sh` is missing for any
# reason, this hook falls back to the original #843 literal-substring-only
# behaviour (conservative — the pre-existing false-positive-on-read
# limitation re-applies, but nothing new is weakened).
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
# match still applies. The same skip-when-unresolvable philosophy extends
# to #962's indirect-resolution path: when the PR number or repo can't be
# recovered from the command text, that comparison is skipped, but kind
# (rex vs security vs architecture) is ALWAYS required to match — and an
# unresolved kind can never match, so under-resolution fails closed, not
# open.
#
# THREAT MODEL: same as every other marker in this framework (see
# .claude/rules/pr-workflow.md). Local session state, gitignored, converts
# invisible inference into visible, checkable file existence. Claude can
# still fabricate the active-reviewer marker by hand — that is a visible,
# auditable, grep-able rule violation, same order of magnitude as forging
# the marker directly used to be. The mechanical gate exists to remove the
# INDUCED failure mode (auto-code-review.sh's banner telling a build agent
# to do the impossible), not to defend against a deliberately adversarial
# agent. #962's resolved-target detection narrows the surface further but
# makes the same non-claim: a sufficiently adversarial agent that avoids
# every keyword/naming signal this hook looks for is not mechanically
# stopped — the load-bearing defences remain the per-PR human-approver nod
# and the orchestrator running a real, separate reviewer pass.
#
# #873 trimmed the BLOCKED banner's orchestrator branch: since the sanctioned
# reviewer writes the marker via the variable form (now DETECTED by #962,
# see above — no longer a blind spot), the only caller who used to land on
# this banner via a literal-path write was doing the induced-forgery case.
# Printing a copy-pasteable `printf > active-reviewer` recipe there handed a
# working marker-set command to the agent we least want holding one. The
# banner points the orchestrator at the matching skill (/code-review,
# /security-review, /design-review) instead — same skills that already own
# the marker's set/clear lifecycle (see auto-code-review.sh's #843 banner for
# the sibling fix this mirrors).
#
# Wired in .claude/settings.json PreToolUse for:
#   matcher: Write    (catches direct file writes)
#   matcher: Bash     (catches shell redirections, echo >, printf, tee, etc.)
#
# #974 hardened _active_reviewer_allows() further: a malformed on-disk
# active-reviewer marker (empty kind after a trailing colon) combined with
# an unresolved indirect-write role could satisfy `[ "" = "" ]` and
# incorrectly ALLOW the write — the exact "total ambiguity" case the #962
# comment assumed was already fail-closed. Both sides of the kind
# comparison are now guarded explicitly for non-empty before it runs.
#
# References: #728, #843, #873, #957, #962, #974, AgDR-0062, AgDR-0104,
#             .claude/rules/pr-workflow.md § "Build agents cannot self-review"

set -u

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"

# Source the bash-write detector (#962). Same helper require-active-
# ticket.sh's Bash matcher uses for the identical "does this command
# actually write" question — see me2resh/apexyard#151. Missing library is
# handled gracefully: fall back to the pre-#962 literal-substring-only
# behaviour rather than bricking the hook (HAVE_BDW_LIB=0 below).
HAVE_BDW_LIB=0
if [ -f "$HOOK_DIR/_lib-detect-bash-write.sh" ]; then
  # shellcheck source=/dev/null
  . "$HOOK_DIR/_lib-detect-bash-write.sh"
  HAVE_BDW_LIB=1
fi

_is_marker_target() {
  local text="$1"
  # Match any path ending with a review-marker filename under the reviews dir:
  #   *-rex.approved          — Rex gate marker (BLOCKING, #843)
  #   *-security.approved     — Security Reviewer gate marker (BLOCKING, #843)
  #   *-architecture.approved — Solution Architect gate marker (BLOCKING, #843)
  #   *-ceo.approved          — CEO gate marker (advisory-only, unchanged)
  echo "$text" | grep -qE '\.claude/session/reviews/[^[:space:]"'"'"']+-(rex|ceo|security|architecture)\.approved'
}

# _is_marker_plausible_indirect COMMAND (#962)
#
# True when COMMAND performs a write with no literal marker path in sight,
# but still plausibly targets a review marker via the documented
# indirection idiom:
#   REX_MARKER=$(review_marker_path "$REPO" "$PR" rex "$MARKER_HOME")
#   printf '%s\n' "$SHA" > "$REX_MARKER"
#
# Signals (any one is sufficient):
#   - a `review_marker_path` call anywhere in the command
#   - a literal `.claude/session/reviews/` directory mention (without a full
#     matched filename — e.g. a directory-only reference, or a path built
#     via concatenation rather than a single contiguous literal)
#   - a literal `active-reviewer` mention
#   - a write-target-shaped variable name following the established
#     *_MARKER convention this codebase's reviewers use (REX_MARKER,
#     CEO_MARKER, SECURITY_MARKER, ARCH_MARKER, ARCHITECTURE_MARKER, …)
_is_marker_plausible_indirect() {
  local text="$1"
  if echo "$text" | grep -qE 'review_marker_path|\.claude/session/reviews/|active-reviewer'; then
    return 0
  fi
  echo "$text" | grep -qiE '\$\{?[a-z_]*marker[a-z_]*\}?'
}

# _extract_marker_role COMMAND (#962)
#
# Best-effort role extraction from a `review_marker_path <repo> <pr> <role>
# [marker_home]` call embedded in COMMAND. The call's own arguments are
# conventionally literal in the reviewers' documented usage even when the
# call's RESULT is assigned to a variable (see code-reviewer.md,
# solution-architect.md) — so the role can be recovered even though the
# eventual write target cannot. Echoes rex|ceo|security|architecture, or
# nothing if no such call (or no recognisable role argument) is found.
_extract_marker_role() {
  local cmd="$1" call
  call=$(echo "$cmd" | grep -oE 'review_marker_path[^;&|)]*' | head -1)
  [ -z "$call" ] && return 1
  echo "$call" | grep -oE '\b(rex|ceo|security|architecture)\b' | head -1
}

# _extract_marker_pr COMMAND (#962)
#
# Best-effort PR-number extraction from the SAME `review_marker_path` call
# — the {number} positional argument is conventionally a literal integer at
# the point a reviewer or skill actually invokes it (a placeholder filled in
# with the real PR number, per code-reviewer.md / solution-architect.md).
# Echoes the first bare digit-run found in the call, or nothing.
_extract_marker_pr() {
  local cmd="$1" call
  call=$(echo "$cmd" | grep -oE 'review_marker_path[^;&|)]*' | head -1)
  [ -z "$call" ] && return 1
  echo "$call" | grep -oE '\b[0-9]+\b' | head -1
}

MATCHED=0
MARKER_TYPE=""
TARGET=""
TARGET_PR=""
TARGET_REPO=""
RESOLVED_VIA="literal"   # "literal" | "indirect" — which detection path matched

case "$TOOL_NAME" in
  Write)
    # Write's file_path is always a literal, harness-resolved string — never
    # a shell expression a variable could hide — so the read/write ambiguity
    # and indirection concerns below don't apply here. Unchanged from #843.
    FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
    if _is_marker_target "$FILE_PATH"; then
      MATCHED=1
      TARGET="$FILE_PATH"
    fi
    ;;
  Bash)
    COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)

    if [ "$HAVE_BDW_LIB" = "1" ]; then
      IS_WRITE=1
      bash_command_appears_to_write "$COMMAND" || IS_WRITE=0

      if [ "$IS_WRITE" = "1" ] && _is_marker_target "$COMMAND"; then
        # Literal marker path present AND this command actually performs a
        # write — not just a read that happens to mention the path (#962
        # fix for the false-positive half of the bug: a bare `cat`/`grep`/
        # `head` on a literal marker path is no longer blocked).
        MATCHED=1
        TARGET=$(echo "$COMMAND" | grep -oE '\.claude/session/reviews/[^[:space:]"'"'"']+-(rex|ceo|security|architecture)\.approved' | head -1)
        RESOLVED_VIA="literal"
      elif [ "$IS_WRITE" = "1" ] && _is_marker_plausible_indirect "$COMMAND"; then
        # No literal path in the command text, but it performs a write AND
        # plausibly targets a review marker via variable/function
        # indirection (#962 fix for the false-negative half of the bug) —
        # e.g. REX_MARKER=$(review_marker_path ...); printf ... > "$REX_MARKER"
        MATCHED=1
        RESOLVED_VIA="indirect"
        MARKER_TYPE=$(_extract_marker_role "$COMMAND")
        TARGET_PR=$(_extract_marker_pr "$COMMAND")
        TARGET="<resolved via variable/function indirection; detected role: ${MARKER_TYPE:-unresolved}, pr: ${TARGET_PR:-unresolved}>"
      fi
    else
      # Library unavailable — fall back to the pre-#962 literal-substring
      # check with no read/write distinction (conservative: re-applies the
      # known false-positive-on-read limitation, but doesn't newly weaken
      # anything that was previously caught).
      if _is_marker_target "$COMMAND"; then
        MATCHED=1
        TARGET=$(echo "$COMMAND" | grep -oE '\.claude/session/reviews/[^[:space:]"'"'"']+-(rex|ceo|security|architecture)\.approved' | head -1)
        RESOLVED_VIA="literal"
      fi
    fi
    ;;
esac

if [ "$MATCHED" != "1" ]; then
  exit 0
fi

if [ "$RESOLVED_VIA" = "literal" ]; then
  MARKER_BASENAME=$(basename "$TARGET")
  MARKER_TYPE=$(printf '%s' "$MARKER_BASENAME" | sed -E 's/^.*-(rex|ceo|security|architecture)\.approved$/\1/')
fi

# --- Configurable human-approver DISPLAY title (me2resh/apexyard#957) ---
# DISPLAY ONLY: substitutes the printed word for the human per-PR merge
# approver in the CEO banner below. Does NOT affect the marker filename
# (still "-ceo.approved") or any gate logic. Default "CEO" is a
# zero-behaviour-change no-op.
# shellcheck source=/dev/null
. "$HOOK_DIR/_lib-read-config.sh" 2>/dev/null || true
if command -v config_get_or >/dev/null 2>&1; then
  APPROVER_TITLE=$(config_get_or '.review_markers.human_approver_title' 'CEO')
else
  APPROVER_TITLE="CEO"
fi
[ -z "$APPROVER_TITLE" ] && APPROVER_TITLE="CEO"

# --- CEO marker: unchanged #728 advisory-only behaviour (never blocks). ---
if [ "$MARKER_TYPE" = "ceo" ]; then
  cat >&2 <<BANNER
======================================================================
[apexyard] VIOLATION WARNING: Unauthorized review-marker write detected
======================================================================

You are about to write a *-ceo.approved review marker (filename stays
"-ceo.approved" regardless of the configured approver title below).

  *-ceo.approved must be written ONLY by the /approve-merge skill
  on an explicit per-PR ${APPROVER_TITLE} approval. It carries structured
  provenance fields (approved_by=user, skill_version=2) that cannot be
  fabricated casually.

  Who may write this marker:
    /approve-merge skill, invoked by the orchestrator on an explicit ${APPROVER_TITLE} nod

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

# --- rex / security / architecture (or an unresolved #962 indirect role):
#     BLOCKING gate on the active-reviewer marker. ---

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

if [ "$RESOLVED_VIA" = "literal" ]; then
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
fi
# else (RESOLVED_VIA=indirect): TARGET_PR was already best-effort set (may
# be empty) by _extract_marker_pr above; TARGET_REPO stays empty — a repo
# slug is essentially never a literal argument to review_marker_path in
# real usage (always a variable), so there's nothing reliable to recover.
# Same "skip when unresolvable" fallback the legacy bare-marker-filename
# case already uses below.

_active_reviewer_allows() {
  # Returns 0 (allow) iff the active-reviewer marker exists and its
  # <repo>#<pr>:<kind> content matches this write's (repo, pr, role).
  #
  # #974: the #962 comment this replaced claimed fail-closed-on-empty-
  # MARKER_TYPE was automatic — "no well-formed active-reviewer marker can
  # ever have an empty kind field, so `[ "$c_kind" = "$MARKER_TYPE" ]` can
  # never succeed". True for a WELL-FORMED marker, but a MALFORMED one on
  # disk (a stray trailing colon: "owner/repo#42:" with nothing after it)
  # parses to an empty c_kind below. Pair that with this write's own role
  # being unresolved too (MARKER_TYPE="" — the #962 indirect path when
  # _extract_marker_role finds no literal rex/ceo/security/architecture
  # token in the review_marker_path(...) call), and the equality check
  # collapses to `[ "" = "" ]` — TRUE — incorrectly ALLOWING the write.
  # Guard both sides explicitly: an empty resolved role, on EITHER side,
  # can never be treated as a match.
  [ -n "$MARKER_TYPE" ] || return 1

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

  [ -n "$c_kind" ] || return 1
  [ "$c_kind" = "$MARKER_TYPE" ] || return 1
  [ -n "$TARGET_PR" ] && [ "$c_pr" != "$TARGET_PR" ] && return 1
  # Repo check only when the target filename encodes a repo (post-#485
  # qualified marker). Legacy bare markers, and #962 indirect writes where
  # the repo couldn't be recovered, skip this comparison.
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

You are about to write a *-${MARKER_TYPE:-<unresolved>}.approved review marker with no
matching active-reviewer session marker.

Target:  ${TARGET}
Expected active-reviewer marker: ${ACTIVE_REVIEWER_MARKER}
  (must contain: <owner>/<repo>#${TARGET_PR:-<pr>}:${MARKER_TYPE:-<role>})

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
