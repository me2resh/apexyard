# dailyxp — Feature Inventory

**Date**: 2026-08-21
**Scanner**: `/extract-features` via `/handover` (All docs)
**Scope**: `/run/media/mohamed/storage/Projects/DailyXP` (local path; `da5ater/dailyxp`)
**Stack detected**: QML (Omarchy Quattro shell plugin) + plain JavaScript domain models (Qt-free) + Node built-in `node:test`

## Coverage scope

**Walked**:
- `/` — root JS models (`*Model.js`, `*Journal.js`), QML surfaces (`BarWidget.qml`, `Panel.qml`, `StateStore.qml`), `manifest.json`, `README.md`, `CONTEXT.md`, `AGENTS.md`
- `docs/` — 12 model docs + `docs/design/dailyxp-v1.md` (V1 PRD, 1036 lines) + `docs/agents/`
- `tests/` — 16 test suites
- `.scratch/wayfinder/` — 9 wayfinder question files (`map.md` + 8 deep-dives)

**Skipped** (vendored / generated / fixtures):
- `.git/`, `.scratch/` (except wayfinder reads), `node_modules` (none), `dist`/`build` (none), `coverage` (none)

**Axes that produced findings**:
- [x] HTTP routes / entry points — 1 plugin kind (`bar-widget` + `service`), 2 entry points (not HTTP routes)
- [x] Data models / DB schema — 16 JS domain models + 1 QML service store
- [ ] Async jobs / queue handlers — 0 (local-only; no queue/cron/BullMQ/Celery)
- [x] Test names — 137 tests across 16 suites (gold axis)
- [x] UI screens / forms / interactions — 2 QML surfaces (BarWidget + Panel with Play/Journey/World)
- [x] Documented features — V1 PRD + 12 model docs + CONTEXT glossary

## Consolidated feature matrix

