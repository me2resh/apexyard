# AgDR-0028: `/tech-vision` skill — interactive section-by-section authoring, markdown-only output

> In the context of shipping a `/tech-vision` skill that fills in the existing `templates/architecture/vision.md` template (#224), facing the question of whether the skill should be a one-shot prose generator, a fully-rendered diagram tool, or an interactive section-by-section interviewer, I decided to ship `/tech-vision` as an **interactive section-by-section interviewer that emits text-first markdown** at `projects/<name>/architecture/vision.md` via the custom-templates resolver (#244), to achieve the load-bearing sections (current-vs-target, anti-scope, migration path) actually getting filled in with operator-authored content, accepting that the skill takes longer to run than a single-shot generator.
>
> **Naming note.** The skill is `/tech-vision`, not `/vision`. The shorter `/vision` collides with product / company vision in a multi-stakeholder portfolio (CEOs / Heads of Product use the same word for non-architecture documents). The template path stays `templates/architecture/vision.md` — renaming the template would break the `custom-templates/architecture/vision.md` override path that landed in #244 / #224. Only the slash-command is renamed.

## Context

The `templates/architecture/vision.md` template shipped in #224 covers seven sections: Scope, Principles, Target-state architecture (Mermaid C4 L1), Current vs Target (table), Migration path (multi-quarter table), Things we explicitly chose NOT to build (the load-bearing anti-scope), and Review cadence. The template is good; the failure mode it's designed to prevent is **vision docs that ship as half-filled-in stubs**.

Three forces converge on this decision:

1. **The empty-template problem.** Without an interactive author, operators copy the template, fill in the easy bits (Scope, Principles, Review cadence), and either skip or hand-wave the hard ones (Current-vs-Target, Anti-scope, Migration path). The template's whole point is to force those hard sections; without prompting, they get skipped.
2. **Custom-templates resolver (#244) just landed.** Every template-consuming skill in the family (`/c4`, `/decide`, `/migration`, `/spike`, `/handover`) routes through `portfolio_resolve_template`; `/tech-vision` should do the same so adopters can override the template shape without forking the skill.
3. **Sibling skill `/c4` precedent.** `/c4` writes to `projects/<name>/architecture/{context,container}.md` from a registered project name. `/tech-vision` sits in the same directory family — same path resolution, same overwrite-prompt UX, same Mermaid-renders-on-GitHub assumption for the embedded C4 L1 block.

The skill is text-first by design: a vision is prose + bulleted horizons + a single optional embedded Mermaid block. Unlike `/c4` (pure diagram) or `/journey` (HTML-rendered graph), `/tech-vision`'s artefact is words.

## Options Considered

### A. Interactive section-by-section interviewer, markdown-only output (CHOSEN)

| Pros | Cons |
| --- | --- |
| Forces the operator through every load-bearing section in order (Anti-scope cannot be skipped silently) | Takes longer to run than a single-shot prose generator (5–15 minutes vs 30 seconds) |
| Per-section confirmation lets the operator iterate without restarting the whole flow | Per-section UX needs careful prompt design; sloppy prompts produce sloppy sections |
| Output is a fully populated `vision.md` the operator can commit as-is or hand-edit | An operator who already knows what they want to say is forced through prompts they may experience as ceremony |
| Mirrors the per-section flow used by `/decide`, `/migration`, `/spike`, `/feature` — consistent UX across the skill family | |
| Uses the custom-templates resolver so adopters with `custom-templates/architecture/vision.md` see their shape | |

### B. Single-shot prose generator from a problem statement

| Pros | Cons |
| --- | --- |
| Fastest path from "I need a vision" to "I have a vision draft" | The output is the model's guess at the architecture vision, not the operator's |
| Lower-friction for operators who already have a clear mental model | The hard sections (Anti-scope, Current-vs-Target) require operator-specific knowledge the model doesn't have — output is filler or hallucination |
| | Defeats the template's whole purpose: the template exists to surface operator decisions, not to be filled in by the model |

### C. Fully-rendered tool (HTML / SVG / interactive diagram)

| Pros | Cons |
| --- | --- |
| Pretty | Vision is text-first — there's no graphical artefact except the embedded C4 L1 (which already renders via Mermaid on GitHub) |
| | Adds a build / preview layer for an artefact that fundamentally lives as markdown |
| | Out of step with `/c4` / `/dfd` / `/sequence` family, all of which are Mermaid-in-markdown |
| | Operators committing a vision want a file that diffs cleanly, not an HTML blob |

### D. One-pass author (interactive, but all sections shown at once, no per-section confirmation)

| Pros | Cons |
| --- | --- |
| Less ceremony than Option A | Harder to iterate — a typo in section 3 means re-running the whole prompt |
| | Operators staring at a 7-section prompt block tend to skip / hand-wave the harder ones — same failure mode as the empty-template problem |

## Decision

Chosen: **Option A**, because the template's load-bearing sections (Current-vs-Target, Anti-scope, Migration path) are exactly the ones operators skip when there's no prompt. Per-section confirmation makes it easy to iterate on a single section without re-running the whole interview; the model never authors the content, only structures the prompts and assembles the resulting file.

The skill is **text-first**: no HTML, no SVG, no rendering layer. The single graphical element (target-state C4 L1) renders via Mermaid on GitHub — zero new toolchain. This matches the `/c4` / `/dfd` / `/sequence` family and respects AgDR-0003 (Mermaid C4 for diagrams).

## Sub-decisions made in the same scope

### A1. Output location: `projects/<name>/architecture/vision.md`

Same convention as `/c4` writing to `projects/<name>/architecture/{context,container}.md`. Renders inline on GitHub, ops-fork view of the project's architecture, sits next to the C4 diagrams so an observer browsing `projects/<name>/architecture/` sees four architecture artefacts of the same system (context, container, data-flow, vision).

Framework-scoped invocations (cwd at ops fork root, no project arg) write to `<ops_root>/docs/architecture/vision.md` — same split as `/c4` framework-wide mode.

### A2. Use the custom-templates resolver (#244) for template structure

`portfolio_resolve_template architecture/vision.md` returns either:

1. `<private_repo>/custom-templates/architecture/vision.md` (adopter override), OR
2. `<ops_root>/templates/architecture/vision.md` (framework default)

The skill **reads the resolved template** to know which sections to interview against, then **rewrites the placeholder regions** with the operator's answers. The template's surrounding markdown (section headers, notes-to-author callouts) is preserved verbatim where it's documentation; section bodies are replaced.

This means an adopter who renames "Things we explicitly chose NOT to build" to "Out-of-scope" in their `custom-templates/architecture/vision.md` automatically sees that wording in the interview prompts AND in the output — the skill follows the template, not a hardcoded section list.

### A3. Per-section confirm, default-no on overwrite

The interview is **section-by-section**: one prompt per section, operator answers, the assembled draft of that section shows, operator confirms (or asks to redo just that section). After all sections are confirmed, the full assembled doc shows once more for final confirm, then writes.

Re-runs against an existing `vision.md` follow the same UX as `/c4`, `/extract-features`, `/dfd`: **OFFER (default-no) to overwrite**. Accept-no preserves the existing file; accept-yes prompts again section-by-section using the existing file's content as defaults.

This mirrors the AC's "Idempotence" requirement: re-running on an existing vision doc preserves content for sections not explicitly updated. Implementation: parse the existing file's sections, present each section's existing content as the default during the interview, write-through unchanged sections verbatim.

### A4. Mermaid C4 L1 embedded inline; no `/c4` chain in v1

The AC mentions an option to call into `/c4` from inside `/tech-vision` to scaffold the target-state diagram. For v1 of `/tech-vision`, the skill **accepts the Mermaid block inline** during the Target-state section interview — operator pastes it from `/c4` output, hand-authors it, or accepts the template's placeholder block as a starting point.

Chaining `/c4` from inside `/tech-vision` is a follow-up (filed as a v1.x enhancement note in the skill body, not blocking v1). Two reasons:

1. **Vision target-state ≠ current-state**. `/c4` reads the codebase and produces a current-state diagram. The vision's target-state diagram is by definition NOT today's code — it's where the architecture is going. Auto-scaffolding via `/c4` would seed a current-state diagram into a target-state section, which the operator then has to edit anyway.
2. **Skill-calls-skill is a new pattern in the apexyard family** — no existing skill does it today. Adding it for `/tech-vision` v1 introduces a coupling that's better validated as its own decision (a follow-up AgDR) rather than smuggled in.

For v1, the skill **suggests** running `/c4 <project> --level=1` first if no diagram is provided, and lets the operator paste the result into the Target-state section.

### A5. Single Markdown file, no companion YAML

Unlike `/journey` (which emits both an HTML render and a YAML source-of-truth), `/tech-vision` emits a single markdown file. The vision doc IS the source of truth — no separate machine-readable representation, no render step. Markdown is the canonical, diffable, GitHub-rendered format.

## Consequences

### Wins

- **The load-bearing sections actually get filled in.** Anti-scope and Current-vs-Target stop being optional in practice — the interview makes them prompted-and-confirmed in the same flow as the easier sections.
- **Adopters can override the template** without forking the skill — the custom-templates resolver (#244) just works.
- **Idempotent re-runs** let the operator iterate on individual sections quarterly (matching the template's review-cadence note) without rewriting the whole vision.
- **Text-first output diffs cleanly in git** and renders inline on GitHub, same as every other markdown artefact in the architecture/ family.

### Costs

- **Interview takes longer than a single-shot generator** — typical run is 5–15 minutes depending on how many gap-rows + migration milestones + anti-scope items the operator provides. Mitigated by the per-section confirm UX (operators can re-run a single section without restarting).
- **Skill is operator-bound, not model-bound** — the model can't fill in sections the operator skips (by design; that's the whole point). An impatient operator who answers each prompt with "minimal" produces a minimal vision. The template + the prompts make the operator's quality bar visible; the skill cannot raise it.
- **Single conflict path with `/investigation` (#245)** on CLAUDE.md + docs/multi-project.md skill-count + table additions. Coordinated by parallel sibling agent; second-to-merge resolves trivially.

### Out of scope (explicit non-goals for v1)

- **HTML / SVG rendering** — markdown-only. Mermaid C4 L1 renders via GitHub.
- **Calling `/c4` from inside `/tech-vision`** — accept inline Mermaid in v1; chain in a follow-up.
- **A `/tech-vision-review` companion** that re-prompts every section quarterly — the idempotent re-run handles this in v1.
- **Vision-doc enforcement** (Rex checking whether code matches the vision) — that's an AgDR + `/decide` concern, not a vision-doc one.
- **Multi-team vision composition** — one vision per system / domain, same scope as the template.

## Artifacts

- Ticket: [me2resh/apexyard#246](https://github.com/me2resh/apexyard/issues/246)
- Template: [`templates/architecture/vision.md`](../../templates/architecture/vision.md) (shipped #224)
- Dependency: [#244 — custom-templates layer with override semantics](https://github.com/me2resh/apexyard/issues/244) (lands first; provides `portfolio_resolve_template`)
- Sibling: [#245 — `/investigation` skill](https://github.com/me2resh/apexyard/issues/245) (parallel author, shared CLAUDE.md + multi-project.md edits)
- Related prior art:
  - [AgDR-0003: Mermaid C4 for diagrams](AgDR-0003-mermaid-c4-for-diagrams.md) — why Mermaid is the default diagram format in apexyard
  - [AgDR-0023: Custom templates override semantics](AgDR-0023-custom-templates-override-semantics.md) — the path-mirroring layer `/tech-vision` consumes
  - [AgDR-0026: `/dfd` skill as source of truth](AgDR-0026-dfd-skill-as-source-of-truth.md) — same producer-skill / `projects/<name>/architecture/` pattern
