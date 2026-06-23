# Backspace Architecture

Architecture package for the Backspace workspace operations initiative.

| Diagram / Document | Source | Last generated / written | Purpose |
|--------------------|--------|--------------------------|---------|
| [Architecture Vision](./vision.md) | `/tech-vision` shaped manually from PRD | 2026-06-23 | Target state, migration path, anti-scope. |
| [System Context (C4 L1)](./context.md) | `/c4` shaped manually from repo inspection | 2026-06-23 | Staff actors, system boundary, external/manual channels. |
| [Container (C4 L2)](./container.md) | `/c4` shaped manually from repo inspection | 2026-06-23 | Existing runnable units and data store. |
| [Data Flow Diagram](./dfd.md) | `/dfd` shaped manually from PRD + repo inspection | 2026-06-23 | Trust boundaries and sensitive data crossings. |
| [Visit Checkout Sequence](./sequence-visit-checkout.md) | `architecture/sequence.md` template | 2026-06-23 | Time-ordered visit to checkout flow. |

## Notes

- These are planning/design artefacts for the existing `workspace/backspace` codebase.
- They do not imply a stack replacement, external payment provider, or new app scaffold.
- Re-run the corresponding ApexYard skills after implementation changes the architecture materially.

---

_Generated as part of the Backspace ApexYard planning package on 2026-06-23._
