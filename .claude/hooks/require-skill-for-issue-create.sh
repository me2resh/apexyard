#!/bin/bash
# require-skill-for-issue-create.sh — block raw ticket-creation CLIs unless
# invoked from inside one of the structured ticket skills (/task, /feature,
# /bug, /spike, /migration, /investigation, /idea).
#
# Wired as PreToolUse:Bash. Reads stdin as the Claude Code hook JSON payload.
# Tracker-agnostic by construction: only the matcher list knows about specific
# CLIs (`gh issue create`, `gh api repos/.../issues`, `linear issue create`,
# `jira issue create`, `asana task create`, etc.), and the list is sourced
# from `.claude/project-config.defaults.json` → `ticket.create_command_patterns`
# (adopters extend via `.claude/project-config.json` shallow-merge).
#
# Resolution:
#   1. If the command does not match any configured pattern → exit 0 (no-op).
#   2. If the bootstrap-skill marker (.claude/session/active-bootstrap) is
#      present AND the active skill is on the bootstrap_skills list → exit 0.
#      (Keeps `/handover` and friends able to file their bookkeeping tickets.)
#   3. If the ticket-skill marker (.claude/session/active-issue-skill) is
#      present → exit 0 (a structured skill is in flight).
#   4. If APEXYARD_ALLOW_RAW_TICKET_CREATE=1 → exit 0 with a stderr warning.
#   5. Otherwise → BLOCK with a clear message naming the 7 skill alternatives.
#
# See AgDR-0030 and me2resh/apexyard#268.

set -u

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
if [ "$TOOL_NAME" != "Bash" ]; then
  exit 0
fi

COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
if [ -z "$COMMAND" ]; then
  exit 0
fi

# Discover ops root (mirror of clear-bootstrap-marker.sh / require-active-ticket.sh).
HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
OPS_ROOT=""
if [ -f "$HOOK_DIR/_lib-ops-root.sh" ]; then
  # shellcheck source=/dev/null
  . "$HOOK_DIR/_lib-ops-root.sh"
  OPS_ROOT=$(resolve_ops_root "${REPO_ROOT:-$PWD}")
else
  cur="${REPO_ROOT:-$PWD}"
  while [ -n "$cur" ] && [ "$cur" != "/" ]; do
    if [ -f "$cur/.apexyard-fork" ]; then OPS_ROOT="$cur"; break; fi
    if [ -f "$cur/onboarding.yaml" ] && [ -f "$cur/apexyard.projects.yaml" ]; then
      OPS_ROOT="$cur"; break
    fi
    cur=$(dirname "$cur")
  done
fi
MARKER_HOME="${OPS_ROOT:-${REPO_ROOT:-.}}"

# Read the configured matcher list. Patterns are substrings; if no patterns
# are configured (no defaults file, jq missing), the hook is a no-op.
PATTERNS=""
if [ -f "$HOOK_DIR/_lib-read-config.sh" ]; then
  # shellcheck source=/dev/null
  . "$HOOK_DIR/_lib-read-config.sh"
  if command -v config_get >/dev/null 2>&1; then
    PATTERNS=$(config_get '.ticket.create_command_patterns[]' 2>/dev/null)
  fi
fi
if [ -z "$PATTERNS" ]; then
  exit 0
fi

# Normalise the command for matching: collapse whitespace.
NORM_CMD=$(echo "$COMMAND" | tr -s '[:space:]' ' ')

# Match patterns at a COMMAND BOUNDARY only — at the start of the line,
# or immediately after a shell command separator (`;`, `&&`, `||`, `|`).
# Substring-anywhere matching false-positives on commit messages or
# scripts that mention the pattern in prose, e.g.
# `git commit -m "...mentions gh issue create..."`.
MATCHED=""
while IFS= read -r pat; do
  [ -z "$pat" ] && continue
  case "$NORM_CMD" in
    "$pat"*|*"; $pat"*|*"&& $pat"*|*"|| $pat"*|*"| $pat"*)
      MATCHED="$pat"; break ;;
  esac
