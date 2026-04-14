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
# .claude/project-config.json `.ui_paths` (JSON array of regex patterns).
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

if [ -z "$TOUCHED_UI" ]; then
  # Not a UI PR — nothing to enforce, merge-gate will continue
  exit 0
fi

# UI PR detected — require a design approval marker
APPROVAL="${REPO_ROOT:-.}/.claude/session/reviews/${PR_NUMBER}-design.approved"

if [ ! -f "$APPROVAL" ]; then
  cat >&2 <<MSG
BLOCKED: PR #${PR_NUMBER} touches UI files but has no design-review approval marker.

UI files in this diff:
$(echo "$TOUCHED_UI" | tr ' ' '\n' | sed 's/^/  /' | grep -v '^  $' | head -20)

ApexStack requires a design review on any PR that touches user-facing UI —
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

To customize which file patterns count as "UI", set
\`.ui_paths\` in .claude/project-config.json (JSON array of regex patterns).

For projects that deliberately ship UI without design review (e.g. admin tools,
internal dashboards), touch the marker file manually — that's a visible,
auditable "we decided to skip design review" artifact rather than an
invisible omission.
MSG
  exit 2
fi

# SHA consistency check
APPROVED_SHA=$(tr -d '[:space:]' < "$APPROVAL")
CURRENT_SHA=$(git rev-parse HEAD 2>/dev/null)
if [ -n "$APPROVED_SHA" ] && [ -n "$CURRENT_SHA" ] && [ "$APPROVED_SHA" != "$CURRENT_SHA" ]; then
  cat >&2 <<MSG
BLOCKED: Design review approved commit ${APPROVED_SHA:0:7} but HEAD is now ${CURRENT_SHA:0:7}.

New commits were pushed after the design review. Re-request design review
on the latest HEAD before merging.
MSG
  exit 2
fi

exit 0
