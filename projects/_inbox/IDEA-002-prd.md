<!-- Source: ApexYard · templates/prd.md · github.com/me2resh/apexyard · MIT -->

# PRD: AI Parental Co-Presence — Mum, Dad & Baby Interfaces

**Status**: Draft
**Author**: Mariam (Product Manager)
**Created**: 2026-06-03
**Last Updated**: 2026-06-03
**IDEA ref**: IDEA-002
**Validation**: GREEN — `projects/_inbox/validation/IDEA-002-validation.md`

---

## Overview

### Problem Statement

When one parent is physically absent — travelling for work, on a night shift, or simply in a different room for the day — that parent is invisible to the child's day and disconnected from their partner's caregiving reality. The absent parent misses feeds, sleep windows, and milestone moments. The present parent carries the mental load alone. And underneath both of these, the couple's romantic relationship quietly erodes: conversations become handoffs, not connection.

Current tools split this into three separate problems with three separate apps: a baby tracker, a co-parenting notification tool, and a relationship app. None of them are aware of each other, and none of them speak in the family's voice.

**This product is one app that holds all three layers — and ties them together through AI personas that feel alive.**

---

### Target User

**Primary — The Absent Parent (typically the dad)**
A first-time parent of a child aged 0–18 months who works away from home, travels regularly, or works long shifts. They want to feel present in their child's day without constant phone calls that interrupt both parties. They want their partner to feel like they're still invested — not just informed.

**Secondary — The Present Parent (typically the mum)**
The parent carrying the primary caregiving load at home. They need practical AI-driven advice matched to their baby's exact age and current state. They want their partner to actually engage — not just receive notifications passively. And they want to remember, beneath the exhaustion, that they're still in a relationship.

**Tertiary — Expectant & new couples (pre-birth, 0–3 months)**
The highest-anxiety window. Couples who start using the app before birth will build habits that carry them through the hardest first months. Early acquisition here drives lifetime retention.

---

### Goals

1. **Co-presence**: ≥ 80% of absent parents view their child's live state at least once per day within 30 days of onboarding
2. **Communication lift**: Measurable increase in direct parent-to-parent messages (in-app) compared to week 1 baseline at the 6-week mark — the primary kill criterion inverted
3. **Advice engagement**: ≥ 60% of present parents act on at least one AI advice nudge per day (tap "done", log a response, or share with partner)
4. **Couple layer activation**: ≥ 40% of couples activate the partner-nudge feature within 14 days of onboarding
5. **Avatar engagement**: ≥ 70% of users open the baby avatar view at least 3 times per week in the first month

---

### Non-Goals (Out of Scope)

- **Medical diagnosis or clinical advice** — the AI gives developmental guidance, not medical recommendations. "Your baby may be going through a sleep regression" is in scope; "your baby has colic, try X medication" is not.
- **Social / community features** — no public profiles, no parent forums, no sharing outside the family unit in V1. This is an intimate family tool.
- **Multi-child support in V1** — designed for one baby. Second-child support is a V2 consideration once the core loop is validated.
- **Third-party integrations (health apps, wearables)** in V1 — data comes from parent-logged entries only. Wearable sync is a V2 infrastructure decision.
- **Divorce / separated co-parenting** — the couple layer assumes an intact romantic relationship. The separated-parent use case (OurFamilyWizard territory) is explicitly out of scope.
- **Web app** — mobile only (iOS + Android) at launch. A web companion is future scope.

---

### Success Metrics

| Metric | Target | How Measured |
|--------|--------|--------------|
| D30 absent-parent daily active rate | ≥ 80% | App analytics — absent-parent session on child's live state |
| 6-week inter-parent message volume vs. week 1 | ≥ +20% | In-app message count per couple |
| Advice action rate (present parent) | ≥ 60% daily | Tap events on advice nudge CTA |
| Couple layer activation (day 14) | ≥ 40% of couples | Feature flag on first partner nudge sent |
| Avatar weekly open rate | ≥ 70% of users | Avatar screen view events, 3×/week |
| App Store rating | ≥ 4.5 ★ | iOS App Store + Google Play rating at 90 days |
| D90 couple retention | ≥ 55% | Both parents active at day 90 |

