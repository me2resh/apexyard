---
id: AgDR-0003
timestamp: 2026-04-17T09:20:00Z
agent: atlas
model: claude-opus-4-7
trigger: user-prompt
status: executed
ticket: me2resh/apexstack#50
---

# Mermaid C4 as the diagramming format for ApexStack-managed projects

> In the context of adding architecture-diagram support to ApexStack per #50, facing the choice between Mermaid C4, Structurizr DSL, PlantUML C4, and D2, I decided to ship **Mermaid C4 only** for v1 (L1 context + L2 container templates), accepting that L3+ precision and "proper" Structurizr-style modelling are deferred until a real project actually needs them.

## Context

Per issue #50, ApexStack-managed projects should include architecture diagrams in their documentation, with the C4 model (Context, Container, Component, Code) as the target. The CEO prefers C4 and is open to the choice of tool.

The v1 target is L1 (system + external actors) and L2 (containers: frontend, backend, database, CDN) — enough to communicate "how this project fits together" to a new engineer or external reader. L3 (component-level) and L4 (code-level) are explicitly out of scope for this AgDR — the issue itself flags them as rare / auto-generated.

Two audiences matter:

1. **Framework users** (fork-based distribution) — they read diagrams on GitHub or in their IDE. They have `gh`, `git`, and a shell. They may not have Java, Docker, or a Go toolchain.
2. **New engineers joining a managed project** — they open `docs/architecture/` in their browser (via GitHub) or an editor with a Markdown preview. They expect diagrams to render without setup.

## Options Considered

| Tool | Format | Rendering | Pros | Cons |
|------|--------|-----------|------|------|
| **Mermaid C4** | Markdown-embedded ```mermaid C4Context/C4Container blocks``` | Native on GitHub; native in VS Code preview; native in most Markdown viewers | Zero install. Every GitHub user sees it inline. Renders in the repo's file view. Single-source (Markdown is the whole artifact). | C4 support in Mermaid is "beta" — fewer features than Structurizr. No automatic L1→L2→L3 zoom. Less precise about technology-vs-container distinction. |
| **Structurizr DSL** | Custom text DSL (`.dsl` file) | Structurizr Lite (Docker) or CLI; output is SVG/PNG/PlantUML | Purpose-built for C4. Single model, auto-renders all zoom levels. Industry-standard for C4. | Requires Docker or a Java CLI to render. GitHub doesn't render `.dsl` files inline — users see raw DSL. Two-source problem: DSL + rendered PNG committed together, or you lose the "view on GitHub" experience. |
| **PlantUML C4** | Text DSL (`.puml`) with C4 library includes | PlantUML jar or server; output is SVG/PNG | Mature C4 library. Widely used in enterprise. | Java dependency. Same two-source problem as Structurizr. GitHub renders PlantUML in README previews only via a third-party service (unreliable). |
| **D2** | Text DSL (`.d2`) | `d2` CLI (Go binary) | Modern aesthetics. No Java. Fast. | Not C4-native — general-purpose diagramming. Would need a C4-shaped convention on top, maintained by us. GitHub doesn't render `.d2` natively either. |

### Decision dimensions weighted

| Dimension | Weight | Mermaid | Structurizr | PlantUML | D2 |
|-----------|--------|---------|-------------|----------|-----|
| **GitHub inline render** (most users will open the repo and read the diagram there) | Critical | ✅ | ❌ | ~ (flaky) | ❌ |
| **Zero external dependency** (no Java, no Docker, no Go) | High | ✅ | ❌ | ❌ | ❌ |
| **C4 fidelity** (do L1/L2 diagrams look like proper C4?) | Medium | ~ | ✅ | ✅ | ~ |
| **Supports L3+ when we need it** | Low (deferred per #50) | ~ | ✅ | ✅ | ~ |
| **Single-source (no "DSL + rendered PNG" two-commit dance)** | High | ✅ | ❌ | ❌ | ❌ |

Mermaid wins on three of the four critical/high dimensions. Loses on C4 fidelity (fine for L1/L2, mediocre for L3+ — but L3+ is out of scope).

## Decision

Chosen: **Mermaid C4 for L1 + L2, in Markdown files committed alongside the rest of the docs**.

Concretely:

- Templates at `templates/architecture/c4-context.md` (L1) and `templates/architecture/c4-container.md` (L2) — both Markdown with a Mermaid C4 block inside.
- Rendered-in-place: users view diagrams by opening the `.md` file on GitHub; no separate PNG commit, no render step.
- Directory convention: framework-level diagrams in `docs/architecture/`, per-managed-project apexstack docs in `projects/<name>/architecture/`, project-internal code-level diagrams in that project's own `docs/architecture/` (follows the split already documented in `docs/multi-project.md`).

## Consequences

### Immediate (shipped with this AgDR)

- Two templates in `templates/architecture/` that any project / `/handover` output can copy and fill in.
- ApexStack dogfoods: `docs/architecture/apexstack-context.md` (L1) and `docs/architecture/apexstack-container.md` (L2) show the framework's own C4 diagrams. Meta, but demonstrates the convention.
- `docs/multi-project.md` updated with a "Architecture diagrams" subsection pointing at the convention.

### Deferred (follow-up issues filed with this PR)

- `/handover` skill emits a stub L2 container diagram from the assessment — useful but non-trivial change to the skill; bundled separately.
- Structurizr DSL as an escape hatch for projects that hit Mermaid's C4 ceiling (L3 component diagrams, precise "technology" metadata, auto-zoom). Add when a project asks.
- L3 component and L4 code templates — most projects won't need these; add when one does.

### Costs if we're wrong

Low. If a project later needs L3 precision, Structurizr can be added without deprecating Mermaid — they coexist happily (Mermaid for L1/L2 overview, Structurizr for deep L3 workspace). The templates are simple Markdown; deleting them is one commit. No lock-in.

### Costs if we're right but wait

Higher. Without diagrams, new engineers onboard more slowly on each managed project. Handover docs feel incomplete. The gap grows as the portfolio grows. Shipping Mermaid now is low-risk and makes the ApexStack-managed-project experience noticeably better.

## Artifacts

- Templates: `templates/architecture/c4-context.md`, `templates/architecture/c4-container.md`
- Dogfood examples: `docs/architecture/apexstack-context.md`, `docs/architecture/apexstack-container.md`
- Documentation: `docs/multi-project.md` § "Architecture diagrams"
- Follow-up issues (filed with the PR): `/handover` auto-generation, Structurizr DSL support, L3+ templates
- Ticket: [#50](https://github.com/me2resh/apexstack/issues/50)
- PR: (filled at merge time)
