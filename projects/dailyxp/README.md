# DailyXP

**Repo**: https://github.com/da5ater/dailyxp
**Workspace**: workspace/dailyxp/ (local path: `/run/media/mohamed/storage/Projects/DailyXP` — link or clone when ready)
**Docs**: projects/dailyxp/
**Status**: handover
**Tier**: P1

## What it is

DailyXP is an Omarchy-first life-gamification product for focused work, goals, habits, recovery, social competition, and a persistent comeback story. Today it ships as an Omarchy Quattro plugin (bar widget on every monitor, nested panel with Play / Journey / World, headless StateStore service, canonical versioned event journal). The hosted Rails + PostgreSQL companion (`da5ater/dailyxp-api`) is planned as a separate repo and will provide sync, XP ledger, Seasons/Leagues/Groups/Guilds/Circles.

## Who owns it

- **Owner / product decisions**: Mohamed Osama Mohamed Khater (@da5ater) — owns all merge decisions (`merge` required)
- **Tech leads / implementers**: ApexYard roles — `tech-lead`, `backend-engineer`, `frontend-engineer`, `sre` (wires in when the Rails host appears)

## Tech stack

- **Language / runtime**: QML (Quickshell, Omarchy 4 / Quattro shell plugin host) + plain JavaScript domain models (Qt-free)
- **DB / persistence**: Local filesystem envelope (`$XDG_STATE_HOME/dailyxp/` — primary/backup + canonical event journal); future `da5ater/dailyxp-api` → PostgreSQL (Single-AZ in V1, acknowledged)
- **Tests**: `node --test` — 137/137 green; `qmllint` for QML (requires Omarchy checkout for `qs.*` imports)
- **CI**: none yet — to be adapted from `golden-paths/pipelines/ci.yml` to `node --test` + `qmllint`

## Handover

- **Assessment**: [handover-assessment.md](./handover-assessment.md) — origin, health, 5-dimension harnessability (`low`), risks, integration plan
- **Harnessability**: `low` — flat JS/QML, no type system, no lint baseline, weak framework opinionation; Rex advisory-only until scaffolding
- **Architecture**:
  - `architecture/container.md` — C4 L2 (plugin host trio + local envelope + future Rails boundary)
  - `architecture/context.md` — C4 L1 (Person → DailyXP → Omarchy/Marketplace/GitHub/future hosted)
  - `architecture/sequence-journal.md` — envelope + atomic save + recovery
  - `architecture/sequence-session.md` — focused Session lifecycle (FOCUS-001)
  - `architecture/dfd.md` — trust boundaries + data crossings (input to STRIDE)
  - `architecture/vision.md` — north-star + current→target + migration path + anti-scope
- **Feature inventory**: [feature-inventory.md](./feature-inventory.md) — six-axis catalogue (16 JS models, 2 QML surfaces, 137 tests, V1 PRD)
- **Journey**: [journeys/dailyxp-v1.yaml](./journeys/dailyxp-v1.yaml) + [journeys/dailyxp-v1.html](./journeys/dailyxp-v1.html) — 12 pages, Play/Journey/World flow preview
- **Vision**: [architecture/vision.md](./architecture/vision.md) — quarterly, next review after 2026-10-20 re-audit (issue #13)

## Source docs (in the DailyXP repo)

- **V1 PRD (Revised)**: `docs/design/dailyxp-v1.md` (1036 lines)
- **Domain glossary**: `CONTEXT.md` (single-context)
- **Model contracts**: `docs/event-model.md`, `planning-model.md`, `session-model.md`, `habit-model.md`, `recovery-model.md`, `progression-model.md`, `story-model.md`, `share-model.md`, `feed-model.md`, `insight-model.md`, `ux-model.md`
- **Wayfinder**: `.scratch/wayfinder/map.md` + 8 deep-dives (`accepted-contract`, `aws-zero-spend`, `repository-topology`, etc.)

## Quick verify

```sh
node --test /run/media/mohamed/storage/Projects/DailyXP/tests/*.test.js
/usr/lib/qt6/bin/qmllint -I /usr/share/omarchy/shell \
  /run/media/mohamed/storage/Projects/DailyXP/BarWidget.qml \
  /run/media/mohamed/storage/Projects/DailyXP/Panel.qml \
  /run/media/mohamed/storage/Projects/DailyXP/StateStore.qml
omarchy plugin validate /run/media/mohamed/storage/Projects/DailyXP
```

## Registry

Registered in `apexyard.projects.yaml` as `dailyxp` (`da5ater/dailyxp`) — status `handover`, roles `tech-lead, backend-engineer, frontend-engineer, sre`.
