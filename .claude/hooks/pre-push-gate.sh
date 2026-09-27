#!/bin/bash
# pre-push-gate.sh — advisory reminder for local pre-push checks.
#
# REDESIGNED (me2resh/apexyard#1366, AgDR-0173). This hook used to pick a
# target repository out of the Bash command's TEXT (a `cd` prefix, a
# `-C` flag, or the session's own working directory), read that repo's
# `.pre_push.commands`, and run them itself. Every shape of that parsing
# was exploitable: PR #1405 spent four review rounds narrowing it and
# never closed it. Hakim's H1 finding on that PR's last commit still
# reproduced with a heredoc body, a quoted separator, a commit message,
# and an echo — read-only text that only MENTIONS a push could make the
# gate run a repository's declared commands before any permission
# prompt. See that PR's closing comment and AgDR-0104 ("command-text
# parsing cannot be made sound").
#
# This hook now NEVER executes a repository's commands and NEVER blocks.
# The real check moved to the git-native layer:
#
#   .githooks/pre-push -> bin/run-configured-pre-push-checks.sh
#
# A git `pre-push` hook receives its working directory from git itself —
# the repository actually being pushed, always, by construction. There is
# no command text to parse there, so H1 (a read-only command running a
# repo's commands), H3 (a crafted command steering the check to a clean
# repo), and L2 (some push shapes skipping the Claude-layer hooks) from
# PR #1405's review all stop applying: none of them describe a way to
# fool git about its own working directory.
#
# This hook's only remaining job is a one-line reminder, printed only
# when the session's own working-directory repo has not installed that
# git-native hook. It reads nothing but that repo's own `git config` —
# never the command text — so it has nothing left to get wrong about
# "which repo." A clone that never installs the git-native hook and never
# runs CI locally is not blocked here. CI is the actual backstop, the
# same accepted trade-off `bin/run-pre-push-checks.sh` already documents
# for a fresh clone with no git hooks installed at all.
#
# Install the git-native hook once per clone:
#   git config core.hooksPath .githooks
#   (or: bash bin/install-git-hooks.sh)
#
# See docs/agdr/AgDR-0173-git-native-pre-push-command-execution.md.

INPUT=$(cat)
COMMAND=""
if command -v jq >/dev/null 2>&1; then
  COMMAND=$(jq -r '.tool_input.command // empty' <<<"$INPUT" 2>/dev/null) || COMMAND=""
fi
if [ "$COMMAND" = "null" ]; then
  COMMAND=""
fi

if [ -z "$COMMAND" ]; then
  exit 0
fi

# A loose, best-effort check used ONLY to decide whether to print a
# reminder. This hook runs no commands and blocks nothing, so a false
# match here costs one extra reminder line, never a security decision —
# unlike the pre-#1366 version, precision does not matter for safety.
if ! printf '%s' "$COMMAND" | grep -qE '\bgit[[:space:]]+push\b'; then
  exit 0
fi

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
if [ -z "$REPO_ROOT" ]; then
  exit 0
fi

# ---------------------------------------------------------------------------
# Has this repo installed the git-native hook? If so, it will run when git
# itself executes the push — correctly scoped no matter what the Bash
# command looked like — so no reminder is needed.
# ---------------------------------------------------------------------------

HOOKS_PATH=$(git -C "$REPO_ROOT" config --get core.hooksPath 2>/dev/null)
if [ -n "$HOOKS_PATH" ]; then
  case "$HOOKS_PATH" in
    /*) HOOK_FILE="$HOOKS_PATH/pre-push" ;;
    *) HOOK_FILE="$REPO_ROOT/$HOOKS_PATH/pre-push" ;;
  esac
  if [ -f "$HOOK_FILE" ] && [ -x "$HOOK_FILE" ]; then
    exit 0
  fi
fi

cat >&2 <<MSG
NOTE: this session's working-directory repo ($REPO_ROOT) has not
installed the git-native pre-push hook. Configured .pre_push.commands
now run only through that hook, not through this Claude Code check.

Install it once per clone:
  git config core.hooksPath .githooks
  (or: bash bin/install-git-hooks.sh)

Until then, CI is the only backstop for .pre_push.commands on this
clone. See .claude/rules/git-conventions.md and AgDR-0173.
MSG
exit 0