done <<EOF
$PATTERNS
EOF

if [ -z "$MATCHED" ]; then
  exit 0
fi

# Refinement for the `gh api` family — the configured `gh api repos/` pattern
# is a pure substring prefix, which catches read-only GETs like
# `gh api repos/<owner>/<repo>/contents/README.md` as well as ticket-create
# POSTs. Downgrade the match to a no-op unless the command BOTH targets an
# `/issues` endpoint AND carries a write signal (-X POST / --method POST / a
# `-f` / `-F` / `--field` / `--raw-field` / `--input` flag — gh switches from
# GET to POST when fields are supplied). Other patterns (gh issue create,
# linear issue create, jira issue create, asana task create) keep their pure
# substring-prefix matching. See me2resh/apexyard#382.
case "$MATCHED" in
  "gh api"*)
    is_issues_endpoint=0
    case "$NORM_CMD" in *"/issues"*) is_issues_endpoint=1 ;; esac
    is_write=0
    case "$NORM_CMD" in
      *" -X POST"*|*" -XPOST"*|*" --method POST"*|*" --method=POST"*|\
      *" -f "*|*" -F "*|*" --field "*|*" --raw-field "*|*" --input "*)
        is_write=1 ;;
    esac
    if [ "$is_issues_endpoint" -ne 1 ] || [ "$is_write" -ne 1 ]; then
      exit 0
    fi
    ;;
esac

# Bootstrap-skill exemption — same shape as require-active-ticket.sh.
BOOTSTRAP_MARKER="$MARKER_HOME/.claude/session/active-bootstrap"
if [ -f "$BOOTSTRAP_MARKER" ]; then
  active_bootstrap=$(tr -d '[:space:]' < "$BOOTSTRAP_MARKER" 2>/dev/null)
  if [ -n "$active_bootstrap" ] && command -v config_get >/dev/null 2>&1; then
    if config_get '.ticket.bootstrap_skills[]' 2>/dev/null | grep -qwF "$active_bootstrap"; then
      exit 0
    fi
  fi
fi

# Ticket-skill marker — a structured skill is in flight.
SKILL_MARKER="$MARKER_HOME/.claude/session/active-issue-skill"
if [ -f "$SKILL_MARKER" ]; then
  active_skill=$(tr -d '[:space:]' < "$SKILL_MARKER" 2>/dev/null)
  if [ -n "$active_skill" ]; then
    exit 0
  fi
fi

# Env-var escape hatch.
if [ "${APEXYARD_ALLOW_RAW_TICKET_CREATE:-0}" = "1" ]; then
  echo "WARN: APEXYARD_ALLOW_RAW_TICKET_CREATE=1 — bypassing skill-gated ticket-create hook (matched pattern: '$MATCHED')." >&2
  exit 0
fi

cat >&2 <<MSG
BLOCKED: Raw ticket-create CLI detected (matched pattern: "$MATCHED").

ApexYard requires that every ticket be filed through a structured skill so it
conforms to the skill's contract (driver/scope/AC for /task; user story/AC for
/feature; etc.). Re-run via one of:

  /feature        — user-facing feature (user story + acceptance criteria)
  /bug            — bug report (Given/When/Then + repro + severity)
  /task           — technical task (driver + scope + acceptance criteria)
  /spike          — hypothesis-driven, time-boxed exploration
  /migration      — DB / schema migration ticket + migration AgDR
  /investigation  — sustained root-cause investigation (live-doc workflow)
  /idea           — new product idea (added to the ideas backlog)

If you genuinely need to bypass the gate (recovery scenario, broken skill,
emergency ticket), re-run with the env-var escape hatch:

  APEXYARD_ALLOW_RAW_TICKET_CREATE=1 <your command>

To extend the matcher list for a different tracker (Linear, Jira, Asana,
custom), add patterns under .claude/project-config.json →
ticket.create_command_patterns (shallow-merges with defaults).

See AgDR-0030-skill-gated-ticket-create.md and me2resh/apexyard#268.
MSG
exit 2
