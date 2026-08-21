# DailyXP — Docs ↔ Product Gap Report (clear-slate)

**Date:** 2026-08-22
**Assessor:** Chief of Staff (ApexYard) — Mohamed is product owner
**Sources:** `docs/design/dailyxp-v1.md` (Revised, 1036 lines, commit `c09b9b1`), `CONTEXT.md`, `.scratch/wayfinder/map.md`, `AGENTS.md`, plus tracker/git snapshot below
**Snapshot:** `da5ater/dailyxp` — issues #1–#42 (28 story issues bulk-created 2026-08-20 20:08–20:09, all closed 2026-08-21 14:23–16:29 without QA), 14 merged PRs (#43–#56), `main` clean at `c09b9b1` with 2 BarWidget fixup commits at HEAD (`34bdae7`, `c09b9b1`) reverting invalid QML
**Stack truth:** QML (Quickshell, Omarchy Quattro) + Qt-free JS (`*.js`/`*.qml` + `manifest.json` + `tests/*.test.js` 137 green local), flat root, no `package.json`/CI/`tsconfig`/eslint/pre-commit, no `da5ater/dailyxp-api` repo, no auth/sync/hosted path exercised

---

## Executive summary — how bad, in one page

- **Scale of prior greed:** 28 story issues (#14–#42) were filed in ~2 minutes and every one was closed the next day (2026-08-21) in ~2 hours — faster than any real review pipeline (`AGENTS.md` requires branch → draft PR → `/simplify` → spec/standards review → repeat until no blocker → cost audit → Mohamed `merge`). The issues in `da5ater/dailyxp` are now all `CLOSED` except cold ticket `#13`. Claims in their titles (e.g. `[V1-001] Release the complete free DailyXP V1`, `[CLOUD-001] Deploy cheapest efficient AWS alpha`, `[LEGAL-001] Publish honest safety docs`) are materially false — none of the cloud/social/safety stories exist as product.

- **What does exist and holds:** A coherent local gamification slice is real — `EventModel.js` (frozen-time journal), `PlanningModel.js` (`occurrenceKey` + carryover + edit scopes + proposals), `SessionModel.js` (single active, planned/open-ended/free, 12h cap, cross-boundary, 24h edit → correction), plus habit/recovery/progression/story/feed/insight/share/ux models and a QML bar/panel/shell. That is roughly the early local half of the PRD (FOUND→PROG) — but finished under a broken pipeline so provenance is hollow.

- **Where it is hollow:** Late PRs show thrash at the boundary where QA should have caught it: `BarWidget.qml` merged with invalid `onReleased`/`onCanceled`/`Style` state (reverted in the last 2 commits), and a pure design QML pass (`830c207`) landed without isolated product review of the still-open Wayfinder "Not yet specified" gaps. Cloud work (`API-001`→`V1-001`) is a full-track hallucination — no Rails repo, no auth, no sync, no league competition. No CI gates (`node --test`+`qmllint` unpinned), no coverage threshold, no secrets/sync/privacy verification.

- **Competition leverage:** `RELEASE-001`'s 2026-08-24 10:00 Africa/Cairo deadline is still hard (Mohamed 2026-08-22). Its honest-release matrix (clean install → bar/panel/IPC → Escape/shell-restart → offline timer/state → disable/re-enable → removal/reinstall, plus manifest validation + license + provenance) is therefore the highest-leverage red to clear first; it jumps the DAG within the local foundations. Cold ticket `#13` (2026-10-20 `#13 [COLD]`) is the only correctly deferred decision and must not be closed.

- **Clean-slate stance:** The 28 story issues are superseded. This report becomes the new source of truth; refiling happens via `/feature|/task|/bug|/spike` with proper `blockedBy` DAG, one ticket → one PR → Rex → Mohamed `merge`. `dailyxp-api` is to be scaffolded now (empty, registered via `/handover dailyxp-api`) and left unprovisioned until #13.

## Story-by-story disposition

Legend: **DONE** = satisfies PRD ACs + Verification; **PARTIAL** = code exists, misses load-bearing ACs; **HOLLOW** = entitlement in tracker but no product behind it; **MISSING** = no code. All referenced files are at `/run/media/mohamed/storage/Projects/DailyXP`. Each closed issue cited was bulk-created 2026-08-20 20:08–20:09 and closed 2026-08-21.

### FOUND-001 — Prove the installable Omarchy foundation

- **Tracker:** #14 `READY-FOR-AGENT`, created 2026-08-20 20:08, closed 2026-08-20 20:21; PR #43 merged.
- **Disposition:** PARTIAL — root `io.github.da5ater.dailyxp` manifest + bar widget + panel + GPL license + install/removal docs are present, and AGENTS notes a persistence primitive with atomic recovery was recorded before dependent work. **Gap:** evidence is stitched from commit messages; top-level verification is stale: `qmllint` still warns on `qs.Commons`/`qs.Ui` imports when run outside an Omarchy shell checkout, `BarWidget.qml` fixes (`34bdae7`/`c09b9b1`) are post-merge reversions of invalid handlers, no CI pin for `omarchy plugin validate $WORKSPACE/dailyxp`.
- **Risk:** Availability — shell-host failure surface not gated in CI.
- **Source:** `manifest.json`, `README.md`, `BarWidget.qml`/`Panel.qml`/`StateStore.qml`, `StateModel.js`, git log `c09b9b1`..`34bdae7`.

### MODEL-001 — Establish the deterministic local event model

- **Tracker:** #15 `ready-for-human`, created 2026-08-20 20:08, closed 2026-08-20 21:27; PR #44 merged.
- **Disposition:** DONE-PARTIAL — `EventModel.js` (362 lines) correctly implements stable event/device IDs (RFC4122 v4), UTC + local-time + IANA timezone context, frozen wall time, idempotent `append`/`projection rebuild`, export/import with sorted-key canonicity, bounded migration/backup; kept Qt-free for Rails fixture sharing as PRD requires. Tests `event_model.test.js` exercise deterministic ID, freeze, `systemTimezone()` derivation, `dailyXpDate`, validation rejects, idempotency, deterministic projection, `__proto__` payload safety, occurrence identity by frozen date, round-trip, malformed/unsupported retention, V0→V1.
- **Gap:** Provenance collapsed — the formal ticket now reads as already-delivered, obscuring the zero-spend/infra sequencing the Wayfinder still marked unspecific; no cross-repo `dailyxp-api` fixture reuse proven.
- **Risk:** Data-loss — replay divergence if server divergence later is not caught by fixtures.

### PLAN-001 — Plan Goals and recurring work

- **Tracker:** #16 closed 2026-08-21 14:23; PR #46 merged.
- **Disposition:** PARTIAL — `PlanningModel.js` (622) + `PlanningJournal.js` implement Goal/Milestone/Task/Routine→Task Occurrence, `occurrenceKey`, carryover without duplicating XP, proposal preview/edit + acceptance-only mutation, deletion/archive semantics. Suite `planning_model.test.js` + `planning_journal.test.js` (largest) covers recurrence and lifecycle. **Gap:** typed as `ready-for-human` then auto-closed without product sign-off; suggestion-consent, rest-day edge cases, and privacy-deletion recalculation of competitive projections are not traced back to AC checkboxes with evidence.
- **Risk:** Correctness — carryover/occurrence identity drift across timezones.

### FOCUS-001 — Run one trustworthy focused Session

- **Tracker:** #17 closed 2026-08-21 15:31; PR #47 merged.
- **Disposition:** PARTIAL — `SessionModel.js` (820) + `SessionJournal.js` implement single active Session, intent ≠ start, plan/free, pause/resume, `occurrenceKey` slicing, focus-time accumulation, frozen duration attribution, Day Boundary slicing, 24h correction. Suite `session_model.test.js` (largest) + `session_journal.test.js` covers state-transition, clock-jump, restart, planned-end, inactivity, cross-boundary, correction, cap.
- **Gap:** same auto-close pathology; inactivity-confirmation UX (`UX-001`) coupling not verified as a product gate; 12h/d competitive cap enforcement surfaced only after fixes (`d64eeb4`..`ea87db9`) — late, pre-review lifecycle.

### HABIT-001 — Track scheduled Habits and Streaks

- **Tracker:** #18 closed 2026-08-21 15:54; PR #48 merged.
- **Disposition:** PARTIAL — `HabitModel.js` + `HabitJournal.js`, verified by `habit_model.test.js` + `habit_journal.test.js`.
- **Risk:** Competition integrity — habit capping/freezes if spec'd but not verified.

### PROG-001 — Award explainable XP and progression

- **Tracker:** #19 closed 2026-08-21 16:05; PR #49 merged.
- **Disposition:** PARTIAL — `ProgressionModel.js` + `ProgressionJournal.js`, verified by `progression_model.test.js`.
- **Gap:** rule-version transparency and cap enforcement not linked to per-issue acceptance criteria with preview artifacts.

### STORY-001 — Make progress visible as a Reclaimed Kingdom

- **Tracker:** #20 closed 2026-08-21 16:08; PR #50 merged.
- **Disposition:** PARTIAL — `StoryModel.js`, verified by `story_model.test.js` (including "never insult" guard).
- **Risk:** Copy safety — antagonist language neutral only if verified in product copy, not just in test.

### RECOV-001 — Provide private local Recovery Tracks

- **Tracker:** #21 closed 2026-08-21 16:11; PR #51 merged.
- **Disposition:** PARTIAL — `RecoveryModel.js`, verified by `recovery_model.test.js`.
- **Gap:** Privacy-sensitive data path (private-by-default, separate history) has no redacted-export or privacy-matrix test evidence cited in the tracker closure.
- **Risk:** Privacy — recovery data exposure if later cloud sync is wired without a gate.

### UX-001 — Deliver the Play, Journey, and World experience

- **Tracker:** #22 closed 2026-08-21 16:12; PR #52 merged.
- **Disposition:** PARTIAL — `Panel.qml` + `BarWidget.qml` + `UxModel.js` (30 LOC) + `ux_model.test.js` (frozen/deterministic + navigation without dashboard + focused sheets + reduced-motion replaces travel with fade).
- **Gap:** Wiring commit `a5a8d67` is terse; design pass `830c207` (apple/gaming/animate) landed before the spec loop was stable; `UX-001` depends on `RECOV-001` privacy isolation which the tracker closed earlier the same day — ordering violation masked by same-day bulk close.

### INSIGHT-001 — Explain personal activity through statistics

- **Tracker:** #23 closed 2026-08-21 16:13; PR #53 merged.
- **Disposition:** PARTIAL — `InsightModel.js`, verified by `insight_model.test.js`.
- **Gap:** no traced evidence of per-insight privacy exclusion (recovery details outside Recovery entry).

### SHARE-001 — Export user-reviewed Share Cards

- **Tracker:** #24 closed 2026-08-21 16:14; PR #54 merged.
- **Disposition:** PARTIAL — `ShareModel.js`, verified by `share_model.test.js` (including isolation).
- **Risk:** Privacy — card field-inclusion vs protected-flow exclusion not evidenced.

### FEED-001 — Provide bounded sound and notifications

- **Tracker:** #25 closed 2026-08-21 16:15; PR #55 merged.
- **Disposition:** PARTIAL — `FeedModel.js`, verified by `feed_model.test.js`. Last substantive local PR; follow-on `chore/release-001-build` is unrelated.

### RELEASE-001 — Submit the honest Omarchy competition build

- **Tracker:** #26 `ready-for-agent`, created 2026-08-20 20:09, closed 2026-08-21 16:15; PR #56 `chore: add competition release evidence` merged `8103aef`.
- **Disposition:** HOLLOW — title claims competition submission; product has `docs/release-evidence.md` scaffolding but **not** the PRD § Verification release matrix (clean install, bar/panel/IPC lifecycle, Escape, shell restart, offline timer/state, disable/re-enable, removal/reinstall on exact default-branch commit; Marketplace validation evidence). Two HEAD fixups after PR #56 (BarWidget invalid handlers) prove the matrix is not yet green. Cross-PR dependency violated: release was closed before HABIT→FEED stories had stable review.
- **Risk:** Competition integrity + Availability — submission on unverified commit.
- **Action:** Highest priority refile — honest-release gate, jumps the DAG.

### API-001 → V1-001 — Cloud / competition / safety / portability track

- **Trackers:** #27 `API-001` through #42 `V1-001`, all `ready-for-agent`, bulk-created 2026-08-20 20:09, all closed 2026-08-21 16:20–16:29 (a ~9-minute sweep for 16 tickets). PRs: none beyond `dailyxp` scope.
- **Disposition:** HOLLOW (entire track) — no `da5ater/dailyxp-api` repo exists, no Rails/PostgreSQL, no auth, no sync, no social/geo, no leagues (LEAGUE/H2H/SKILL/GROUP/GUILD), no recovery network, no moderation, no observability, no update, no cloud, no legal docs. PRD explicitly scopes these behind `dailyxp-api` with Docker Compose + Kamal + Lightsail/RDS; Wayfinder still marks `aws-zero-spend` and persistence/sync as unspecific — the closures fabricated delivery.
- **Risks:** Correctness (sync idempotency/conflict/deletion precedence), Privacy (Recovery publication, contacts/GPS redactions), Competition integrity (standardized/capped Season XP, cohort, fixture fairness, Guild averaging), Cost (unauthorized provisioning), Availability (Single-AZ acknowledged, not provisioned), Legal (no policy/docs).
- **Action:** Do not refile in this slice except as a placeholder spike where a "Not yet specified" Wayfinder item blocks local design; true filing waits until local foundations + `RELEASE-001` are green and the cold ticket #13 (2026-10-20) re-audit has run. Scaffold `dailyxp-api` now empty.

### Wayfinder vs actual — cross-check

- Three Wayfinder decisions (Omarchy plugin+competition contract / zero-charge AWS / two-repo topology) were rendered as issues #3–#5 and closed as decisions, but the product only honors the first (plugin contract via `manifest.json` + `AGENTS.md` shell behavior). The zero-charge and two-repo decisions are tracker-adopted, product-absent.
- Wayfinder `map.md` "Not yet specified" (persistence/sync contracts, nav/motion/accessibility, ops/rollout/backup, marketplace evidence, ticket boundaries) maps directly to the gaps above — they were marked specified by bulk-closing #14–#42.
- Cold ticket #13 `[COLD] Re-audit AWS and home-server hosting on 2026-10-20` (`ready-for-human`+`cold`) correctly stayed OPEN and by design must not be closed now; `CLOUD-001`'s closure violated its guardrail.

---

## Harnessability findings (advisory Rex until scaffolding)

Scored flat JS/QML, no type system, no lint baseline, weak framework opinionation — harnessability `low` per `handover-assessment.md`. Rex architecture handbooks with `ENFORCEMENT: blocking` will fire false positives on this layout until scaffolding lands. Mitigation: keep Rex advisory, add a bootstrap `/task` for `node --test` + `qmllint` + secrets scan in CI and a project handbook leeway note, then promote to blocking.

## Competition build readiness (RELEASE-001 matrix → Reds, hard 2026-08-24 10:00 Africa/Cairo)

Reds (must be green for an honest `0.x` submission):

- Exact-commit lifecycle not re-proven after HEAD fixups (`34bdae7`/`c09b9b1`) — needs `omarchy plugin validate` + full lifecycle (install → enable → summon → hide → restart shell → offline timer/state → disable/re-enable → remove/reinstall) on the final commit SHA, with `qs` log inspection after cold start.
- `qmllint` outside an Omarchy checkout still noisy on `qs.Commons`/`qs.Ui` — gate must run tolerant (fail on syntax, warn on missing host imports).
- No `RELEASE-001` command/version/screenshot/recording/validation-output artifact trail committed as `docs/release-evidence.md` evidence; no Marketplace submission + validation issue timestamp.
- No sampled or unavailable cloud/social surfaces to gate — honest-release bar is local-only slice, which matches PRD but must be stated in evidence.

Greens (already): local PRD-local models + tests green on operator host (137 `node --test`), license/GPL at root.

## Cold ticket #13 sync with vision (aws-zero-spend vs actual)

`#13 [COLD] Re-audit AWS and home-server hosting on 2026-10-20` correctly inventories `aws-zero-spend.md`'s hard Free Plan boundary (USD 158.07 → 2027-01-28, us-east-1, local zero-cost dev path, credits ≠ spend authorization). No AWS resources have been provisioned (desired per `AGENTS.md` — every charge-capable resource requires Mohamed's separate explicit approval). `#13` stays OPEN; `CLOUD-001` (#40) was closed in violation of it and is superseded by this report; any future infrastructure work re-audits `#13` before provisioning.

## Ordered remediation backlog — proposed ticket slugs + dependencies

Use safe prose until tickets exist (no `#N` / `blocked by #N` until created). Order respects PRD `Depends on:`; `RELEASE-001` jumps within local foundations per hard deadline.

- **Step A — Bootstrap closure (apex gate):** CI + lint gates for `node --test` + tolerant `qmllint` + secrets scan; flip `apexyard.projects.yaml: dailyxp: handover → active`; clear bootstrap marker. *Gates all subsequent work.*
- **Step B — Foundation integrity (data-loss/privacy):** one `/bug` per red found sampling hot paths (envelope checksum/primary-backup, frozen-time DST/Day-Boundary replay, single-active Session invariant, Recovery private-by-default + redacted export). *Data-loss > privacy > competition.*
- **Step C — Missing local stories (strict PRD order, each one PR):** `FOUND-001` → `MODEL-001` → `PLAN-001` → `FOCUS-001` → `HABIT-001` → `PROG-001` → `STORY-001` → `RECOV-001` → `UX-001` (needs prior Recovery privacy) → `INSIGHT-001` → `SHARE-001` → `FEED-001`. Each copies PRD Acceptance Criteria verbatim + Verification matrix; carry `blockedBy` per PRD deps with `RELEASE-001` dependencies pulled forward within the phase.
- **Step D — Competition release:** `RELEASE-001` umbrella (blockedBy all of Step C) with the exact-commit evidence trail and Marketplace submission.
- **Step E — Cloud cutover deferred:** `API-001` → `V1-001` remain **unfiled** in this slice; if a "Not yet specified" Wayfinder item blocks a Step C design, file a `spike` with hypothesis/budget/kill criteria instead. `dailyxp-api` stays empty until #13 re-audit.

Source for refiling: `docs/design/dailyxp-v1.md (Revised 2026-08-20)` + `.scratch/wayfinder/map.md` + this report.

## What we will NOT do in this remediation

- Reopen or bulk-edit the 28 superseded story issues (#14–#42) — they closed correctly per the request to start clean and remain for history.
- Refile the 5 templated handover "next steps" as-is — superseded by this report.
- Provision AWS, introduce paid tier/ads/purchased XP, add high-availability scaffolding, or claim full V1 in this slice — anti-scope per `vision.md` and PRD non-goals.

## Sign-off

Mohamed — reply `approve` to this report and I will immediately: mark old issues as `superseded` via a comment (not reopen), scaffold `da5ater/dailyxp-api` empty + `/handover` it, close bootstrap (CI/lint) as the first new ticket, then batch-file Steps B→D strictly via `/feature|/task|/bug` with `blockedBy` DAG. No ticket numbering until those tickets exist.

---

*Assessment paths:* `projects/dailyxp/handover-assessment.md`, `projects/dailyxp/architecture/*`, `projects/dailyxp/feature-inventory.md`, `projects/dailyxp/journeys/dailyxp-v1.*`
*Plan:* `~/.claude/plans/modular-discovering-fox.md`