| # | Feature | Surface | Status | Source | Notes |
|---|---------|---------|--------|--------|-------|
| 1 | Bar widget per-monitor status | QML — `BarWidget.qml` | Active | UI + doc | Shows crest, selected Task, elapsed/planned, pause/resume, crest/achievement transform, offline/sync indicator; tap opens Play. Verified via PRD § Primary experience + `manifest.json` `barWidget` |
| 2 | Panel — Play / Journey / World + focused sheets | QML — `Panel.qml` → JS seam `UxModel.js` | Active | UI + model + doc + test | 3 surfaces + focused sheets; `UxModel.project(currentSurface)` drives `uxProjection.currentSurface`; Play is the default. Tests: `ux_model.test.js` (4 tests: frozen, navigation without dashboard, focused sheets, motion) |
| 3 | State service (once per shell) + envelope recovery | QML + JS — `StateStore.qml` + `StateModel.js` | Active | UI + model + test | Manifest `service: StateStore.qml` (headless, once). Recovers newest checksum-valid primary/backup envelope; equal-gen → primary wins; torn write → preserve whole generation. Tests: `state_store_recovery.test.js` + `state_model.test.js` |
| 4 | Canonical event journal + frozen time | JS — `EventModel.js` + `docs/event-model.md` | Active | model + doc + test | RFC4122 v4 IDs, frozen UTC + IANA zone + offset + `dayBoundaryMinutes` + `dailyXpDate`; immutable idempotent `append` by `eventId`; canonical sorted-key export + newline; `loadJournal` preserves `originalRaw`, migration V0→V1 returns `backupRaw`. Tests: `event_model.test.js` (14 tests incl. DST, occurrenceKey, __proto__, migration, malformed) |
| 5 | System clock / timezone source | JS/QML — `EventModel` + `StateStore.qml` | Active | model + doc | No `Intl` in QML: `readlink /etc/localtime` → IANA name, wall time + offset from `Date`; refuses recording if unverifiable; default Day Boundary 04:00 configurable |
| 6 | Local verbs — probe, planning, session | Shell IPC — `omarchy-shell io.github.da5ater.dailyxp <verb>` | Active | doc + model | `addProbe`, `ensurePlanningDay` (async atomic save → check `planningDayStatus`), `sessionStatus`/`sessionCommand`; documented in `README.md` Verify |
| 7 | Planning hierarchy — Goals, Milestones, Tasks, Routines → Occurrences | JS — `PlanningModel.js` + `PlanningJournal.js` + `docs/planning-model.md` | Active | model + doc + test | Routines generate dated Task Occurrences; carryover makes unfinished occurrence overdue without duplicating XP; edits scope to today/today+future/all; proposal object is previewable/editable, only acceptance mutates plan. Tests: `planning_model.test.js` (largest suite), `planning_journal.test.js` |
| 8 | Focused Sessions — select → remind → run → slice → correct | JS — `SessionModel.js` + `SessionJournal.js` + `docs/session-model.md` | Active | model + doc + test | Single active Session; selection ≠ start; delayed `notify-send` reminder (Start/Change Task/Dismiss); start/pause/resume/finish/discard/changeTask; runtime slicing by Day Boundary; inactivity excluded only on confirmation (no keys/screens/URLs); 12h capped competitive XP; cross-boundary attribution to majority day; 24h free edit then auditable adjustment; corrections re-slice by frozen boundary. Tests: `session_model.test.js` (largest, incl. wall-clock jump, day-boundary, caps) + `session_journal.test.js` |
| 9 | Habits + recovery separation | JS — `HabitModel.js` + `HabitJournal.js` + `RecoveryModel.js` + `docs/habit-model.md` + `docs/recovery-model.md` | Active | model + doc + test | Habits scheduled/recorded by completion/count; Recovery Tracks recorded via start/ongoing/relapse events (not Habit completion); Recovery Attempts end only on explicit relapse; tests: `habit_model.test.js`, `habit_journal.test.js`, `recovery_model.test.js` |
| 10 | Progression + XP ledger + Levels/Story Ranks | JS — `ProgressionModel.js` + `ProgressionJournal.js` + `docs/progression-model.md` | Active | model + doc + test | Lifetime XP for personal progress (unbounded Level `500+50*level`), Season XP capped/standardized for competition, Recovery XP separate; `XP Ledger` explains every award/correction; Story Rank thresholds Wanderer(1)→Sovereign(150). Tests: `progression_model.test.js` |
| 11 | Reclaimed Kingdom + Hollow King + Comeback Quest | JS — `StoryModel.js` + `docs/story-model.md` + `docs/design/dailyxp-v1.md` § Story | Active | model + doc + test | Goal=Province, Milestone=landmark; Momentum from last-7 eligible days (Dormant→Legendary, rest days harmless); Hollow King occupies only unfinished territory; 7 inactive days → 3-day Comeback Quest. Tests: `story_model.test.js` (antagonist cause language, never insult) |
| 12 | Feed / Insight / Share Cards | JS — `FeedModel.js` + `InsightModel.js` + `ShareModel.js` + `docs/feed-model.md` + `docs/insight-model.md` + `docs/share-model.md` | Active | model + doc + test | Feed bounded notifications+sounds; Insight stats; Share Cards are user-reviewed images (never auto-post) — privacy invariant. Tests: `feed_model.test.js`, `insight_model.test.js`, `share_model.test.js` |
| 13 | Competition — Seasons/Leagues/Groups/Guilds/Circles | Doc + future hosted — `docs/design/dailyxp-v1.md` § Competition | Planned | doc only | Global / geographic / Skill / private / Head-to-Head / Group / Guild / Support Circles + Recovery Circles; fixture-based Head-to-Head (3/1/0); wayfinder `social-competition.md` + `recovery.md` gate privacy |
| 14 | Omarchy Marketplace + competition submission | Infra/doc — `docs/release-evidence.md` + `.scratch/wayfinder/accepted-contract.md` | In progress | doc | Root-installable Quattro plugin; `omarchy plugin validate` + `qmllint`; Marketplace listing before 2026-08-24 10:00 Africa/Cairo; honest competition build before full V1 |
| 15 | AWS vs home-server hosting | Infra decision — `.scratch/wayfinder/aws-zero-spend.md` + issue #13 | Deferred | doc | Hard zero-charge Free Plan boundary; throttled local-first public-alpha; credits ≠ spend auth; re-audit 2026-10-20 `#13 [COLD]`; separate `da5ater/dailyxp-api` Rails repo per `repository-topology.md` |
| 16 | Offline install / removal / data ownership | Doc — `README.md` § Data and removal | Active | doc + model | `omarchy plugin add --enable` / `plugin remove`; durable state under `$XDG_STATE_HOME/dailyxp/` (primary/backup); removal leaves state intact |

## Per-axis findings

### Entry points — Omarchy plugin (not HTTP routes)

No HTTP routes — DailyXP is a local shell plugin. Entry points are manifest-declared + shell IPC verbs:

