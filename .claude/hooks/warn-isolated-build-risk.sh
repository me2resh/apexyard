#!/bin/bash
# PreToolUse advisory hook (exit 0 always) — nudges toward the safe
# multi-repo git pattern documented in .claude/rules/isolated-builds.md
# (me2resh/apexyard#784).
#
# WHAT IT WARNS ON
# ----------------
# Two command shapes that historically preceded a corrupted ops fork:
#
#   1. `cd` into a `/tmp` (or macOS `/private/tmp`, `/var/folders`) path as
#      part of a build/clone workflow. `/tmp` clones can be cleaned mid-
#      session, and a subsequent command in the same chain then silently
#      runs wherever the shell actually ended up.
#   2. `git reset --hard` (or other destructive git: `git clean -fd`,
#      `git checkout --force`) anywhere in the command. If a preceding `cd`
#      in the same chain silently failed (no `|| exit 1`), this can reset
#      the WRONG repo — including the ops fork itself.
#
# WHY THIS HOOK CANNOT BLOCK
# --------------------------
# It cannot tell "this /tmp path is a scratch read" from "this /tmp path is
# a build clone", nor "this hard reset is guarded by a prior toplevel check"
# from "this hard reset is not". Blocking on a false positive would stop
# entirely legitimate scratch-directory work. The achievable value is a
# loud, cheap nudge — same shape as check-upstream-drift.sh and
# detect-role-trigger.sh: advisory only, exit 0 in every path.
#
# See .claude/rules/isolated-builds.md for the full rule this hook backstops.

set -u

INPUT=$(cat)
COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)

if [ -z "$COMMAND" ]; then
  exit 0
fi

WARN_TMP=0
WARN_HARD_RESET=0

# Match `cd` into /tmp, /private/tmp (macOS symlink target), or /var/folders
# (macOS's actual TMPDIR). Word-boundary on `cd` so `bundle exec cd-tool` etc.
# don't false-positive.
if echo "$COMMAND" | grep -qE '(^|[;&|]|\s)cd\s+["'"'"']?(/tmp|/private/tmp|/var/folders)(/|["'"'"']?(\s|$))'; then
  WARN_TMP=1
fi

# Match destructive git: hard reset, forced clean, forced checkout.
if echo "$COMMAND" | grep -qE '\bgit\s+reset\s+(--hard|-\-hard)\b|\bgit\s+clean\s+(-[a-zA-Z]*f[a-zA-Z]*d?|--force)\b|\bgit\s+checkout\s+(--force|-f)\b'; then
  WARN_HARD_RESET=1
fi

if [ "$WARN_TMP" -eq 0 ] && [ "$WARN_HARD_RESET" -eq 0 ]; then
  exit 0
fi

{
  echo "ApexYard advisory (.claude/rules/isolated-builds.md) — isolated-build risk detected:"
  if [ "$WARN_TMP" -eq 1 ]; then
    echo "  - 'cd' into a /tmp-class path. /tmp clones can be cleaned mid-session;"
    echo "    prefer 'git worktree add' off a persistent clone, and always"
    echo "    'cd <dir> || exit 1' so a vanished/mistyped path aborts loudly."
  fi
  if [ "$WARN_HARD_RESET" -eq 1 ]; then
    echo "  - Destructive git (reset --hard / clean -f / checkout --force) detected."
    echo "    Confirm 'git rev-parse --show-toplevel' names the intended repo"
    echo "    before running this — a silently-failed 'cd' earlier in the chain"
    echo "    would otherwise let this land on the wrong repo (e.g. the ops fork)."
  fi
  echo "  This is advisory only — not blocking. See the rule for the safe pattern."
} >&2

exit 0
