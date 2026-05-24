# AgDR-0020 — Adopter handbooks consumed by Rex during code review: scope, discovery, format, enforcement

> In the context of letting adopters layer company-specific coding standards on top of the framework's generic rules without forcing them to fork `.claude/rules/` (#232), facing five load-bearing choices (handbook scope, discovery mechanism, file format, sample-scaffold-per-feature, enforcement default), I decided **framework-level handbooks only (no per-project layering in v1), path-convention discovery (`architecture/` always-loads, `language/<lang>/` loads on diff match, `general/` always-loads), flat markdown without YAML frontmatter, ship 4 sample handbooks demonstrating each shape (no auto-scaffold per feature), and advisory-by-default with explicit `ENFORCEMENT: blocking` opt-in**, to achieve a low-friction handbook layer that grows organically with the framework while staying mechanically enforceable for the rules that genuinely warrant blocking, accepting that v1 has no per-project handbook scope and that the path-convention discovery requires authors to put files in the right directory.

## Context

[me2resh/apexyard#232](https://github.com/me2resh/apexyard/issues/232) introduces a new "handbook" concept — adopter-authored markdown files containing company-specific coding standards that Rex (the code-reviewer agent) consults during PR review, alongside the framework-wide rules in `.claude/rules/`. The CEO answered five design questions in conversation; this AgDR records those answers as the load-bearing decisions because each shapes how adopters interact with the layer.

## Options Considered

### A. Handbook scope: framework-level only vs per-project vs both layered

| Option | Pros | Cons |
|---|---|---|
| **Framework-level only** (chosen) | Simple. Handbooks travel with the ops fork; one source of truth across all managed projects. Matches the way `.claude/rules/` already works — adopters know the pattern. | Adopters with truly project-specific patterns can't express them. Migration to per-project later is additive — no breaking change. |
| Per-project only | Matches the per-project nature of audits + tickets. | Most coding standards are organisation-wide ("never use floats for currency", "API responses are camelCase") — forcing per-project duplication creates drift. Adopter has to author the handbook N times for N projects. |
| Both, layered (project overrides framework) | Maximum flexibility. | The conflict-resolution rules (project wins? merge? warn-on-conflict?) become a design surface of their own. v1 should not carry that complexity until an adopter asks. |

### B. Discovery mechanism: path-convention vs frontmatter targeting vs always-load

| Option | Pros | Cons |
|---|---|---|
| **Path-convention** (chosen): `architecture/` always-loads, `language/<lang>/` loads on diff match, `general/` always-loads | No format inspection — discovery is a glob over the file tree. Authors don't have to learn YAML. The directory IS the targeting metadata. Cheap to implement; cheap to audit. | Adopters with a handbook that doesn't fit the three buckets need to bend it (or ask for a fourth bucket via PR). |
| YAML frontmatter (`applies_to: "**/*.tsx"`) | Maximally targeted — author specifies exactly which paths trigger loading. | Handbook authoring becomes "write YAML correctly". Discovery requires opening and parsing every file even when it won't apply. CEO answered "flat markdown" explicitly — frontmatter would contradict that. |
| All handbooks always load | Trivial to implement. | Rex's review prompt grows linearly with handbook count. A 50-handbook adopter pays the full cost on every PR even when 49 are language-specific and don't apply. |

### C. File format: flat markdown vs structured frontmatter vs YAML-only

| Option | Pros | Cons |
|---|---|---|
| **Flat markdown** (chosen) | Same as `.claude/rules/` — adopters already know the format. Rex reads as prose, no parser needed. Authors write English, not config. | No machine-readable metadata — discovery has to live in path conventions (which it does, per choice B). |
| Markdown with YAML frontmatter | Captures `enforcement`, `applies_to`, `severity`, `version` as structured data. | Authors learn YAML. Discovery touches every file even when irrelevant. Every example handbook becomes a vehicle for documenting the schema. |
| Pure YAML / JSON | Rex can introspect every field. | Handbook prose has nowhere to live; rules degenerate into one-liners that lose explanatory context (the WHY behind the rule). Loses the "Rex reads as prose" property that makes the layer trivial to extend. |

### D. Sample-handbook-per-feature: auto-scaffold vs prompt-only vs ship-examples-only

| Option | Pros | Cons |
|---|---|---|
| **Ship sample handbooks; no per-feature scaffold** (chosen) | Adopters see the convention by example. New handbooks are written when an actual standard emerges, not on a feature-creation cadence. Avoids handbook bloat from speculative "this feature might need a rule someday" stubs. | No mechanical nudge to grow the handbook library; adopters must remember the layer exists. |
| Auto-scaffold a draft handbook stub when `/feature` is run | Handbook coverage grows mechanically with feature count. | Most features don't need a new handbook entry. The scaffold becomes ceremony — adopters delete the stub or worse, leave empty stubs. Pollutes the handbook tree with noise. |
| Prompt the operator (default-yes) inside `/feature` | Compromise — scaffold offered but skippable. | Still adds friction to every `/feature` run for the rare case where a handbook entry is warranted. CEO answered "just write an example for us" explicitly — no per-feature mechanism. |

### E. Enforcement: advisory-only vs blocking-by-default vs hybrid with opt-in

| Option | Pros | Cons |
|---|---|---|
| **Advisory by default; blocking via `ENFORCEMENT: blocking` marker** (chosen) | Matches the existing rule mix (parallel-work + plan-mode are advisory; ticket-first + secret-scan are blocking). Authors decide per-rule whether the cost of false-positives outweighs the cost of false-negatives. Adopter-friendly first run — no day-1 blocking spree. | Marker phrase is a magic string; mistyping it silently downgrades to advisory. Mitigation: README documents the exact phrase + Rex agent docs cite it. |
| Always blocking | Strongest enforcement signal. | Day-1 hostile to adopters — every false-positive blocks merges. Authors get ratio'd into removing rules instead of refining them. |
| Always advisory | No false-positive risk. | Defeats half the value — the rules that should be blocking (e.g. "never log PII") become a polite suggestion. |

## Decision

Chosen — for all five:

**A.** Framework-level handbooks only at `handbooks/` in the ops fork.
**B.** Path-convention discovery (`architecture/` + `general/` always-load; `language/<lang>/` loads on diff-match).
**C.** Flat markdown, no YAML frontmatter.
**D.** Ship 4 sample handbooks demonstrating the four shapes; no auto-scaffold per `/feature` invocation.
**E.** Advisory by default; opt in to blocking with the literal phrase `ENFORCEMENT: blocking` at the top of the file.

Why this combination:

1. **Path-convention + flat markdown is the only consistent pair.** YAML frontmatter would carry the metadata that path conventions carry; one or the other suffices. Flat markdown matches the framework's existing rule shape — adopters reach for the pattern they already know.
2. **Framework-level first, per-project later if asked** matches the framework's adoption curve. Most company coding standards are organisation-wide; the v1 shape covers 95% of the use case at 50% of the complexity.
3. **Sample handbooks demonstrate the shape** without imposing a workflow change to `/feature`. Adopters see four real examples and write their own when an actual standard emerges.
4. **Advisory-by-default with blocking opt-in** mirrors the framework's existing rule mix and respects the principle that mechanical enforcement should match operator intent — not be the universal default.

## Consequences

- The four sample handbooks shipped in this PR are also the *recommended defaults*. Adopters who don't author their own get a non-trivial baseline of standards Rex enforces. Adopters who do author their own can keep, edit, or replace the samples freely.
- Rex's review prompt grows by the loaded handbook count per PR. Diff-match for `language/<lang>/` keeps the per-PR cost bounded. If a future adopter has 50 architecture handbooks (always-load), follow-up work could add a `glob:` directive in handbook prose to narrow further — but v1 ships without it because no adopter has hit the limit yet.
- The `ENFORCEMENT: blocking` marker is a magic phrase. If a future schema bump introduces a YAML frontmatter (reversal of choice C), the marker becomes a frontmatter field. The phrase is documented in `handbooks/README.md` and cited in `.claude/agents/code-reviewer.md` so the convention is discoverable.
- Per-project handbook scope is filed as a follow-up consideration in the ticket's "Out of Scope" section. Adding it later is additive (introduce a `projects/<name>/handbooks/` resolution path; layer over framework handbooks) and reversible (remove the per-project arm if it doesn't get traction).
- Handbook violations surface in Rex's existing review-comment shape — no new UI or output channel. Operators see them inline alongside framework-rule findings.
- The `/handbook` authoring skill (interactive scaffold for new handbooks) is also out of scope. v1 expects adopters to copy a sample and edit. If authoring friction shows up, file a follow-up.

## Artifacts

- Ticket: [me2resh/apexyard#232](https://github.com/me2resh/apexyard/issues/232)
- Implementation PR: feature/GH-232-adopter-handbooks (this branch)
- Sample handbooks: `handbooks/architecture/clean-architecture-layers.md`, `handbooks/architecture/migration-safety.md` (blocking), `handbooks/language/typescript/strict-mode.md`, `handbooks/general/commit-message-quality.md`
- Rex agent update: `.claude/agents/code-reviewer.md`
- Index: `handbooks/README.md`
- CLAUDE.md QUICK REFERENCE updated to surface `handbooks/`