---

## Product Architecture — Three Layers

### Layer 1: The Baby Persona

An AI-generated avatar built from the parents' uploaded photos. The avatar is not a novelty — it is the emotional centrepiece of the app.

- Generated from: mum photo + dad photo + optional baby photo (or generated from combined parent features pre-birth)
- Ages in real time: appearance, vocabulary, and personality shift week by week based on the child's date of birth and logged milestone data. A 6-week-old avatar looks and sounds different from a 9-month-old.
- Speaks in the baby's voice: feeds, sleep events, and milestones are narrated as first-person baby messages to each parent ("I just had 120ml and I'm feeling sleepy 😴 — Dad, I need you to set up the cot")
- Both parents see the same baby avatar but receive different messages tailored to their role and task list

### Layer 2: The Co-parenting Loop

Real-time synchronisation of the child's state between both parents.

- The present parent logs events (feed, sleep, nappy, mood, milestone)
- The absent parent receives an instant notification in the baby's voice
- Each parent has a role-differentiated task list: the present parent sees advice-driven next steps; the absent parent sees engagement tasks ("send a voice note", "read the bedtime story tonight")
- Both parents see the same timeline of the baby's day — eliminating "catch me up" conversations

### Layer 3: The Couple Layer

The layer that no competitor has. A relationship-wellness module running parallel to the baby tracking.

- Both parents log their own biological cycles (energy, mood, hormonal phase — optional, consent-gated)
- The AI uses this data to time couple-connection nudges intelligently — not pushing a romantic prompt when one partner is in a low-energy phase
- The absent parent's AI persona (the "partner avatar") flirts, checks in, and prompts small romantic gestures: "She hasn't heard from you today — send her something that isn't about the baby"
- The present parent receives these as notifications that feel like they're from their partner, not an algorithm
- The goal: parents remember they are a couple first, parents second

---

## User Stories

### US-1: Baby Avatar Creation

> As a new parent, I want to create an AI avatar of my baby from mine and my partner's photos, so that we have a living, evolving visual representation of our family that we both feel emotionally connected to.

**Acceptance Criteria**:

- [ ] Parent can upload their own photo and invite partner to upload theirs
- [ ] System generates a baby avatar within 60 seconds of both photos being submitted
- [ ] Avatar is visually distinct (not a literal face merge — a warm, illustrated persona)
- [ ] Avatar appearance updates automatically at key age milestones (newborn → 3m → 6m → 9m → 12m → 18m)
- [ ] Both parents see the same avatar in their respective interfaces
- [ ] Pre-birth parents can generate an avatar from parent photos alone; it updates when a baby photo is added

---

### US-2: Live Co-presence Notification (Present → Absent Parent)

> As the absent parent, I want to receive a real-time notification in my baby's voice every time my partner logs a care event, so that I feel present in my child's day without interrupting my partner with phone calls.

**Acceptance Criteria**:

- [ ] Notification arrives within 5 seconds of the present parent logging an event
- [ ] Notification text is generated in the baby's voice, matching the event type (feed, sleep, nappy, mood, milestone)
- [ ] Notification includes the baby avatar image at the current age
- [ ] Tapping the notification opens the baby's live state screen
- [ ] Absent parent can react with an emoji or a voice note; the present parent is notified of the reaction

---

### US-3: AI Parenting Advice (Present Parent)

> As the present parent, I want to receive AI-generated advice matched to my baby's exact age, current state, and recent activity log, so that I have a trusted guide through the hardest moments without having to search for answers.

**Acceptance Criteria**:

- [ ] Advice is contextualised to the baby's exact age in weeks, not just months
- [ ] Advice references recent log data (e.g. "You've logged 3 short naps today — this is typical for a sleep regression at this age")
- [ ] Advice is marked clearly as developmental guidance, not medical advice; links to "speak to your health visitor" when appropriate
- [ ] Parent can mark advice as "done", "not applicable", or "share with partner"
- [ ] "Share with partner" sends the advice to the absent parent's task list

---

### US-4: Absent Parent Task List

> As the absent parent, I want a personalised task list of small, meaningful actions I can take from anywhere, so that I stay engaged and my partner sees that I'm contributing even when I'm not physically present.

