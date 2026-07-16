# Store the teach-in-context glossary as a structured markdown sibling asset `docs/onboarding/glossary.md`

> In the context of the increment-2 education layer needing a plain-language glossary that three separate consumers read (the just-in-time asides in `/onboard`, the full render in `/tutorial`, and the on-demand single-term lookup in any session), facing the PRD Open Question of *where the glossary content lives* (FR-4: "reusable across skills, not locked inside the new flow"), I decided to store it as a **structured markdown sibling** `docs/onboarding/glossary.md` — one term per stable heading anchor — rather than appending a `## Glossary` section to the existing tour asset or introducing a structured data file, to achieve single-source content that is both human-editable and individually term-addressable, accepting that a light heading/anchor convention must be documented so the per-term readers can extract one entry without a markdown parser.

## Context

Increment 2 of the guided-onboarding initiative (technical design: `docs/technical-designs/onboarding-increment-2.md`, ticket #912) adds the teach-in-context education layer the increment-1 walking skeleton deferred. Its central content artifact is a plain-language glossary for the five core SDLC terms — **issue/ticket, PR, merge, branch, CI** — each 1–3 sentences with no jargon-on-jargon (FR-4 / US-4 AC).

Increment-1's design (§ D3) already pre-established `docs/onboarding/` as the seam directory and explicitly left the storage shape to this design: *"Increment 2 adds a sibling `docs/onboarding/glossary.md` consumed by the same two skills plus the on-demand lookup — the directory is the seam"* and, in its Open Questions, *"Where does the plain-language glossary content live (sibling `docs/onboarding/glossary.md` vs appended to the tour asset)?"*.

The distinguishing constraint versus the tour asset (`capability-tour.md`, rendered whole, in order): the glossary has **three consumers with three different read granularities**:

1. `/onboard` guided-mode asides (#913) — read **one** term's plain-language sentence at its first encounter.
2. `/tutorial` full glossary (#915) — render **all** entries, in depth mode.
3. On-demand lookup (#915, FR-8) — resolve **one** term the adopter names in any session.

That "read one entry, addressably" requirement is what makes the storage shape an architecture-class call rather than an authoring detail.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| **A. Append a `## Glossary` section to `docs/onboarding/capability-tour.md`** | No new file; the tour asset already anticipated it | Couples two assets with different render cadences (tour = rendered whole and in order; glossary = read per-term); a single-term aside read would have to slice a sub-section out of a larger file; grows the "60-second tour" asset into a mixed-purpose document, muddying `/tutorial`'s "render the tour" contract |
| **B. Structured data file** (`glossary.yaml` / `glossary.json`: `term → definition`) | Trivially machine-addressable per term; unambiguous keys | Breaks the framework's asset convention (every shared content asset — `capability-tour.md`, `templates/audits/<dim>.md` — is human-readable markdown); harder for a non-engineer maintainer to edit; needs `yq`/`jq` present to read, adding a dependency to a plain-text lookup; no natural place for the "no jargon-on-jargon" prose nuance |
| **C. Structured markdown sibling `docs/onboarding/glossary.md`** — one term per stable `###` heading anchor + a machine-greppable term-key line *(chosen)* | Single source of truth in the same markdown idiom as `capability-tour.md`; human-editable by anyone; per-term addressable via the heading anchor (a reader greps `### issue / ticket` … up to the next `###`); `/tutorial` renders the whole file, asides/lookups slice one anchor; sits in the already-established `docs/onboarding/` seam | Requires a documented heading/anchor convention so the three readers extract consistently; a light contract, not a parser |

## Decision

Chosen: **Option C — a structured markdown sibling `docs/onboarding/glossary.md`**, one entry per stable `###` heading, mirroring the shape and MIT-header convention of its sibling `capability-tour.md`.

The read contract (documented in the design § "Shared glossary asset — read contract"):

- Each of the five terms is one `###` section with a **stable, lowercased anchor** — `### issue / ticket`, `### PR (pull request)`, `### merge`, `### branch`, `### CI (continuous integration)`.
- Each section carries a machine-greppable key line as its first line — `<!-- term: issue,ticket -->` — so a per-term reader (aside or lookup) can locate the entry by key without positional assumptions, and one entry can serve multiple surface spellings ("issue" and "ticket" resolve to the same anchor).
- Body is 1–3 plain-language sentences, no jargon-on-jargon (any term used inside a definition that isn't itself common English is inlined or is one of the other five).
- `/tutorial` (#915) renders the whole file in order; `/onboard` asides (#913) and the on-demand lookup (#915) slice a single anchored section by its `term:` key.

Rationale for C over B: the framework's established precedent is that **shared content is markdown, not data** (`capability-tour.md`, the audit templates) — an adopter or a non-technical maintainer must be able to reword a definition without touching a data schema, and reading one plain-text section needs no `yq`/`jq` on the path. The heading-anchor + `term:` key gives Option B's addressability without Option B's dependency and readability costs. Rationale for C over A: keeping the glossary a separate file preserves `/tutorial`'s clean "render the tour" contract from increment 1 and lets the two assets evolve on their own cadence — the tour stays a 60-second orientation; the glossary is a per-term reference.

## Consequences

- New shared asset `docs/onboarding/glossary.md` authored under #913 (M5), with the five-term structured shape above. It is framework-static content, identical across forks (no adopter-specific data), same as `capability-tour.md`.
- Three consumers read it, none embed its prose: `/onboard` guided asides (#913), `/tutorial` full glossary (#915), the on-demand lookup rule (#915). The no-duplication discipline from increment-1 D3 extends to this asset — the reusability guard is structural.
- `capability-tour.md` is **unchanged** by this decision — its increment-2 forward-reference comment (which floated "append a `## Glossary` companion") is resolved in favour of the sibling file; the tour section stays a stable anchor exactly as increment-1 D3 promised.
- The heading-anchor + `term:` key convention is a documented read contract, not enforced by a parser — a Rex/QA review checkpoint (like the increment-1 tour reusability spec), not a hook.
- Increment-1's `docs/onboarding/` directory choice is validated: the seam it pre-established is exactly where this asset lands, no new directory decision needed.

## Artifacts

- Technical design: `docs/technical-designs/onboarding-increment-2.md` § "D1" and § "Shared glossary asset — read contract"
- PRD: `docs/prds/onboarding-overhaul.md` (#902 / #905) — FR-4, US-4, Open Question "Where does the plain-language glossary content live"
- Ticket: [me2resh/apexyard#912](https://github.com/me2resh/apexyard/issues/912) · build in [#913](https://github.com/me2resh/apexyard/issues/913) (glossary asset) and [#915](https://github.com/me2resh/apexyard/issues/915) (full render + lookup)
- Prior art: AgDR-0097 / AgDR-0098 (increment-1 shared-asset + shared-detector seams); increment-1 design § D3 (shared tour asset, author-once/consume-many)
- Related: AgDR-0101 (just-in-time first-encounter detection — the mechanism that reads this asset per-term)
