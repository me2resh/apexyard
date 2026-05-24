---
name: migration
description: Create a labelled migration ticket + matching migration AgDR — required by the migration gate.
argument-hint: "[<project>]"
allowed-tools: Bash, Read, Write
---

# /migration — Create a Migration Ticket + AgDR

Migrations are high-blast-radius: data loss, downtime, lock contention, cross-service coordination. ApexYard treats them as a distinct class of change from code — a migration PR needs:

1. A tracker issue with the `migration` label (plus priority) that captures the plan.
2. A migration AgDR at `docs/agdr/AgDR-NNNN-migration-<slug>.md` that captures the options considered, rollback plan, downtime estimate, cross-service consumers, data volume, testing plan, and observability.

`require-migration-ticket.sh` (the matching PreToolUse hook) refuses to let you write to migration paths without both artefacts in place. This skill produces both in one pass.

## Path resolution

Read the registry path via `portfolio_registry`, the per-project docs dir via `portfolio_projects_dir`, and the ideas backlog via `portfolio_ideas_backlog` — all from `.claude/hooks/_lib-portfolio-paths.sh`. Source the helper at the top of any bash block that touches those paths:

```bash
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-read-config.sh"
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-portfolio-paths.sh"
registry=$(portfolio_registry)
```

Defaults match today's single-fork layout (`./apexyard.projects.yaml`, `./projects`, `./projects/ideas-backlog.md`). Adopters in split-portfolio mode override the `portfolio.{registry, projects_dir, ideas_backlog}` keys in `.claude/project-config.json`. Don't hardcode literal `apexyard.projects.yaml` or `projects/` paths in bash blocks — the helper resolves whichever mode the adopter is in. See `docs/multi-project.md`.

## Usage

```
/migration                 # prompts for everything, creates ticket + AgDR in the current project
/migration curios-dog      # explicitly target a registered project
```

## When to invoke

- Before writing a new SQL migration file
- Before adding/modifying a DynamoDB table in `backend/template.yaml`
- Before adding/modifying an `aws_rds_*` / `aws_dynamodb_table` resource in Terraform
- Before editing a Prisma schema in a way that will produce a migration
- Before editing TypeORM / Alembic migration directories
- Generally: BEFORE the first `Write` on anything the migration-gate hook blocks

## Process

### 0. Write the active-issue-skill marker (REQUIRED — me2resh/apexyard#268)

Before any `gh issue create` (or other tracker CLI), write this skill's name to the active-issue-skill marker so `require-skill-for-issue-create.sh` lets the command through. At skill entry:

```bash
ops_root="$(r=$PWD;while [ ! -f \"$r/onboarding.yaml\" ] && [ \"$r\" != / ];do r=${r%/*};done;echo $r)"
mkdir -p "$ops_root/.claude/session"
echo "migration" > "$ops_root/.claude/session/active-issue-skill"
```

Remove the marker on **every** exit path (success, early-exit, user cancel, error):

```bash
rm -f "$ops_root/.claude/session/active-issue-skill"
```

The `clear-issue-skill-marker.sh` SessionStart hook sweeps stale markers from killed sessions, but a clean exit should never leave one behind. See AgDR-0030.

### 1. Resolve the target project

If the user passed `<project>`, use that. Otherwise:

- If cwd is under `<ops_root>/workspace/<project>/`, infer project from the path
- Otherwise ask explicitly: "Which project is this migration for?"

Look up the project in `apexyard.projects.yaml` to get `repo` (the tracker) and `workspace` (for computing the AgDR path).

If the project isn't registered, stop — file one via `/handover` first, or pass the ticket as a plain ops-level change.

### 2. Gather the migration facts (conversational)

Ask each of the following. Each answer feeds both the issue body and the AgDR — the skill writes them into both so the user never retypes.

