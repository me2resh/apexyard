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

## Spike work — exempt from a defined subset of these gates

Spike tickets (prefix `[Spike]`, label `spike`) are hypothesis-driven, time-boxed, throw-away exploration. The full production SDLC is the wrong bar — author avoidance is the failure mode. The exemption set below is **surgical, not blanket**:

| Gate | Production work | Spike work |
|------|----------------|------------|
| Pre-Build (parent epic, story tickets, ACs, design review) | Required | Skipped — the spike ticket IS the unit |
| AgDR for technical decisions (`require-agdr-for-arch-pr.sh`, `require-agdr-for-arch-changes.sh`) | Required | Skipped — ship a memo on `/spike-close --discard` instead |
| Test coverage > 80% | Required | Skipped — coverage is irrelevant for throw-away code |
| Code Reviewer agent (Rex) | Required on every PR | **Required** — even throw-away code gets a sanity check |
| Security Auditor (auth/crypto/secrets diff) | Required | **Required** — security gates fire regardless of intent |
| Glossary in PR body | Required | **Required** — spike PRs explain WHAT WAS LEARNED, which is the artefact |
| QA Engineer verification | Required (AC verification) | **Required** (Hypothesis verification: did we answer the question?) |
| Disposition decision before close | N/A | **Required** — operator must declare PROMOTE or DISCARD via `/spike-close` |

**Detection.** AgDR-required hooks detect a spike PR via:

1. PR title carries `spike(...)` as the conventional-commit type
2. Active ticket marker references a `[Spike]`-prefixed ticket
3. Branch name starts with `spike/`

Any one match exempts the gate; otherwise the production rule applies. See `.claude/skills/spike/SKILL.md`, `.claude/skills/spike-close/SKILL.md`, and `docs/agdr/AgDR-0017-spike-skill-schema-and-exemptions.md`.

## QA State is Mandatory

A merged PR moves the ticket to **QA** state, **not** Done. A QA Engineer manually verifies the acceptance criteria, then moves the ticket to Done.

```
In Progress → In Review → QA → Done
                          ^
                    MANDATORY STOP
                    QA must verify
```