**Acceptance Criteria**:

- [ ] Task list is generated daily by the AI based on the baby's current state and the absent parent's logged availability
- [ ] Tasks are small and actionable remotely: send a voice note, read a bedtime story over video, write a message to read at bath time
- [ ] Completing a task notifies the present parent in real time
- [ ] Incomplete tasks carry forward and escalate with a gentle nudge after 24 hours
- [ ] Present parent can assign a custom task to the absent parent

---

### US-5: Couple Layer — Biological Cycle Logging and Partner Nudges

> As a parent who is exhausted and losing touch with my partner, I want the app to help me remember to be a partner — not just a co-parent — by sending me prompts to connect romantically at the right moment, so that my relationship doesn't silently deteriorate during the hardest year.

**Acceptance Criteria**:

- [ ] Both parents can opt in to logging their biological cycle / energy state (daily, 30-second check-in — optional, always skippable)
- [ ] The AI uses both parents' logged states to time romantic nudges; it does not prompt when either parent is in a logged low-energy state
- [ ] The absent parent's partner avatar sends one nudge per day maximum: a flirtatious or romantic prompt that does not mention the baby
- [ ] The present parent receives the nudge as a warm notification attributed to their partner ("A message from [name]")
- [ ] Both parents can disable the couple layer at any time without affecting the baby tracking layer
- [ ] All couple-layer data is stored separately from baby data and is not shared with any third party

---

### US-6: Avatar Aging and Milestone Celebration

> As a parent, I want to see my baby avatar evolve visually and verbally as my real baby grows, so that the app feels like a living record of my child's first years rather than a static tracker.

**Acceptance Criteria**:

- [ ] Avatar appearance and vocabulary update automatically at each developmental stage (newborn, 3m, 6m, 9m, 12m, 18m+)
- [ ] When a milestone is logged (first smile, first word, first steps), both parents receive a special celebration notification with an aged avatar moment
- [ ] Past avatar states are preserved in a timeline ("look back" feature — scroll back to see the 3-month avatar)
- [ ] Avatar personality traits are seeded from the parents' own photos and optionally from a short personality quiz on setup

---

### Edge Cases

| Scenario | Expected Behaviour |
|----------|--------------------|
| Only one parent has the app | App works in single-parent mode; co-presence features are dormant until partner joins; onboarding prompts partner invite |
| Partner invite declined | App continues as a solo baby tracker with AI advice; couple layer remains dormant |
| Baby photo uploaded differs dramatically from generated avatar | Parent can regenerate the avatar up to 3 times; after that, submit a support request |
| Both parents are the "present parent" (both home) | App detects no absent-parent session and switches to shared-timeline mode; task lists merge |
| Parent logs no events for 48+ hours | App sends a gentle re-engagement prompt; does not assume anything is wrong |
| Baby passes 18 months | App extends gracefully; avatar continues aging; advice layer shifts to toddler content |
| Couple layer triggers during a sensitive period (e.g. postpartum depression flag) | App detects repeated low-energy logging over 5+ consecutive days and replaces couple nudges with a signpost to mental health resources |

---

## Requirements

### Functional Requirements

| ID | Requirement | Priority | Notes |
|----|-------------|----------|-------|
| FR-1 | Photo-based AI baby avatar generation from two parent photos | Must | Core emotional hook |
| FR-2 | Avatar ages automatically at developmental stage milestones | Must | Retention mechanic |
| FR-3 | Real-time care event logging (feed, sleep, nappy, mood, milestone) | Must | Data foundation for all AI layers |
| FR-4 | Push notification to absent parent within 5s of event log | Must | Co-presence core |
| FR-5 | Notifications written in baby's AI voice, age-appropriate | Must | Differentiator |
| FR-6 | Role-differentiated interfaces (present parent vs. absent parent) | Must | UX architecture |
| FR-7 | AI parenting advice engine — age + context aware | Must | Value for present parent |
| FR-8 | Absent parent task list, AI-generated daily | Must | Engagement for absent parent |
| FR-9 | Couple layer — opt-in biological cycle logging | Should | Relationship differentiator |
| FR-10 | Partner nudge engine — timed romantic prompts | Should | Requires FR-9 data |
| FR-11 | Milestone celebration notifications with avatar moment | Should | Retention + delight |
| FR-12 | Look-back timeline of past avatar states | Should | Emotional stickiness |
| FR-13 | Partner invite flow (SMS / link) | Must | Growth mechanic |
| FR-14 | Voice note recording and playback between parents | Should | Intimacy layer |
| FR-15 | Offline mode — log events without connectivity; sync when back | Should | Reliability |
| FR-16 | Data export — full history as PDF/CSV on request | Could | GDPR compliance + trust |
| FR-17 | Multi-language support (Arabic, English at launch) | Should | Target market |

