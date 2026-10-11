#!/usr/bin/env bash
# Check the operator escape hatch: hooks are ON by default and OFF under
#   claude --settings '{"disableAllHooks": true}'
# (me2resh/apexyard#1623). See docs/hooks-fail-closed.md.
#
# The check starts the real Claude Code CLI twice in this repository. It uses
# a fake API key, so no model call succeeds and no credential is needed. The
# SessionStart hook still runs before the model is called, and Claude Code
# writes one "Hooks: SessionStart" line per hook run to the debug file.
#
#   1. Default run: the debug file MUST show the repository's SessionStart
#      hook finishing. If it does not, hooks are not on by default.
#   2. Override run: the debug file MUST show no hook run at all. If it does,
#      the override no longer disables hooks.
#
# Usage: bin/check-escape-hatch.sh
# Exit:  0 pass, 1 fail, 2 the claude CLI is missing.
# bash 3.2 compatible.

set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"

if ! command -v claude >/dev/null 2>&1; then
  echo "ERROR: the claude CLI is not on PATH. Install the pinned version first." >&2
  exit 2
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/home"

# Start claude in the repository with a clean environment. A run that ends in
# an invalid-key error is expected. Only the debug file matters.
run_claude() {
  # $1 = debug file, remaining args = extra claude options
  local debug_file="$1"
  shift
  (
    cd "$ROOT" || exit 1
    env -i PATH="$PATH" HOME="$WORK/home" ANTHROPIC_API_KEY=sk-ant-fake-key-for-escape-hatch-check \
      claude -p hi --debug-file "$debug_file" "$@" </dev/null >"$WORK/stdout" 2>&1
  )
  return 0
}

hook_runs() {
  # Count the hook runs that Claude Code logged in a debug file.
  local count
  count=$(grep -c 'Hooks: SessionStart.*finished with status' "$1" 2>/dev/null) || count=0
  printf '%s' "$count"
}

run_claude "$WORK/default.log"
default_runs=$(hook_runs "$WORK/default.log")

run_claude "$WORK/override.log" --settings '{"disableAllHooks": true}'
override_runs=$(hook_runs "$WORK/override.log")

status=0
if [ "$default_runs" -ge 1 ]; then
  echo "PASS: hooks are on by default ($default_runs SessionStart hook run(s) logged)"
else
  echo "FAIL: hooks did not run by default (0 SessionStart hook runs logged)" >&2
  status=1
fi
if [ "$override_runs" -eq 0 ]; then
  echo "PASS: hooks are off under --settings disableAllHooks true (0 hook runs logged)"
else
  echo "FAIL: hooks still ran under --settings disableAllHooks true ($override_runs run(s) logged)" >&2
  status=1
fi
exit "$status"
