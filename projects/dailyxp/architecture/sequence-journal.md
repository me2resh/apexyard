<!-- Source: ApexYard · templates/architecture/sequence.md · github.com/me2resh/apexyard · MIT -->
<!-- Wayfinder-grounded: EventModel envelope + V0 migration + frozen Day Boundary -->

# Sequence — Journal Envelope & Atomic Save

> **Time-ordered walkthrough** of DailyXP's local persistence. Grounded in `docs/event-model.md`, `EventModel.js`, and `StateStore.qml` head. Audience: tech lead + backend engineer debugging startup or a torn write.

## Diagram

```mermaid
sequenceDiagram
    autonumber
    participant Shell as Omarchy Shell (Quickshell process)
    participant Store as StateStore.qml (service, once)
    participant Event as EventModel.js (Qt-free)
    participant FS as Local FS — $XDG_STATE_HOME/dailyxp/
    actor User

    Note over Shell,FS: Startup — recover + validate + migrate (once per shell launch)

    Shell->>Store: load service (manifest entryPoint: service)
    Store->>FS: read primary envelope + backup envelope
    FS-->>Store: raw bytes (primary, backup) + checksums

    Store->>Store: pick newest checksum-valid envelope<br/>(equal gen → prefer primary)
    alt neither envelope valid
        Store-->>Panel: stay available with actionable error — do NOT overwrite either file
    else one valid envelope
        Store->>Event: loadJournal(canonicalBytes.embeddedJournal)
        Event-->>Store: { ok, journal } OR { ok:false, originalRaw, recoverable:true } OR { migrated, backupRaw }
        alt load ok (incl. V0 migrated)
            Store->>Store: hold journal + backupRaw (if migrated) in memory
            Note over Store,FS: Panel reads sessionStatus / planningDayStatus from memory; no write yet
        else load recoverable failure (malformed / unsupported / invalid events)
            Store-->>Panel: error + originalRaw preserved — panel disables recording
        end
    end

    Note over User,FS: Steady-state — idempotent append + atomic envelope commit

    User->>Panel: addProbe / ensurePlanningDay / session verb
    Panel->>Store: request verb (omarchy-shell io.github.da5ater.dailyxp <verb>)
    Store->>Event: createEvent({ eventId, deviceId, occurredAtUtc, timezone, localDateTime, utcOffset, dayBoundaryMinutes, occurrenceKey, payload })
    Event->>Event: validate UTC round-trip, IANA zone, dayBoundary, frozen dailyXpDate
    Event-->>Store: frozen Event (or throw)
    Store->>Event: append(journal, event)  // immutable + idempotent by eventId
    Event-->>Store: newJournal
    Store->>Event: exportJournal(newJournal) // canonical sort + trailing newline → deterministic bytes
    Event-->>Store: canonicalBytes
    Store->>FS: atomic write: backup = old primary; primary = new canonicalBytes (generation++)
    FS-->>Store: fsync ok
    Store-->>Panel: status: planningDayStatus / sessionStatus ready

    Note over Store,FS: Failure during atomic write — recovery preserves a whole generation

    Store->>FS: write torn (process killed mid-replace)
    FS-->>Store: next launch: primary checksum invalid, backup valid → recover backup generation
    Store->>Store: never overwrite originalRaw until a validated replacement is durably written
```

## When this flow runs

- **Startup**: once when the Omarchy shell loads plugins — `StateStore.qml` is the `service` entryPoint, not per-monitor.
- **Every local verb**: `addProbe`, `ensurePlanningDay`, `sessionStatus`, and every domain verb that appends an event (Planning / Session / Habit / Recovery / Progression). All funnel through `createEvent → append → exportJournal → atomic envelope write`.
- **Recovery**: next launch after a torn write, a V0 legacy file, or a checksum mismatch.

## Failure modes

| # | Branch | Cause | Detection | Recovery |
|---|--------|-------|-----------|----------|
| 4a | Neither envelope valid | Both checksums fail (power loss, disk error, manual edit) | `StateStore` finds no valid generation | Show actionable error in panel; keep `originalRaw` byte-exact; panel disables recording until a valid journal is restored |
| 6b | Malformed / unsupported journal | Invalid JSON, unknown `schemaVersion`, failed `validUtcInstant` or `isUuidV4` | `loadJournal` returns `{ ok:false, recoverable:true, originalRaw }` | Keep `originalRaw`, do not overwrite source; surface message to user |
| 7a | V0 migration | Legacy `version:0` envelope from before canonical journal | `loadJournal` returns `{ migrated:true, backupRaw }` | Keep `backupRaw`; write migrated V1 only through the normal atomic commit |
| 11 | `createEvent` throw | Bad timezone, offset mismatch, `dayBoundaryMinutes` out of range, payload contains `undefined` | `Event` throws `field: reason` | Reject before append; no journal change |
| 13 | Torn atomic write | Shell killed between `backup = old primary` and `primary = new` | Next launch: primary invalid, backup valid | Recover newest valid generation; generation counter guarantees no partial apply |
| — | Double append with same `eventId` | Retried verb (shell resend) | `append` checks `appliedEventIds` | Second append is a no-op — same object returned (idempotent) |

## Notes

- **Idempotency.** `append` is idempotent by `eventId` — the shell may retry a verb safely. Canonical export is byte-identical for the same logical journal (sorted keys + one trailing newline).
- **Frozen time.** `dailyXpDate`, `context.timezone`, `utcOffsetMinutes`, and `dayBoundaryMinutes` are frozen on the event. Changing Day Boundary or DST never reinterprets history — `rebuildProjection` never consults the current clock.
- **No partial import.** Unsupported or invalid journals return `originalRaw` untouched — callers must not overwrite the source until a validated replacement is durably written.
- **QML `Intl` absence.** Wall time comes from `readlink /etc/localtime` + `Date`; recording is refused if an IANA zone cannot be proven.
