#!/bin/bash
# bin/run-pre-push-checks.sh — run the framework pre-push check set.
#
# Shared implementation used by:
#   - .githooks/pre-push   (terminal `git push`)
#   - .claude/hooks/pre-push-gate.sh reads .pre_push.commands from
#     .claude/project-config.json directly and calls bash -c on each entry,
#     so it doesn't invoke this script — but the command strings in config are
#     defined to match what this script does.
#
# This script is the canonical reference for "what checks run before push".
# If you add a check, add it here AND mirror it in .claude/project-config.json
# → pre_push.commands so both paths stay in sync.
#
# Exit codes:
#   0 — all checks passed (or all missing-tool checks were skipped)
#   1 — one or more checks failed
#
# Skip marker:
#   Include the literal string <!-- pre-push: skip --> in the HEAD commit
#   message (subject or body) to bypass for a genuine emergency.
#   The bypass is printed to stderr so it's visible and grep-able.
#
# Usage:
#   bash bin/run-pre-push-checks.sh
#   bash bin/run-pre-push-checks.sh --list   # print check names and exit 0

set -euo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
if [ -z "$REPO_ROOT" ]; then
  echo "ERROR: not inside a git repository." >&2
  exit 1
fi

# --list mode: print check names and exit
if [ "${1:-}" = "--list" ]; then
  echo "markdownlint"
  echo "shellcheck"
  echo "site-counts"
  echo "subpacks"
  exit 0
fi

# ---------------------------------------------------------------------------
# Skip marker — check HEAD commit message for the escape hatch.
# ---------------------------------------------------------------------------

SKIP_MARKER='<!-- pre-push: skip -->'
HEAD_MSG=$(cd "$REPO_ROOT" && git log -1 --format='%B' 2>/dev/null)
if echo "$HEAD_MSG" | grep -qF -- "$SKIP_MARKER"; then
  echo "WARN: pre-push checks bypassed by skip marker in HEAD commit message." >&2
  echo "      All skipped checks will still run in CI — fix before merging." >&2
  exit 0
fi

# ---------------------------------------------------------------------------
# Helper: run_check <name> <command>
#   Runs <command> via bash -c. On failure, prints the name, command, and
#   last 20 lines of output, then exits 1.
# ---------------------------------------------------------------------------

FAILED=""

run_check() {
  local name="$1"
  local cmd="$2"
  echo "  running: $name" >&2
  local tmp
  tmp=$(mktemp -t pre-push-check.XXXXXX)
  if bash -c "$cmd" >"$tmp" 2>&1; then
    # Pass: surface any INFO: lines (e.g. missing-tool skip messages) so the
    # contributor sees the actionable install hint, then discard the rest.
    grep "^INFO:" "$tmp" >&2 || true
    rm -f "$tmp"
    return 0
  fi
  echo "" >&2
  echo "FAILED: $name" >&2
  echo "  command: $cmd" >&2
  echo "  last 20 lines:" >&2
  tail -20 "$tmp" >&2
  rm -f "$tmp"
  FAILED="$name"
  return 1
}

# ---------------------------------------------------------------------------
# Check set — keep in sync with .claude/project-config.json pre_push.commands
# ---------------------------------------------------------------------------

cd "$REPO_ROOT"

echo "pre-push checks:" >&2

# 1. markdownlint
# Uses npx so no global install is required. Missing npx → skip with note.
MARKDOWNLINT_CMD="command -v npx >/dev/null 2>&1 || { echo 'INFO: npx not found — markdownlint check skipped. Install Node.js (https://nodejs.org) to enable it locally.'; exit 0; }; npx --yes markdownlint-cli2 '**/*.md' '#node_modules' '#.git' '#workspace' 2>&1"
run_check "markdownlint" "$MARKDOWNLINT_CMD" || true

# 2. shellcheck — .claude/hooks/*.sh, severity=warning
# Missing shellcheck → skip with note.
SHELLCHECK_CMD="command -v shellcheck >/dev/null 2>&1 || { echo 'INFO: shellcheck not installed — shell-script check skipped. Install with: brew install shellcheck  (macOS) | apt-get install shellcheck  (Debian/Ubuntu) | dnf install shellcheck  (Fedora).'; exit 0; }; find .claude/hooks -maxdepth 1 -name '*.sh' | sort | xargs shellcheck --severity=warning 2>&1"
run_check "shellcheck" "$SHELLCHECK_CMD" || true

# 3. site-counts drift detection
run_check "site-counts" "bash .claude/hooks/tests/test_site_counts.sh 2>&1" || true

# 4. subpack extraction smoke test
run_check "subpacks" "bash .claude/hooks/tests/test_subpack_extraction.sh 2>&1" || true

# ---------------------------------------------------------------------------
# Result
# ---------------------------------------------------------------------------

if [ -n "$FAILED" ]; then
  echo "" >&2
  cat >&2 <<MSG
BLOCKED: pre-push check failed: $FAILED

Fix the issue above, then push again.

To bypass for a genuine emergency (checks still run in CI):
  git commit --amend -m "\$(git log -1 --format=%B)
  ${SKIP_MARKER}"

Bypasses are grep-able on purpose — they should be rare and auditable.
See .claude/rules/pr-workflow.md "Before git push (HARD STOP)".
MSG
  exit 1
fi

echo "  all checks passed." >&2
exit 0