| Kind | Path / verb | Handler | File | Notes |
|------|-------------|---------|------|-------|
| bar-widget | `BarWidget.qml` | `BarWidget { stateStore: serviceFor(moduleName) }` | `manifest.json` + `BarWidget.qml` | One per monitor; reads `sessionProjection` |
| service | `StateStore.qml` | `StateStore` (headless) | `manifest.json` + `StateStore.qml` | Once per shell; owns envelope + journal |
| shell verb | `omarchy-shell io.github.da5ater.dailyxp addProbe` | `EventModel.createEvent → append → envelope commit` | `README.md` + `EventModel.js` | Idempotent via `eventId` |
| shell verb | `ensurePlanningDay` + `planningDayStatus` | Async atomic save; status polled after request | `README.md` + `PlanningModel` | Day lifecycle idempotent |
| shell verb | `sessionStatus` / `sessionCommand` | `SessionModel` start/pause/resume/finish/correct | `docs/session-model.md` | Single active Session invariant |

### Data models / DB schema

Models are plain JS modules (no ORM). The future hosted store (`da5ater/dailyxp-api` → PostgreSQL) is not yet in this repo — see wayfinder `repository-topology.md`.

| Model | Fields / responsibility | Relations | File |
|-------|------------------------|-----------|------|
| `EventModel` | `eventId` (v4), `deviceId`, `type`, `occurredAtUtc`, `localDateTime`, `timezone`, `utcOffsetMinutes`, `dayBoundaryMinutes`, `dailyXpDate`, `occurrenceKey`, `payload`, `context` | Parent of all journals; `createJournal`, `append`, `rebuildProjection`, `exportJournal`/`loadJournal` | `EventModel.js` (362 LOC) |
| `FeedModel` | Bounded notifications + sound triggers | Consumes events | `FeedModel.js` |
| `HabitModel` / `HabitJournal` | Habit scheduling + completion/count recording | Own journal | `HabitModel.js`, `HabitJournal.js` |
| `InsightModel` | Stats aggregation | Reads projections | `InsightModel.js` |
| `PlanningModel` / `PlanningJournal` | Goals → Milestones → Tasks → Routines → Task Occurrences + Planning Proposals (previewable, acceptance-only mutation) | Own journal + occurrenceKey | `PlanningModel.js` (622 LOC), `PlanningJournal.js` |
| `ProgressionModel` / `ProgressionJournal` | XP awards, Level, Story Rank, Momentum | Consumes Session/Habit/Milestone events | `ProgressionModel.js`, `ProgressionJournal.js` |
| `RecoveryModel` | Recovery Tracks / Attempts / Circles, Recovery XP, privacy gates | Own journal; separate from Habit | `RecoveryModel.js` |
| `SessionModel` / `SessionJournal` | One timed focused period per Task+Skill, slicing, caps, corrections | Own journal, frozen timezone/Boundary | `SessionModel.js` (820 LOC), `SessionJournal.js` |
| `ShareModel` | User-reviewed share cards (no auto-post) | Reads projections | `ShareModel.js` |
| `StateModel` / `StateStore.qml` | Envelope primary/backup, generation, checksum, recovery | Wraps all journals | `StateModel.js`, `StateStore.qml` |
| `StoryModel` | Provinces, landmarks, Momentum states, Hollow King, Comeback Quests, Achievements | Derives from progression + inactivity | `StoryModel.js` |
| `UxModel` | `currentSurface` (Play/Journey/World), focused sheets, reduced-motion | Pure seam consumed by `Panel.qml` | `UxModel.js` |

### Async jobs / queue handlers

None in this repo. DailyXP is local-only and synchronous today. Future hosted jobs (notifications, rankings, sync fan-out) belong in `da5ater/dailyxp-api` and are not yet specified — see wayfinder `aws-zero-spend.md` and `social-competition.md`.

### Test names (137 — grouped)

#### `event_model.test.js` (14)
- RFC4122 v4 from injectable source, `isUuidV4`
- Freezes UTC/timezone/offset/localTime/DailyXP date
- Derives verified local context from system clock
- Computes `dailyXpDate` without consulting current timezone (Day Boundary 04:00)
- Rejects invalid context (`occurredAtUtc`, `timezone`, `dayBoundaryMinutes`, `payload`)
- Append immutable + idempotent by `eventId`
- Rebuild deterministic + ignores duplicate IDs
- DST + Day Boundary changes cannot move frozen history
- Prototype-like keys (`__proto__`, `constructor`) retained safely
- Occurrence identity from frozen date
- Canonical export round-trips + replays offline
- Malformed/unsupported retain exact `originalRaw` + `recoverable`
- V0 migration returns `backupRaw` + deterministic V1
- Torn replacement restarts from envelope backup

