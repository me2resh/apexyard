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
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path // empty' 2>/dev/null)

# Bash-tool path: if the command writes, try to extract the target so we
# can apply the migration-path matcher to it. If extraction fails (e.g.
# `python -c '…write_text("file"…)…'`), FILE_PATH stays empty and the
# hook exits 0 — the migration gate is path-specific, so an
# unextractable target falls outside the gate's scope.
# See me2resh/apexyard#151 + _lib-detect-bash-write.sh for the detector.
if [ "$TOOL_NAME" = "Bash" ]; then
  COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
  [ -z "$COMMAND" ] && exit 0

  HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
  if [ -f "$HOOK_DIR/_lib-detect-bash-write.sh" ]; then
    # shellcheck source=/dev/null
    . "$HOOK_DIR/_lib-detect-bash-write.sh"
    if ! bash_command_appears_to_write "$COMMAND"; then
      exit 0
    fi
    FILE_PATH=$(bash_extract_write_target "$COMMAND")
  else
    # Library missing — fall back to no-op rather than bricking the hook.
    exit 0
  fi
fi

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
HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
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
      parent=$(dirname "$r"); [ "$parent" = "$r" ] && break; r="$parent"
    done
  fi
fi
MARKER_HOME="${OPS_ROOT:-$REPO_ROOT}"
MARKER_HOME="${MARKER_HOME:-.}"

