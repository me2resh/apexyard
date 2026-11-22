# Topologies: harness templates per service shape

A **topology** defines a common service shape: a web app, API service, or data pipeline. ApexYard supplies a standard configuration for each shape. Each topology bundles handbooks, CI pipelines, and stack-specific AgDR templates. Without a topology, adopters must assemble these framework components during each onboarding.

Design rationale: [`docs/agdr/AgDR-0048-topology-templates.md`](../docs/agdr/AgDR-0048-topology-templates.md).

> **Pick a topology when running `/handover`.** The skill asks early in its procedure. When you select a topology, it copies the bundle into the new project. The default is "Skip / custom". Adopters who do not want a bundle receive the existing procedure without changes.

## The three starter topologies (v1)

| Topology | Use when | Ambient affordances | Primary language |
|----------|----------|---------------------|------------------|
| [`typescript-nextjs`](typescript-nextjs/) | Building a SaaS web app with API routes, server components, and a relational DB | TS strict + Next.js conventions + ORM opinionation | TypeScript |
| [`python-fastapi`](python-fastapi/) | Building an HTTP service with persistence, JWT auth, and OpenAPI docs | Python type hints + Pydantic validation + FastAPI conventions | Python |
| [`go-data-pipeline`](go-data-pipeline/) | Building a batch or streaming pipeline (ETL, event processor) with no HTTP surface | Go's enforced error returns + module boundaries + stdlib-first | Go |

If your project does not match any of the three, run `/handover` without selecting a topology. You receive the existing procedure and the framework's default handbooks. The universal layer applies to all projects.

## Directory shape

Every topology uses the framework's component layout. The path supplies the discovery metadata, as with `handbooks/<bucket>/` and `templates/custom-templates/<path>`. See AgDR-0020 + AgDR-0023:

```
topologies/<name>/
├── VERSION                       ← semver string, "1.0.0" to start
├── README.md                     ← what this topology is for, when to pick it
├── handbooks/
│   ├── architecture/*.md         ← curated subset of handbooks/architecture/
│   ├── language/<lang>/*.md      ← stack-specific (typescript/, python/, go/)
│   └── domain/<area>/*.md        ← ≥ 3 concrete domain handbooks with paths: frontmatter
├── golden-paths/*.yml            ← stack-specific CI workflows
└── templates/agdr-<stack>.md     ← stack-specific AgDR template prompts
```

## Adding a new topology (framework PR)

v1 supports **framework-curated topologies only**. Adopter-authored topologies must wait until v2.1 (see AgDR-0048 § "Out of scope"). To propose a new topology:

1. File a feature ticket against `me2resh/apexyard` with the topology name and the stack it covers
2. Wait until at least 5 adopters have asked for the same shape (mitigates topology proliferation per #297)
3. Open a framework PR that adds `topologies/<name>/` with the directory shape above
4. Bump the topology's `VERSION` per the rules below. Use `1.0.0` for the first PR.

## Versioning

Each topology has its own `VERSION` file with a semver string. Bump rules:

| Change | Bump |
|--------|------|
| Add a new file (handbook, pipeline, template) | minor |
| Edit an existing file (clarify a rule, update a pipeline step) | patch |
| Remove a file (delete a handbook, drop a pipeline) | major (breaks adopter expectations) |
| New topology, first ship | `1.0.0` |

When an adopter runs `/update`, the skill compares topology versions. It compares the framework's `VERSION` with the adopter's `VERSION`, copied during handover. If the versions differ, it offers to copy each file again. See `.claude/skills/update/SKILL.md` § "Topology drift detection".

## Out of scope (v1)

- Adopter-authored topologies: v2.1, alongside custom-skills + custom-handbooks (AgDR-0022)
- Topology composition (e.g. "NextJS web + Python ML service"): select the closest single shape. Manually create the second.
- Per-team topology overrides: file a follow-up if multi-team adopters need this
- Automatic topology selection: `/handover` already detects the tech stack in step 3. A future PR can use that result to suggest a topology

## New project entry point

Use `/scaffold` to copy a bundle floor into a new project.
The skill selects the bundle from the confirmed host and shape answers.
It copies handbooks, writes CI commands, and records the bundle VERSION.
The typescript-nextjs bundle also copies its starter source tree.
A custom stack receives placeholders, an exact-pin check, and a request draft.
