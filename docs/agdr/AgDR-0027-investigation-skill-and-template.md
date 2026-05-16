# Investigation skill — methodology choice, ticket-type vs label, live-doc vs after-the-fact

> In the context of ApexYard's existing ticket family (`/feature`, `/bug`, `/spike`, `/task`, `/migration`) covering greenfield work, immediate-fix work, hypothesis-driven exploration, technical work, and migration work — facing a missing scaffold for **sustained root-cause investigation** that produces a *written artefact* of how an unknown was resolved (incident retrospective, bug archaeology, regression hunt, performance mystery, competitive analysis) — I decided to ship a new **Investigation** ticket type with a **hypothesis-tree** methodology, a **live-doc evidence-gathering** workflow (the markdown file IS the working surface, not an after-the-fact retrospective), and a **Trigger / Hypothesis / Method / Findings / Conclusion / Follow-up actions** template shape, with template-resolution routed through `portfolio_resolve_template` so adopters can override the structure without forking the skill — to achieve a consistent reusable artefact for "why did this happen" work that future-us (or a teammate) can pick up mid-thread, accepting that the investigation ticket does NOT close itself on PR merge (it closes only when every Follow-up action either lands or is explicitly dropped), that the hypothesis-tree methodology is opinionated (Five Whys and Fishbone fans will see their methodology absent from the template by default), and that the skill ships without a `/investigation-close` companion (the Follow-up actions section IS the close gate, prose-only).

## Context

Three problems pointed at the same gap:

1. **No home for written investigation artefacts.** `/spike` handles hypothesis-driven *forward-looking* exploration ("does this approach work?"). `/bug` handles immediate-fix scenarios. `/debug` is a *process* helper for live debugging sessions. None of them produces a structured *written record* of "this is what we observed, here's the data, here's what we conclude" — the documentation shape that incident retros, bug archaeologies, and regression hunts need. Operators end up writing freeform docs that look different every time and rot in a `docs/notes/` folder nobody searches.

2. **Methodology shopping.** Root-cause work has three well-known methodologies — Five Whys (Toyota / Lean), Fishbone / Ishikawa, Hypothesis Tree. Each is opinionated about *how* you decompose the problem. Without picking one, the skill is a freeform note-taker and adds little over a blank file. With the wrong one, half the user base finds the skill at odds with how they think.

3. **Where does the artefact live, and when does it get written?** Two extremes: (a) the file is opened at the start of the investigation and updated as evidence accumulates ("live doc" — the doc IS the working surface); (b) the file is written after the work is done as a retrospective. Both have failure modes — (a) tends to be messy and unfinished if the investigator gets distracted; (b) tends to be thin because human memory degrades within hours of the work.

## Options Considered

### Option A — Add `investigation` as a LABEL on existing bug tickets, no new type or skill

| Pros | Cons |
|------|------|
| Zero new surface — label-based, reuses `[Bug]` template | A bug is the *thing to fix*; an investigation is the *process of understanding what to fix*. They produce different artefacts (a fix vs a written record). Conflating them buries the investigation under the bug's lifecycle (the bug closes on merge; the investigation often outlives it) |
| Adopters can opt in without framework changes | No interview / no template structure — operators still write freeform |
| | A bug deserves Given/When/Then + Severity; an investigation deserves Trigger/Hypothesis/Method/Findings — overloading one schema confuses both |

### Option B — New `Investigation` ticket type + `/investigation` skill + dedicated template (chosen)

`Investigation` gets its own ticket prefix (`[Investigation]`), label (`investigation`), template (`templates/investigation.md`), and skill (`/investigation`). The skill interviews on the six template sections, optionally writes a sibling live-doc file at `<projects_dir>/<name>/investigations/<YYYY-MM-DD>-<slug>.md`, and creates the GitHub Issue referencing the live-doc.

| Pros | Cons |
|------|------|
| Distinct shape mirrors distinct work — investigations are sustained, multi-day, often span multiple PRs | More surface: new template, new skill, new label, new prefix-whitelist entry |
| Template forces structure that ad-hoc docs lack — reproducible artefact across the portfolio | Adopters used to filing investigation work as bugs have to relearn the boundary |
| Optionally writes a live-doc the investigator updates as evidence comes in — separates the *ticket* (cross-cutting visibility) from the *working surface* (the file) | Two artefacts per investigation (issue + file) instead of one — operator has to keep them in sync |
| Sits cleanly alongside `/spike` (forward-looking POC) and `/bug` (immediate-fix) without competing | The investigation ticket's close semantics are different from every other type (closes when follow-ups land, not on merge); operators have to remember |