# Resolve the workspace dir (defaults to $OPS_ROOT/workspace; v2
# split-portfolio adopters point at the private sibling repo).
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
# Reuse the #41 resolution: per-project marker if FILE_PATH is under the
# resolved workspace dir, otherwise the ops-level fallback. The resolved
# workspace dir may live in the private sibling repo for v2 adopters.
PROJECT=""
if [ -n "$WORKSPACE_DIR" ]; then
  case "$FILE_PATH" in
    "$WORKSPACE_DIR"/*)
      tail="${FILE_PATH#$WORKSPACE_DIR/}"
      PROJECT="${tail%%/*}"
      ;;
  esac
fi
if [ -z "$PROJECT" ] && [ -n "$OPS_ROOT" ]; then
  case "$FILE_PATH" in
    "$OPS_ROOT"/workspace/*)
      tail="${FILE_PATH#$OPS_ROOT/workspace/}"
      PROJECT="${tail%%/*}"
      ;;
  esac
fi

# Three-tier marker lookup, mirroring require-active-ticket.sh (#41 + #513):
# tier 0 per-worktree (tickets/<project>/<safe-branch>) → tier 1 per-project
# (tickets/<project>, a FILE) → tier 2 ops fallback (current-ticket).
MARKER=""
if [ -n "$PROJECT" ]; then
  # Tier 0 worktree detection — identical to require-active-ticket.sh: env var,
  # else LINKED-worktree check via absolute git-dir vs absolute common-dir.
  WT_BRANCH="${CLAUDE_WORKTREE_BRANCH:-}"
  if [ -z "$WT_BRANCH" ]; then
    _fdir=$(dirname "$FILE_PATH")
    _gd=$(git -C "$_fdir" rev-parse --absolute-git-dir 2>/dev/null)
    _gcd=$(git -C "$_fdir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
    if [ -n "$_gd" ] && [ "$_gd" != "$_gcd" ]; then
      WT_BRANCH=$(git -C "$_fdir" branch --show-current 2>/dev/null)
    fi
  fi
  if [ -n "$WT_BRANCH" ]; then
    SAFE_BRANCH="${WT_BRANCH//\//__}"
    if [ -f "$MARKER_HOME/.claude/session/tickets/$PROJECT/$SAFE_BRANCH" ]; then
      MARKER="$MARKER_HOME/.claude/session/tickets/$PROJECT/$SAFE_BRANCH"
    fi
  fi
fi
if [ -z "$MARKER" ] && [ -n "$PROJECT" ] && [ -f "$MARKER_HOME/.claude/session/tickets/$PROJECT" ]; then
  MARKER="$MARKER_HOME/.claude/session/tickets/$PROJECT"
elif [ -z "$MARKER" ] && [ -f "$MARKER_HOME/.claude/session/current-ticket" ]; then
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

# --------- Shape-guard marker-derived values before the tracker call ---------
# TICKET_NUM / TICKET_REPO come from the session-local active-ticket marker via
# `cut -d= -f2-`, which keeps everything after the first `=` — so a marker line
# like `number=42; touch X` yields TICKET_NUM='42; touch X'. Gate 2 below feeds
# both values into `tracker_view`, which builds its command by string-substituting
# {id}/{owner_repo} into a template and running `eval` (_lib-tracker.sh). Without a
# shape check that is a command-injection sink: the base (pre-#755) hook used direct
# argv (`gh issue view "$TICKET_NUM" --repo "$TICKET_REPO"`), which was
# injection-immune; routing through the tracker abstraction reintroduces the eval.
# The sibling caller `validate-pr-create.sh` reaches the same eval only AFTER its
# ticket number passed a shape check — this hook must not skip the equivalent guard.
# Whitelist a conservative charset (no shell metacharacters): ticket IDs like 42,
# #42, GH-42, ABC-123; owner/repo slugs (incl. GitLab nested groups) of letters,
# digits, `.`, `_`, `-`, `/`. Anything else fails closed. (#755 security review;
# defence-in-depth alongside the printf %q quoting _tracker_substitute now applies.)
if ! printf '%s' "$TICKET_NUM" | grep -qE '^#?[A-Za-z0-9_-]+$'; then
  cat >&2 <<MSG
BLOCKED: Active ticket marker at $MARKER has a malformed \`number=\` value.
Only ticket IDs like 42, #42, GH-42, or ABC-123 are allowed (no shell
metacharacters). Re-run /start-ticket to rewrite the marker cleanly.
MSG
  exit 2
fi
if ! printf '%s' "$TICKET_REPO" | grep -qE '^[A-Za-z0-9._/-]+$'; then
  cat >&2 <<MSG
BLOCKED: Active ticket marker at $MARKER has a malformed \`repo=\` value.
Only owner/repo slugs (letters, digits, \`.\`, \`_\`, \`-\`, \`/\`) are
allowed (no shell metacharacters). Re-run /start-ticket to rewrite the
marker cleanly.
MSG
  exit 2
fi

# --------- Gate 2: issue is open + has migration label ---------
# Resolve the ticket through the tracker abstraction (_lib-tracker.sh) so this
# gate works for every configured tracker — GitHub (gh), GitLab (glab), Linear,
# Jira, Asana, custom — not just GitHub. Before #755 this hardcoded
# `gh issue view`, which returned empty for GitLab-tracked projects and
# false-blocked every migration edit even when the GitLab ticket was valid.
# tracker_view emits the normalised {state,title,url,labels,body} shape
# regardless of tracker; labels come back as a flat string array and body is
# populated for gh/glab (the kinds the migration gate reads).
if [ -f "$HOOK_DIR/_lib-tracker.sh" ]; then
  # shellcheck source=/dev/null
  . "$HOOK_DIR/_lib-tracker.sh"
fi

# Resolve the tracker kind for the TICKET's repo (per-project registry override
# wins over the global config; see #670). tracker.kind=none has no queryable
# tracker, so existence / label / AgDR can't be verified online — per the #755
# Expected behaviour, skip the online gates (Gate 1 already proved an active
# ticket marker exists) and allow the edit, operator-trusted. The skip is
# printed to stderr so it is auditable, never silent.
TICKET_KIND="gh"
if command -v tracker_kind >/dev/null 2>&1; then
  TICKET_KIND=$(tracker_kind "$TICKET_REPO" 2>/dev/null)
  [ -n "$TICKET_KIND" ] || TICKET_KIND="gh"
fi
if [ "$TICKET_KIND" = "none" ]; then
  echo "note: tracker.kind=none for ${TICKET_REPO} — skipping migration label/AgDR verification (operator-trusted; #755)." >&2
  exit 0
fi

if command -v tracker_view >/dev/null 2>&1; then
  ISSUE_JSON=$(tracker_view "$TICKET_NUM" "$TICKET_REPO" 2>/dev/null)
else
  # Library missing (should not happen in a real fork) — fall back to gh so the
  # gate still functions on a GitHub tracker rather than bricking, normalising
  # to the same shape tracker_view emits (labels as a flat string array).
  ISSUE_JSON=$(gh issue view "$TICKET_NUM" --repo "$TICKET_REPO" --json state,title,url,labels,body 2>/dev/null \
    | jq -c '{state,title,url,labels:((.labels // []) | map(.name)),body}' 2>/dev/null)
fi

if [ -z "$ISSUE_JSON" ]; then
  cat >&2 <<MSG
BLOCKED: Could not fetch ${TICKET_REPO}#${TICKET_NUM} from the configured
tracker (kind: ${TICKET_KIND}). Network / auth problem? Or the issue
doesn't exist?

The migration gate is fail-closed by design — a high-blast-radius change is
not allowed against a ticket the framework cannot verify. (This is stricter
than the PR-create / commit-ref existence checks, which fall back to
shape-only when a non-gh CLI is unreachable, per #501 — a migration edit
warrants a hard stop.) If your tracker is untracked, set tracker.kind=none.

Check your tracker auth (e.g. gh auth status / glab auth status), or run
/migration to create a new ticket.
MSG
  exit 2
fi

STATE=$(echo "$ISSUE_JSON" | jq -r '.state // empty')
# Normalised labels are a flat string array, so a direct membership test.
HAS_LABEL=$(echo "$ISSUE_JSON" | jq -r --arg L "$MIGRATION_LABEL" '.labels | index($L) != null')
BODY=$(echo "$ISSUE_JSON" | jq -r '.body // empty')

# Closed-state recognition is tracker-agnostic — same vocabulary as
# validate-pr-create.sh / verify-commit-refs.sh: gh/glab "CLOSED", Linear
# "Done", Jira "Resolved", Asana "Closed", etc.
STATE_LC=$(echo "$STATE" | tr '[:upper:]' '[:lower:]')
case "$STATE_LC" in
  closed|done|cancelled|canceled|resolved|completed)
    cat >&2 <<MSG
BLOCKED: Active ticket ${TICKET_REPO}#${TICKET_NUM} is "$STATE", not open.
Migration files require an OPEN labelled ticket. Run /migration to create
a fresh one, or /start-ticket on a different OPEN migration ticket.
MSG
    exit 2 ;;
esac

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
# The issue body is populated by tracker_view only for the gh and glab adapters
# (see _lib-tracker.sh). For any other tracker kind the body comes back empty,
# so this gate cannot see an AgDR link even when one exists — surface that in the
# failure message rather than blaming the ticket. Adopters on those trackers can
# set tracker.kind=none to skip online migration verification. (Widening body to
# jira/linear/asana is tracked separately from #755.)
if ! echo "$BODY" | grep -qE 'docs/agdr/AgDR-[0-9]+-[^[:space:]]*migration[^[:space:]]*\.md'; then
  KIND_NOTE=""
  case "$TICKET_KIND" in
    gh|glab) ;;
    *) KIND_NOTE="

NOTE: tracker.kind=${TICKET_KIND} — this gate reads the issue body only for the
gh and glab trackers, so for ${TICKET_KIND} the body is not fetched and this
check cannot see an AgDR link even if the ticket has one. Track migrations on a
gh/glab ticket, or set tracker.kind=none to skip online migration verification." ;;
  esac
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
relative path in the body satisfies gate 3.${KIND_NOTE}
MSG
  exit 2
fi

# All gates passed — allow the edit.
exit 0
