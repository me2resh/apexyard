# KoraID roadmap (ApexYard)

Living summary — detail and acceptance criteria are in [docs/koraid-full-prd.md](https://github.com/Dr-kersho/koraid/blob/main/docs/koraid-full-prd.md) and GitHub Issues.

## Phase 1 — MVP

| Area | Status | GitHub |
|------|--------|--------|
| Auth, profile, FIFA card | Done | #2–12 |
| Courts + Paymob booking | Done | — |
| Silver/gold drills + stats | Done | — |
| Training hub, match board, ratings, squads | Done | #26–30 |
| Parent mode + deletion | Done | #31 |
| Court submission, RTL, PWA, pre-launch | Done | #32–35 |
| Pitch IQ CV (software) | Shipped | #48 epic open; #83 deploy closed |
| Architecture stores + competition | Done | #172 umbrella closed (#171–#176) |
| Public product catalogue | Done | #170 |
| Dynamo GSI index guard | Done | #98 |

## Phase 2 — in progress

| Area | Status | GitHub |
|------|--------|--------|
| Scout player search | Done | #42 |
| Scout watchlist | MVP shipped | #43 |
| Scout contact request | MVP shipped | #44 |
| G Coins earn + spend | Done | #45, #46 |
| Kora Reels | Done | #36 |
| Physical card printing | **Deferred** — see [FEASIBILITY-047-physical-card-printing.md](./FEASIBILITY-047-physical-card-printing.md) | #47 |
| Goals of the week, diamond tier, etc. | Backlog | #37–51 |

## Ops (manual)

| Step | Doc |
|------|-----|
| DrillCompletedIndex deploy + backfill | `docs/infra/drill-completed-index.md` |

## How to update

After shipping a milestone, close the issue on GitHub and adjust this table (or run `/roadmap` from the ops repo with project `koraid`).
