# KoraID

**Source repo:** [github.com/Dr-kersho/koraid](https://github.com/Dr-kersho/koraid)

Digital identity layer for Egyptian grassroots football — FIFA-style player cards, court booking, community matches, squads, and parent-managed child profiles.

## Stack (high level)

- Next.js 14 App Router, TypeScript, Arabic RTL
- Auth: Supabase (sessions); dev sign-in at `/auth` when `ALLOW_DEV_AUTH=true`
- Data: DynamoDB single-table (prod) / in-memory store (dev)
- Payments: Paymob (bookings)
- Local dev: **http://localhost:3010** (`npm run dev`)

## Canonical docs (in app repo)

| Doc | Path in `koraid` repo |
|-----|------------------------|
| PRD | `docs/koraid-full-prd.md` |
| Design system | `DESIGN.md` |
| Agent notes | `CLAUDE.md` |

## ApexYard docs here

Roadmap, handover notes, and cross-repo AgDRs for KoraID live under `projects/koraid/` in the ops repo. Implementation truth is always the **koraid** git repo.

## Local clone

From the ops repo root (`~/Documents/apexyard`):

```bash
ln -sf ~/Documents/koraid workspace/koraid
```

Or `git clone git@github.com:Dr-kersho/koraid.git workspace/koraid` if you prefer a separate clone.

## Ticket prefix

GitHub Issues — **#N** (e.g. `#31` parent mode). Branches: `feature/#31-parent-mode`.

## MVP status (2026-05)

Shipped on `main`: courts/booking, drills, training hub, match board/join, peer ratings, squads, trials. Open: **#31** (parent mode, PR #76), then **#32–35** (court submission, RTL, PWA polish, pre-launch).
