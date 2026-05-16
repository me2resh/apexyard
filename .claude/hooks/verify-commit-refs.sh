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
#
# Upstream awareness (me2resh/apexyard#207): when an `upstream` remote is
# configured (typical fork-of-apexyard layout), a #N reference that misses in
# the primary tracker is rechecked against `upstream` before being declared
# missing. This lets a fork's `Closes #150` validate when issue 150 lives on
# the upstream repo — and, more importantly, lets GitHub's auto-close fire on
# merge (auto-close requires BARE #N notation; the cross-repo workaround
# `Closes owner/repo#150` passes the hook but breaks auto-close).
#
# Short-circuit: try the primary tracker first, only fall back to upstream on
# miss. No double query for refs that resolve in origin.

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
# the literal -m value spans multiple lines in the command string. We use awk
# with a line-by-line accumulator so the match runs against the whole logical
# command, not one physical line.
#
# Quoted-value regex is GREEDY and anchored on the next flag boundary
# (whitespace + `-<letter>`) or end-of-string. The earlier sed form
# `-m "([^"]*)"` truncated at the first embedded double quote
# (me2resh/apexyard#227), so commit messages whose body contained any
# `"` (admin-notice strings, status labels in quotes, prose like "current
# state") had their `Closes #N` / `Refs #N` references past the truncation
# point go unverified. awk + greedy + boundary anchor matches the closing
# `"` of the FLAG argument, not the first internal `"` inside the message.

extract_commit_msg() {
  # $1 = whole command string. Prints the extracted -m value, empty if none.
  printf '%s' "$1" | awk -v SQ="'" '
    { buf = (NR == 1 ? $0 : buf "\n" $0) }
    END {
      s = buf
      # Boundary terminator: whitespace + `-<letter>` (catches -F, -- flags,
      # and short flags like -S / -s) or end-of-string. -m is the only flag
      # before us in this branch, so any later -<letter> marks the end of
      # the -m value.
      # Single-quoted -m value, greedy.
      re = "-m[[:space:]]+" SQ "(.*)" SQ "([[:space:]]+-[a-zA-Z]|[[:space:]]*$)"
      if (match(s, re)) {
        chunk = substr(s, RSTART, RLENGTH)
        sub("^-m[[:space:]]+" SQ, "", chunk)
        sub(SQ "([[:space:]]+-[a-zA-Z].*)?$", "", chunk)
        sub(SQ "[[:space:]]*$", "", chunk)
        print chunk
        exit
      }
      # Double-quoted -m value, greedy.
      re = "-m[[:space:]]+\"(.*)\"([[:space:]]+-[a-zA-Z]|[[:space:]]*$)"
      if (match(s, re)) {
        chunk = substr(s, RSTART, RLENGTH)
        sub("^-m[[:space:]]+\"", "", chunk)
        sub("\"([[:space:]]+-[a-zA-Z].*)?$", "", chunk)
        sub("\"[[:space:]]*$", "", chunk)
        print chunk
        exit
      }
    }
  '
}

MSG=$(extract_commit_msg "$COMMAND")

# -F <file> / --file <file>
if [ -z "$MSG" ]; then
  COMMAND_FLAT=$(echo "$COMMAND" | tr '\n' ' ')
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

# Optional upstream fallback (see file header). Parse `git remote get-url
# upstream` into `owner/repo`; empty if no upstream remote is configured —
# in which case the validator behaves exactly as before (origin-only check).
UPSTREAM_REPO=""
if git remote get-url upstream >/dev/null 2>&1; then
  UPSTREAM_URL=$(git remote get-url upstream 2>/dev/null)
  UPSTREAM_REPO=$(echo "$UPSTREAM_URL" | sed -nE 's|.*[:/]([^/:]+/[^/]+)\.git$|\1|p; s|.*[:/]([^/:]+/[^/]+)$|\1|p' | head -1)
  # Don't double-check if upstream resolves to the same repo as the primary
  # tracker (e.g. running INSIDE the framework repo itself, where origin and
  # upstream both point at me2resh/apexyard).
  if [ "$UPSTREAM_REPO" = "$TRACKER_REPO" ]; then
    UPSTREAM_REPO=""
  fi
fi

# Verify each referenced issue exists. Fabricated #N (issue not found) is
# BLOCKING — that's the failure mode the ticket-vocabulary rule targets.
# References to CLOSED issues are WARNED (not blocked) because a commit may
# legitimately reference the closed issue it just finished (e.g. a revert or
# a follow-up clarification commit after the closing PR already shipped).
# The PR-level hook (validate-pr-create.sh) is the right place to enforce
# "every PR needs its own OPEN ticket".
MISSING=""
CLOSED=""
for REF in $REFS; do
  NUM=$(echo "$REF" | tr -d '#')
  ISSUE_JSON=$(gh issue view "$NUM" --repo "$TRACKER_REPO" --json number,state 2>/dev/null)
  # Short-circuit: only consult upstream when the primary tracker missed.
  if [ -z "$ISSUE_JSON" ] && [ -n "$UPSTREAM_REPO" ]; then
    ISSUE_JSON=$(gh issue view "$NUM" --repo "$UPSTREAM_REPO" --json number,state 2>/dev/null)
  fi
  if [ -z "$ISSUE_JSON" ]; then
    MISSING="${MISSING}${REF} "
    continue
  fi
  ISSUE_STATE=$(echo "$ISSUE_JSON" | jq -r '.state // empty' 2>/dev/null)
  if [ "$ISSUE_STATE" = "CLOSED" ]; then
    CLOSED="${CLOSED}${REF} "
  fi
done

if [ -n "$MISSING" ]; then
  # Include the upstream repo in the error when one was consulted — makes the
  # blocked-because-it's-not-in-either-place case explicit.
  if [ -n "$UPSTREAM_REPO" ]; then
    LOCATION_MSG="${TRACKER_REPO} or upstream ${UPSTREAM_REPO}"
  else
    LOCATION_MSG="${TRACKER_REPO}"
  fi
  cat >&2 <<MSG
BLOCKED: Commit message references issues that do not exist in ${LOCATION_MSG}:
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

if [ -n "$CLOSED" ]; then
  cat >&2 <<MSG
WARN: Commit message references CLOSED issue(s) in ${TRACKER_REPO}:
  ${CLOSED}
This commit is allowed through — a commit may legitimately reference the
issue it just closed. But at PR-create time the stricter rule applies: every
PR needs its own OPEN ticket. If this commit will end up in a PR that points
at the closed issue as its primary ticket, create a new open ticket first.
MSG
fi

exit 0
