#!/bin/bash
# Blocks Edit/Write/MultiEdit on code paths when no active ticket is set.
# Enforces the ticket-first rule mechanically instead of relying on prose
# in CLAUDE.md, workflows/sdlc.md, or .claude/rules/workflow-gates.md.
#
# Active tickets are declared by the /start-ticket skill. The marker
# layout is two-tier (apexyard#41):
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
# Ops root is the apexyard fork root (has both onboarding.yaml and
# apexyard.projects.yaml at the top level). It's discovered by walking
# up from the nearest git toplevel; this handles the case where an agent
# worktree or a cloned managed project lives inside the ops tree and
# would otherwise report a nested git root.
#
# Exempt paths (meta / framework / docs — no ticket required):
#   - anything under .claude/
#   - any *.md file (READMEs, CLAUDE.md, rule docs, AgDRs)
#   - anything under docs/
#   - anything under projects/*/docs/ (per-project apexyard docs)
#
# Everything else (source code, config, infra) requires a ticket marker.

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path // empty' 2>/dev/null)

# Bash-tool path: extract the target file from the command if it appears
# to be a write. Closes the bypass surface where Bash file-writes
# (`echo > file`, `tee file`, `sed -i ... file`, `python -c
# 'pathlib.Path(...).write_text(...)'`, etc.) routed around the
# Edit/Write/MultiEdit-only gate. See me2resh/apexyard#151 + the
# _lib-detect-bash-write helper for the matcher details and design
# choice (false-negatives preferred over false-positives).
if [ "$TOOL_NAME" = "Bash" ]; then
  COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
  if [ -z "$COMMAND" ]; then
    exit 0
  fi

  # Source the bash-write detector. Library lives next to this hook.
  HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
  if [ ! -f "$HOOK_DIR/_lib-detect-bash-write.sh" ]; then
    # Library missing — fall back to non-Bash behavior to avoid bricking
    # the hook entirely.
    exit 0
  fi
  # shellcheck source=/dev/null
  . "$HOOK_DIR/_lib-detect-bash-write.sh"

  if ! bash_command_appears_to_write "$COMMAND"; then
    # Read-only command — no gate.
    exit 0
  fi

  # Try to extract a target path so we can apply the same path-based
  # exemptions (.claude/, docs/, *.md). If extraction fails, FILE_PATH
  # stays empty and the gate is applied categorically.
  FILE_PATH=$(bash_extract_write_target "$COMMAND")
fi

if [ -z "$FILE_PATH" ] && [ "$TOOL_NAME" != "Bash" ]; then
  exit 0
fi

