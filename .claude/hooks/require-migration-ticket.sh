#!/bin/bash
# PreToolUse hook on Write/Edit/MultiEdit: when the target path looks like a
# database migration file, enforce the migration-ticket-first rule.
#
# Enforces `.claude/rules/workflow-gates.md` gate 4a (migration) —
# "any edit to migration paths requires a labelled migration ticket +
# linked migration AgDR". Backs up the `/migration` skill: skill creates
# the ticket + AgDR; this hook refuses to let writes happen without them.
#
# Three gates in order:
#
#   G1. Active ticket marker exists (same resolution as
#       require-active-ticket.sh — per-project first, then fallback).
#   G2. The referenced tracker issue is OPEN and carries the migration
#       label (default "migration", overridable per project).
#   G3. The issue body references an AgDR at
#       `docs/agdr/AgDR-\d+-.*migration.*\.md`.
#
# If any gate fails, block with a message pointing at `/migration`.
#
# Pass-through (exit 0) paths:
#   - FILE_PATH doesn't match any migration-path pattern
#   - FILE_PATH is under .claude/, docs/, projects/*/docs/, any *.md
#     (meta / docs edits don't need a migration ticket even on paths
#     that look migration-ish)
#   - Any *.example file (migration templates in golden-paths/ etc.)
#
# Path patterns are overridable per project via
# `.claude/project-config.json`:
#
#   {
#     "migration_paths": ["src/db/**", "db/migrations/**"],
#     "migration_label": "database"
#   }
#
# The config is read from `<ops_root>/.claude/project-config.json` if
# present, otherwise defaults below apply.

INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path // empty' 2>/dev/null)

if [ -z "$FILE_PATH" ]; then
  exit 0
fi

# --------- Exempt meta / docs / example files ---------
# These never need a migration ticket regardless of path, so short-circuit
# before doing any network calls.
case "$FILE_PATH" in
  */.claude/*|*/.claude|*/docs/*|*/docs) exit 0 ;;
  *.md|*.example) exit 0 ;;
esac
# Note: `*/projects/*/docs/*` is subsumed by `*/docs/*` above (shell case `*`
# crosses `/`), so no separate arm is needed.

# --------- Discover ops root ---------
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
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

# --------- Load project-config overrides ---------
MIGRATION_LABEL="migration"
CUSTOM_PATHS=""
PCONFIG="$MARKER_HOME/.claude/project-config.json"
if [ -f "$PCONFIG" ] && command -v jq >/dev/null 2>&1; then
  label=$(jq -r '.migration_label // empty' "$PCONFIG" 2>/dev/null)
  [ -n "$label" ] && MIGRATION_LABEL="$label"
  CUSTOM_PATHS=$(jq -r '.migration_paths // [] | join("\n")' "$PCONFIG" 2>/dev/null)
fi

