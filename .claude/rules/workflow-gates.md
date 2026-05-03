# Workflow Gates

| Gate | Before | Verify |
|------|--------|--------|
| 1 | PRD → Tech Design | PRD approved, parent epic exists |
| 2 | Tech Design → Build | Design approved, story tickets exist, **AgDR for key decisions** |
| 3 | Starting code | Ticket exists, branch created, design review if UI work |
| 3a | Starting a **migration** edit | Active ticket has the `migration` label **and** its body references a migration AgDR at `docs/agdr/AgDR-\d+-.*migration.*\.md`. Enforced by `require-migration-ticket.sh`. Use `/migration` to produce both artefacts in one flow. |
| 4 | Creating PR | Tests pass, checks pass, **> 80% coverage**, **AgDR linked if decisions made** |
| 5 | Merging PR | 2 reviews (agent + human), CI green, **commit SHA matches review** |
| 6 | Ticket → Done | QA verified, signed off |

**If a gate fails → STOP. Complete the missing step first.**

## One Ticket at a Time

Work on **one** ticket at a time. Complete it fully before starting the next. Each PR = one ticket only.

```
WRONG:
  Start ticket A → Start ticket B → Start ticket C → PR with all 3

RIGHT:
  Start A → PR → Review → QA → Done
  Start B → PR → Review → QA → Done
  Start C → PR → Review → QA → Done
```

## Pre-Build Gate

Do not start coding until **all** of these exist in your ticket tracker:

- Parent epic / feature ticket (with link to the PRD)
- User story tickets (sub-issues)
- Each story has acceptance criteria
- Technical tasks broken down
- Tickets moved to "Todo" or "In Progress"

### Bootstrap-skill exemption

The pre-build gate is enforced mechanically by `require-active-ticket.sh`, which fires on `Edit`, `Write`, `MultiEdit`, **and** `Bash` (the Bash matcher uses `_lib-detect-bash-write.sh` to detect `>` redirection, `tee`, `sed -i`, `python -c '…write…'`, `node -e '…writeFile…'`, etc. — closing the bypass surface from me2resh/apexyard#151).

A small set of **bootstrap-class skills** runs before any portfolio is configured, before any project is registered, and therefore before any tracker tickets can exist. For these, the gate is exempt:

- `/setup` — first-run framework bootstrap on a fresh fork
- `/handover` — adopting an external project (registry / `projects/<name>/` writes happen before the project's own tracker is wired up)
- `/update` — upstream sync (touches framework files; the only "ticket" for this work is the sync itself)
- `/split-portfolio` — destructive migration to split-portfolio mode (rewriting fork-root files; existing private-name tickets being redacted *as the work proceeds*)

The list lives at `.claude/project-config.defaults.json` → `ticket.bootstrap_skills`. Adopters extend it via `.claude/project-config.json` shallow-merge if they have custom bootstrap skills.

**Mechanism:** each bootstrap skill writes its name to `.claude/session/active-bootstrap` on entry and removes the file on completion. The hook reads the marker and exempts skills on the configured list. The `clear-bootstrap-marker.sh` SessionStart hook sweeps stale markers from interrupted sessions so a crashed / killed skill can't leave the exemption open forever.

See AgDR-0011 + me2resh/apexyard#150 for the full design rationale.

## Migration Gate (3a) — dedicated ticket + AgDR

Any edit to a file that matches the migration-path patterns (configurable via `.claude/project-config.json` → `migration_paths`) requires:

1. An OPEN tracker issue with the `migration` label (default, overridable via `migration_label`)
2. The issue body contains a reference to a migration AgDR at `docs/agdr/AgDR-\d+-.*migration.*\.md`

Default migration paths:

- `**/migrate-*.{ts,js,py,sql}` — one-off migration scripts
- `**/migrations/**` — any file under a migrations/ directory
- `prisma/schema.prisma`, `prisma/migrations/**` — Prisma
- `src/migrations/*.{ts,js}` — TypeORM
- `alembic/versions/*.py` — Alembic
- `db/migrate/*.rb` — Rails

**Enforcement**: `require-migration-ticket.sh` fires on PreToolUse for Edit / Write / MultiEdit. Runs BEFORE `require-active-ticket.sh` in the hook chain — if the path isn't a migration path, it's a no-op and the normal active-ticket check applies.

**How to satisfy**: run `/migration` — it asks for migration type, affected tables, rollback plan, downtime estimate, cross-service consumers, data volume, testing plan, and observability, then creates the labelled issue AND writes the AgDR in one flow.

## QA State is Mandatory

A merged PR moves the ticket to **QA** state, **not** Done. A QA Engineer manually verifies the acceptance criteria, then moves the ticket to Done.

```
In Progress → In Review → QA → Done
                          ^
                    MANDATORY STOP
                    QA must verify
```