### Non-Functional Requirements

| Category | Requirement | Target |
|----------|-------------|--------|
| Performance | Push notification delivery latency | < 5 seconds p99 |
| Performance | Avatar generation time (initial) | < 60 seconds |
| Performance | App cold-start time | < 2 seconds on mid-range device |
| Security | All baby photos and personal data | End-to-end encrypted at rest and in transit |
| Security | Couple-layer data (biological cycles) | Stored in a separate, access-controlled data partition |
| Privacy | GDPR + COPPA compliance (child data) | Full right-to-deletion; no advertising use of baby data |
| Accessibility | WCAG 2.1 AA | Screen reader support for all core flows |
| Reliability | Uptime | 99.9% monthly |
| Scalability | Notification throughput | Handle 100k concurrent families at launch target |
| Platform | iOS minimum version | iOS 16+ |
| Platform | Android minimum version | Android 10+ |

---

## Design

### User Flow — Onboarding

```
[Download app]
      |
      v
[Sign up — name, email, baby's DOB (or due date)]
      |
      v
[Upload your photo]
      |
      v
[Invite partner — SMS link]
      |
      +---> [Partner joins + uploads their photo]
      |           |
      |           v
      |     [Baby avatar generated — both parents see it]
      |
      +---> [Partner skips — solo mode activated]
      |
      v
[Role selection — "I'm with the baby now" / "I'm away"]
      |
      v
[Personalisation — baby name, due date / birth date confirmed]
      |
      v
[First advice card delivered — age-appropriate]
      |
      v
[Home screen — baby avatar live state]
```

### User Flow — Care Event (Present Parent → Absent Parent)

```
[Present parent taps + Log Event]
      |
      v
[Select type: Feed / Sleep / Nappy / Mood / Milestone]
      |
      v
[Enter details — quantity, duration, notes (optional)]
      |
      v
[AI generates baby-voice notification copy]
      |
      v
[Push notification → Absent parent]
      |
      v
[Absent parent taps notification]
      |
      v
[Baby live state screen — avatar + recent events]
      |
      v
[Absent parent reacts: emoji / voice note / task complete]
      |
      v
[Present parent receives reaction notification]
```

### User Flow — Couple Layer

```
[Daily check-in prompt — "How are you feeling today?"]
      |
      v
[Parent logs energy/mood — 3-tap scale]
      |
      v
[AI reads both partners' logged states]
      |
      +---> [Both parents in good state → partner nudge eligible]
      |           |
      |           v
      |     [Absent parent receives: "A message from [name]" — romantic prompt]
      |           |
      |           v
      |     [Absent parent acts: sends voice note / message]
      |           |
      |           v
      |     [Present parent receives notification attributed to partner]
      |
      +---> [Either parent in low state → nudge suppressed]
      |
      +---> [5+ consecutive low-energy days → mental health signpost shown]
```

### Wireframes / Mockups

_To be authored by Iman (UX Designer) and Nour (UI Designer) in the design phase. Key screens: Home (baby avatar live state), Log Event, Baby Timeline, Partner Notification, Absent Parent Task List, Couple Check-in._

---

## Technical Notes

### Dependencies

| Dependency | Type | Status | Owner |
|------------|------|--------|-------|
| AI image generation API (avatar creation + aging) | External | To be decided — AgDR required | Tech Lead |
| AI language model (baby voice, advice engine, couple nudges) | External | To be decided — AgDR required | Tech Lead |
| Push notification service (FCM + APNs) | External | Standard — Firebase recommended | Backend |
| Real-time sync (WebSocket or similar) | Internal | Architecture decision required | Tech Lead |
| Photo storage (encrypted) | External / Internal | S3-equivalent with encryption at rest | Backend |
| Biological cycle + health data store | Internal | Separate partition — data governance decision | Backend + Security |

