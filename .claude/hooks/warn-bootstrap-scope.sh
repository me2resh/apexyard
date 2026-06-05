#!/bin/bash
# PreToolUse advisory hook on `git commit`: fires when the bootstrap
# exemption marker is active (.claude/session/active-bootstrap) but the
# commit message does NOT reference expected handover outputs.
#
# The bootstrap exemption is intentionally narrow — it covers only the
# registry, assessment, architecture stub, README, and topology files
# written by /handover, /setup, /update, and /split-portfolio. If the
# agent commits something unrelated while the marker is set, that is
# scope-creep and warrants an advisory warning.
#
# Resolution: .claude/rules/workflow-gates.md § Bootstrap-skill exemption
# and .claude/skills/handover/SKILL.md § "Bootstrap scope".
#
# This hook is ADVISORY ONLY — exit 0 in every path. It never blocks.
# Shape mirrors check-upstream-drift.sh and detect-role-trigger.sh.

set -u

INPUT=$(cat)

# Only act on Bash tool calls.
TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
if [ "$TOOL_NAME" != "Bash" ]; then
  exit 0
fi

COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
if [ -z "$COMMAND" ]; then
  exit 0
fi

# Only inspect git commit commands.
if ! printf '%s' "$COMMAND" | grep -qE '\bgit\s+commit\b'; then
  exit 0
fi

# Only warn when the bootstrap marker is active.
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)
if [ -z "$REPO_ROOT" ]; then
  exit 0
fi

MARKER="$REPO_ROOT/.claude/session/active-bootstrap"
if [ ! -f "$MARKER" ]; then
  exit 0
fi

# Extract commit message from -m or -F flags (same pattern as
# validate-commit-format.sh). If the message cannot be extracted (e.g.
# heredoc substitution, interactive commit), exit 0 — we can't check.
COMMAND_FLAT=$(printf '%s' "$COMMAND" | tr '\n' ' ')
MSG=""
MSG=$(printf '%s' "$COMMAND_FLAT" | sed -nE "s/.*-m[[:space:]]+'([^']*)'.*/\1/p" | head -1)
if [ -z "$MSG" ]; then
  MSG=$(printf '%s' "$COMMAND_FLAT" | sed -nE 's/.*-m[[:space:]]+"([^"]*)".*/\1/p' | head -1)
fi
if [ -z "$MSG" ]; then
  MSG_FILE=$(printf '%s' "$COMMAND_FLAT" | sed -nE 's/.*(-F|--file)[[:space:]]+([^[:space:]]+).*/\2/p' | head -1)
  if [ -n "$MSG_FILE" ] && [ -f "$MSG_FILE" ]; then
    MSG=$(cat "$MSG_FILE")
  fi
fi

if [ -z "$MSG" ]; then
  # Can't read the message (heredoc / interactive) — advisory can't run.
  exit 0
fi

# Check whether the commit message contains keywords that belong to
# the expected set of handover outputs. Case-insensitive grep.
#
# Bootstrap-related keywords are intentionally specific to avoid false
# positives on common verbs like "update" or "setup":
#
#   handover-assessment, handover       — /handover skill output
#   apexyard.projects.yaml, registry    — registry append (step 7)
#   architecture/container, architecture stub — C4 diagram stub
#   topology                            — topology bundle instantiation
#   /setup, /update, /split-portfolio   — other bootstrap skills
#   projects/<path>                     — ops-repo projects/ dir writes
#   active-bootstrap                    — the marker file itself
if printf '%s' "$MSG" | grep -qiE \
  'handover|apexyard\.projects\.yaml|registry|architecture.?(stub|container)|topology|/setup|/update|split.?portfolio|projects/|active-bootstrap'; then
  # Commit looks related to bootstrap work — no warning.
  exit 0
fi

# The marker is active but the commit message doesn't reference any known
# bootstrap output. Emit an advisory banner.
cat >&2 <<'BANNER'
⚠ Bootstrap exemption is active but this commit doesn't reference handover output.
  If this work is unrelated to the handover, run /start-ticket first.
BANNER

exit 0
