#!/bin/bash
# Non-blocking advisory hook: detects role-trigger conditions per
# .claude/rules/role-triggers.md and emits a system-reminder-style banner
# naming the role + the file the agent should read before continuing.
#
# This hook converts the prose-only role-trigger rule into mechanical
# enforcement — same shape as check-upstream-drift.sh (advisory banner,
# exit 0 always). It does NOT block the underlying tool call.
#
# Triggers covered in v1 (acceptance criteria for me2resh/apexyard#206):
#
#   1. Label-based (Bash → `gh issue edit ... --add-label qa`)
#        → QA Engineer
#   2. Diff/path-based (Edit/Write/MultiEdit on auth / crypto / secrets /
#      .env* paths)
#        → Security Auditor
#   3. Prompted (UserPromptSubmit "act as the X" / "as the X" /
#      "put on your X hat")
#        → matching role
#
# Additional path-based triggers wired up because they fall out of the
# same plumbing for free:
#
#   - .github/workflows/**, golden-paths/pipelines/** → Platform Engineer
#   - docs/agdr/**                                    → Tech Lead
#
# The banner is written to stderr; Claude Code surfaces hook stderr to
# the assistant as a system-reminder-style note. For UserPromptSubmit,
# both stdout and stderr are surfaced; we use stderr for consistency
# with the other advisory hooks.
#
# Exit 0 in every path. The hook is purely advisory.

set -u

INPUT=$(cat)

HOOK_EVENT=$(printf '%s' "$INPUT" | jq -r '.hook_event_name // empty' 2>/dev/null)
TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)

# ---------------------------------------------------------------------------
# Resolve REPO_ROOT once — needed by lookup_role_class for the role-file
# read. Set early so it's available to all helpers below.
# ---------------------------------------------------------------------------
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)

# ---------------------------------------------------------------------------
# Look up the `**Class**:` value from a role file's `## Activation mode`
# section. Returns one of:
#   - isolated-work-class
#   - in-flow-class
#   - in-flow-class (fallback when the file is missing, the section is
#     absent, or the Class line can't be parsed — conservative fail-open
#     so a malformed role file doesn't break trigger detection)
#
# Per AgDR-0050 § Axis 6's HYBRID integration: isolated-work-class roles
# spawn a sub-agent; in-flow-class roles adopt the persona in-thread.
# ---------------------------------------------------------------------------
lookup_role_class() {
  local rel="$1"
  local path
  if [ -n "$REPO_ROOT" ]; then
    path="$REPO_ROOT/$rel"
  else
    path="$rel"
  fi
  [ -f "$path" ] || { echo "in-flow-class"; return; }

  local class
  class=$(awk '
    /^## Activation mode/ { in_section = 1; next }
    in_section && /^\*\*Class\*\*:/ {
      sub("^\\*\\*Class\\*\\*:[[:space:]]*", "")
      print
      exit
    }
  ' "$path")

  case "$class" in
    isolated-work-class|in-flow-class) echo "$class" ;;
    *) echo "in-flow-class" ;;
  esac
}

# ---------------------------------------------------------------------------
# Map a role-file path to the matching sub-agent slug (the value to pass
# as `subagent_type` when spawning via the Agent tool).
#
# 1:1 by default — `roles/<dept>/<slug>.md` → `.claude/agents/<slug>.md`.
# Exception: the Hatim→Hakim consolidation (#360) means
# `roles/security/security-auditor.md` maps to the `security-reviewer`
# agent file (the consolidation preserved the filename so `/security-review`
# and `auto-code-review.sh` keep working). See AgDR-0050 § Axis 2 line 49.
# ---------------------------------------------------------------------------
agent_slug_for() {
  local file="$1"
  local stem
  stem=$(basename "$file" .md)
  case "$stem" in
    security-auditor) echo "security-reviewer" ;;
    *) echo "$stem" ;;
  esac
}

# ---------------------------------------------------------------------------
# Helper: emit one class-aware banner line. Multiple triggers in a single
# call can fire multiple banners.
#
# Per AgDR-0050 § Axis 6, the banner shape depends on the role's
# Activation Class:
#
#   isolated-work-class → instructs the agent to SPAWN the sub-agent via
#     the Agent tool with `subagent_type: <slug>`. Used for roles whose
#     work benefits from isolated context + tool restriction (Head-of-X,
#     Tech Lead, QA, SRE, Security Auditor, Pen Tester, Data Analyst,
#     etc.).
#
#   in-flow-class → instructs the agent to ADOPT the persona in-thread.
#     Used for roles that work tightly alongside the main thread
#     (Backend / Frontend / Platform Engineer, Product Manager, UI / UX
#     Designer, Data Engineer).
#
# Args:
#   $1 — role display name (e.g. "Security Auditor")
#   $2 — role file path relative to repo root (e.g. roles/security/security-auditor.md)
#   $3 — reason text (e.g. "PR diff touches **/auth/**")
# ---------------------------------------------------------------------------
emit_banner() {
  local role="$1" file="$2" reason="$3"
  local class agent_slug
  class=$(lookup_role_class "$file")
  agent_slug=$(agent_slug_for "$file")

  if [ "$class" = "isolated-work-class" ]; then
    printf 'ROLE TRIGGER: %s activates per .claude/rules/role-triggers.md (%s). Isolated-work-class — SPAWN the sub-agent via the Agent tool with subagent_type: %s. Canonical role at %s, agent wrapper at .claude/agents/%s.md. Per AgDR-0050 § Axis 6.\n' \
      "$role" "$reason" "$agent_slug" "$file" "$agent_slug" >&2
  else
    printf 'ROLE TRIGGER: %s activates per .claude/rules/role-triggers.md (%s). In-flow-class — adopt the persona IN-THREAD. Read %s before continuing. Per AgDR-0050 § Axis 6.\n' \
      "$role" "$reason" "$file" >&2
  fi
}