# --------- Does this path look like a migration? ---------
#
# Defaults cover the common tool / convention set. Patterns use shell
# glob semantics (`*` crosses `/` inside case). Add to this list sparingly
# — false positives on non-migration files block productive edits.
is_migration_path() {
  local path="$1"

  # Project-configured patterns take precedence if any
  if [ -n "$CUSTOM_PATHS" ]; then
    while IFS= read -r pat; do
      [ -z "$pat" ] && continue
      # SC2254: unquoted expansion is intentional — the project-configured
      # pattern should be interpreted as a glob, not compared literally.
      # shellcheck disable=SC2254
      case "$path" in
        $pat) return 0 ;;
      esac
    done <<< "$CUSTOM_PATHS"
    # When custom patterns are set, don't fall through to defaults —
    # projects that override are saying "only these paths"
    return 1
  fi

  # Default patterns.
  # Note: shell case `*` crosses `/`, so `*/migrations/*.sql` already covers
  # nested paths like `*/migrations/<sub>/file.sql` — no separate arm needed.
  case "$path" in
    # SQL migrations anywhere under a `migrations/` directory
    */migrations/*.sql) return 0 ;;
    # `migrate-*.ts` / `.js` / `.py` / `.sql` anywhere
    */migrate-*.ts|*/migrate-*.js|*/migrate-*.py|*/migrate-*.sql) return 0 ;;
    # Prisma
    */prisma/schema.prisma|*/prisma/migrations/*) return 0 ;;
    # TypeORM (typical convention)
    */src/migrations/*.ts|*/src/migrations/*.js) return 0 ;;
    # Alembic
    */alembic/versions/*.py) return 0 ;;
    # Rails / ActiveRecord
    */db/migrate/*.rb) return 0 ;;
    # Generic — any file immediately under a `migrations/` directory, any extension
    */migrations/*) return 0 ;;
  esac
  return 1
}

if ! is_migration_path "$FILE_PATH"; then
  # Not a migration file — other hooks handle the standard ticket check.
  exit 0
fi

# --------- Gate 1: active ticket marker ---------
# Reuse the #41 resolution: per-project marker if FILE_PATH is under
# ops_root/workspace/<project>/, otherwise the ops-level fallback.
PROJECT=""
if [ -n "$OPS_ROOT" ]; then
  case "$FILE_PATH" in
    "$OPS_ROOT"/workspace/*)
      tail="${FILE_PATH#$OPS_ROOT/workspace/}"
      PROJECT="${tail%%/*}"
      ;;
  esac
fi

MARKER=""
if [ -n "$PROJECT" ] && [ -f "$MARKER_HOME/.claude/session/tickets/$PROJECT" ]; then
  MARKER="$MARKER_HOME/.claude/session/tickets/$PROJECT"
elif [ -f "$MARKER_HOME/.claude/session/current-ticket" ]; then
  MARKER="$MARKER_HOME/.claude/session/current-ticket"
fi

if [ -z "$MARKER" ]; then
  cat >&2 <<MSG
BLOCKED: No active ticket set — and this file looks like a database migration.

Migrations need a dedicated labelled ticket + AgDR, not just any ticket.
Run /migration to create both in one guided flow:

  /migration${PROJECT:+ $PROJECT}

Then /start-ticket <owner/repo>#<number> to activate the new ticket for
this session, and retry the edit.

Path matched migration pattern: $FILE_PATH
MSG
  exit 2
fi

# --------- Parse marker for repo + issue number ---------
TICKET_REPO=$(grep -E '^repo=' "$MARKER" | head -1 | cut -d= -f2-)
TICKET_NUM=$(grep -E '^number=' "$MARKER" | head -1 | cut -d= -f2-)

if [ -z "$TICKET_REPO" ] || [ -z "$TICKET_NUM" ]; then
  cat >&2 <<MSG
BLOCKED: Active ticket marker at $MARKER is missing \`repo=\` or
\`number=\` — can't verify migration discipline without those fields.

Re-run /start-ticket to rewrite the marker cleanly, or /migration to
create a fresh migration ticket.
MSG
  exit 2
fi

# --------- Gate 2: issue is open + has migration label ---------
ISSUE_JSON=$(gh issue view "$TICKET_NUM" --repo "$TICKET_REPO" --json state,labels,body 2>/dev/null)
if [ -z "$ISSUE_JSON" ]; then
  cat >&2 <<MSG
BLOCKED: Could not fetch ${TICKET_REPO}#${TICKET_NUM} from GitHub.
Network / auth problem? Or the issue doesn't exist?

Migration files can't be edited without a verifiable migration ticket.
Check your gh auth status, or run /migration to create a new ticket.
MSG
  exit 2
fi

STATE=$(echo "$ISSUE_JSON" | jq -r .state)
HAS_LABEL=$(echo "$ISSUE_JSON" | jq -r --arg L "$MIGRATION_LABEL" '.labels | map(.name) | index($L) != null')
BODY=$(echo "$ISSUE_JSON" | jq -r .body)

if [ "$STATE" != "OPEN" ]; then
  cat >&2 <<MSG
BLOCKED: Active ticket ${TICKET_REPO}#${TICKET_NUM} is $STATE, not OPEN.
Migration files require an OPEN labelled ticket. Run /migration to create
a fresh one, or /start-ticket on a different OPEN migration ticket.
MSG
  exit 2
fi

if [ "$HAS_LABEL" != "true" ]; then
  cat >&2 <<MSG
BLOCKED: Active ticket ${TICKET_REPO}#${TICKET_NUM} does not have the
\`$MIGRATION_LABEL\` label.

Migrations need a dedicated labelled ticket — the label is the signal
that a reviewer should scrutinise rollback plan, downtime, and
cross-service impact before approval.

Two options:
  1. Add the label to the existing ticket if it genuinely is a migration:
       gh issue edit $TICKET_NUM --repo $TICKET_REPO --add-label "$MIGRATION_LABEL"
     Then edit the body to include the migration-shape fields and link an
     AgDR (see /migration output for the body template).
  2. Create a fresh migration ticket + AgDR:
       /migration${PROJECT:+ $PROJECT}
     Then /start-ticket the new ticket and retry.
MSG
  exit 2
fi

# --------- Gate 3: body references a migration AgDR ---------
if ! echo "$BODY" | grep -qE 'docs/agdr/AgDR-[0-9]+-[^[:space:]]*migration[^[:space:]]*\.md'; then
  cat >&2 <<MSG
BLOCKED: Active ticket ${TICKET_REPO}#${TICKET_NUM} has the
\`$MIGRATION_LABEL\` label but its body does not reference a migration
AgDR matching \`docs/agdr/AgDR-\\d+-.*migration.*\\.md\`.

A migration-class change needs a paired Agent Decision Record capturing
rollback plan, downtime, cross-service consumers, and observability.

Create one with /migration, or if the AgDR already exists, edit the
ticket body to include a reference to it:

  gh issue edit $TICKET_NUM --repo $TICKET_REPO --body-file <path>

The regex the hook checks is permissive — any occurrence of the AgDR
relative path in the body satisfies gate 3.
MSG
  exit 2
fi

# All gates passed — allow the edit.
exit 0
