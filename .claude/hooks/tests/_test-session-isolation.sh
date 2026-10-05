#!/bin/bash
# _test-session-isolation.sh — source from every hook test (me2resh/apexyard#1549).
#
# A live Claude Code / Cursor shell often exports CLAUDE_CODE_SESSION_ID.
# Hooks then write ops-root pins and resolve-cache files under
# ${APEXYARD_OPS_PIN_DIR:-$HOME/.claude/apexyard}/. Inheriting that session id
# from a test shell overwrites the operator's real pin and cache.
#
# This helper neutralises every per-session location the hooks write:
#   - unsets CLAUDE_CODE_SESSION_ID (no pin/cache key)
#   - APEXYARD_OPS_DISABLE_PIN=1 (walk-up only; ignore any leftover pin)
#   - APEXYARD_DISABLE_RESOLUTION_CACHE=1 (no resolve-cache-* writes)
#   - APEXYARD_OPS_PIN_DIR=<fresh temp dir> (belt-and-suspenders if a case
#     re-exports a session id without its own pin dir)
#
# Include line (must use BASH_SOURCE so `source ./test_foo.sh` resolves the
# helper next to the test file; plain `$0` is `/bin/bash` when sourced):
#   . "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"
#
# Temp pin dirs are left under $TMPDIR unless the runner exports
# _APEXYARD_TEST_PIN_DIR (bin/run-hook-tests.sh does, and removes it on EXIT).
# Pin-behaviour suites may override these exports per-case after sourcing.
#
# Re-applying on every source is intentional: a subshell inherits
# _TEST_SESSION_ISOLATION_SOURCED from its parent, and must still clear a
# freshly exported CLAUDE_CODE_SESSION_ID before invoking a hook.
#
# Architecture evolution (#1549): isolation used to be runner-only
# (APEXYARD_OPS_DISABLE_PIN + APEXYARD_DISABLE_RESOLUTION_CACHE). That left
# direct `bash test_*.sh` under a live session able to overwrite
# ~/.claude/apexyard/ops-root-<sid> and resolve-cache-<sid>-*. The helper
# moves the same neutralisation into every suite, keeps a disposable pin
# dir, and pairs with a required-helper lint plus a write-capable regression.

unset CLAUDE_CODE_SESSION_ID

export APEXYARD_OPS_DISABLE_PIN=1
export APEXYARD_DISABLE_RESOLUTION_CACHE=1

if [ -z "${_APEXYARD_TEST_PIN_DIR:-}" ] || [ ! -d "${_APEXYARD_TEST_PIN_DIR}" ]; then
  _APEXYARD_TEST_PIN_DIR=$(mktemp -d "${TMPDIR:-/tmp}/apexyard-test-pins.XXXXXX") || {
    echo "FAIL: could not create temp pin dir for session isolation" >&2
    exit 1
  }
fi
export APEXYARD_OPS_PIN_DIR="${_APEXYARD_TEST_PIN_DIR}"
_TEST_SESSION_ISOLATION_SOURCED=1

# #1528 — the leak scans look up remote visibility with `gh api`. A test must
# never reach the network. Default the test-only lookup command to `false`
# (lookup fails → fail closed → scan). Suites that exercise classification
# override APEXYARD_LEAK_VISIBILITY_CMD with a stub.
export APEXYARD_LEAK_VISIBILITY_CMD="${APEXYARD_LEAK_VISIBILITY_CMD:-false}"