### Option C — Add a `[Investigation]` prefix that piggybacks on `/spike` (one skill, two prefixes)

Reuse `/spike`'s interview machinery; just swap the prefix and the four required sections (Hypothesis / Budget / Kill Criteria / Disposition → Trigger / Method / Findings / Conclusion).

| Pros | Cons |
|------|------|
| Less skill surface — one interview engine, two prefix dispatches | The two shapes diverge sharply: a spike is *time-boxed* with a *budget* and a *kill criterion*; an investigation has none of those (it ends when the question is answered, however long that takes) |
| | A spike's Disposition (PROMOTE / DISCARD) is a binary forward-decision; an investigation's Follow-up actions are an open-ended list that can include "no follow-up" |
| | Coupling forces both skills to evolve in lockstep — a change to the spike interview cascades into investigation, surprising adopters |

### Methodology sub-choice — Five Whys vs Fishbone vs Hypothesis Tree (within Option B)

| Methodology | Shape | Fits investigations because… | Fails because… |
|-------------|-------|-------------------------------|----------------|
| **Five Whys** | Linear chain of "why? why? why?" | Cheap, fast, no diagram needed, well-known | Forces a single causal chain; multi-cause incidents (the most interesting ones) get awkwardly flattened |
| **Fishbone (Ishikawa)** | Diagram with category-spines (People / Process / Tech / Environment) | Good for brainstorming-style root-cause sessions in a group | Diagrams don't render cleanly in markdown / GitHub issue bodies; works in Miro, not in `gh issue view` |
| **Hypothesis Tree (chosen)** | Nested bulleted list of hypotheses with evidence-for / evidence-against under each | Renders as plain markdown; supports multi-cause; iterates naturally as evidence comes in; matches how engineers actually think during debugging | Less prescriptive than Five Whys — investigators have to write the hypotheses; the template gives a starting shape |

### Live-doc sub-choice — file written WHILE investigating vs AFTER

| Approach | Pros | Cons |
|----------|------|------|
| **Live-doc (chosen)** | Captures evidence at the moment it's gathered (logs / SQL output / repro steps) — memory loss doesn't degrade the record. The doc IS the working surface. | Risks unfinished docs if the investigator drops the thread. Mitigation: the ticket's Follow-up actions section is the close gate, so a half-written doc has a ticket reminding it exists |
| After-the-fact retrospective | Cleaner final artefact; ruthless editing | Memory degrades within hours; nuance lost. Common failure mode: operator never gets back to writing the retro at all |

Live-doc wins because the worst failure mode (unfinished doc + open ticket) is recoverable; the after-the-fact failure mode (no doc at all) is permanent.

## Decision

Chosen: **Option B — new `Investigation` ticket type with its own skill, template, label, and prefix; hypothesis-tree methodology as the core; live-doc evidence-gathering workflow.**

Three reasons it wins:

1. **The work IS distinct from a bug or a spike.** A bug is "fix this broken behaviour." A spike is "explore this unknown to commit or reject an approach." An investigation is "understand why this happened so we can decide what to do." Conflating any pair confuses both. The new type makes the distinction visible at the prefix level.

2. **Hypothesis-tree is the methodology that survives rendering in a GitHub issue body.** Fishbone needs a diagram; Five Whys flattens multi-cause incidents. Hypothesis-tree is just nested bullets, renders cleanly everywhere markdown does, and matches how engineers think during debugging (entertain several hypotheses, gather evidence on each, prune). The template ships a starter tree; adopters override via `custom-templates/investigation.md` if they want Five Whys / Fishbone instead.

3. **Live-doc + Follow-up actions as the close gate is the right shape.** Investigations are sustained — they outlive a single PR merge. Auto-closing on merge is the wrong default (an "investigation closed because we shipped a fix" can mask follow-ups like "audit the rest of the codebase for the same pattern"). Leaving the ticket open until the Follow-up actions land puts the right close moment on the operator's calendar.

### Why no `/investigation-close` companion (cf. `/spike-close`)

`/spike-close` exists because spikes have a **binary disposition** (PROMOTE or DISCARD) that's hard to capture by just closing the issue — there's no place for the memo otherwise. Investigations have an **open-ended list** of follow-up actions, each of which is either a separate tracker ticket (already gets its own close), a documentation artefact (lands when committed), or explicitly `(no follow-up)`. The Follow-up actions section IS the close gate — when every action is resolved, the operator closes the issue. No third file needed.

