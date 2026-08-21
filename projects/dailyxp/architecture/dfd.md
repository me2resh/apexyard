<!-- Source: ApexYard · templates/architecture/dfd.md · github.com/me2resh/apexyard · MIT -->
<!-- Wayfinder-grounded for DailyXP: local-first envelope + future Rails host + Recovery sensitivity -->

# Data Flow Diagram — DailyXP

> **Trust boundaries + data crossings.** Input to a future STRIDE threat model (`/threat-model`). Grounded in `docs/event-model.md`, `docs/design/dailyxp-v1.md` § Privacy + Operational posture, and `.scratch/wayfinder/aws-zero-spend.md`. Audience: tech lead + security auditor.

## Diagram

```mermaid
flowchart LR
    user([Person])
    shell[/"Omarchy Quattro Shell<br/>(Quickshell process — unsandboxed)"/]

    subgraph device_zone["Device Zone — user-owned, offline-capable"]
        widget["Bar Widget<br/>(BarWidget.qml)"]
        panel["Panel<br/>(Panel.qml — Play / Journey / World)"]
        service["State Service<br/>(StateStore.qml — once per shell)"]
        journal["Event Journal<br/>(EventModel.js — Qt-free)"]
    end

    subgraph data_zone["Local Data Zone — most trusted on device"]
        envelope[("Primary / Backup Envelope<br/>$XDG_STATE_HOME/dailyxp/<br/>checksum + generation")]
        clock[("System Clock<br/>/etc/localtime → IANA zone<br/>Day Boundary 04:00")]
    end

    subgraph future_hosted["Future Hosted Zone — not yet implemented (da5ater/dailyxp-api)"]
        rails["Rails API<br/>(da5ater/dailyxp-api — planned)"]
        pg[("PostgreSQL<br/>Single-AZ in V1")]
        notify_srv["Notification / Ranking Service"]
    end

    ext_marketplace[("Omarchy Marketplace<br/>(plugin validation)")]
    ext_github[("GitHub<br/>(PRD + Wayfinder source)")]
    ext_notify[("Local notify-send<br/>(Session reminders)")]

    user -->|select Task, start/pause/resume/finish Session,<br/>record Habit/Recovery, plan Goals| panel
    user -->|glance / tap bar| widget
    widget -->|reads selected Task / Session state| service
    panel -->|omarchy-shell verbs<br/>ensurePlanningDay, sessionStatus, addProbe| service
    service -->|createEvent / append / exportJournal<br/>frozen UTC + IANA + Day Boundary| journal
    journal -->|canonical bytes (sorted keys, trailing newline)| service
    service -->|atomic write: backup = old primary<br/>primary = new generation + checksum| envelope
    envelope -->|recover newest valid generation<br/>equal gen → primary wins| service
    service -->|readlink /etc/localtime + Date<br/>derive wall time, offset, dailyXpDate| clock
    service -->|display validation + actionable error<br/>when envelope or journal invalid| panel
    service -->|Session reminder: Start / Change Task / Dismiss| ext_notify
    ext_notify -->|user action| service

    service -.->|future: sync journal — HTTPS<br/>local-first, offline-tolerant| rails
    rails -->|read / write user records| pg
    rails -->|rankings, Fixtures, Groups, Guilds,<br/>Recovery Circles (privacy-gated)| notify_srv
    rails -.->|future: pull sync + push notifications| service

    shell -.->|hosts: unsandboxed QML service| service
    shell -.->|hosts: bar widget per monitor| widget
    shell -.->|omarchy plugin validate| ext_marketplace
    service -.->|PRD + Wayfinder reference| ext_github

    %% Trust boundaries dashed
    style device_zone stroke-dasharray: 5 5
    style data_zone stroke-dasharray: 5 5
    style future_hosted stroke-dasharray: 5 5
```

Dashed subgraph borders are **trust boundaries**. Every arrow that crosses a boundary is a STRIDE candidate — that's where auth, data classification, and validation rules matter. Arrows are labelled with the data they carry; unlabelled arrows lose half their value. External actors and stores outside all subgraphs belong to other people's trust zones.

## Trust boundaries

