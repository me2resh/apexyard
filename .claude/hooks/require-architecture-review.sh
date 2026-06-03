#!/bin/bash
# PreToolUse hook on `gh pr merge` AND `gh api .../pulls/<N>/merge`: when the
# PR's diff carries a DESIGN ARTIFACT (technical design doc, migration AgDR, or
# feature spec / PRD), require an architecture-review approval marker at
# .claude/session/reviews/<pr>-architecture.approved (with a matching HEAD SHA)
# before letting the merge through.
#
# This is the Design->Build gate: a technical design lands as a committed doc
# and is merged BEFORE the team builds against it. Gating that merge on the
# Solution Architect's (Tariq's) sign-off is the mechanical realisation of
# "review the design before Build". It is the non-code analog of
# require-design-review-for-ui.sh (which gates UI PRs on a design marker).
#
# Both merge shapes are covered — see _lib-extract-pr.sh for the parser and
# #47 for why the API-shape bypass was a gap worth closing.
#
# Enforces .claude/rules/workflow-gates.md § "Architecture Review Gate" and
# workflows/sdlc.md Phase 2 (Technical Design).
#
# What counts as a "design artifact" (default patterns, regex):
#   - docs/agdr/AgDR-*migration*.md      migration AgDRs
#   - **/technical-design*.md, **/*tech-design*.md
#   - **/designs/**                      design docs
#   - **/prds/**, **/*prd*.md            product requirements / feature specs
#   - **/feature-spec*.md
#
# Projects that want a broader/narrower list can override via
# .claude/project-config.json:
#   `.design_paths`         — REPLACE the default DESIGN_GLOBS entirely (JSON array of regex patterns)
#   `.design_paths_exclude` — ADDITIVE: paths matching any pattern here are removed
#                             from the touched-design set AFTER DESIGN_GLOBS matching.
#                             Mirrors the `ui_paths_exclude` precedent (#275).
#
# How the marker gets written: the Solution Architect agent (Tariq) writes it
# on an APPROVED verdict, or the operator records it via /approve-architecture.
#
# Trust model: same as the other markers. Local session state, gitignored,
# converts invisible inference ("the design looked fine") into visible file
# existence. For adversarial trust, use CODEOWNERS.

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)

if [ -z "$COMMAND" ]; then
  exit 0
fi

# Shared merge-shape detector + PR-number parser (see _lib-extract-pr.sh).
# Handles `gh pr merge <N>` and `gh api repos/<owner>/<repo>/pulls/<N>/merge`.
. "$(dirname "$0")/_lib-extract-pr.sh"
# Repo-qualified marker path helper (#485).
. "$(dirname "$0")/_lib-review-markers.sh"

if ! is_merge_command "$COMMAND"; then
  exit 0
fi

# Parse --repo (for `gh pr merge --repo owner/repo`). Fallback: recover from
# the `gh api .../pulls/<N>/merge` URL path so downstream `gh pr diff` calls
# still know which repo to talk to.
CMD_REPO=$(echo "$COMMAND" | sed -nE 's/.*--repo[[:space:]]+([^[:space:]]+).*/\1/p' | head -1)
if [ -z "$CMD_REPO" ]; then
  CMD_REPO=$(echo "$COMMAND" | grep -oE 'repos/[^/[:space:]]+/[^/[:space:]]+/pulls/[0-9]+/merge' | sed -nE 's|repos/([^/]+/[^/]+)/pulls/.*|\1|p' | head -1)
fi
REPO_FLAG=""
if [ -n "$CMD_REPO" ]; then
  REPO_FLAG="--repo $CMD_REPO"
fi

PR_NUMBER=$(extract_pr_number "$COMMAND")
# Resolve the repo for qualified marker paths (#485).
# CMD_REPO already parsed above; fall back via helper if blank.
if [ -z "$CMD_REPO" ]; then
  CMD_REPO=$(extract_repo_from_command "$COMMAND")
fi

if [ -z "$PR_NUMBER" ]; then
  # Let block-unreviewed-merge.sh handle the "no PR number" error — we skip
  exit 0
fi

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
# Resolve the ops fork root (where session markers live), not the
# workspace clone's git toplevel. Inside `workspace/<project>/`,
# REPO_ROOT is the project clone — markers live in the ops fork
# above it. See me2resh/apexyard#229 + #230.
HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$HOOK_DIR/_lib-ops-root.sh" ]; then
  # shellcheck source=/dev/null
  . "$HOOK_DIR/_lib-ops-root.sh"
  OPS_ROOT=$(resolve_ops_root "$REPO_ROOT")
fi
MARKER_HOME="${OPS_ROOT:-${REPO_ROOT:-.}}"

# Default design-artifact path patterns (regex, case-insensitive match below).
DESIGN_GLOBS='docs/agdr/AgDR-.*migration.*\.md$
technical-design.*\.md$
tech-design.*\.md$
/designs/
/prds/
prd.*\.md$
feature-spec.*\.md$'

# Allow project-config to override (REPLACE the default list).
if [ -n "$REPO_ROOT" ] && [ -f "${REPO_ROOT}/.claude/project-config.json" ]; then
  CUSTOM=$(jq -r '.design_paths // [] | join("|")' "${REPO_ROOT}/.claude/project-config.json" 2>/dev/null)
  if [ -n "$CUSTOM" ] && [ "$CUSTOM" != "null" ]; then
    DESIGN_GLOBS=$(printf '%s' "$CUSTOM" | tr '|' '\n')
  fi