### Why hypothesis-tree over the alternatives (one more pass)

Five Whys keeps showing up in incident-response literature because it's easy to teach. But the production-incident reality is that a single chain rarely holds — you usually find *three plausible causes* and have to weigh which contributed how much. Forcing a single chain into the template biases the investigation toward a single answer too early. Hypothesis-tree explicitly invites enumeration of competing hypotheses, with evidence under each — the right shape for the work.

Fishbone is good for the *workshop* version of root-cause (six people, a whiteboard, an hour). It's bad for the *artefact* version (one engineer writing in a markdown file). Wrong tool for the medium.

### Where the live-doc lives

In **single-fork mode**: `projects/<project>/investigations/<YYYY-MM-DD>-<slug>.md`. The `projects/` dir is the per-project docs area, parallel to `projects/<project>/processes/<slug>.bpmn` (from `/process`), `projects/<project>/feature-inventory.md` (from `/extract-features`), `projects/<project>/architecture/c4-context.md` (from `/c4`).

In **split-portfolio mode** the `projects_dir` resolver routes to the sibling private repo automatically.

When invoked from the ops fork root (no project context), the live-doc lands at `docs/investigations/<YYYY-MM-DD>-<slug>.md` — the framework's own investigations live there.

### Date-prefixed filenames

`YYYY-MM-DD-<slug>.md` is the same convention `/spike-close --discard` uses for memo filenames (`docs/spike-memos/<slug>.md` — though `/spike-close` doesn't date-prefix; we add the date here because investigations cluster more around incidents than spikes do, and chronological sort is a useful directory listing).

### Template override path

`portfolio_resolve_template investigation.md` — drop a custom shape at `<private_repo>/custom-templates/investigation.md` to replace the framework default. Same path-mirroring convention as `prd.md`, `spike.md`, etc. See [`templates/README.md`](../../templates/README.md) and [AgDR-0023](AgDR-0023-custom-templates-override-semantics.md).

## Consequences

### Now safer

- **One canonical shape for investigation artefacts.** Future-us can search `projects/*/investigations/` across the portfolio and skim the structure without re-parsing every author's idiosyncratic layout.
- **Live-doc captures evidence at gather-time.** Less memory loss; more reproducible incidents.
- **Follow-up actions section is the close gate.** No more orphan investigations that drift open forever — every follow-up either lands or is explicitly marked `(no follow-up)`, then the issue closes.

### Now riskier

- **Two artefacts per investigation (issue + file).** Operator has to keep them in sync. Mitigation: the skill writes the file path into the issue body so the issue links to the file; the file's metadata block links back to the issue.
- **Methodology is opinionated.** Five Whys / Fishbone fans see their methodology absent from the template. Mitigation: `custom-templates/investigation.md` can replace the shape entirely; the rest of the skill (interview, file placement, issue creation) stays the same.
- **No close gate beyond the operator's discipline.** Investigations rely on the operator closing the issue when follow-ups resolve. If they don't, the open count drifts up. Acceptable for v1 — if measurable in practice, add a `/investigation-close` skill or a hard gate later.

### Now slower

- **Investigation work explicitly takes longer than filing a bug.** That's deliberate — the bar is "produce a written artefact future-us can pick up", not "fix the symptom." Fast-fix bugs should stay on `/bug`.

### Future work

- **Auto-link to related tickets.** When `/investigation` runs and the live-doc lists follow-up actions, the skill could offer to file them as `/bug` / `/feature` / `/spike` tickets in the same flow. v2 — keeps v1 simple.
- **Investigation rollups for `/stakeholder-update`.** Recent investigations are a useful weekly-update item ("we resolved 3 investigations this week"). v2 once enough investigations exist to roll up.
- **`/investigation-close` if discipline-only proves insufficient.** Measurable trigger: count of `investigation`-labelled issues open > 30 days with no recent body update over the trailing 90 days.
- **Cross-investigation patterns.** A `/agdr search` style helper for "have we investigated this before?" — useful once the corpus grows. v2.

## Artifacts

- `me2resh/apexyard#245` — feature ticket
- `templates/investigation.md` — new template
- `.claude/skills/investigation/SKILL.md` — new skill
- `.claude/skills/investigation/tests/smoke.sh` — smoke test asserting template structure
- `.claude/project-config.defaults.json` — `Investigation` added to `.ticket.prefix_whitelist` + `.ticket.required_sections`
- `CLAUDE.md` — skill registry row + count bump
- `templates/README.md` — investigation entry in the override table
