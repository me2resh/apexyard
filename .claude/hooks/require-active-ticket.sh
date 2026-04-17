#!/bin/bash
# Blocks Edit/Write/MultiEdit on code paths when no active ticket is set.
# Enforces the ticket-first rule mechanically instead of relying on prose
# in CLAUDE.md, workflows/sdlc.md, or .claude/rules/workflow-gates.md.
#
# Active ticket is declared by running the /start-ticket skill, which writes
# .claude/session/current-ticket (key=value lines: repo, number, title, url,
# suggested_branch, started_at).
#
# Exempt paths (meta / framework / docs — no ticket required):
#   - anything under .claude/
#   - any *.md file (READMEs, CLAUDE.md, rule docs, AgDRs)
#   - anything under docs/
#   - anything under projects/*/docs/ (per-project apexstack docs)
#
# Everything else (source code, config, infra) requires a ticket marker.

INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path // empty' 2>/dev/null)

if [ -z "$FILE_PATH" ]; then
  exit 0
fi

# Normalise to repo-relative path when possible
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
REL_PATH="$FILE_PATH"
if [ -n "$REPO_ROOT" ]; then
  case "$FILE_PATH" in
    "$REPO_ROOT"/*) REL_PATH="${FILE_PATH#$REPO_ROOT/}" ;;
  esac
fi

# Exempt paths.
#
# Each path-prefix exemption is matched in both REL_PATH (repo-relative)
# and absolute (*/path/*) forms. Absolute-path fallthrough happens when
# FILE_PATH points outside REPO_ROOT (e.g. agent worktrees whose
# git-toplevel differs from the outer apexstack tree); in that case the
# strip on lines 29-31 is a no-op and REL_PATH stays absolute. The
# existing `*.md` pattern already crosses `/`, so absolute-match via a
# `*/…` prefix is a known-good shape — #56 extends the same trick to the
# path-prefix exemptions.
case "$REL_PATH" in
  .claude/*|.claude|*/.claude/*|*/.claude) exit 0 ;;
  docs/*|docs|*/docs/*|*/docs) exit 0 ;;
  TODO.md|README.md|MEMORY.md|CLAUDE.md) exit 0 ;;
esac
# Note: `projects/*/docs/*` is subsumed by `*/docs/*` above (shell case `*`
# crosses `/`), so no separate arm needed. Per-project apexstack docs are
# matched by the generic docs-in-any-subtree pattern.
case "$REL_PATH" in
  *.md) exit 0 ;;
esac

MARKER="${REPO_ROOT:-.}/.claude/session/current-ticket"
if [ -f "$MARKER" ]; then
  exit 0
fi

cat >&2 <<'MSG'
BLOCKED: No active ticket set for this session.

ApexStack requires a ticket BEFORE any code changes (workflow-gates rule #3,
pre-build gate, "one ticket at a time"). To proceed:

  1. Create or find the ticket (GitHub Issue in the project's own repo):
       gh issue create --repo <owner/repo> --title "..."
  2. Declare it for this session — run the /start-ticket skill with the
     issue number (or pass owner/repo#number to pin it)
  3. Retry the edit

Exempt paths (no ticket required): .claude/, docs/, projects/*/docs/, *.md
MSG
exit 2
