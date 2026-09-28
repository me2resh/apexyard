---
id: AgDR-0179
timestamp: 2026-09-28T00:00:00Z
agent: platform-engineer
model: claude-sonnet-5
session: session_01KGvb2ba4gyT3TN8L2uMLTn
trigger: me2resh/apexyard#1446
status: executed
category: architecture
---

# ORBIT handoff creates one tracker issue per validated slice

> In the context of the `/orbit handoff` operation (apexyard#1446), facing the record-only boundary AgDR-0164 set for the `/orbit` adapter, I decided to permit exactly one tracker issue per validated execution slice, gated by a dry-run preview, a leak scrub, and an explicit operator confirmation, to achieve a working handoff from ORBIT planning into the ApexYard build flow, accepting that the adapter now performs one write against an external tracker.

## Context

- AgDR-0164 fixed the `/orbit` adapter boundary as record-only: "It does not create external tracker records, change source code, or execute slices."
- That boundary left `/orbit` planning with no path into ApexYard's ticket-first build flow. The ORBIT Plan for building with ORBIT in ApexYard (`plan-apexyard-orbit-build`, revision 3) names this gap directly: outcome `o1-slice-to-ticket` and its Reconciliation mark `ac1-6` and `ac1-12` as contradicted by AgDR-0164.
- Execution Slice `slice-plan-apexyard-orbit-build-o1-handoff` scopes the fix to one operation: `/orbit handoff` turns one validated slice into one issue, through the `orbit sync github` adapter that `orbit-spec` already ships.
- The write must stay bounded and observable: one issue per slice, never a batch, never silent, and never past a leaked private reference.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| Keep AgDR-0164's record-only boundary; require a human to file the issue by hand from the slice | No adapter change; boundary stays exactly as decided | ORBIT planning has no path into the ApexYard build flow; the gap the Plan names stays open |
| Let `/orbit` write any number of tracker records (issues, comments, labels) without a per-write gate | Most flexible for future ORBIT operations | Reopens the record-only boundary far wider than this slice's scope; no bounded review point before a write |
| Permit exactly one issue per validated slice, gated by dry-run preview + leak scrub + operator confirmation | Matches the slice's scope exactly; keeps the write auditable and reversible before it happens; duplicate-issue refusal keeps it idempotent-safe | Every future ORBIT write (e.g. the O3 Projects v2 board sync) needs its own amendment or a broader one |

## Decision

Chosen: **one tracker issue per validated slice, after preview, leak scrub, and confirmation**, because this is the exact shape the Plan's `o1-slice-to-ticket` outcome asks for, and each gate (dry-run, leak scrub, confirmation) keeps the single write bounded and reviewable before it happens.

This narrows AgDR-0164's decision text for one case only. AgDR-0164's decision text is not rewritten; this record adds the exception:

- The `/orbit` adapter remains record-only for every operation except `handoff`.
- `handoff` may create exactly one GitHub issue for one validated execution slice, using the existing single-issue `orbit sync github` adapter.
- `handoff` never edits, closes, or creates a second issue for the same slice; it refuses when an open issue in the target repo already carries that slice's ID.
- The write happens only after, in order: a dry-run preview, a leak scrub of that preview, and an explicit operator "yes".
- No other `/orbit` operation, and no skill other than `/orbit`, calls the ORBIT CLI or writes to an external tracker.

## Consequences

- `/orbit handoff` (apexyard#1446) can file one ticket from a validated slice without waiting on a broader tracker-write amendment.
- Later ORBIT slices that add new write paths — the sidecar mapping and idempotent re-handoff (ac1-7 to ac1-9), and the Projects v2 board sync (O3) — need their own AgDR, since this record's exception covers only the single-issue `handoff` write.
- AgDR-0164 stays intact as the general adapter-boundary decision; readers of AgDR-0164 need the "Partly superseded by" pointer added there to find this exception.

## Artifacts

- me2resh/apexyard#1446
- `docs/orbit/slices/slice-o1-handoff.json` (me2resh/apexyard#1447)
- `plan-apexyard-orbit-build.r3.json`, outcome `o1-slice-to-ticket`
