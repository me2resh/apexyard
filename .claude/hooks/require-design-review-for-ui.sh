#!/bin/bash
# PreToolUse hook on `gh pr merge` AND `gh api .../pulls/<N>/merge`: when the
# PR's diff touches UI files, require a design approval marker at
# .claude/session/reviews/<pr>-design.approved (with a matching HEAD SHA) before
# letting the merge through.
#
# Both merge shapes are covered — see _lib-extract-pr.sh for the parser and
# #47 for why the API-shape bypass was a gap worth closing.
#
# Enforces .claude/rules/pr-quality.md § "Design Review" and
# workflows/code-review.md § "UI Designer (conditional)" — which were
# prose-only until this hook shipped.
#
# What counts as "UI":
#   - *.tsx, *.jsx (React)
#   - *.vue (Vue)
#   - *.svelte (Svelte)
#   - *.css, *.scss, *.sass, *.less (styles)
#   - design-tokens.* (design systems)
#
# Projects that want a broader/narrower list can override via
# .claude/project-config.json:
#   `.ui_paths`         — REPLACE the default UI_GLOBS entirely (JSON array of regex patterns)
#   `.ui_paths_exclude` — ADDITIVE: paths matching any pattern here are removed
#                         from the touched-UI set AFTER UI_GLOBS matching. Mirrors
#                         the `migration_paths`-exclude precedent (#275).
#
# Use `ui_paths_exclude` when you want to keep the default broad matching but
# carve out a specific dir (e.g. `^docs/examples/`, `^wiki/artifacts/`) where
# `.jsx`/`.tsx` files are documentation samples rather than real UI.
#
# How the marker gets written: the design-reviewer records approval by
# writing the marker file. There is no /approve-design skill yet — the
# design reviewer writes the file manually or via a (future) skill.
#
# Trust model: same as other markers. Local session state, gitignored,
# converts invisible inference ("ah, the UI change looked fine") into
# visible file existence. For adversarial trust, use CODEOWNERS.

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)

if [ -z "$COMMAND" ]; then
  exit 0
fi

# Shared merge-shape detector + PR-number parser (see _lib-extract-pr.sh).
# Handles `gh pr merge <N>` and `gh api repos/<owner>/<repo>/pulls/<N>/merge`.
. "$(dirname "$0")/_lib-extract-pr.sh"

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

# Default UI path patterns (regex). Note: .tsx$ / .jsx$ are EXACT — they must
# not match plain .ts / .js, which are often backend/server files. The
# original draft had \.tsx?$ which matched .ts too; caught in smoke test.
UI_GLOBS='\.tsx$
\.jsx$
\.vue$
\.svelte$
\.css$
\.scss$
\.sass$
\.less$
design-tokens'

# Allow project-config to override
if [ -n "$REPO_ROOT" ] && [ -f "${REPO_ROOT}/.claude/project-config.json" ]; then
  CUSTOM=$(jq -r '.ui_paths // [] | join("|")' "${REPO_ROOT}/.claude/project-config.json" 2>/dev/null)
  if [ -n "$CUSTOM" ] && [ "$CUSTOM" != "null" ]; then
    UI_GLOBS="$CUSTOM"
  fi
fi

# Get the PR's changed files
CHANGED=$(gh pr diff "$PR_NUMBER" $REPO_FLAG --name-only 2>/dev/null)
if [ -z "$CHANGED" ]; then
  # Couldn't determine files — skip rather than false-positive
  exit 0
fi

TOUCHED_UI=""
while IFS= read -r FILE; do
  [ -z "$FILE" ] && continue
  while IFS= read -r PATTERN; do
    [ -z "$PATTERN" ] && continue
    if echo "$FILE" | grep -qE "$PATTERN"; then
      TOUCHED_UI="${TOUCHED_UI}${FILE} "
      break
    fi
  done <<< "$UI_GLOBS"
done <<< "$CHANGED"

# Apply `.ui_paths_exclude` — additive override that REMOVES paths from the
# touched-UI set even when UI_GLOBS matched. Lets adopters keep the broad
# defaults while carving out specific directories (e.g. `^docs/examples/`,
# `^wiki/artifacts/`) where `.jsx`/`.tsx` files are doc samples not UI (#275).
if [ -n "$REPO_ROOT" ] && [ -f "${REPO_ROOT}/.claude/project-config.json" ]; then
  EXCLUDE=$(jq -r '.ui_paths_exclude // [] | join("|")' "${REPO_ROOT}/.claude/project-config.json" 2>/dev/null)
  if [ -n "$EXCLUDE" ] && [ "$EXCLUDE" != "null" ] && [ -n "$TOUCHED_UI" ]; then
    FILTERED=""
    for FILE in $TOUCHED_UI; do
      if ! echo "$FILE" | grep -qE "$EXCLUDE"; then
        FILTERED="${FILTERED}${FILE} "
      fi
    done
    TOUCHED_UI="$FILTERED"
  fi
fi

if [ -z "$TOUCHED_UI" ]; then
  # Not a UI PR — nothing to enforce, merge-gate will continue
  exit 0
fi

# UI PR detected — require a design approval marker
# Marker lives at the ops fork root (MARKER_HOME), not the workspace clone.
APPROVAL="${MARKER_HOME}/.claude/session/reviews/${PR_NUMBER}-design.approved"

if [ ! -f "$APPROVAL" ]; then
  cat >&2 <<MSG
BLOCKED: PR #${PR_NUMBER} touches UI files but has no design-review approval marker.

UI files in this diff:
$(echo "$TOUCHED_UI" | tr ' ' '\n' | sed 's/^/  /' | grep -v '^  $' | head -20)

ApexYard requires a design review on any PR that touches user-facing UI —
see .claude/rules/pr-quality.md § "Design Review (UI Changes)" and
workflows/code-review.md § "UI Designer (conditional)".

The expected approval file does not exist:
  ${APPROVAL}

To unblock:

  1. Invoke the UI Designer role (or a human designer) to review the UI changes
  2. When the designer approves, record it with the current HEAD SHA:
       mkdir -p .claude/session/reviews
       git rev-parse HEAD > .claude/session/reviews/${PR_NUMBER}-design.approved
  3. Retry the merge

To customize which file patterns count as "UI":

  \`.ui_paths\`         — REPLACE the default list entirely (JSON array of regex)
  \`.ui_paths_exclude\` — ADDITIVE carve-out: keep the broad defaults but skip
                          specific dirs (e.g. ["^docs/examples/", "^wiki/"]).
                          Useful when .jsx/.tsx files are doc samples not UI
                          (#275).

Both keys live in .claude/project-config.json.

For projects that deliberately ship UI without design review (e.g. admin tools,
internal dashboards), touch the marker file manually — that's a visible,
auditable "we decided to skip design review" artifact rather than an
invisible omission.
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
BLOCKED: Design review approved commit ${APPROVED_SHA:0:7} but HEAD is now ${CURRENT_SHA:0:7}.

New commits were pushed after the design review. Re-request design review
on the latest HEAD before merging.
MSG
  exit 2
fi

exit 0
