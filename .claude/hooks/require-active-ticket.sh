#!/bin/bash
# Blocks Edit/Write/MultiEdit on code paths when no active ticket is set.
# Enforces the ticket-first rule mechanically instead of relying on prose
# in CLAUDE.md, workflows/sdlc.md, or .claude/rules/workflow-gates.md.
#
# Active tickets are declared by the /start-ticket skill. The marker
# layout is two-tier (apexstack#41):
#
#   ops_root/.claude/session/tickets/<project>    ← per-project, preferred
#   ops_root/.claude/session/current-ticket       ← ops-repo / fallback
#
# Resolution order for a given FILE_PATH:
#   1. If FILE_PATH is under ops_root/workspace/<project>/, look up
#      ops_root/.claude/session/tickets/<project>. If present → exempt.
#   2. Fall back to ops_root/.claude/session/current-ticket. If present →
#      exempt.
#   3. Otherwise, block with instructions.
#
# Ops root is the apexstack fork root (has both onboarding.yaml and
# apexstack.projects.yaml at the top level). It's discovered by walking
# up from the nearest git toplevel; this handles the case where an agent
# worktree or a cloned managed project lives inside the ops tree and
# would otherwise report a nested git root.
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
# strip on lines 43-45 is a no-op and REL_PATH stays absolute. The
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

# Discover the ops root. Walk up from REPO_ROOT until we find a directory
# with both onboarding.yaml AND apexstack.projects.yaml (a configured ops
# fork). Stop at /. If not found, OPS_ROOT stays empty and we treat the
# REPO_ROOT itself as the marker home (pre-#41 behaviour).
OPS_ROOT=""
if [ -n "$REPO_ROOT" ]; then
  r="$REPO_ROOT"
  while [ -n "$r" ] && [ "$r" != "/" ]; do
    if [ -f "$r/onboarding.yaml" ] && [ -f "$r/apexstack.projects.yaml" ]; then
      OPS_ROOT="$r"
      break
    fi
    r=$(dirname "$r")
  done
fi

MARKER_HOME="${OPS_ROOT:-$REPO_ROOT}"
MARKER_HOME="${MARKER_HOME:-.}"

# Per-project resolution (apexstack#41): if FILE_PATH points under
# <ops_root>/workspace/<project>/, we look for a per-project marker at
# .claude/session/tickets/<project>. This keeps per-project session state
# keyed by the managed-project name and localised in the ops fork
# (gitignored), instead of the pre-#41 scheme that relied on a
# .claude/session/ inside each managed-project clone.
PROJECT=""
if [ -n "$OPS_ROOT" ]; then
  case "$FILE_PATH" in
    "$OPS_ROOT"/workspace/*)
      tail="${FILE_PATH#$OPS_ROOT/workspace/}"
      PROJECT="${tail%%/*}"
      ;;
  esac
fi

PER_PROJECT_MARKER=""
if [ -n "$PROJECT" ]; then
  PER_PROJECT_MARKER="$MARKER_HOME/.claude/session/tickets/$PROJECT"
  if [ -f "$PER_PROJECT_MARKER" ]; then
    exit 0
  fi
fi

# Fallback: the ops-level current-ticket marker. This is the pre-#41
# location and still honoured for ops-repo framework edits, and as a
# safety net for any file we couldn't map to a specific project.
FALLBACK_MARKER="$MARKER_HOME/.claude/session/current-ticket"
if [ -f "$FALLBACK_MARKER" ]; then
  exit 0
fi

# Nothing found — emit a guide that names both possibilities.
cat >&2 <<MSG
BLOCKED: No active ticket set for this session.

ApexStack requires a ticket BEFORE any code changes (workflow-gates rule #3,
pre-build gate, "one ticket at a time"). To proceed:

  1. Create or find the ticket (GitHub Issue in the project's own repo):
       gh issue create --repo <owner/repo> --title "..."
  2. Declare it for this session — run the /start-ticket skill with the
     issue number (or pass owner/repo#number to pin it). The skill writes
     a per-project marker if the ticket's repo matches a registered
     managed project, otherwise falls back to the ops-level marker.
  3. Retry the edit

Markers looked up for this path (in order):
$([ -n "$PER_PROJECT_MARKER" ] && echo "  per-project:  $PER_PROJECT_MARKER")
  ops fallback: $FALLBACK_MARKER

Exempt paths (no ticket required): .claude/, docs/, projects/*/docs/, *.md
MSG
exit 2
