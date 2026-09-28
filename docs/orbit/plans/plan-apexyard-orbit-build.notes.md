# Notes for plan-apexyard-orbit-build (current: revision 3)

These notes sit beside the Plan record because the ORBIT v0.1 Plan schema has no fields for constraints, assumptions, or direction. The Plan record stays valid ORBIT.

## Constraints

- **C1. No hard dependency.** Every ApexYard gate and every skill that is not ORBIT-specific works without the ORBIT CLI. ORBIT paths fail closed with one install note.
- **C2. ApexYard governance wins.** ORBIT records cannot bypass tickets, reviews, review markers, or merges. No merge gate reads ORBIT records.
- **C3. Records stay valid ORBIT.** No schema fork. Tracker identities live in a sidecar mapping, not in canonical records. A needed schema change goes upstream to orbit-spec.
- **C4. Tracker writes need a preview and a confirmation.** Leak protection applies to every tracker write and to every record committed to a public repo.
- **C5. Small PRs.** One ticket per PR.

## Assumptions

- **A1.** The ORBIT CLI is not on npm yet. Operators install it from the orbit-spec repo.
- **A2.** The single-issue `orbit sync github` adapter is stable enough for a handoff of one issue per slice. Pin a known commit or tag.
- **A3.** This is one operator's workflow today. Adoption beyond that is not proven.

## Direction for a later revision

Revision 1 proposed a wider scope. A premise challenge found that it contradicted C1 and C3, and that it depended on provider features that do not exist yet. The wider scope stays as the long-term direction:

- The ApexYard planning and ticket skills use the ORBIT model internally, as their planning abstraction.
- The ORBIT hierarchy maps to tracker structure: a Plan to an epic, an outcome to a sub-issue, a slice to a ticket.

Preconditions before a revision takes this on:

- The ORBIT provider adapter supports hierarchy, lookup-based idempotency, and read-back, in a tagged release.
- Several real slice-to-merge cycles show that the handoff in this revision is not enough.
- A written rule states which system owns each field (ORBIT for intent, the tracker for checkbox and QA state).

## Follow-ups

- Structured epics and sub-issues for the ticket skills (#1269) stays a native tracker feature. ORBIT can use it later.
- Open an orbit-spec issue for hierarchy and idempotent sync support in the provider adapter.

## Revision history

- **Revision 2** added O1 (slice to ticket) and O2 (build traceability). The record is in `docs/orbit/history/`.
- **Revision 3** added O3 (the Plan hierarchy on a Projects v2 board: the Plan and outcomes as draft items, only slices as real issues) and O4 (ORBIT as the default planning path behind `orbit.default_planning`, shipped `false`). The CEO wants ORBIT as the default in their own process, so their fork sets the flag to `true`.

Revision 2 records move to `docs/orbit/history/` because `orbit validate --all` rejects two records with the same Plan ID in one record set.

## Upstream gaps found (file in orbit-spec)

- The Plan schema has no fields for constraints or assumptions. This notes file holds them instead.
- `orbit validate --all` cannot hold more than one revision of a Plan in the same record set.
- `orbit slice` does not copy repository commits from the Snapshot into `basedOn.repositories`, and it leaves `contributesTo` empty unless the operator passes `--contributes`.
- `orbit sync github` creates one issue and can add it to a board. It has no board hierarchy, no field setting, and no lookup-based idempotency (see O3).

## Validating the history records

`orbit validate --all` does not read `docs/orbit/history/`. To check a history record, validate it on its own, for example `orbit validate docs/orbit/history/plan-apexyard-orbit-build.r2.json`.

The snapshot records the local planning branch name. The commit `378623e` is the `dev` tip at snapshot time.
