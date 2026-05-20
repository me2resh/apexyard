# XPORT CRM

**Source repo:** [github.com/Dr-kersho/XPORT-CRM](https://github.com/Dr-kersho/XPORT-CRM)

Gulf export sales CRM — lead pipeline, call log, scored CSV ingest, assisted WhatsApp outreach, consent-gated programmatic send (v2).

## Stack (high level)

- Next.js 14 App Router, TypeScript, Tailwind
- Auth: Auth0 (`@auth0/nextjs-auth0`)
- Data: AWS DynamoDB (local Docker port 8000 in dev)
- Billing: Stripe (test mode on staging)
- Local dev: **http://localhost:443** (`npm run dev -- -p 443`)

## Canonical docs (in app repo)

| Doc | Path in `XPORT-CRM` repo |
|-----|--------------------------|
| Domain language | `CONTEXT.md` |
| Auto-leads | `docs/AUTO-LEADS.md` |
| Staging runbook | `docs/STAGING-RUNBOOK.md` (if present) |
| AgDRs | `docs/agdr/` |

## ApexYard docs here

Roadmap and portfolio-level notes live under `projects/xport-crm/` in this ops repo. Implementation truth is always the **XPORT-CRM** git repo.

## Local clone

Live copy (sibling to ops repo):

```bash
# From apexyard root
ln -sf ../XPORT-CRM workspace/xport-crm
```

Or: `/Users/apple/Documents/XportCRM/XPORT-CRM`

## Ticket prefix

GitHub Issues — **#N** (e.g. `#16` Meta WhatsApp). Branches: `feature/16-meta-whatsapp`. Integration branch: **`staging`** → Vercel staging.

## Status (2026-05-20)

| Epic | PR | State |
|------|-----|--------|
| #13 Auto-lead ingest | #19 | Merged → `staging` |
| #14 Consent fields | #20 | Merged → `staging` |
| #15 Outreach task queue | #21 | Merged → `staging` |
| #16 Meta WhatsApp API | — | **Next** |
| #17 Conditional auto-send | — | Blocked on #16 + consent |
| #18 Inbound webhook | — | Backlog |

**Staging blockers:** #6 Auth0, #8 Vercel env, #9 D2 smoke on `xportcrm-staging.vercel.app`
