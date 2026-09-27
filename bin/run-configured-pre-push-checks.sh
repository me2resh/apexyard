#!/bin/bash
# bin/run-configured-pre-push-checks.sh — run THIS repo's own configured
# pre-push commands (`.claude/project-config.json` -> `.pre_push.commands`).
#
# Companion to bin/run-pre-push-checks.sh, which runs the framework's own
# hardcoded check set (markdownlint, shellcheck, subpacks). This script
# runs whatever an adopter — or this ops fork — configured for their OWN
# repo, the same command list `.claude/hooks/pre-push-gate.sh` used to run
# against a text-derived, sometimes-wrong target (me2resh/apexyard#1366).
#
# This script has no target to get wrong. It is invoked from
# .githooks/pre-push, a git-native `pre-push` hook whose working directory
# git itself sets to the repository being pushed — there is no command
# text to parse here at all. See
# docs/agdr/AgDR-0173-git-native-pre-push-command-execution.md.
#
# Exit codes:
#   0 — no commands configured, all configured commands passed, or the
#       skip marker was present
#   1 — a configured command failed
#
# Skip marker: same shape as bin/run-pre-push-checks.sh — a HEAD commit
# message line consisting of exactly `<!-- pre-push: skip -->` bypasses
# this script for one push.
#
# Usage:
#   bash bin/run-configured-pre-push-checks.sh

set -u

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
if [ -z "$REPO_ROOT" ]; then
  echo "ERROR: not inside a git repository." >&2
  exit 1
fi
cd "$REPO_ROOT" || exit 1

# ---------------------------------------------------------------------------
# Skip marker — check HEAD commit message for the escape hatch.
# ---------------------------------------------------------------------------

SKIP_MARKER='<!-- pre-push: skip -->'
HEAD_MSG=$(git log -1 --format='%B' 2>/dev/null)
# -x: whole-line match only. See #1097 — prose that merely mentions the
# marker must not act as a bypass, only a line consisting of exactly it.
if printf '%s\n' "$HEAD_MSG" | grep -qxF -- "$SKIP_MARKER"; then
  echo "WARN: configured pre-push commands bypassed by skip marker in HEAD commit message." >&2
  echo "      Skipped commands will still run in CI — fix broken state before merging." >&2
  exit 0
fi

# ---------------------------------------------------------------------------
# Load command list from project config via the shared reader.
# ---------------------------------------------------------------------------

CMDS_JSON=""
if [ -f "$REPO_ROOT/.claude/hooks/_lib-read-config.sh" ]; then
  # Disable the session-scoped resolution cache (Hakim's A1, PR #1428
  # review). config_get otherwise consults a cache file keyed by a weak
  # fingerprint (modification time and size, no path). A git hook shares
  # its Claude Code session ID with the session that invoked the push,
  # so a same-second, same-size coincidence could hand this script a
  # cached config from a DIFFERENT repository, or let it plant one for
  # an ops-fork gate to read later. Setting this before the library loads
  # forces a fresh read every time, exactly like the existing config
  # tests that already export it for the same class of reason
  # (test_config_warn_dropped_defaults.sh,
  # test_config_merge_semantics.sh).
  export APEXYARD_DISABLE_RESOLUTION_CACHE=1
  # shellcheck disable=SC1090,SC1091
  . "$REPO_ROOT/.claude/hooks/_lib-read-config.sh"
  # Pin the config root to THIS repository. _config_repo_root's ops-fork
  # walk-up (me2resh/apexyard#1102, AgDR-0118) exists for the Claude Code
  # session case, where the process's working directory and the intended
  # config owner can legitimately differ (a session rooted in the ops
  # fork, editing a sibling clone). Here they cannot differ: git already
  # resolved THIS process's working directory to the pushed repository,
  # so that repository's own config is the only correct answer — even
  # when it sits nested under an ops fork's workspace/<name>/, the exact
  # layout where the walk-up would otherwise return the ops fork instead
  # (me2resh/apexyard#1405 review, finding B1). This direct assignment
  # has no matching precedent elsewhere in the tree. Every other
  # assignment to this variable resets it to empty, in a test, rather
  # than pinning it to a target (Rex's A5, PR #1428 review).
  _CONFIG_ROOT_CACHE="$REPO_ROOT"
  CMDS_JSON=$(config_get '.pre_push.commands' 2>/dev/null)
fi

if [ -z "$CMDS_JSON" ] || [ "$CMDS_JSON" = "null" ] || [ "$CMDS_JSON" = "[]" ]; then
  exit 0
fi

# ---------------------------------------------------------------------------
# Run each command. On first non-zero, block with a summary.
# ---------------------------------------------------------------------------

# printf '%s', NOT echo — CMDS_JSON may carry a JSON backslash escape (the
# markdownlint `tr '\n' '\0'` command). echo would mangle it under an
# escape-interpreting shell. Same bug class as #629/#631.
NUM_CMDS=$(printf '%s' "$CMDS_JSON" | jq 'length' 2>/dev/null)
if [ -z "$NUM_CMDS" ] || [ "$NUM_CMDS" = "null" ]; then
  exit 0
fi

FAILED=""
FAILED_CMD=""
FAILED_TAIL=""
i=0
while [ "$i" -lt "$NUM_CMDS" ]; do
  NAME=$(printf '%s' "$CMDS_JSON" | jq -r ".[$i].name // \"step-$i\"" 2>/dev/null)
  RUN=$(printf '%s' "$CMDS_JSON" | jq -r ".[$i].run // empty" 2>/dev/null)
  i=$((i + 1))

  if [ -z "$RUN" ]; then
    continue
  fi

  TMP_LOG=$(mktemp -t run-configured-pre-push.XXXXXX)
  if bash -c "$RUN" >"$TMP_LOG" 2>&1; then
    rm -f "$TMP_LOG"
    continue
  fi

  FAILED_TAIL=$(tail -20 "$TMP_LOG" 2>/dev/null)
  rm -f "$TMP_LOG"
  FAILED="$NAME"
  FAILED_CMD="$RUN"
  # Fail-fast, matching bin/run-pre-push-checks.sh and the pre-#1366
  # pre-push-gate.sh: don't keep running once one check has failed.
  break
done

if [ -n "$FAILED" ]; then
  cat >&2 <<MSG

BLOCKED: configured pre-push check failed: $FAILED
  command: $FAILED_CMD
  last 20 lines of output:
$FAILED_TAIL

Fix the issue above, then push again.

To bypass for a genuine emergency (checks still run in CI):
  git commit --amend -m "\$(git log -1 --format=%B)
  ${SKIP_MARKER}"

See .claude/rules/git-conventions.md and AgDR-0173.
MSG
  exit 1
fi

exit 0
