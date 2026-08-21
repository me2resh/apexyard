<!-- Source: ApexYard · templates/architecture/sequence.md · github.com/me2resh/apexyard · MIT -->
<!-- Wayfinder + V1 PRD: FOCUS-001 — single active Session, pause/resume, inactivity, 12h cap, 24h edit window -->

# Sequence — Focused Session Lifecycle

> **Time-ordered walkthrough** of one DailyXP focused Session from selection through correction. Grounded in `docs/session-model.md`, `SessionModel.js` + `SessionJournal.js`, and `docs/design/dailyxp-v1.md` § Sessions and time. Audience: backend + frontend engineers debugging timer, caps, or cross-boundary attribution.

## Diagram

```mermaid
sequenceDiagram
    autonumber
    actor User
    participant Panel as Panel.qml (Play)
    participant Store as StateStore.qml
    participant Session as SessionModel.js
    participant Event as EventModel.js
    participant Notify as notify-send

    Note over User,Notify: Select intent — does NOT start time

    User->>Panel: select Task (optional: free Session allowed)
    Panel->>Store: set selectedWork { taskId?, skill }
    Store->>Event: createEvent task.selected (frozen timezone + Day Boundary)
    Event-->>Store: ok → append → atomic envelope
    Store-->>Panel: sessionStatus: selected, not running

    Note over Store,Notify: Delayed reminder (configurable) — not auto-start

    Store->>Notify: after delay: notify-send "Start / Change Task / Dismiss"
    Notify-->>User: actionable reminder
    alt User taps Start (or starts from panel)
        User->>Panel: Start Session
        Panel->>Store: session.start { plannedMinutes? }
        Store->>Session: startSession(selectedWork, plannedMinutes)
        Session->>Event: createEvent session.started (only one Session may run account-wide)
        Event-->>Store: append → commit
        Store-->>Panel: running — elapsed / planned, pause control visible
    else User dismisses or changes Task
        User->>Panel: Dismiss / Change Task
        Panel->>Store: dismissReminder / updateSelectedWork
        Store-->>Panel: reminder cleared; selection updated
    end

    Note over Panel,Notify: Running — pause / resume / inactivity / finish

    loop while running
        User->>Panel: Pause
        Panel->>Store: session.pause
        Store->>Session: pause(elapsed, wallClock)
        Session-->>Store: paused (wall-clock jump cannot subtract / double-count focused time)
        Store-->>Panel: resume control

        User->>Panel: Resume
        Panel->>Store: session.resume
        Store->>Session: resume()
        Session-->>Store: running again

        Session->>Session: inactivity prompt (no keys/screens/URLs captured)
        Session-->>Panel: confirm focused time
        User->>Panel: confirm / exclude inactivity
        Panel->>Store: session.confirmInactivity(included)
        Store->>Session: slice timeline, removing confirmed inactivity from focused total
    end

    alt planned duration passed
        Session-->>Panel: requires confirmation before further competitive XP accrues
        User->>Panel: confirm continuation
        Panel->>Store: session.confirmBeyondPlanned
        Store->>Session: allow beyond-planned minutes (still capped by 12h/day)
    end

    User->>Panel: Finish / Discard / Change Task attachment
    Panel->>Store: session.finish | discard | changeTask
    Store->>Session: finish(discard?) — freeze finish instant + timezone + Day Boundary
    Session->>Event: createEvent session.finished (or discarded)
    Event-->>Store: append → commit

    Note over Panel,Event: Finished — free edit 24h; cross-boundary + caps applied

    Session->>Session: slice by Day Boundary → attribute to day with most focused minutes
    Session->>Session: enforce 12 focused hours / DailyXP day — excess minutes earn no competitive XP
    Session->>Session: freeze 24h free-edit deadline (correction cannot roll deadline)

    User->>Panel: Correct Session (within 24h, freely; after, explicit adjustment)
    Panel->>Store: session.correct { revisedMinutes / excludedInactivity / finishInstant }
    Store->>Session: correctSession(correction) — normalize inactivity, re-slice by frozen boundary
    Session->>Event: createEvent session.corrected
    Event-->>Store: append → recompute XP ledger + kingdom delta (correction is auditable)
    Store-->>Panel: updated focused minutes + XP + story signal
```

## When this flow runs

- **Selection**: every time the user picks a Task (or explicitly starts a free Session) from Play — the bar widget mirrors `selected` state without opening the panel.
- **Reminder**: once per selection after the configured delay — local-only, `notify-send`, dismissible.
- **Running loop**: every active Session — only one may run across the account at a time.
- **Finish / correction**: every Session — `finish` freezes attribution; `correct` is available freely for 24 hours, then only as an explicit auditable adjustment.

## Failure modes

| # | Branch | Cause | Detection | Recovery |
|---|--------|-------|-----------|----------|
| 5 | `session.started` rejected | Another Session already running | `SessionModel` checks single-active invariant | Keep existing Session; surface "a Session is already running" |
| 7 | Reminder not delivered | `notify-send` missing / shell not running | Panel still shows Play entry | User can start directly from panel — reminder is non-blocking |
| 11 | Wall-clock jump (backward or forward) | Sleep/wake, manual clock change | `Session` diffs wall clock vs focused accumulation | Backward jump cannot subtract or double-count focused time (invariant) |
| 13 | Inactivity prompt ignored | User away | Session continues; inactivity accumulates | Confirm on return — included inactivity stays focused only if user confirms |
| 16 | Beyond planned without confirmation | User kept working past `plannedMinutes` | `Session` blocks competitive XP past plan | Require explicit tap before further competitive XP |
| 19 | Finish vs discard confusion | User ends early | `Session` distinguishes `finished` vs `discarded` | Discarded Sessions do not earn XP; finished ones do (then capped) |
| 21 | Cross-boundary Session | Session spans 04:00 Day Boundary | `Session` slices timeline by frozen `dayBoundaryMinutes` | Attribute to day with most focused minutes; `dailyXpDate` frozen on events |
| 22 | 12h cap hit | Very long day | `Session` caps focused minutes contributing to Season XP | Excess minutes ignored for competition; still recorded personally |
| 24 | Correction creates future/overlap | User edits to a time that overlaps another Session | `Session` validates `revisedDuration` against frozen timeline | Reject correction — keep prior history untouched |
| 25 | Late correction (after 24h) | User edits after free-edit window | `Session` marks `correct` as auditable adjustment | Apply as `session.corrected` with XP ledger correction, not silent edit |

## Notes

- **Idempotency.** Each verb appends a new event with a fresh `eventId`; `EventModel.append` deduplicates only on repeated `eventId`, not on semantic duplicate — the domain layer guards the single-active invariant separately.
- **Frozen context.** Correction re-slices across the *original* Day Boundary, timezone, and DST that were frozen on `session.started` — `rebuildProjection` never consults the current clock.
- **Privacy.** Inactivity confirmation prompts without capturing keys, screens, URLs, or content — per V1 privacy invariant.
