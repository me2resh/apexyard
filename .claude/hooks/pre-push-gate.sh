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
# This hook's only remaining job is a reminder about the SESSION's OWN
# working-directory repo. It never reasons about a different repository
# a push might target (a sibling checkout, a `workspace/<name>/` clone).
# It names the repo it checked, every time, so the scope is never
# ambiguous (PR #1428 review, Rex finding B1).
#
# MAINTAINER DECISION (PR #1428 round 2): ApexYard runs configured local
# pre-push commands only inside an ApexYard fork that has installed the
# git-native hook. A managed-project clone gets NO local pre-push checks
# from ApexYard, ever — that clone's own CI is its backstop. This matches
# AgDR-0115, which already forbids ApexYard from setting `core.hooksPath`
# in a managed clone. So this hook never suggests that install in a repo
# that is not an ApexYard fork (PR #1428 review, Rex finding B2) — doing
# so would point an operator at wiring AgDR-0115 already rejected, and a
# managed repo that ships its own `.githooks/` would get ITS OWN scripts
# executed if the operator followed that advice (the #1087 HIGH-1 hazard
# `.claude/skills/handover/SKILL.md` already documents for a related
# case).
#
# So this hook checks two things about ONLY the session's own
# working-directory repo, never the command text:
#   1. Is this repo an ApexYard fork at all? (a `.apexyard-fork` marker,
#      or the fork's own `.githooks/pre-push` plus `bin/install-git-hooks.sh`)
#   2. If it is, has it installed the git-native hook?
#
# It reads nothing but that repo's own files and `git config` — never
# the command text — so it has nothing left to get wrong about "which
# repo." Before this redesign, the Claude-layer gate ran a repository's
# commands itself, sometimes against the wrong repo (#1366). After it,
# only the fork's git-native hook runs them, and only inside a fork.
#
# Install the git-native hook once per ApexYard-fork clone:
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

# ---------------------------------------------------------------------------
# Is this repo an ApexYard fork at all? Only a fork gets the install
# advice. A managed-project clone gets a short scope note instead — never
# the `core.hooksPath` suggestion AgDR-0115 forbids for that case.
# ---------------------------------------------------------------------------

IS_APEXYARD_FORK=0
if [ -f "$REPO_ROOT/.apexyard-fork" ]; then
  IS_APEXYARD_FORK=1
elif [ -f "$REPO_ROOT/.githooks/pre-push" ] && [ -f "$REPO_ROOT/bin/install-git-hooks.sh" ]; then
  IS_APEXYARD_FORK=1
fi

if [ "$IS_APEXYARD_FORK" != "1" ]; then
  echo "NOTE: this session's working-directory repo ($REPO_ROOT) is not an ApexYard fork. This check covers only that repo. ApexYard runs no local pre-push checks here — this repo's own CI is the backstop." >&2
  exit 0
fi

cat >&2 <<MSG
NOTE: this session's working-directory repo ($REPO_ROOT) is an ApexYard
fork that has not installed the git-native pre-push hook. This check
covers only that repo, not a different repository this push might
target. Configured .pre_push.commands run only through that hook, not
through this Claude Code check.

Install it once per clone:
  git config core.hooksPath .githooks
  (or: bash bin/install-git-hooks.sh)

Until then, CI is the only backstop for .pre_push.commands on this
clone. See .claude/rules/git-conventions.md and AgDR-0173.
MSG
exit 0
