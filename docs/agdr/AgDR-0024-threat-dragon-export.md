---
id: AgDR-0024
timestamp: 2026-05-16T00:00:00Z
agent: claude-opus-4-7
model: claude-opus-4-7
trigger: user-prompt
status: executed
ticket: me2resh/apexyard#255
category: integrations
projects: [apexyard]
---

# OWASP Threat Dragon v2 JSON as the export format for `/threat-model --format=dragon`

> In the context of shipping a machine-consumable export for `/threat-model` per me2resh/apexyard#255 (so adopters can open the model in a visual editor for ongoing maintenance), facing the choice between OWASP Threat Dragon v2 JSON, Microsoft TMT `.tm7` XML, and the IriusRisk export format, I decided to ship **Threat Dragon v2 JSON with an auto-grid layout** — accepting that the grid is a "sane starting state" rather than a publication-quality layout, and that round-trip import (editing the JSON in Dragon then folding edits back into the skill's markdown) is explicitly out of scope for v1.

## Context

`/threat-model` already emits a structured markdown artefact: a Mermaid DFD section (added in #225), a STRIDE catalogue table, an OWASP cross-check, and a per-run JSON persisted via `_lib-audit-history.sh`. The markdown is excellent for PR review and human reading; it is **not** a format any threat-modelling tool consumes for visual editing.

Adopters running periodic threat modelling want two things the markdown can't give:

1. **Open the model in a visual editor.** Drag boundaries, re-arrange shapes, annotate visually — the things a markdown table can't do.
2. **Share it with a security team or external auditor** who uses a known tool (not "open this .md in your IDE").

The Mermaid DFD encodes everything needed to reconstruct a structured model: external actors, processes, data stores, trust boundaries, and labelled data flows. The STRIDE table encodes per-element findings with severity, type, and mitigation. A serialiser that walks the structured input the skill already builds and writes a tool-consumable file is a small addition; the question is *which* tool's format to target.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| **OWASP Threat Dragon v2 JSON** | OWASP project, open-source, actively maintained (2026). Desktop + web app. JSON schema published at `td.vue/src/assets/schema/threat-dragon-v2.schema.json`. Threats attach directly to cells via `data.threats[]` with `severity` / `type` / `description` / `mitigation` / `status` — clean fit for our STRIDE findings. Shapes (`actor`, `process`, `store`, `flow`, `trust-boundary-box`) map 1:1 to our DFD vocabulary. Auto-arrange on first open re-flows whatever coordinates we emit. | Schema requires UUIDs everywhere, a `summary` object, `detail.{contributors, diagrams, diagramTop, reviewer, threatTop}` — moderate boilerplate, but mechanical. Auto-layout is "sane defaults" not "publication-ready" — operators may want to drag for clarity on first open. |
| **Microsoft Threat Modeling Tool `.tm7` XML** | Established in security-tool ecosystems. SDL-aligned threat libraries. | Windows-only desktop app — excludes our macOS / Linux adopter base. Format is XML, schema undocumented (reverse-engineered from sample files). Microsoft has signalled this tool is in maintenance mode; new investment is in Microsoft Defender / Azure tooling. Out of scope per the ticket. |
| **IriusRisk export format** | Vendor backing, large rule library, commercial-grade reporting. | Proprietary SaaS — not every adopter has an IriusRisk account. Export format requires login to access the schema. Tying our open-source skill to a commercial vendor is a bad shape. Out of scope per the ticket. |
| **OTM (Open Threat Model)** — IriusRisk's open spec | Multi-tool target (Dragon, IriusRisk, others consume it). Vendor-neutral. | Less mature than Dragon's native format; Dragon itself ships an OTM importer rather than treating it as primary. Importing OTM into Dragon then re-saving still produces Dragon JSON. Net win is dubious for the same effort. |
| **Plain GraphViz `.dot`** | Trivially small serialiser, viewer-agnostic. | No tool consumes it for *threat modelling* — only for graph rendering. We'd be back to "no threats attached to shapes". Defeats the use case. |

### Decision dimensions weighted

| Dimension | Weight | Dragon v2 | TMT .tm7 | IriusRisk | OTM | GraphViz |
|-----------|--------|-----------|----------|-----------|-----|----------|
| **Open-source, cross-platform** | Critical | ✅ | ❌ (Windows) | ❌ (SaaS) | ✅ | ✅ |
| **Active maintenance (2026)** | Critical | ✅ | ❌ (maintenance mode) | ✅ | ✅ | ✅ |
| **Threats attach to shapes** | Critical | ✅ | ✅ | ✅ | ✅ | ❌ |
| **Schema is public + parseable** | High | ✅ | ❌ (undocumented) | ❌ (login required) | ✅ | ✅ |
| **DFD vocabulary fit (actor/process/store/flow/boundary)** | High | ✅ (1:1 mapping) | ✅ | ✅ | ✅ | ~ (graph only, no semantics) |
| **STRIDE-native** | High | ✅ (diagramType=STRIDE) | ✅ | ~ (multi-methodology) | ~ (methodology-agnostic) | ❌ |
| **Auto-layout on first open** | Medium | ✅ | ✅ | ✅ | n/a | n/a |
| **Adopter familiarity** | Medium | ✅ (mainstream OSS) | ~ (older tool) | ~ (commercial) | ~ (less mainstream) | ❌ (not a TM tool) |

Dragon wins on every critical row plus the high-weight rows. TMT is the closest fit on shape semantics but fails the cross-platform + maintenance gates. IriusRisk fails the open-source gate. OTM is viable but adds a translation layer without a clear adopter win.

### Auto-grid layout decision

The schema requires `position: {x, y}` and `size: {width, height}` for every cell. Three layout options:

| Option | Pros | Cons |
|--------|------|------|
| **Auto-grid** (rows by element class, columns by index) | Deterministic, ~10 lines of code, regenerable, predictable across runs. Dragon re-flows on first open — operator drags to taste. | Dense models look cramped before re-flow. Acceptable trade-off because the operator is going to re-arrange anyway. |
| **Hand-rolled hierarchical layout** (BFS by trust-boundary depth) | Visually tidy on first open. | Significant code (the `/journey` skill burns ~150 lines on hand-rolled BFS layout; we'd be duplicating that engine for a use case where Dragon's own auto-arrange handles re-flow). Brittle on dense / cyclic graphs. |
| **Defer layout to Dragon entirely** (no coords) | Smallest serialiser. | Schema requires `position` + `size` as `required`. Omitting them produces invalid JSON. Non-starter. |

Auto-grid is the right shape: row-by-element-class (actors row at `y=0`, processes at `y=200`, stores at `y=400`, x-spaced 200px), accept the cramped first-open look, document that Dragon's auto-arrange will re-flow.

## Decision

Chosen: **OWASP Threat Dragon v2 JSON, with an auto-grid layout**.

Concretely:

- **Flag surface**: `--format=markdown` (default, unchanged), `--format=dragon` (JSON only), `--format=both` (markdown + JSON). Markdown-only stays default to preserve backward compatibility.
- **Serialiser**: a self-contained Python script at `.claude/skills/threat-model/serialize_dragon.py`. Input is a small YAML/JSON structured-input file (entities + flows + boundaries + threats) the skill builds while running. Output is Threat Dragon v2 JSON at `<output-dir>/threat-model.json`.
- **Shape mapping**:
  - External actors → `shape: actor`, `data.type: tm.Actor`
  - Processes → `shape: process`, `data.type: tm.Process`
  - Data stores → `shape: store`, `data.type: tm.Store`
  - Trust boundaries → `shape: trust-boundary-box`, `data.type: tm.BoundaryBox`, `data.isTrustBoundary: true`
  - Data flows → `shape: flow`, `data.type: tm.Flow`, with `source.cell` / `target.cell` referencing the connected shapes' UUIDs
- **STRIDE findings** attach to their parent shape via `data.threats[]` with `severity` (Critical→High mapped to "High", Medium→"Medium", Low→"Low" — Dragon's enum), `type` (one of "Spoofing", "Tampering", "Repudiation", "Information disclosure", "Denial of service", "Elevation of privilege"), `description`, `mitigation`, `status: "Open"`, `title`, `modelType: "STRIDE"`, `id` (UUID).
- **Auto-grid layout**: actors row at `y=0`, processes at `y=200`, stores at `y=400`; x-spaced 200px starting at `x=10`. Trust-boundary boxes computed to wrap their child shapes with a 40px margin.
- **No round-trip import** (out of scope per ticket). The skill writes; if an operator edits in Dragon they own the JSON from that point.
- **No `.tm7` export** (out of scope). Operators who want TMT can use Dragon's own OTM converter as an intermediate step — not our problem.
- **Validation**: smoke test asserts top-level required keys (`version`, `summary.title`, `detail.{contributors,diagrams,diagramTop,reviewer,threatTop}`), every cell has `id`/`shape`/`zIndex`, every flow has `source.cell`/`target.cell` pointing at real cell UUIDs, every threat has the six required fields.

## Consequences

### Immediate

- Adopters running `/threat-model --format=dragon` get a `threat-model.json` they can open directly in OWASP Threat Dragon (desktop or web).
- The serialiser is ~250 lines of Python, dependency-free except for the standard library (uses `uuid`, `json`, `argparse`; YAML input is parsed with a minimal subset parser if PyYAML is absent — matches the `/journey` skill's convention).
- The markdown path is unchanged. Default behaviour (markdown only) is preserved; the flag is opt-in.

### Deferred

- **Round-trip import** — if an operator edits in Dragon, their edits don't flow back into the skill's markdown. Decision deferred; the cleanest shape would be a separate `/threat-model --import-dragon <path>` skill, not a bidirectional `/threat-model --format=dragon`. Re-visit when an adopter asks.
- **Layout quality** — auto-grid is "sane starting state". If adopters report that the cramped first-open is unusable, swap in a real layout engine (Dragon ships its own auto-arrange button on the toolbar, which is the recommended first action). Cost of swap: renderer-only change, schema stays stable.
- **OTM as a secondary export** — viable future addition if adopters ask for multi-tool portability. The serialiser's internal IR (entities/flows/threats) is the right factor-out point; adding a second emitter is mostly schema-mapping work.
- **`.tm7` export** — explicitly excluded. If Microsoft revives TMT investment or an adopter has a hard requirement, revisit.

### Costs if we're wrong

Modest. The serialiser is self-contained and the JSON output is independent of the markdown path. If Dragon's v2 schema changes incompatibly (unlikely — they've been on v2 for years), we update the serialiser. If adopters prefer OTM, we add a second emitter behind a `--format=otm` flag without disturbing the Dragon path.

The bigger risk is auto-grid layout pushback. Mitigated by documenting "Dragon's auto-arrange re-flows on first open" in the SKILL.md output blurb, so operators know the cramped first-open is intentional.

### Costs if we're right but wait

Adopters who want visual editing keep hand-redrawing models in Dragon from the markdown — error-prone, time-consuming, and the markdown stays the source of truth while the visual model rots. Shipping the export now closes that gap; the layout polish can come later.

## Artifacts

- Skill: `.claude/skills/threat-model/SKILL.md` (extended)
- Serialiser: `.claude/skills/threat-model/serialize_dragon.py`
- Fixture: `.claude/skills/threat-model/fixtures/sample-input.yaml`
- Tests: `.claude/skills/threat-model/tests/test_serialize_dragon.sh`
- Schema reference: [OWASP/threat-dragon `threat-dragon-v2.schema.json`](https://github.com/OWASP/threat-dragon/blob/main/td.vue/src/assets/schema/threat-dragon-v2.schema.json)
- Ticket: [me2resh/apexyard#255](https://github.com/me2resh/apexyard/issues/255)
- PR: (filled at merge time)