fi

# Get the PR's changed files
CHANGED=$(gh pr diff "$PR_NUMBER" $REPO_FLAG --name-only 2>/dev/null)
if [ -z "$CHANGED" ]; then
  # Couldn't determine files — skip rather than false-positive
  exit 0
fi

TOUCHED_DESIGN=""
while IFS= read -r FILE; do
  [ -z "$FILE" ] && continue
  while IFS= read -r PATTERN; do
    [ -z "$PATTERN" ] && continue
    if echo "$FILE" | grep -qiE "$PATTERN"; then
      TOUCHED_DESIGN="${TOUCHED_DESIGN}${FILE} "
      break
    fi
  done <<< "$DESIGN_GLOBS"
done <<< "$CHANGED"

# Apply `.design_paths_exclude` — additive override that REMOVES paths from the
# touched-design set even when DESIGN_GLOBS matched. Lets adopters keep the
# broad defaults while carving out specific dirs (e.g. doc samples / fixtures).
if [ -n "$REPO_ROOT" ] && [ -f "${REPO_ROOT}/.claude/project-config.json" ]; then
  EXCLUDE=$(jq -r '.design_paths_exclude // [] | join("|")' "${REPO_ROOT}/.claude/project-config.json" 2>/dev/null)
  if [ -n "$EXCLUDE" ] && [ "$EXCLUDE" != "null" ] && [ -n "$TOUCHED_DESIGN" ]; then
    FILTERED=""
    for FILE in $TOUCHED_DESIGN; do
      if ! echo "$FILE" | grep -qiE "$EXCLUDE"; then
        FILTERED="${FILTERED}${FILE} "
      fi
    done
    TOUCHED_DESIGN="$FILTERED"
  fi
fi

if [ -z "$TOUCHED_DESIGN" ]; then
  # Not a design-artifact PR — nothing to enforce, merge-gate will continue
  exit 0
fi

# Design-artifact PR detected — require an architecture-review approval marker.
# Marker lives at the ops fork root (MARKER_HOME), repo-qualified (#485).
APPROVAL=$(review_marker_path "${CMD_REPO:-unknown}" "$PR_NUMBER" architecture "$MARKER_HOME")

if [ ! -f "$APPROVAL" ]; then
  cat >&2 <<MSG
BLOCKED: PR #${PR_NUMBER} carries a design artifact but has no architecture-review approval marker.

Design artifacts in this diff:
$(echo "$TOUCHED_DESIGN" | tr ' ' '\n' | sed 's/^/  /' | grep -v '^  $' | head -20)

ApexYard requires a Solution Architect review on any PR that carries a
technical design, migration AgDR, or feature spec — the design must be sound
before the team builds against it. See .claude/rules/workflow-gates.md
§ "Architecture Review Gate" and workflows/sdlc.md Phase 2.

The expected approval file does not exist:
  ${APPROVAL}

To unblock:

  1. Run /design-review ${PR_NUMBER} — the Solution Architect (Tariq) reviews
     the design against the architecture lens (NFRs, patterns, tech debt,
     AgDR linkage, risk, trade-offs, traceability, migration safety).
  2. On an APPROVED verdict, Tariq writes the marker automatically. A human
     architect can instead record it with /approve-architecture ${PR_NUMBER}.
  3. Retry the merge.

To customize which file patterns count as a "design artifact":

  \`.design_paths\`         — REPLACE the default list entirely (JSON array of regex)
  \`.design_paths_exclude\` — ADDITIVE carve-out: keep the broad defaults but skip
                            specific dirs (e.g. doc samples / fixtures).

Both keys live in .claude/project-config.json.

For PRs that deliberately ship a design without architecture review, record
the marker manually — that's a visible, auditable "we decided to skip the
architecture review" artifact rather than an invisible omission.
MSG
  exit 2
fi

# SHA consistency check — resolve the PR's real HEAD via GitHub rather than
# local HEAD (see #55). Falls back to local HEAD with a warning if the
# gh call fails (network, auth).
APPROVED_SHA=$(tr -d '[:space:]' < "$APPROVAL")
CURRENT_SHA=$(resolve_pr_head "$PR_NUMBER" "$CMD_REPO")
if [ -z "$CURRENT_SHA" ]; then
  echo "WARN: Could not resolve PR #${PR_NUMBER} HEAD via gh — falling back to local HEAD. If this merge fails, run 'gh pr checkout ${PR_NUMBER}' first or re-authenticate gh." >&2
  CURRENT_SHA=$(git rev-parse HEAD 2>/dev/null)
fi
if [ -n "$APPROVED_SHA" ] && [ -n "$CURRENT_SHA" ] && [ "$APPROVED_SHA" != "$CURRENT_SHA" ]; then
  cat >&2 <<MSG
BLOCKED: Architecture review approved commit ${APPROVED_SHA:0:7} but HEAD is now ${CURRENT_SHA:0:7}.

New commits were pushed after the architecture review. Re-request the design
review on the latest HEAD before merging.
MSG
  exit 2
fi

exit 0
