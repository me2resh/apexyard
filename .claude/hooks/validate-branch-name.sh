#!/bin/bash
# Validates branch naming convention before push.
# Format: {type}/{TICKET-ID}-{description}
#
# The accepted branch-type list is project-configurable via
# .claude/project-config.json (.branch.type_whitelist). Defaults ship at
# .claude/project-config.defaults.json. See apexyard#109 for the schema.

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)

if [ -z "$COMMAND" ]; then
  exit 0
fi

# Only check on git push
if ! echo "$COMMAND" | grep -qE '\bgit\s+push\b'; then
  exit 0
fi

# Read the branch from the actual push command's source ref when present.
# This is the worktree-safe path: when an Agent fan-out worker runs `git push
# origin feature/GH-N-foo` from inside its own worktree, the harness $PWD may
# be a sibling worktree, so `git branch --show-current` returns the wrong
# branch. The push command itself carries the truth.
#
# Falls back to local HEAD when the push has no source ref (no-arg push,
# `git push origin` with no ref, etc.) — preserves today's behaviour for
# anyone not passing the ref explicitly. See me2resh/apexyard#194.
HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
PUSH_REF=""
if [ -f "$HOOK_DIR/_lib-extract-push-ref.sh" ]; then
  # shellcheck disable=SC1090,SC1091
  . "$HOOK_DIR/_lib-extract-push-ref.sh"
  PUSH_REF=$(extract_push_ref "$COMMAND")
fi

if [ -n "$PUSH_REF" ]; then
  CURRENT_BRANCH="$PUSH_REF"
else
  CURRENT_BRANCH=$(git branch --show-current 2>/dev/null)
fi

# Allow trunk and shared integration branches.
# Match the dev/main release model (apexyard#116) — dev is a valid trunk.
if [ "$CURRENT_BRANCH" = "main" ] || [ "$CURRENT_BRANCH" = "master" ] || [ "$CURRENT_BRANCH" = "develop" ] || [ "$CURRENT_BRANCH" = "dev" ]; then
  exit 0
fi

# Allow release-cut branches (apexyard#116, AgDR-0007). The /release skill
# prescribes `release/vN.N.N` (and optionally a `-rcN` suffix) as the
# canonical name for the dev → main release PR's source branch. This is
# a narrow, intentional exception to the standard {type}/{TICKET}-{desc}
# shape — release branches don't carry a ticket-id because the release
# itself is the ticket. See me2resh/apexyard#168 for why this exception
# exists.
if echo "$CURRENT_BRANCH" | grep -qE '^release/v[0-9]+\.[0-9]+\.[0-9]+(-rc[0-9]+)?$'; then
  exit 0
fi

# Load the branch-type whitelist from project config.
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
# shellcheck source=./_lib-read-config.sh
if [ -n "$REPO_ROOT" ] && [ -f "$REPO_ROOT/.claude/hooks/_lib-read-config.sh" ]; then
  # shellcheck disable=SC1090,SC1091
  . "$REPO_ROOT/.claude/hooks/_lib-read-config.sh"
  TYPES=$(config_get '.branch.type_whitelist[]' | paste -sd'|' -)
fi
# Fallback if config unavailable (jq missing, standalone install, etc.)
if [ -z "$TYPES" ]; then
  TYPES="feature|fix|refactor|chore|docs|test|spike|ci|build|perf"
fi

# Load the ticket-ID regex from the tracker lib. The pattern is shape-only
# (no existence check at the push gate — that's validate-pr-create.sh's job).
# Default covers GH `#123` / `GH-123` plus enterprise prefixes (LIN, JIRA,
# ABC). Adopters who want a stricter shape (e.g. exactly Linear: `^[A-Z]+-[0-9]+$`)
# override `.tracker.id_pattern` in project-config.json. See AgDR-0033 and
# `.claude/hooks/_lib-tracker.sh`.
TRACKER_ID_PATTERN=""
if [ -n "$REPO_ROOT" ] && [ -f "$REPO_ROOT/.claude/hooks/_lib-tracker.sh" ]; then
  # shellcheck disable=SC1090,SC1091
  . "$REPO_ROOT/.claude/hooks/_lib-tracker.sh"
  TRACKER_ID_PATTERN=$(tracker_id_pattern)
fi

# Strip the anchors from the tracker pattern so we can embed it inside the
# branch-name regex (`type/<TICKET-ID>-<description>`). The lib returns a
# fully-anchored regex (`^...$`) because consumers like /start-ticket use
# it standalone; here we need the inner alternation.
INNER_PATTERN="${TRACKER_ID_PATTERN#^}"
INNER_PATTERN="${INNER_PATTERN%$}"
# Drop the wrapping parens if the pattern was `^(...)$` — they get re-added below.
case "$INNER_PATTERN" in
  '('*')')
    INNER_PATTERN="${INNER_PATTERN#(}"
    INNER_PATTERN="${INNER_PATTERN%)}"
    ;;
esac
# Fallback if extraction failed.
if [ -z "$INNER_PATTERN" ]; then
  INNER_PATTERN='[A-Z]{2,10}-[0-9]+|GH-[0-9]+|#[0-9]+'
fi

# Validate: type/<TICKET>-<description>
# The TICKET pattern is sourced from tracker.id_pattern so Linear / Jira
# / custom adopters get their own shape validation. Note: this pattern is
# intentionally aligned with the pr-title-check.yml CI workflow regex so
# anything that passes this hook also passes CI.
if ! echo "$CURRENT_BRANCH" | grep -qE "^(${TYPES})/(${INNER_PATTERN})-"; then
  cat >&2 <<MSG
BLOCKED: Branch '$CURRENT_BRANCH' doesn't follow naming convention.

Required shape (.claude/rules/git-conventions.md § "Branch Naming"):
  {type}/{TICKET-ID}-{description}

Accepted types: ${TYPES//|/, }
  (configurable: .claude/project-config.*.json → .branch.type_whitelist)

Accepted ticket-ID pattern: ${INNER_PATTERN}
  (configurable: .claude/project-config.*.json → .tracker.id_pattern)

Examples:
  feature/ABC-123-add-auth
  fix/GH-45-login-bug
  docs/ENG-99-update-readme

To unblock:
  1. Pick a ticket-ID (existing or new): /feature, /task, /bug
  2. Pick a short kebab-case description (max ~40 chars)
  3. Rename the current branch in place:
       git branch -m "$CURRENT_BRANCH" "feature/GH-XX-your-description"
     OR start fresh from the project's integration branch (most
     managed projects are trunk-based on 'main'; the apexyard framework
     itself uses 'dev' — pick the one that matches THIS repo):
       git checkout main && git checkout -b "feature/GH-XX-your-description"
  4. Retry the operation

If the current branch has commits you want to keep, the rename in
step 3 preserves them — the branch keeps its history, just gains a
new name.
MSG
  exit 2
fi

exit 0
