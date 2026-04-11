#!/bin/bash
# PreToolUse hook on `git commit -m / -F`: scans the commit message for
# issue references (Closes #N, Refs #N, Fixes #N, Resolves #N, Related to #N)
# and blocks the commit if any reference points at an issue that doesn't
# exist in the tracker repo.
#
# Backstop for the ticket-vocabulary rule (.claude/rules/ticket-vocabulary.md).
# The primary enforcement is self-discipline: never use tracker notation for
# plan items that have no real issue behind them. This hook catches the
# downstream symptom — a fabricated #N that made it into a commit message
# on its way to becoming durable history.
#
# Interactive commits (no -m / -F) are NOT checked. Parsing .git/COMMIT_EDITMSG
# before the editor opens would race with git's own validation, and Claude
# rarely uses the interactive path anyway. Accepted gap.
#
# Tracker repo resolves in this order:
#   1. .claude/project-config.json `.tracker_repo`
#   2. origin remote (parsed from `git remote get-url origin`)

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)

if [ -z "$COMMAND" ]; then
  exit 0
fi

# Only check on git commit
if ! echo "$COMMAND" | grep -qE '\bgit\s+commit\b'; then
  exit 0
fi

# Extract the commit message. Try -m "..." / -m '...' first, then -F <file>.
# If neither is present, assume interactive commit — skip.
#
# IMPORTANT: Claude and humans both commonly use multi-line -m arguments via
# HEREDOC substitution like `git commit -m "$(cat <<EOF ... EOF)"`, which means
# the literal -m value spans multiple lines in the command string. `sed -nE`
# processes stdin line-by-line by default, so a regex like `-m "([^"]*)"`
# cannot span lines and silently fails to match.
#
# Fix: flatten the command string with `tr '\n' ' '` before sed processing.
# The message then parses as a single logical line. The ref-pattern grep
# below doesn't care about line breaks either way.
#
# Without this flattening, the hook was INERT for any multi-line commit —
# which is the default shape for Claude-generated commits. Confirmed via
# smoke test before the fix.
COMMAND_FLAT=$(echo "$COMMAND" | tr '\n' ' ')

MSG=""

# -m 'single quoted'
MSG=$(echo "$COMMAND_FLAT" | sed -nE "s/.*-m[[:space:]]+'([^']*)'.*/\1/p" | head -1)

# -m "double quoted"
if [ -z "$MSG" ]; then
  MSG=$(echo "$COMMAND_FLAT" | sed -nE 's/.*-m[[:space:]]+"([^"]*)".*/\1/p' | head -1)
fi

# -F <file> / --file <file>
if [ -z "$MSG" ]; then
  MSG_FILE=$(echo "$COMMAND_FLAT" | sed -nE 's/.*(-F|--file)[[:space:]]+([^[:space:]]+).*/\2/p' | head -1)
  if [ -n "$MSG_FILE" ] && [ -f "$MSG_FILE" ]; then
    MSG=$(cat "$MSG_FILE")
  fi
fi

# No message found → interactive commit or parse failure. Skip.
if [ -z "$MSG" ]; then
  exit 0
fi

# Extract issue references. Patterns matched (case-insensitive):
#   Closes #N / Close #N / Closed #N
#   Fixes #N / Fix #N / Fixed #N
#   Resolves #N / Resolve #N / Resolved #N
#   Refs #N / Ref #N / References #N / Related to #N
# One reference per line is the common pattern; multiples in one line also work.
REFS=$(echo "$MSG" | grep -oEi '\b(close[sd]?|fix(e[sd])?|resolve[sd]?|ref(s|erences)?|related to)[[:space:]]+#[0-9]+' | grep -oE '#[0-9]+' | sort -u)

if [ -z "$REFS" ]; then
  exit 0
fi

# Resolve tracker repo
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
TRACKER_REPO=""
if [ -f "${REPO_ROOT}/.claude/project-config.json" ]; then
  TRACKER_REPO=$(jq -r '.tracker_repo // empty' "${REPO_ROOT}/.claude/project-config.json" 2>/dev/null)
fi
if [ -z "$TRACKER_REPO" ]; then
  ORIGIN_URL=$(git remote get-url origin 2>/dev/null)
  TRACKER_REPO=$(echo "$ORIGIN_URL" | sed -nE 's|.*[:/]([^/:]+/[^/]+)\.git$|\1|p; s|.*[:/]([^/:]+/[^/]+)$|\1|p' | head -1)
fi

if [ -z "$TRACKER_REPO" ]; then
  echo "WARN: verify-commit-refs.sh could not resolve tracker repo. Skipping." >&2
  exit 0
fi

# Verify each referenced issue exists
MISSING=""
for REF in $REFS; do
  NUM=$(echo "$REF" | tr -d '#')
  if ! gh issue view "$NUM" --repo "$TRACKER_REPO" --json state >/dev/null 2>&1; then
    MISSING="${MISSING}${REF} "
  fi
done

if [ -n "$MISSING" ]; then
  cat >&2 <<MSG
BLOCKED: Commit message references issues that do not exist in ${TRACKER_REPO}:
  ${MISSING}

This is the failure mode the ticket-vocabulary rule exists to prevent — do NOT
use tracker notation (Closes #N, Refs #N, etc.) for plan items that have no
real issue behind them. See .claude/rules/ticket-vocabulary.md.

If you intended to reference a real issue, verify the number(s).
If you were about to commit work that has no ticket yet, create one first:
  gh issue create --repo ${TRACKER_REPO} --title "..."
and use the returned number in your commit message.

If the reference is truly informational (cross-repo link that can't be verified
with \`gh issue view\`), write it as a plain URL instead of #N notation.
MSG
  exit 2
fi

exit 0
