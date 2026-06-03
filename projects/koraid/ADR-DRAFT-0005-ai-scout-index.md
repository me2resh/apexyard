# ADR-0005 (DRAFT) — Pitch IQ Scout Index (AI assist, human primary)

**Status:** DRAFT — for review while **076** runs  
**Supersedes nothing; amends spirit of** [ADR-0002](https://github.com/Dr-kersho/koraid/blob/main/docs/adr/0002-scout-led-ratings-and-provenance.md)  
**Blocks:** Lane B code until sprint calibration sign-off ([PLAN-PARALLEL-LANE-A-B-2026.md](./PLAN-PARALLEL-LANE-A-B-2026.md))

## Context

CEO wants **both**:

1. **Lane A:** Stronger AI **evidence** (calibrated drills) + **human** scout scores (current `/scout`).
2. **Lane B:** **AI-generated scouting index** to shortlist players faster.

Spike ([SPIKE-CV-SCOUT-OVR-2026-05.md](./SPIKE-CV-SCOUT-OVR-2026-05.md)) confirmed: OVR ≠ scout score; CV today verifies drills, does not scout.

## Decision

Introduce **Pitch IQ Scout Index** — a **scout-only**, **AI-computed** composite (0–100 or 1–5) with **confidence** and **explainability**, subordinate to human judgment.

### Trust hierarchy (unchanged + extended)

| Rank | Signal | Set by |
|------|--------|--------|
| 1 | Scout event rating | Human scout (`SCOUT_EVENT_RATING`) |
| 2 | Coach / peer event ratings | Humans (ADR-0002) |
| 3 | **Pitch IQ Scout Index** | Model (new) |
| 4 | OVR / six stats | Merit drills (player + confirm flow) |
| 5 | Drill CV verify flags | Pitch IQ per drill |

### Rules (v1)

- **Never** auto-write human scout ratings.
- **Never** show Index on public FIFA card or player-facing hero (scout tools + optional sort only).
- **Never** label Index as “verified” or “scientific” until inputs meet calibration gates (076+).
- Index **must** list inputs: e.g. sprint CV pass, jump CV pass, % gold drills calibrated, clip pass count, self-report deltas.
- Scouts can **sort/filter** by Index with disclaimer: *“AI estimate — not a scout grade.”*
- Optional v1.1: “Use as draft” pre-fills human rating form; submit still requires scout confirm.

### Inputs (v1 formula — engineering to implement post-PRD)

Weighted composite from **calibrated** signals only:

- Silver: sprint/jump/agility `cvVerified` + confidence
- Gold: calibrated gold methods only (exclude passthrough)
- Clips: CV-pass count toward scout-ready
- Penalty: large self-report vs AI deltas (stat suggestion history)

Exact weights: PRD + calibration outcomes (076 MAE drives sprint weight cap).

## Alternatives rejected

1. **Rename OVR to “AI scout score”** — rejected; conflates merit card with scout judgment.
2. **Auto scout rating when Index &gt; X** — rejected; trust and minor safety.
3. **Ship Index before 076** — rejected (parallel but gated).

## Consequences

- New entities or fields: `scoutIndex`, `scoutIndexConfidence`, `scoutIndexExplain[]` (scout-readable).
- Scout search API: optional `sort=scout_index`.
- PRD ticket slice after ADR acceptance.
- Analytics: track human override rate.

## Open questions (PM → CEO)

1. Show Index to **players** as opaque “visibility score”? (default **no**)
2. Subscription: Index only for paid scouts? (default **yes** if subscription stub becomes real)
3. Minors: Index computed but hidden until parent/scout policy clear?

---

**Acceptance to move DRAFT → Accepted:** sprint calibration sign-off + CEO + Tech Lead review.
