#!/bin/bash
# Validates PR creation:
# - PR title matches format: type(TICKET): description
# - PR body contains a Glossary section
# - Branch has a ticket ID
# - The ticket referenced in the title actually exists in the tracker repo
#   (backstop for the ticket-vocabulary rule — catches fabricated #N that
#   slipped through prose into a PR title)
#
# Customize the ticket pattern below if your team uses a different scheme.

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)

if [ -z "$COMMAND" ]; then
  exit 0
fi

# Parse --repo from the gh command for cross-repo PR creation
CMD_REPO=$(echo "$COMMAND" | sed -nE 's/.*--repo[[:space:]]+([^[:space:]]+).*/\1/p' | head -1)

# Only check on gh pr create
if ! echo "$COMMAND" | grep -qE '\bgh\s+pr\s+create\b'; then
  exit 0
fi

ERRORS=""

# Extract --title value (macOS-compatible, no grep -P)
TITLE=$(echo "$COMMAND" | sed -n 's/.*--title[[:space:]]*["'"'"']\([^"'"'"']*\)["'"'"'].*/\1/p' | head -1)
if [ -z "$TITLE" ]; then
  TITLE=$(echo "$COMMAND" | sed -n 's/.*--title[[:space:]]*\([^[:space:]]*\).*/\1/p' | head -1)
fi

# Validate PR title format if we can extract it
# Accepts: type(<TICKET>): … or type(<TICKET>)!: … (breaking change)
# The !? makes the breaking-change marker optional per Conventional Commits 1.0.
#
# The accepted type list is project-configurable via .claude/project-config.json
# (.pr.title_type_whitelist). Defaults ship at .claude/project-config.defaults.json.
# See apexyard#109.
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
PR_TYPES=""
if [ -n "$REPO_ROOT" ] && [ -f "$REPO_ROOT/.claude/hooks/_lib-read-config.sh" ]; then
  # shellcheck disable=SC1090,SC1091
  . "$REPO_ROOT/.claude/hooks/_lib-read-config.sh"
  PR_TYPES=$(config_get '.pr.title_type_whitelist[]' 2>/dev/null | paste -sd'|' -)
fi
if [ -z "$PR_TYPES" ]; then
  PR_TYPES="feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert"
fi

TICKET_REF=""
if [ -n "$TITLE" ]; then
  if ! echo "$TITLE" | grep -qE "^(${PR_TYPES})\(([A-Z]{2,10}-[0-9]+|#[0-9]+)\)!?:"; then
    ERRORS="${ERRORS}PR title '$TITLE' doesn't match format: type(TICKET-ID): description\n"
    ERRORS="${ERRORS}Accepted types (from .claude/project-config.*.json → .pr.title_type_whitelist): ${PR_TYPES//|/, }\n"
  else
    # Extract the ticket reference so we can verify it exists
    TICKET_REF=$(echo "$TITLE" | sed -nE 's/^[a-z]+\(([^)]+)\):.*/\1/p')
  fi
fi

# Verify the ticket in the title actually exists in the tracker repo
# (backstop for ticket-vocabulary.md — catches fabricated #N in PR titles)
if [ -n "$TICKET_REF" ]; then
  # Extract digits from the ref (works for both #N and PREFIX-N)
  TICKET_NUM=$(echo "$TICKET_REF" | grep -oE '[0-9]+$')

  # Resolve tracker repo: prefer --repo flag, then project-config.json, then origin
  REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
  TRACKER_REPO=""
  if [ -n "$CMD_REPO" ]; then
    TRACKER_REPO="$CMD_REPO"
  elif [ -f "${REPO_ROOT}/.claude/project-config.json" ]; then
    TRACKER_REPO=$(jq -r '.tracker_repo // empty' "${REPO_ROOT}/.claude/project-config.json" 2>/dev/null)
  fi
  if [ -z "$TRACKER_REPO" ]; then
    # Parse owner/repo from origin remote
    ORIGIN_URL=$(git remote get-url origin 2>/dev/null)
    TRACKER_REPO=$(echo "$ORIGIN_URL" | sed -nE 's|.*[:/]([^/:]+/[^/]+)\.git$|\1|p; s|.*[:/]([^/:]+/[^/]+)$|\1|p' | head -1)
  fi

  if [ -n "$TICKET_NUM" ] && [ -n "$TRACKER_REPO" ]; then
    # Fetch both number and state in one call so we can distinguish
    # "does not exist" from "exists but CLOSED". Both are blocking.
    ISSUE_JSON=$(gh issue view "$TICKET_NUM" --repo "$TRACKER_REPO" --json number,state 2>/dev/null)
    if [ -z "$ISSUE_JSON" ]; then
      cat >&2 <<MSG