# ---------------------------------------------------------------------------
# Path-based detection (diff-driven triggers).
#
# Given a file path, emit banners for every role whose trigger patterns
# match. Pattern matching uses shell case globs (`*` crosses `/`), which
# is the same convention used by require-active-ticket.sh and the
# migration-paths config.
#
# Patterns are kept narrow on purpose — over-triggering is acceptable
# (security auditor can no-op cheaply) but under-triggering defeats the
# whole point of mechanical enforcement.
# ---------------------------------------------------------------------------
detect_path_triggers() {
  local path="$1"
  [ -z "$path" ] && return 0

  # Normalise: drop a leading ./ and any leading absolute prefix when it
  # resolves under the current REPO_ROOT.
  local rel="$path"
  case "$rel" in
    ./*) rel="${rel#./}" ;;
  esac
  local repo_root
  repo_root=$(git rev-parse --show-toplevel 2>/dev/null || true)
  if [ -n "$repo_root" ]; then
    case "$rel" in
      "$repo_root"/*) rel="${rel#$repo_root/}" ;;
    esac
  fi

  # Security Auditor — auth / crypto / secrets / .env*
  # Patterns anchored to path boundaries to avoid matching e.g. "author.tsx" or "myauth".
  case "$rel" in
    auth|auth/*|*/auth|*/auth/*|\
    crypto|crypto/*|*/crypto|*/crypto/*|\
    secrets|secrets/*|*/secrets|*/secrets/*|\
    .env|.env.*|*/.env|*/.env.*)
      emit_banner \
        "Security Auditor" \
        "roles/security/security-auditor.md" \
        "edit touches security-sensitive path ($rel)"
      ;;
  esac

  # Platform Engineer — CI/CD pipelines + golden-path templates
  case "$rel" in
    .github/workflows/*|*/.github/workflows/*|\
    golden-paths/pipelines/*|*/golden-paths/pipelines/*)
      emit_banner \
        "Platform Engineer" \
        "roles/engineering/platform-engineer.md" \
        "edit touches CI/CD pipeline ($rel)"
      ;;
  esac

  # Tech Lead — architecture decisions
  case "$rel" in
    docs/agdr/*|*/docs/agdr/*)
      emit_banner \
        "Tech Lead" \
        "roles/engineering/tech-lead.md" \
        "edit touches docs/agdr/ (architecture decision)"
      ;;
  esac

  # Solution Architect — design artifacts (technical design / migration AgDR /
  # feature spec / PRD). Reviews the design before Build. Patterns mirror the
  # require-architecture-review.sh DESIGN_GLOBS (kept narrow on purpose — the
  # reviewer no-ops cheaply on a false positive). The migration-AgDR case
  # below is intentionally additive to the Tech Lead docs/agdr/ trigger above:
  # a migration AgDR fires BOTH (Hisham authors, Tariq reviews).
  case "$rel" in
    *technical-design*.md|*tech-design*.md|\
    designs/*|*/designs/*|\
    prds/*|*/prds/*|*prd*.md|\
    *feature-spec*.md)
      emit_banner \
        "Solution Architect" \
        "roles/architecture/solution-architect.md" \
        "edit touches a design artifact (technical design / feature spec)"
      ;;
  esac
  case "$rel" in
    docs/agdr/*migration*.md|*/docs/agdr/*migration*.md)
      emit_banner \
        "Solution Architect" \
        "roles/architecture/solution-architect.md" \
        "edit touches a migration AgDR (design to review before Build)"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Label-based detection (gh-issue-edit triggers).
#
# Parses a Bash command for `gh issue edit ... --add-label <label>`
# and fires the role attached to that label. The label arg can take
# `--add-label foo` or `--add-label foo,bar` (comma list).
# ---------------------------------------------------------------------------
detect_label_triggers() {
  local cmd="$1"
  [ -z "$cmd" ] && return 0

  # Only inspect `gh issue edit` shapes — keep the matcher narrow so
  # `gh issue create --label qa` (a NEW ticket with the qa label) doesn't
  # spuriously fire the QA Engineer trigger. (Trigger semantics from the
  # role-triggers table: "ticket moved to qa label", i.e. transition, not
  # initial create.)
  if ! printf '%s' "$cmd" | grep -qE '\bgh[[:space:]]+issue[[:space:]]+edit\b'; then
    return 0
  fi

  # Extract every `--add-label <value>` argument and split on commas.
  # macOS-compatible: -oE for grep then sed for splitting.
  local labels
  labels=$(printf '%s' "$cmd" \
    | grep -oE -- '--add-label[[:space:]=]+[^[:space:]]+' \
    | sed -E 's/^--add-label[[:space:]=]+//; s/,/ /g' \
    | tr '\n' ' ')
  [ -z "$labels" ] && return 0

  for label in $labels; do
    case "$label" in
      qa|QA)
        emit_banner \
          "QA Engineer" \
          "roles/engineering/qa-engineer.md" \
          "ticket moved to 'qa' label"
        ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# Prompted-activation detection (UserPromptSubmit).
#
# Scans the user's prompt for:
#   - "act as the X"
#   - "as the X"
#   - "put on your X hat"
# where X matches a known role name. Match is case-insensitive.
#
# The known-roles table is hard-coded here (not config-driven) — the role
# files themselves are upstream framework, and the table mirrors the
# Activation Table in .claude/rules/role-triggers.md.
# ---------------------------------------------------------------------------
ROLES_TABLE='
qa engineer|roles/engineering/qa-engineer.md
qa|roles/engineering/qa-engineer.md
security auditor|roles/security/security-auditor.md
penetration tester|roles/security/penetration-tester.md
pen tester|roles/security/penetration-tester.md
head of security|roles/security/head-of-security.md
tech lead|roles/engineering/tech-lead.md
solution architect|roles/architecture/solution-architect.md
head of engineering|roles/engineering/head-of-engineering.md
backend engineer|roles/engineering/backend-engineer.md
frontend engineer|roles/engineering/frontend-engineer.md
platform engineer|roles/engineering/platform-engineer.md
sre|roles/engineering/sre.md
head of product|roles/product/head-of-product.md
product manager|roles/product/product-manager.md
product analyst|roles/product/product-analyst.md
head of design|roles/design/head-of-design.md
ui designer|roles/design/ui-designer.md
ux designer|roles/design/ux-designer.md
head of data|roles/data/head-of-data.md
data analyst|roles/data/data-analyst.md
data engineer|roles/data/data-engineer.md
'

detect_prompt_triggers() {
  local prompt="$1"
  [ -z "$prompt" ] && return 0

  # Normalise: lowercase, replace common punctuation with spaces, then
  # collapse whitespace. Done once up-front so each regex doesn't have
  # to redo it. Punctuation→space lets "as the Security Auditor, please"
  # match the trailing-space anchor used by the role patterns.
  local norm
  norm=$(printf '%s' "$prompt" \
    | tr '[:upper:]' '[:lower:]' \
    | tr ',.;:!?()[]{}"'"'" ' ' \
    | tr -s '[:space:]' ' ')

  # Iterate the roles table. The first match wins per role; if the user
  # mentions "QA Engineer" we'll fire on the longer phrase before the
  # bare "qa" form catches it.
  local fired=""
  while IFS='|' read -r pattern file; do
    [ -z "$pattern" ] && continue

    # Skip roles we've already fired for in this prompt (de-dupe).
    case "$fired" in *"|$file|"*) continue ;; esac

    # Three phrase shapes the activation rule documents:
    #   "act as the <role>"
    #   "as the <role>"          (handles "review this as the security auditor")
    #   "put on your <role> hat"
    # All matched at word boundaries via spaces.
    local hit=0
    if printf ' %s ' "$norm" | grep -qE "[[:space:]]act as (the|a|an) ${pattern}[[:space:]]"; then
      hit=1
    elif printf ' %s ' "$norm" | grep -qE "[[:space:]]as (the|a|an) ${pattern}[[:space:]]"; then
      hit=1
    elif printf ' %s ' "$norm" | grep -qE "[[:space:]]put on (your|the) ${pattern} hat[[:space:]]"; then
      hit=1
    fi

    if [ "$hit" = "1" ]; then
      # Capitalise the pattern for the display name (simple title-case).
      local display
      display=$(printf '%s' "$pattern" | awk '{for(i=1;i<=NF;i++)$i=toupper(substr($i,1,1)) substr($i,2);print}')
      emit_banner \
        "$display" \
        "$file" \
        "prompted activation ('$pattern')"
      fired="${fired}|$file|"
    fi
  done <<EOF
$ROLES_TABLE
EOF
}

# ---------------------------------------------------------------------------
# Dispatch on hook event.
# ---------------------------------------------------------------------------
case "$HOOK_EVENT" in
  UserPromptSubmit)
    prompt=$(printf '%s' "$INPUT" | jq -r '.prompt // empty' 2>/dev/null)
    detect_prompt_triggers "$prompt"
    ;;
  PreToolUse|PostToolUse|"")
    # Hook event name was missing on some older harness versions — fall
    # back to tool-name dispatch.
    case "$TOOL_NAME" in
      Edit|Write|MultiEdit)
        FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path // empty' 2>/dev/null)
        detect_path_triggers "$FILE_PATH"
        ;;
      Bash)
        COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
        detect_label_triggers "$COMMAND"
        ;;
    esac
    ;;
esac

exit 0