1. **One-line summary** — goes in the ticket title: `[Migration] <type>: <summary>`
2. **Migration type** — `schema | data | sql | orm` (pick one; if it straddles, use the most invasive)
3. **Affected tables / entities** — comma-separated list. Required non-empty.
4. **Rollback plan** — free text, required non-empty. Ask "if this goes wrong in prod at 3am, what exactly does the rollback runbook look like?" Capture the actual steps, not a promise to figure it out later.
5. **Rollback tested against** — `staging | copy of prod | unit fixture | not tested`. If "not tested", flag it in the AgDR and tell the user this is a blocker for prod apply (not for creating the ticket).
6. **Estimated downtime** — `none | seconds | minutes | hours`. Plus reasoning: "why this much / this little?"
7. **Cross-service consumers** — list every service that reads or writes the affected tables. If genuinely none, say so (makes review easier).
8. **Deploy-order constraint** — if any service must deploy before or after this migration, record it.
9. **Data volume** — rough row/item count. If unknown, note that and add "size check" to the testing plan.
10. **Testing plan** — dev smoke command, staging verify steps, canary / phased rollout if applicable.
11. **Observability** — metrics/logs that will confirm success during and after. If the project already has dashboards, link them.
12. **Priority** — `P0 | P1 | P2 | P3`. Default `P1` for migrations (blast radius).

Re-prompt if rollback plan is empty, affected tables is empty, or priority is missing — these are the three fields with no safe default.

### 3. Preview

Before creating anything, echo back a structured preview so the user can correct mistakes:

```
Ticket:
  Tracker:      <owner/repo>
  Title:        [Migration] <type>: <summary>
  Labels:       migration, <priority>
  Body:         (formatted — see below)

AgDR:
  Path:         docs/agdr/AgDR-NNNN-migration-<slug>.md
  Next number:  NNNN = max(existing AgDR ids in that dir) + 1
```

Ask "Create ticket + AgDR? [y/N]". Only proceed on explicit `y`.

### 4. Create the AgDR first (local write, reversible)

Resolve the migration AgDR template via the portfolio helper so adopter overrides win when present:

```bash
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-read-config.sh"
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-portfolio-paths.sh"
template=$(portfolio_resolve_template agdr-migration.md)   # → custom-templates/agdr-migration.md if present
cp "$template" "$resolved_agdr_path"
```

Single-fork adopters (no `portfolio` block) and adopters with no override fall straight through to `templates/agdr-migration.md`. Adopters who want a customised migration-AgDR shape drop their version at `<private_repo>/custom-templates/agdr-migration.md`. See `templates/README.md` for the path-mirroring convention.

Fill in:

- Frontmatter (`id`, `timestamp`, `agent`, `model`, `trigger: user-prompt`, `status: draft`, `ticket` — left as `TBD` until step 5 creates the issue and we know the number)
- The title, one-sentence summary, and every Section (Context, Options, Decision, Rollback Plan, Cross-Service Consumers, Testing Plan, Observability, Consequences) with the user's answers

AgDRs are written in the RIGHT repo:

| Where the migration runs | AgDR path |
|--------------------------|-----------|
| Inside a managed project's own code repo | `workspace/<project>/docs/agdr/AgDR-NNNN-migration-<slug>.md` |
| Against the apexyard framework itself (rare — only for framework-level data/config migrations) | `docs/agdr/AgDR-NNNN-migration-<slug>.md` in the ops fork |

For the `NNNN` id: scan the target `docs/agdr/` directory for existing `AgDR-\d+-.*\.md` files, take the max id, increment. Zero-pad to 4 digits.

### 5. Create the GitHub issue

Title: `[Migration] <type>: <summary>`

Labels: `migration` (or whatever the project configures as its migration label — check `.claude/project-config.json` key `migration_label`, default `migration`), plus the priority label (`P0` / `P1` / `P2` / `P3`).

Body — resolve the migration ticket body template via the portfolio helper so adopter overrides win when present:

```bash
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-read-config.sh"
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-portfolio-paths.sh"
ticket_template=$(portfolio_resolve_template tickets/migration.md)   # → custom-templates/tickets/migration.md if present
```

Single-fork adopters (no `portfolio` block) and adopters with no override fall straight through to `templates/tickets/migration.md`. Adopters who want a customised migration-ticket shape drop their version at `<private_repo>/custom-templates/tickets/migration.md`. See `templates/README.md` for the path-mirroring convention.

