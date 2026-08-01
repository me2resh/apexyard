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
# If you add a check, add it here AND mirror it in
# .claude/project-config.example.json → pre_push.commands so both paths stay
# in sync.
#
# NOTE (apexyard#1031): `.claude/project-config.json` is now gitignored AND
# untracked, so a fresh clone does not have one. Be precise about what that
# costs, because the obvious reassurance is wrong:
#
#   - a Claude Code push → pre-push-gate.sh → reads .pre_push.commands from
#     config. With no project-config.json the list is empty and the gate is
#     a no-op.
#   - terminal `git push` → .githooks/pre-push → this script. This does NOT
#     silently cover the gap: .githooks only runs where someone has opted in
#     with `git config core.hooksPath .githooks`, which is per-clone local
#     config and documented as optional (docs/getting-started.md
#     § "Terminal push hook"). On a fresh clone it is unset, so this path is
#     inactive too.
#
# So on a fresh clone BOTH pre-push paths are inactive. That is acceptable
# only because pre-push is a latency optimisation rather than the guardrail:
# the real backstop is CI, where markdown-lint.yml, shellcheck.yml and
# extract-subpacks-on-release.yml all run on `pull_request`. Nothing broken
# can merge whether or not a contributor has a local config.
#
# Contributors who want the local fast feedback do both, once:
#   cp .claude/project-config.example.json .claude/project-config.json
#   git config core.hooksPath .githooks
#
# The commands deliberately do NOT live in project-config.defaults.json —
# see docs/project-config.md for why (the defaults merge would push these
# repo-specific checks onto every adopter).
#
# Exit codes:
#   0 — all checks passed (or all missing-tool checks were skipped)
#   1 — one or more checks failed
#
# Skip marker:
#   Include the literal string <!-- pre-push: skip --> as its OWN LINE in
#   the HEAD commit message (subject or body) to bypass for a genuine
#   emergency. The match is whole-line (grep -x), so a sentence that merely
#   mentions the marker does NOT bypass — only a line consisting of exactly
#   the marker does. The bypass is printed to stderr so it's visible and
#   grep-able.
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
  echo "subpacks"
  exit 0
fi

# ---------------------------------------------------------------------------
# Skip marker — check HEAD commit message for the escape hatch.
# ---------------------------------------------------------------------------

SKIP_MARKER='<!-- pre-push: skip -->'
HEAD_MSG=$(cd "$REPO_ROOT" && git log -1 --format='%B' 2>/dev/null)
# -x: whole-line match only, so prose that mentions the marker inline
# (e.g. a commit that documents the escape hatch) does not trigger it —
# only a line consisting of exactly the marker does. See #1097.
if printf '%s\n' "$HEAD_MSG" | grep -qxF -- "$SKIP_MARKER"; then
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
# Check set — keep in sync with .claude/project-config.example.json's
# pre_push.commands (the tracked template; the real file is untracked, #1031)
# ---------------------------------------------------------------------------

cd "$REPO_ROOT"

echo "pre-push checks:" >&2

# 1. markdownlint
# Uses npx so no global install is required. Missing npx → skip with note.
#
# Lints TRACKED markdown only (`git ls-files`), not everything on disk.
#
# The mirror in .claude/project-config.example.json has used this form since
# 8822d05 (#1065); this script never adopted it, though the header above
# requires the two to stay in sync. Copied from the mirror verbatim.
#
# The previous `'**/*.md'` glob walked the whole working tree minus three
# excluded dirs, which meant:
#   - untracked scratch (scratchpad/, .apexyard/briefs/) blocked every push,
#     on files that will never be committed;
#   - agent worktrees under .claude/worktrees/ were linted too, re-linting the
#     same content once per live worktree.
# On this repo that was ~6900 files against 404 tracked.
#
# Coverage is unchanged for anything that matters: pre-push runs AFTER commit,
# so every file being pushed is tracked and therefore still linted. A file that
# is not tracked is not being pushed, and CI lints the pushed tree regardless.
# Known limit: `git ls-files` reads the CURRENT checkout's index, so pushing a
# branch you are not on lints the wrong branch's markdown. The old glob had the
# same hole and worse (those files are not on disk either); CI is the backstop.
#
# NUL-delimited (`tr '\n' '\0' | xargs -0`) so a path containing a space or an
# apostrophe cannot be word-split or trip xargs' quote handling. Plain `xargs`
# fails on both.
#
# The empty guard is required because `markdownlint-cli2` with no file
# arguments prints its usage banner and lints nothing — so without the guard an
# empty repo produces a confusing non-zero rather than a clean skip. (It does
# NOT fall back to a default glob: .markdownlint.json is a rules-only format
# and cannot carry `globs`.)
MARKDOWNLINT_CMD="command -v npx >/dev/null 2>&1 || { echo 'INFO: npx not found — markdownlint check skipped. Install Node.js (https://nodejs.org) to enable it locally.'; exit 0; }; md_files=\$(git ls-files '*.md' 2>/dev/null); [ -z \"\$md_files\" ] && { echo 'INFO: no tracked markdown files found — markdownlint check skipped.'; exit 0; }; echo \"\$md_files\" | tr '\\n' '\\0' | xargs -0 npx --yes markdownlint-cli2 2>&1"
run_check "markdownlint" "$MARKDOWNLINT_CMD" || true

# 2. shellcheck — .claude/hooks/*.sh, severity=warning
# Missing shellcheck → skip with note.
SHELLCHECK_CMD="command -v shellcheck >/dev/null 2>&1 || { echo 'INFO: shellcheck not installed — shell-script check skipped. Install with: brew install shellcheck  (macOS) | apt-get install shellcheck  (Debian/Ubuntu) | dnf install shellcheck  (Fedora).'; exit 0; }; find .claude/hooks -maxdepth 1 -name '*.sh' | sort | xargs shellcheck --severity=warning 2>&1"
run_check "shellcheck" "$SHELLCHECK_CMD" || true

# 3. subpack extraction smoke test
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