| From | To | Authentication / integrity | Data classification |
|------|----|----------------------------|---------------------|
| **Person → Panel / Bar Widget** | Device UI | Physical device access (no network auth in V1) | Intent data: Goals, Tasks, Sessions, Habits, Recovery Tracks — user-owned, includes sensitive Recovery Tracks |
| **Panel / Widget → State Service** | In-process QML signals + `omarchy-shell` verbs | Same-process; no network hop — trust is the shell host boundary (unsandboxed) | Same as above — intent + derived XP/Story/kingdom |
| **State Service → System Clock** | `readlink /etc/localtime` + `Date` | None — trusts the OS symlink; `service` refuses recording if IANA zone not provable | Timezone name, UTC offset, `dailyXpDate` — frozen on event, never reinterpreted |
| **State Service → Envelope (FS)** | Checksum + generation counter + primary/backup | Backup-first atomic write; recovery picks newest valid; torn writes preserve a whole generation | Full journal — all personal history + Recovery Tracks (highest sensitivity on device) |
| **Envelope → State Service (recover)** | Validated on load | `loadJournal` validates JSON, `schemaVersion`, `eventId` v4, UTC round-trip, IANA pattern | Same — full journal |
| **State Service → notify-send** | Local DBus | None — trusts local session bus | Minimal: reminder title + action labels (`Start / Change Task / Dismiss`) — no content capture (no keys/screens/URLs) |
| **Device → Future Rails API** | *Future* — not yet implemented | *Planned*: TLS + bearer token (local-first, offline-queue then sync); PRD requires local-only without an account | Sync payload: journal events (incl. Recovery Tracks — opt-in Leagues only; personal/global/country/region Recovery Leagues explicit by design, per wayfinder `recovery.md`) |
| **Rails API → PostgreSQL** | *Future* — VPC-internal + DB creds from secrets store | *Planned*: IAM + Secrets Manager | Persistent user records — most sensitive hosted zone |
| **Rails API → Notification/Ranking** | *Future* — internal queue | *Planned*: queue ACL | Rankings, Fixtures, Congratulations — must not leak Recovery Tracks implicitly (sensitive-by-design invariant) |
| **Shell → Marketplace / GitHub** | TLS (server auth) | Marketplace plugin validation; GitHub as PRD source | Marketplace: plugin package; GitHub: V1 PRD + Wayfinder (not user data) |

## Notes

- **Local-first, no daemon, no second process.** The headless `StateStore.qml` runs once inside the existing Omarchy shell process. Installer is `omarchy plugin add ... --enable`; removal via `omarchy plugin remove` leaves `$XDG_STATE_HOME/dailyxp/` untouched (reinstall-safe).
- **Recovery sensitivity.** `Recovery Track` / `Recovery Attempt` / `Recovery Circle` are recorded through start/ongoing/relapse events, not as ordinary Habits (CONTEXT.md). Personal boards are always allowed; private/share is explicit; global/country/region Recovery Leagues are opt-in and category-moderated. Never make Recovery public implicitly.
- **Frozen time invariant.** Every event freezes `dailyXpDate`, `context.timezone`, `utcOffsetMinutes`, and `dayBoundaryMinutes`. DST or Day Boundary changes (default 04:00, configurable) never duplicate occurrences, Streaks, bonuses, or Season XP — projection rebuild never consults the current clock (docs/event-model.md).
- **Sensitive-by-design vs competition.** Concentration-style leaderboards use standardized, capped Season XP; sensitive categories have separate `Recovery XP` and privacy-gated Leagues. Grief/bullying controls (block, report, moderation ops) are future hosted concerns — trust boundary `Hosted Zone` already anticipates them.
- **Zero-spend guardrail.** Wayfinder `aws-zero-spend.md`: Free Plan hard boundary, throttled local-first public-alpha, credits ≠ permission to spend, no chargeable AWS provisioning without Mohamed's explicit approval (re-audit 2026-10-20, issue #13).
- **STRIDE priming** (each crossing → one threat class): Spoofing (can the service be impersonated?), Tampering (can the envelope or sync payload be modified?), Repudiation (can a Session/Recovery event be denied?), Information disclosure (what leaks if the hop is intercepted?), Denial of service (what if the shell, FS, or future Rails is overwhelmed?), Elevation of privilege (can a panel sheet escalate beyond focused-sheet scope?).

## References

- PRD: `docs/design/dailyxp-v1.md` (thesis + non-goals + planning/Sessions/XP/story/competition/sharing)
- Event contract: `docs/event-model.md` + `EventModel.js`
- Domain glossary: `CONTEXT.md` (single-context)
- Wayfinder: `.scratch/wayfinder/map.md` + `aws-zero-spend.md` + `recovery.md` + `social-competition.md` + `repository-topology.md`
- Threat-model skill: `.claude/skills/threat-model/SKILL.md` (consume this DFD)