**Backward-compat fallback**: if `portfolio_resolve_template` returns empty (template file missing — partial adopter setup), fall back to the inline heredoc body below and print a one-line WARN on stderr (`WARN: tickets/migration.md template missing — using inline fallback`).

Body (CommonMark, must include a ref to the AgDR so `require-migration-ticket.sh` can verify it) — the default `templates/tickets/migration.md` shape is reproduced below:

```markdown
## Migration

**Type**: <type>
**Affected tables/entities**: <list>
**Estimated downtime**: <level> — <reasoning>
**Data volume**: <count or "unknown">
**Priority**: <priority>

## Rollback Plan

<rollback plan verbatim>

**Tested against**: <staging | copy of prod | unit fixture | not tested>

## Cross-Service Consumers

<list or "none">

**Deploy-order constraint**: <constraint or "none">

## Testing Plan

- Dev smoke: <command>
- Staging verify: <steps>
- Canary / phased rollout: <plan or "n/a">

## Observability

<what to watch during + after>

## Agent Decision Record

Migration AgDR: `<relative-path-to-AgDR>`

## Glossary

| Term | Definition |
|------|------------|
| <term> | <definition> |

---

Created by `/migration`. Do not edit the labels off this issue — the
migration-gate hook (`require-migration-ticket.sh`) verifies the
`migration` label is present before allowing edits to migration files.
```

Create via:

```bash
gh issue create \
  --repo "<owner/repo>" \
  --title "[Migration] <type>: <summary>" \
  --label "migration" \
  --label "<priority>" \
  --body "$BODY"
```

Capture the returned URL and issue number.

### 6. Back-fill the AgDR with the issue reference

Open the AgDR written in step 4 and update:

- Frontmatter `ticket: <owner/repo>#<number>`
- The Artifacts section: add the ticket URL

This lets a future reader land on the AgDR and find the ticket, and land on the ticket and find the AgDR.

### 7. Return a summary

Single-line output:

```
Migration ticket: <ticket-url>
Migration AgDR:   <relative-path-to-AgDR>
Next step:        run /start-ticket <owner/repo>#<number>, then begin editing the migration files
```

**Do NOT automatically run `/start-ticket`** — the user may have other context to set first, and the explicit handoff makes the workflow legible. The migration gate will block edits until the marker points at this ticket.

## Rules

1. **Never ship without a rollback plan**. If the user cannot articulate rollback steps, the migration isn't ready — the skill refuses to create the ticket until they type something in that field.
2. **Never auto-assign priority**. Migrations span from "trivial schema rename" (P3) to "primary-key column type change on a 100M-row table at peak traffic" (P0). Ask.
3. **Never skip the AgDR**. Even small migrations get one. If it feels like overkill for a 3-line change, the AgDR entries will be short — that's fine. The value is in the forcing function of thinking through rollback + observability, not in the document length.
4. **Never create the AgDR under `.claude/` or `docs/` unless the migration IS against apexyard itself**. For managed projects, the AgDR lives inside that project's repo (`workspace/<project>/docs/agdr/`), not in the ops fork.
5. **Write AgDR first, ticket second, back-fill third** — the AgDR is a local file, reversible with `rm`. The ticket is remote state. If anything errors after the ticket is created, the user has a ghost ticket to clean up; minimise that exposure.
6. **Tell the user the next step is `/start-ticket`** — the migration-gate hook checks the active ticket has the `migration` label, so they need to declare it before touching migration files.

## Relation to the migration gate

| Hook | `require-migration-ticket.sh` (fires PreToolUse on Write/Edit to migration paths) |
|------|------------------------------------------------------------------------------------|
| Gate 1 | Active ticket exists (same as require-active-ticket.sh) |
| Gate 2 | The active ticket on GitHub has the `migration` label |
| Gate 3 | The active ticket's body references an AgDR at `docs/agdr/AgDR-\d+-.*migration.*\.md` |
| Fail message | Points at this skill with the exact invocation to run |

The skill and the gate are two halves of the same mechanism: gate detects the situation and blocks, skill builds the artefacts needed to unblock.

---

*Part of [ApexYard](https://github.com/me2resh/apexyard) — multi-project SDLC framework for Claude Code · MIT.*