#### `planning_model.test.js` (largest) + `planning_journal.test.js`
- Routine → Task Occurrence weekday/custom generation, `occurrenceKey(routineId, dailyXpDate)`
- Carryover → overdue without duplicating XP; completion/reschedule/skip/dismiss/archive/merge
- Repeated misses → smaller rescheduling proposal
- Proposal previewable/editable; only acceptance mutates plan; dismissed interval respected
- Goal/Milestone reward locking, urgency/deadline/skill associations

#### `session_model.test.js` (largest) + `session_journal.test.js`
- Single active Session invariant
- Selection ≠ start; delayed reminder not auto-start
- `startSession` / `pause` / `resume` / `finish` / `discard` / `changeTask`
- Backward wall-clock jump cannot subtract/double-count focused time
- `inactivity` prompts without capturing keys/screens/URLs; confirm-to-include
- Planned vs open-ended; beyond-planned requires confirmation before competitive XP
- Cross-boundary Session belongs to majority day (sliced by frozen Day Boundary)
- 12 focused hours / DailyXP day capped for competitive XP
- Correction freely within 24h, then auditable `session.corrected`; re-slices by original boundary/zone/DST
- Correction cannot create future/overlapping history; finish instant frozen

#### `habit_model.test.js` + `habit_journal.test.js`, `recovery_model.test.js`
- Habit scheduling + streak; Recovery Tracks vs Habits separation; relapse ends Attempt only on explicit record

#### `progression_model.test.js`, `story_model.test.js`
- Lifetime XP `500+50*level` per Level, Season XP capped, Recovery XP separate; `XP Ledger` explainable
- Province/landmark mapping; Momentum Dormant→Legendary; Hollow King only unfinished territory; Comeback Quest 7→3 days

#### `feed_model.test.js`, `insight_model.test.js`, `share_model.test.js`
- Bounded sound/notifications; stats; share cards never auto-post

#### `state_model.test.js`, `state_store_recovery.test.js`, `ux_model.test.js`
- Envelope primary/backup recovery, generation tie-break, torn-write preservation
- `UxModel.project` frozen/deterministic; Play/Journey/World navigation without dashboard; focused sheets; `prefers-reduced-motion` → fade + legible scale

### UI screens / forms / interactions

No HTTP-routed screens — QML surfaces rendered by the Omarchy shell host (not a browser):

| Surface | Component | Entrypoint | Notes |
|---------|-----------|------------|-------|
| Bar widget | `BarWidget.qml` | `manifest.json → barWidget: BarWidget.qml` | Per-monitor; shows crest/Level, selected Task, elapsed/planned, pause/resume, crest/Achievement transform, offline/sync |
| Play | `Panel.qml` — Play section + focused sheets | `UxModel.currentSurface = Play` | Dominant daily interaction: selected Task + Session controls, Today's occurrences, Habits, protected Recovery Tracks, collapsed overdue |
| Journey | `Panel.qml` — Journey section | `UxModel.currentSurface = Journey` | Crest/Level/Story Rank, Momentum, Province/kingdom map, Achievements, stats, Skill mastery, share |
| World | `Panel.qml` — World section | `UxModel.currentSurface = World` | Fixtures, Division, nearby ranks, Skill Leagues, Guild, Groups/Circles discovery |
| Focused sheets | `Panel.qml` sheets via `UxModel` | Triggered from Play/Journey/World | Create/edit Goals/Milestones/Tasks/Routines/Habits/Recovery Tracks; settings behind avatar |

Form fields are QML-bound, not HTML `<form>` — inferred from `PlanningModel`/`HabitModel`/`RecoveryModel` field sets (Goal targetDate/skill/reason, Task estimate/urgency/deadline, Routine weekdays/custom + carryover, Habit schedule, Recovery Track privacy). No `<Table>` routes today; lists live inside the panel.

### Documented features