BLOCKED: PR title references ${TICKET_REF} but issue #${TICKET_NUM} does not
exist in ${TRACKER_REPO}.

This is the failure mode the ticket-vocabulary rule exists to prevent — do NOT
use tracker notation (#N) for plan items that have no real issue behind them.
See .claude/rules/ticket-vocabulary.md § "The rule".

If you intended to create the PR for a real ticket, verify the number.
If you were about to file work that has no ticket yet, create one first:
  gh issue create --repo ${TRACKER_REPO} --title "..."
and use the returned number in your PR title.
MSG
      exit 2
    fi

    ISSUE_STATE=$(echo "$ISSUE_JSON" | jq -r '.state // empty' 2>/dev/null)
    if [ "$ISSUE_STATE" = "CLOSED" ]; then
      cat >&2 <<MSG
BLOCKED: PR title references ${TICKET_REF} but issue #${TICKET_NUM} in
${TRACKER_REPO} is CLOSED.

Every PR needs its own OPEN ticket. Referencing a closed issue means the PR
has no live acceptance criteria, no QA handoff, and no tracker row to move
through the SDLC states — the ticket is already Done.

Common causes:
  - The work is a follow-up to the closed issue → create a NEW ticket that
    describes the follow-up, link back to the closed one in the body, and
    use the new number in the PR title.
  - The closed issue was auto-closed by a prior PR that didn't fully finish
    the work → re-open it (gh issue reopen ${TICKET_NUM} --repo ${TRACKER_REPO})
    or create a new ticket for the remaining work.
  - The number is a typo → fix the PR title.

See .claude/rules/ticket-vocabulary.md and the "every PR needs its own open
ticket" feedback in memory.
MSG
      exit 2
    fi
  fi
fi

# Check PR body for required sections.
#
# The list of required headings is project-configurable via
# .claude/project-config.*.json (`.pr.required_sections`). Shipped default
# is ["Testing", "Glossary"] — matches the canonical PR description in
# `workflows/code-review.md`. Forks extend or restrict per fork.
#
# Supports both --body "..." (inline) and --body-file <path> (file).
#
# Skip marker: the literal `.pr.skip_marker` string in the body bypasses
# the check with a visible stderr WARN. Default marker is
# `<!-- pr-sections: skip -->`.
BODY_CONTENT=""
BODY_FILE=$(echo "$COMMAND" | sed -nE 's/.*--body-file[[:space:]]+([^[:space:]]+).*/\1/p' | head -1)
if [ -n "$BODY_FILE" ] && [ -f "$BODY_FILE" ]; then
  BODY_CONTENT=$(cat "$BODY_FILE")
fi

if echo "$COMMAND" | grep -qE '\-\-body(-file)?\b'; then
  # Combined haystack — scan both the file content (if --body-file) and the
  # raw command (so inline --body "..." also matches).
  HAYSTACK=$(printf '%s\n%s\n' "$BODY_CONTENT" "$COMMAND")

  # Load required sections + skip marker from project config (shared reader).
  # shellcheck disable=SC1090,SC1091
  REQUIRED_SECTIONS=""
  PR_SKIP_MARKER=""
  if [ -n "$REPO_ROOT" ] && [ -f "$REPO_ROOT/.claude/hooks/_lib-read-config.sh" ]; then
    . "$REPO_ROOT/.claude/hooks/_lib-read-config.sh"
    REQUIRED_SECTIONS=$(config_get '.pr.required_sections[]' 2>/dev/null)
    PR_SKIP_MARKER=$(config_get_or '.pr.skip_marker' '<!-- pr-sections: skip -->' 2>/dev/null)
  fi
  # Fallbacks for bare checkouts predating the config schema.
  if [ -z "$REQUIRED_SECTIONS" ]; then
    REQUIRED_SECTIONS=$(printf 'Testing\nGlossary')
  fi
  if [ -z "$PR_SKIP_MARKER" ]; then
    PR_SKIP_MARKER='<!-- pr-sections: skip -->'
  fi

  # Skip marker short-circuits with a visible warning.
  if echo "$HAYSTACK" | grep -qF -- "$PR_SKIP_MARKER"; then
    echo "WARN: pr-sections check bypassed by skip marker ($PR_SKIP_MARKER) in PR body." >&2
  else
    # For each required heading, grep for `## <heading>` (case-insensitive).
    while IFS= read -r section; do
      [ -z "$section" ] && continue
      # Escape regex metachars in the section name so names like "Given / When / Then" work.
      section_re=$(printf '%s' "$section" | sed 's/[][\.^$*+?(){}|]/\\&/g')
      if ! echo "$HAYSTACK" | grep -qiE "^##[[:space:]]+${section_re}\b"; then
        ERRORS="${ERRORS}PR body missing required '## ${section}' section.\n"
      fi
    done <<EOF
${REQUIRED_SECTIONS}
EOF
  fi

  # -------------------------------------------------------------------
  # Single-Closes-keyword check — enforce "one ticket per PR" in the body.
  #
  # Counts distinct issue numbers targeted by GitHub's auto-closing keywords
  # (close / closes / closed / fix / fixes / fixed / resolve / resolves /
  # resolved, plus the `#NN` form). The title validator already caps the
  # title's ticket reference at one; this closes the loophole where the
  # body has `Closes #1 Closes #2 Closes #3` and GitHub auto-closes all
  # three on merge.
  #
  # Config:
  #   .pr.allow_multiple_closes (default false) — teams that batch
  #     umbrella PRs (rollbacks, dependency bumps) can opt in.
  #   .pr.multi_close_skip_marker (default `<!-- multi-close: approved -->`)
  #     — per-PR escape hatch that leaves a grep-able trace.
  #
  # Scans only the body content (not the command line), so a `--title`
  # reference doesn't accidentally count.
  ALLOW_MULTI_CLOSES="false"
  MULTI_CLOSE_SKIP="<!-- multi-close: approved -->"
  # shellcheck disable=SC1090,SC1091
  if [ -n "$REPO_ROOT" ] && [ -f "$REPO_ROOT/.claude/hooks/_lib-read-config.sh" ]; then
    . "$REPO_ROOT/.claude/hooks/_lib-read-config.sh"
    CFG_ALLOW=$(config_get_or '.pr.allow_multiple_closes' 'false' 2>/dev/null)
    if [ "$CFG_ALLOW" = "true" ]; then ALLOW_MULTI_CLOSES="true"; fi
    CFG_MARKER=$(config_get_or '.pr.multi_close_skip_marker' "$MULTI_CLOSE_SKIP" 2>/dev/null)
    if [ -n "$CFG_MARKER" ] && [ "$CFG_MARKER" != "null" ]; then
      MULTI_CLOSE_SKIP="$CFG_MARKER"
    fi
  fi

  if [ "$ALLOW_MULTI_CLOSES" != "true" ]; then
    # Strip code regions so closing keywords used as DOCUMENTATION (inside
    # code examples) don't count as real closes:
    #   - triple-backtick fences       (```...```)
    #   - tilde fences                 (~~~...~~~)
    #   - inline backticks             (`...`)
    #
    # Also strip inline-backticked skip markers so a PR that documents the
    # marker doesn't accidentally bypass its own check.
    STRIPPED_BODY=$(printf '%s\n' "$BODY_CONTENT" | awk '
      BEGIN { in_fence = 0; fence_char = "" }
      {
        line = $0
        if (in_fence == 0) {
          if (line ~ /^```/) { in_fence = 1; fence_char = "`"; next }
          if (line ~ /^~~~/) { in_fence = 1; fence_char = "~"; next }
          # Strip inline-backtick spans on non-fence lines.
          gsub(/`[^`]*`/, "", line)
          print line
        } else {
          if (fence_char == "`" && line ~ /^```/) { in_fence = 0; fence_char = ""; next }
          if (fence_char == "~" && line ~ /^~~~/) { in_fence = 0; fence_char = ""; next }
          # inside fence — drop
        }
      }
    ')

    # Extract distinct issue numbers referenced by a closing keyword + #NN.
    # Pattern: word-boundary, closing keyword (case-insensitive), whitespace,
    # optional repo-qualifier (owner/name), literal `#`, digits, word-boundary.
    CLOSE_NUMS=$(printf '%s\n' "$STRIPPED_BODY" | \
      grep -oiE '\b(close[sd]?|fix(e[sd])?|resolve[sd]?)[[:space:]]+([A-Za-z0-9._-]+/[A-Za-z0-9._-]+)?#[0-9]+' | \
      grep -oE '#[0-9]+' | \
      sort -u)

    CLOSE_COUNT=$(printf '%s\n' "$CLOSE_NUMS" | grep -c '^#')

    if [ "$CLOSE_COUNT" -gt 1 ]; then
      # Skip marker check runs against the STRIPPED body too — a marker used
      # as documentation inside backticks should not trigger a real bypass.
      if printf '%s\n' "$STRIPPED_BODY" | grep -qF -- "$MULTI_CLOSE_SKIP"; then
        echo "WARN: multi-close check bypassed by skip marker ($MULTI_CLOSE_SKIP) in PR body." >&2
      else
        NUMS_LIST=$(printf '%s ' $CLOSE_NUMS)
        ERRORS="${ERRORS}PR body has $CLOSE_COUNT distinct closing references (${NUMS_LIST}) — one ticket per PR (see CLAUDE.md). If this really is an umbrella PR, add the skip marker: $MULTI_CLOSE_SKIP\n"
      fi
    fi
  fi
fi

# Validate branch name has ticket ID
CURRENT_BRANCH=$(git branch --show-current 2>/dev/null)
if [ -n "$CURRENT_BRANCH" ] && [ "$CURRENT_BRANCH" != "main" ] && [ "$CURRENT_BRANCH" != "master" ]; then
  # Release-cut branches are exempt — same recognition `validate-branch-name.sh`
  # added in me2resh/apexyard#168 / #169. Release branches don't carry a
  # ticket-id because the release itself is the ticket.
  if echo "$CURRENT_BRANCH" | grep -qE '^release/v[0-9]+\.[0-9]+\.[0-9]+(-rc[0-9]+)?$'; then
    :  # release branch, exempt — fall through to the rest of the validator
  elif ! echo "$CURRENT_BRANCH" | grep -qE '[A-Z]{2,10}-[0-9]+|GH-[0-9]+|#[0-9]+'; then
    ERRORS="${ERRORS}Branch '$CURRENT_BRANCH' missing ticket ID.\n"
  fi
fi

if [ -n "$ERRORS" ]; then
  echo "PR VALIDATION BLOCKED:" >&2
  printf "$ERRORS" >&2
  echo "" >&2
  echo "Fix the issues above before creating the PR." >&2
  echo "See .claude/rules/git-conventions.md and .claude/rules/pr-quality.md." >&2
  exit 2
fi

exit 0