### Technical Constraints

- Baby photos and couple-layer data are **highly sensitive** — encryption at rest and in transit is non-negotiable; a security review is required before any data architecture goes to build
- Avatar generation latency must be managed with optimistic UI (show a generating state; don't block onboarding)
- Push notification reliability at scale is a first-class engineering concern — a missed "your baby just woke up" notification breaks the core promise
- COPPA applies: the app processes data related to children under 13; consent flows and data handling must be reviewed by legal before launch
- GDPR applies (UK/EU launch): right-to-deletion must cover all three data layers (baby, co-parenting, couple) independently

---

## Launch Plan

### Rollout Strategy

- [ ] **Closed beta** — 50 couples recruited via parenting communities (Mumsnet, Instagram parenting accounts); qualitative feedback on avatar emotional resonance and couple layer
- [ ] **Open beta (TestFlight / Play internal testing)** — 500 couples; quantitative validation of D30 co-presence metric and advice engagement rate
- [ ] **Soft launch** — iOS UK + Android UK; App Store and Play Store submission
- [ ] **Global launch** — English + Arabic; UAE + UK primary markets

### Go-to-Market

- **Acquisition hook**: the avatar creation flow is the shareable moment — "look what our baby avatar looks like" is organic social fuel. Build a share-to-Instagram/WhatsApp moment into avatar generation.
- **Retention hook**: the avatar aging milestone moments are push-worthy events that bring lapsed users back.
- **Referral mechanic**: the partner invite is the built-in referral loop — every present parent onboarded is a distribution event for one absent parent.

---

## Open Questions

| Question | Owner | Status | Resolution |
|----------|-------|--------|------------|
| Which AI image model produces the most emotionally resonant baby avatar without crossing into uncanny valley? | Tech Lead | **Spike pending** | SPIKE-001 + AgDR-0064 — fal.ai Flux, Replicate SD3/IP-Adapter, DALL-E 3; hybrid canonical chain |
| What is the right cadence for avatar aging updates — automatic on DOB milestone vs. triggered by parent confirming the milestone? | Product | **Resolved** | Automatic on DOB + parent can trigger early (`projects/nourish/DECISIONS.md`) |
| Should the couple layer be a separate subscription tier or bundled? | Head of Product | **Resolved** | Single family subscription — all layers bundled |
| What is the minimum viable couple-layer feature for V1 — full biological cycle logging or just a daily mood check-in? | Product | **Resolved** | Full cycle logging day one (grill 2026-06-10) |
| COPPA + GDPR legal review — who owns this and what is the timeline? | Head of Product / Legal | Open | Hard blocker before soft launch |
| What happens to the baby avatar and data if a couple separates? | Product + Legal | **Resolved** | Account fork — `projects/nourish/DECISIONS.md` |

---

## Timeline

| Milestone | Target Date | Status |
|-----------|-------------|--------|
| PRD Approved | 2026-06-17 | Pending |
| Tech Design Complete | 2026-07-01 | Not started |
| UX Flows + Wireframes | 2026-07-08 | Not started |
| UI Design (key screens) | 2026-07-15 | Not started |
| Avatar Generation Spike | 2026-06-24 | Not started |
| Backend Architecture AgDR | 2026-07-01 | Not started |
| Beta Build (Layer 1 + 2 only) | 2026-09-01 | Not started |
| Closed Beta | 2026-09-15 | Not started |
| Open Beta | 2026-10-15 | Not started |
| App Store Submission | 2026-11-01 | Not started |
| Soft Launch (iOS + Android, UK) | 2026-11-15 | Not started |

---

## Approvals

| Role | Name | Date | Status |
|------|------|------|--------|
| Product Manager | Mariam | 2026-06-03 | Author |
| Head of Product | Omar | | Pending |
| Tech Lead | Hisham | | Pending |
| Head of Design | Maha | | Pending |
| Security (COPPA/GDPR review) | Faisal | | Pending |