| Title | Source | Description |
|-------|--------|-------------|
| Life-gamification product thesis | `README.md` + `CONTEXT.md` | Omarchy-first for focused work, goals, habits, recovery, social competition, comeback story |
| V1 PRD (Revised) | `docs/design/dailyxp-v1.md` (1036 lines) | Goals/non-goals/principles; 3 surfaces (Play/Journey/World); planning hierarchy; Sessions with Day Boundary; XP economy; kingdom story; Leagues/Groups/Guilds; sharing; local-first; honest releases; portable contracts |
| Agent contract | `AGENTS.md` + `docs/agents/domain.md` + `docs/agents/issue-tracker.md` | Research/design/impl/verification ownership; Wayfinder in chat, executable issues only after PRD; discovery out of Issues; `/simplify` pass + improvement skills before review |
| 12 model docs | `docs/event-model.md`, `planning-model.md`, `session-model.md`, `habit-model.md`, `recovery-model.md`, `progression-model.md`, `story-model.md`, `share-model.md`, `feed-model.md`, `insight-model.md`, `ux-model.md`, `release-evidence.md` | Per-domain contracts (event journal, planning, sessions, habits/recovery, XP, story, share, feed, insight, UX, competition evidence) |
| Wayfinder destination | `.scratch/wayfinder/map.md` | Produce implementation-ready spec preserving accepted vision for dependency-ordered tickets |
| Repository topology | `.scratch/wayfinder/repository-topology.md` | `da5ater/dailyxp` canonical product/Wayfinder/PRD/plugin, `da5ater/dailyxp-api` separate Rails+AWS; no generated publishing automation in V1 |
| Accepted contract | `.scratch/wayfinder/accepted-contract.md` | Accepted product/ownership/privacy/narrative/delivery decisions vs still-to-refine boundaries |
| Zero-spend AWS | `.scratch/wayfinder/aws-zero-spend.md` | Free Plan hard boundary USD 158.07 → 2027-01-28, us-east-1; local-first public-alpha; credits ≠ auth |

## Coverage gaps

The scanner could **not** determine these — they need human review or stakeholder interviews:

- **Business rules embedded in JS logic** — XP award ordering, streak/momentum eligibility windows, Comeback Quest trigger exact thresholds (code is source of truth; doc paraphrase may drift)
- **Permission / moderation matrix for future hosted** — which roles can do what in Groups/Guilds/Circles/Leagues; report/block flows (deferred via wayfinder `social-competition.md`, `recovery.md`)
- **Sync protocol + retry + dead-letter** — local-first → Rails sync not yet implemented; no webhook signature scheme to audit
- **Configuration-driven behaviour** — Story Rank thresholds (Wanderer 1 … Sovereign 150) are constants today; feature-flag surface not yet designed
- **Implicit competition rules** — Season XP scoring per League type (global/geographic/Skill/private/Head-to-Head) lives in PRD prose, not yet in code
- **Data-cleanup / TTL / expiry** — account expiry, data export/deletion, backup/restore, observability yet to be specified (per wayfinder `map.md` Not yet specified)
- **Stale documented features** — cross-check PRD vs model docs vs `CONTEXT.md` glossary for Drift (e.g. `Store` vs `Realm` if any rename occurred)

## Recommended next steps

1. **Review this matrix with Mohamed** — reconcile with the Wayfinder intent; expect ~10-20% drift vs mental model (especially future hosted competition)
2. **Derive tickets per matrix row slated for V1** — use `/feature` for user-facing, `/task` for scaffolding, `/bug` only for broken behaviour; one PR per ticket (ApexYard SDLC)
3. **Identify smallest-coherent v1 subset** — bucket rows into `must v1` / `nice v1.x` / `defer/drop`; PRD honest-release principle favours a polished competition build before full V1
4. **Validate deferred buckets with the V1 PRD** — ensure deferred scope matches PRD non-goals (no healthcare, no DMs/comments, no ads, no purchasable advantage)
5. **Run `/journey` on the three surfaces** — preview Play/Journey/World flow before tech design; catches missing empty/error/transitions prose can't
6. **Use `/tech-vision dailyxp` to lock target architecture** — local envelope stays source-of-truth; Rails boundary, deployment (EC2 vs home server), and single-AZ trade-off

## Open questions

- Is the hosted service `da5ater/dailyxp-api` already created or still to be scaffolded via `/handover dailyxp-api`?
- Which Progressive marketplace checklist items remain before the 2026-08-24 10:00 Africa/Cairo deadline beyond `omarchy plugin validate` + `qmllint`?
- Does the QML `preference` for Day Boundary live only in `shell.json` plugin entry or also in a future account setting that syncs?