# Normalise to repo-relative path when possible
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
REL_PATH="$FILE_PATH"
if [ -n "$REPO_ROOT" ] && [ -n "$FILE_PATH" ]; then
  case "$FILE_PATH" in
    "$REPO_ROOT"/*) REL_PATH="${FILE_PATH#$REPO_ROOT/}" ;;
  esac
fi

# Exempt paths.
#
# Each path-prefix exemption is matched in both REL_PATH (repo-relative)
# and absolute (*/path/*) forms. Absolute-path fallthrough happens when
# FILE_PATH points outside REPO_ROOT (e.g. agent worktrees whose
# git-toplevel differs from the outer apexyard tree); in that case the
# strip on lines 43-45 is a no-op and REL_PATH stays absolute. The
# existing `*.md` pattern already crosses `/`, so absolute-match via a
# `*/…` prefix is a known-good shape — #56 extends the same trick to the
# path-prefix exemptions.
#
# Skipped entirely when FILE_PATH is empty (Bash command writes to an
# unextractable target — e.g. `python -c '...write...'`). Those fall
# through to the ticket gate; the bootstrap-skill exemption below covers
# the legitimate use case (/setup writing to fork-root files via Bash).
if [ -n "$REL_PATH" ]; then
  case "$REL_PATH" in
    .claude/*|.claude|*/.claude/*|*/.claude) exit 0 ;;
    docs/*|docs|*/docs/*|*/docs) exit 0 ;;
    TODO.md|README.md|MEMORY.md|CLAUDE.md) exit 0 ;;
  esac
  # Note: `projects/*/docs/*` is subsumed by `*/docs/*` above (shell case `*`
  # crosses `/`), so no separate arm needed. Per-project apexyard docs are
  # matched by the generic docs-in-any-subtree pattern.
  case "$REL_PATH" in
    *.md) exit 0 ;;
  esac
fi

# Discover the ops root. Walk up from REPO_ROOT looking for either the
# v2 `.apexyard-fork` marker (split-portfolio v2 layout) OR the legacy
# v1 anchor (onboarding.yaml + apexyard.projects.yaml). Stop at /. If
# not found, OPS_ROOT stays empty and we treat the REPO_ROOT itself as
# the marker home (pre-#41 behaviour).
HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
OPS_ROOT=""
if [ -n "$REPO_ROOT" ]; then
  if [ -f "$HOOK_DIR/_lib-ops-root.sh" ]; then
    # shellcheck source=/dev/null
    . "$HOOK_DIR/_lib-ops-root.sh"
    OPS_ROOT=$(resolve_ops_root "$REPO_ROOT")
  else
    r="$REPO_ROOT"
    while [ -n "$r" ] && [ "$r" != "/" ]; do
      if [ -f "$r/.apexyard-fork" ]; then
        OPS_ROOT="$r"
        break
      fi
      if [ -f "$r/onboarding.yaml" ] && [ -f "$r/apexyard.projects.yaml" ]; then
        OPS_ROOT="$r"
        break
      fi
      r=$(dirname "$r")
    done
  fi
fi

MARKER_HOME="${OPS_ROOT:-$REPO_ROOT}"
MARKER_HOME="${MARKER_HOME:-.}"

# Resolve the workspace dir for the per-project marker resolution below.
# Defaults to $OPS_ROOT/workspace; split-portfolio v2 adopters override
# via portfolio.workspace_dir to point at their private sibling repo.
WORKSPACE_DIR="$OPS_ROOT/workspace"
if [ -n "$OPS_ROOT" ] && [ -f "$HOOK_DIR/_lib-portfolio-paths.sh" ] && [ -f "$HOOK_DIR/_lib-read-config.sh" ]; then
  # shellcheck source=/dev/null
  . "$HOOK_DIR/_lib-read-config.sh"
  # shellcheck source=/dev/null
  . "$HOOK_DIR/_lib-portfolio-paths.sh"
  resolved_ws=$(portfolio_workspace_dir 2>/dev/null)
  if [ -n "$resolved_ws" ]; then
    WORKSPACE_DIR="$resolved_ws"
  fi
fi

# Bootstrap-skill exemption (apexyard#150): skills like /setup,
# /handover, /update, /split-portfolio run BEFORE any ticket can exist
# (no portfolio configured yet, no projects registered). They write a
# marker at .claude/session/active-bootstrap with the skill name on
# entry; this hook reads the marker, looks up the configured
# bootstrap_skills list, and exits 0 if the active skill is on the list.
#
# The marker is cleared at SessionStart by clear-bootstrap-marker.sh so
# a stale marker from an interrupted session can't carry over.
BOOTSTRAP_MARKER="$MARKER_HOME/.claude/session/active-bootstrap"
if [ -f "$BOOTSTRAP_MARKER" ]; then
  active_bootstrap=$(tr -d '[:space:]' < "$BOOTSTRAP_MARKER" 2>/dev/null)
  if [ -n "$active_bootstrap" ]; then
    # Source the config reader and look up bootstrap_skills.
    if [ -f "$MARKER_HOME/.claude/hooks/_lib-read-config.sh" ]; then
      # shellcheck source=/dev/null
      . "$MARKER_HOME/.claude/hooks/_lib-read-config.sh"
      if command -v config_get >/dev/null 2>&1; then
        # `config_get '.ticket.bootstrap_skills[]'` outputs one skill per
        # line. Use grep -wF for whole-word, fixed-string match.
        if config_get '.ticket.bootstrap_skills[]' 2>/dev/null | grep -qwF "$active_bootstrap"; then
          exit 0
        fi
      fi
    fi
  fi
fi

# Per-project resolution (apexyard#41): if FILE_PATH points under the
# resolved workspace dir, we look for a per-project marker at
# .claude/session/tickets/<project>. This keeps per-project session state
# keyed by the managed-project name and localised in the ops fork
# (gitignored), instead of the pre-#41 scheme that relied on a
# .claude/session/ inside each managed-project clone.
#
# Split-portfolio v2 (#242): WORKSPACE_DIR may resolve to a sibling
# private repo path (e.g. ../<fork>-portfolio/workspace) instead of the
# default $OPS_ROOT/workspace; both shapes are handled here.
PROJECT=""
if [ -n "$WORKSPACE_DIR" ]; then
  case "$FILE_PATH" in
    "$WORKSPACE_DIR"/*)
      tail="${FILE_PATH#$WORKSPACE_DIR/}"
      PROJECT="${tail%%/*}"
      ;;
  esac
fi
# Belt-and-suspenders: also recognise the literal $OPS_ROOT/workspace/
# shape, in case workspace_dir is overridden but a tool produced an
# absolute path under the in-fork legacy location.
if [ -z "$PROJECT" ] && [ -n "$OPS_ROOT" ]; then
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

ApexYard requires a ticket BEFORE any code changes (workflow-gates rule #3,
pre-build gate, "one ticket at a time").

To unblock:

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
