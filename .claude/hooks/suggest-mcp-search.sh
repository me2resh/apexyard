#!/bin/bash
# Advisory hook: reminds the agent to try MCP search tools (search_docs,
# search_code) before falling back to grep+Read for codebase exploration.
#
# Fires on PreToolUse for:
#   - Bash: when the command matches grep/find patterns that target framework
#     or project paths (original behaviour, unchanged).
#   - Read/Glob/Grep: when the target path resolves inside a managed-project
#     workspace clone (workspace/<project>/) — closes the bypass where an
#     agent can sidestep the nudge by using native read tools instead of Bash.
#     (#489)
#
# Non-blocking (exit 0 always).
#
# The MCP vector search returns targeted excerpts from indexed chunks,
# saving ~3-5x tokens compared to reading full files via grep+Read.
#
# IMPORTANT (#469): the advisory is emitted as `hookSpecificOutput.additional
# Context` JSON on STDOUT (exit 0), NOT stderr. Claude Code does not inject
# exit-0 stderr into the model's context, so the old stderr banner was
# invisible to the agent — the exact failure this hook exists to prevent.
# It is also install-gated: it only nudges when the `apexyard-search` MCP
# server is actually configured, so adopters without the premium search
# component fall back to plain grep silently. FREE ADOPTERS SEE NOTHING.
#
# Wired to: PreToolUse → Bash|Read|Glob|Grep (checks paths/commands internally)
# See: me2resh/apexyard#418 (original), #469 (additionalContext + install-gate),
#      #489 (Read/Glob/Grep workspace-path extension)

set -u

INPUT=$(cat)

TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)

# ---------------------------------------------------------------------------
# Branch on tool type. Bash uses the original grep/find command scanner.
# Read/Glob/Grep use a simpler workspace-path check on their input paths.
# Any other tool exits immediately.
# ---------------------------------------------------------------------------

case "$TOOL_NAME" in
  Bash) ;;
  Read|Glob|Grep) ;;
  *) exit 0 ;;
esac

if [ "$TOOL_NAME" = "Bash" ]; then
  # -------------------------------------------------------------------------
  # BASH BRANCH: original behaviour, unchanged.
  # -------------------------------------------------------------------------

  COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
  [ -n "$COMMAND" ] || exit 0

  # --- Detect grep/find patterns that MCP could serve better ---------------

  is_search_command=false

  case "$COMMAND" in
    grep\ -rn*|grep\ -r*|grep\ --include*|grep\ -l*)
      is_search_command=true ;;
    *"| grep"*)
      is_search_command=true ;;
  esac

  if echo "$COMMAND" | grep -qE '^find .+ -name .+\.(md|yaml|yml|ts|tsx|js|py)'; then
    is_search_command=true
  fi

  $is_search_command || exit 0

  # --- Check if the search targets framework or project paths ---------------

  targets_framework=false

  framework_patterns=(
    ".claude/"
    "roles/"
    "workflows/"
    "templates/"
    "docs/agdr"
    "handbooks/"
    "skills/"
    "hooks/"
    "topologies/"
    "golden-paths/"
  )

  for pattern in "${framework_patterns[@]}"; do
    if echo "$COMMAND" | grep -q "$pattern"; then
      targets_framework=true
      break
    fi
  done

  # Also check for workspace/ or projects/ (managed project code)
  if echo "$COMMAND" | grep -qE '(workspace/|projects/)'; then
    targets_framework=true
  fi

  $targets_framework || exit 0

else
  # -------------------------------------------------------------------------
  # READ / GLOB / GREP BRANCH (#489): fire when the target path is inside a
  # managed-project workspace clone (workspace/<project>/).
  #
  # Field layout per Claude Code tool_input schema:
  #   Read  → .tool_input.file_path
  #   Glob  → .tool_input.path  (directory to glob in; pattern in .tool_input.pattern)
  #   Grep  → .tool_input.path  (directory to search in; pattern in .tool_input.pattern)
  # We use file_path // path to cover all three shapes in one jq query.
  # -------------------------------------------------------------------------

  TARGET_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path // empty' 2>/dev/null)
  [ -n "$TARGET_PATH" ] || exit 0

  # Only proceed when the path is inside a workspace clone.
  case "$TARGET_PATH" in
    *workspace/*) ;;
    *) exit 0 ;;
  esac

fi

# --- Install-gate: only nudge if apexyard-search is actually configured -----
# Resolve the ops fork from this hook's own location, and also honour
# $APEXYARD_PORTFOLIO_ROOT (split-portfolio mode keeps .mcp.json beside the
# portfolio). If apexyard-search isn't configured in any candidate .mcp.json,
# stay silent — the adopter doesn't have the premium search component, so the
# nudge would be noise. (#469)

ops_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)"

mcp_has_search=false
for mcp_json in "$ops_root/.mcp.json" "${APEXYARD_PORTFOLIO_ROOT:-}/.mcp.json"; do
  [ -n "$mcp_json" ] && [ -f "$mcp_json" ] || continue
  if grep -q 'apexyard-search' "$mcp_json" 2>/dev/null; then
    mcp_has_search=true
    break
  fi
done

$mcp_has_search || exit 0

# --- Emit advisory as additionalContext on stdout (non-blocking) -----------

ADVISORY="apexyard-search MCP is available — prefer mcp__apexyard-search__search_code (managed-project codebases) / search_docs (framework docs) over grep+Read for this search. Semantic, returns targeted excerpts, ~3-5x fewer tokens. Fall back to grep only if MCP returns nothing. Load via ToolSearch(\"select:mcp__apexyard-search__search_code,mcp__apexyard-search__search_docs\")."

jq -n --arg t "$ADVISORY" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    additionalContext: $t
  }
}'

exit 0
