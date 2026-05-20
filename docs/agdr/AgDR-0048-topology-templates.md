# Harness templates by topology — framework-curated bundles per service shape

> In the context of every new project adoption forcing the operator to reassemble the same governance surface (handbooks + AgDR templates + CI pipelines + Rex domain knowledge) by hand, facing both reassembly fatigue AND the variety-explosion that makes the harness less effective per Ashby's Law, I decided to ship **`topologies/<name>/` as a path-mirrored directory tree** of framework-curated bundles (TypeScript NextJS web app, Python FastAPI service, Go data pipeline) instantiated by `/handover` at adoption time and version-tracked by `VERSION` files so `/update` can detect drift, to achieve a "pick one, get the right harness" experience that narrows the agent's output space to a stack the framework has opinions about, accepting the maintenance cost of three starter bundles + the drift-detection mechanism + a deliberately narrow v1 scope (no adopter-authored topologies, no composition).

## Context

Six framework primitives already exist that an adopter must wire up per project on every onboarding:

1. `handbooks/architecture/*.md` — clean-architecture, migration-safety
2. `handbooks/language/<lang>/*.md` — strict-mode rules, error-wrapping conventions
3. `handbooks/domain/<area>/*.md` — per-codebase domain knowledge (the `paths:` frontmatter convention from #293)
4. `golden-paths/pipelines/*.yml` — reusable CI workflows (code-quality, security, dependency-audit)
5. `templates/agdr*.md` + `templates/architecture/*.md` — decision-record forms
6. Rex's discovery globs in `.claude/agents/code-reviewer.md` § 8 — what gets loaded per PR

Today, the adopter reassembles these by hand on every `/handover`. The output is **a different mix every time**, which produces three problems:

1. **Reassembly fatigue.** A Next.js adoption picks the same six TypeScript bits every time; a Python FastAPI adoption picks the same eight Python bits. The framework knows the answer better than the operator does, but doesn't pre-bake it.
2. **Variety explosion (Ashby's Law).** When the harness has to regulate any output the agent might produce, it's underspecified. When the harness commits to "we ship NextJS web apps", it can be MORE specific, MORE opinionated, and therefore MORE effective. Variety reduction is the load-bearing mechanism.
3. **Drift-by-default.** No matter how the adopter assembles the bundle, it falls out of sync the moment they walk away. Same problem service templates have had for years.

The ticket (#297) framed the move as **harness templates** — a term from industry harness-engineering for "the bundle of feedforward guides + feedback sensors pre-configured for one topology." The decision is **how to structure that bundle, where it lives, and how it stays current**.

## Options Considered

### A) Where the topology bundle lives — directory layout

| Option | Pros | Cons |
|--------|------|------|
| **Path-mirrored directory tree (chosen)** — `topologies/<name>/{handbooks,golden-paths,templates,VERSION}/...` mirrors the framework's own layout | Discovery is the convention; no registry to maintain; mirrors how `handbooks/`, `templates/custom-templates/`, and `custom-handbooks/` already work (#232, AgDR-0023); operator opens a topology dir and sees exactly what they're getting | Repeats the framework's own layout once per topology (some file duplication — but copies, not shared state) |
| Frontmatter-tagged single tree — every framework file gets a `topologies: [typescript-nextjs, python-fastapi]` YAML key; `/handover` filters | Single source for each file; no duplication | Coupling explodes — a TS handbook editor must remember the topology tag; the framework's other consumers (Rex's globs) would need to grow a topology-aware filter; partial discovery (file present in one topology and not another) is hard to express; adopter-authored extensions break the closed-world frontmatter |
| Central JSON manifest — `topologies.json` at the framework root maps each topology to a list of files | One file describes the world | The manifest IS a registry by another name; every framework PR has to remember to update it; conflict-prone (two parallel PRs both touch the manifest); no per-file isolation when reading a topology |
| Config-block in `.claude/project-config.defaults.json` — `topologies.<name>.{handbooks, pipelines, ...}` arrays | Reuses the existing config-resolution infrastructure | Same downsides as the JSON manifest, plus the config defaults file is already a busy surface |

Chosen: **path-mirrored directory tree**. Mirrors the existing `handbooks/` + `custom-templates/` + `custom-handbooks/` conventions (path IS the metadata — AgDR-0023). Adopter-authored topologies in v2.1 will be a trivial extension (drop a sibling directory under `<private_repo>/custom-topologies/`).

### B) Which 3 starter topologies — variety reduction angle

The ticket recommended TS NextJS / Python FastAPI / Go data pipeline. Alternatives considered:

| Option | Pros | Cons |
|--------|------|------|
| **TS NextJS web app + Python FastAPI service + Go data pipeline (chosen)** | Three categorically different shapes: a UI-heavy SPA-with-API, an HTTP service with persistence + auth, a batch/streaming pipeline with no HTTP surface. Maps to three of the most common adoptions in the framework's target audience. Each stack has high ambient affordances (TS strict, Python type hints, Go's enforced error returns) — Ashby's-Law variety reduction is meaningful | Three stacks to maintain; the bar for adding a fourth (e.g. Rust web service) becomes a "5+ adopters ask" gate per the ticket's risk note |
| TS NextJS + Python FastAPI + Node Express | Two Node ecosystems is redundant; Express adds nothing categorically different from NextJS API routes | Variety reduction collapses if two topologies overlap |
| TS NextJS + Rails + Go data pipeline | Rails has very high opinionation (would be a great fourth topology) | Rails ecosystem isn't the framework's strongest first impression; defer to v2.1 |
| Just one — TypeScript NextJS, nothing else | Lowest maintenance | Validates the pattern but doesn't prove it generalises; future operators of Python/Go projects see nothing |

Chosen: **three categorically different stacks**. Each one demonstrates that the convention works across languages (TS / Python / Go), architecture shapes (SPA / API service / pipeline), and ambient-affordance profiles (high / high / high). Adding a fourth requires 5+ adopter requests per the ticket's risk-mitigation rule.

### C) Version tracking — how `/update` detects drift

| Option | Pros | Cons |
|--------|------|------|
| **`VERSION` file per topology (chosen)** — semver string at `topologies/<name>/VERSION`; adopter's instantiation copies the file alongside the bundle | Trivial diff (`sort` / `diff` the strings); operator reads the file and knows what version they're on; bumps live in the framework's normal release cycle; matches the per-pair migration anchor pattern from AgDR-0032 | One more file to update per topology when the bundle changes (mitigated: the `/update` skill prompts when it detects an unbumped version) |
| Git-tag-based — `topology-typescript-nextjs-v1.0.0` tags on the framework repo | Free for the framework (tag once, ignore); no per-topology file | Adopter's instantiated copy carries no marker; `/update` has to re-derive the version from the diff content, which is brittle |
| Content-hash comparison — `/update` hashes the live framework bundle and compares to the adopter's | Self-healing; no version file needed | Hashes are noisy (whitespace, line endings); the operator can't read "we're on 1.0.0" from a hash; no human-readable bump signal |

Chosen: **`VERSION` file**. Semver, human-readable, trivially diffable, matches the per-version migration anchor in `.claude/migrations/`. The skill writes the file when it instantiates; `/update` reads both sides and offers re-instantiation when they differ.

### D) `/handover` integration shape — where the topology pick goes in the flow

| Option | Pros | Cons |
|--------|------|------|
| **Early-flow question after the project name (chosen)** — step 1.5 after locating the repo, before tech-stack detection | Pre-commits the operator to a topology; the rest of the handover flow can use it to skip duplicate scans (the topology already knows it's a NextJS app) | Asks before the auto-detection has fired; if the operator picks wrong, the assessment may be off |
| Late-flow interactive pick — after the harnessability assessment, before the final summary | Auto-detected tech stack pre-fills the topology suggestion | Adds a second interactive step at the end of an already-long flow; most adopters won't change the suggestion anyway |
| `--topology <name>` CLI flag only — no prompt | Power-user shape; scriptable | Most operators don't know the available topology names; discoverability drops |

Chosen: **early-flow question + CLI flag**. The skill prompts after the project name resolves (step 1.5), and `--topology <name>` is a power-user override. Default is "Skip / custom" — picks a no-bundle outcome that matches the existing flow byte-for-byte (zero regression for adopters who don't want a topology).

### E) Framework-curated vs adopter-authored (v1 scope)

The ticket lists "Adopter-authored topologies" as v2.1 explicitly. Two reasons to keep v1 framework-curated:

1. **Quality bar.** A framework topology has the framework's reviewers behind it. An adopter-authored topology has whoever wrote it; without a review surface, the marketplace fills with junk topologies.
2. **Discovery surface.** v1 ships with three named topologies in `topologies/`. Adding a fourth requires a framework PR. v2.1 will add `<private_repo>/custom-topologies/<name>/` with the same path-mirroring convention — but that's a separate motion (sibling to the custom-skills + custom-handbooks discovery hook, AgDR-0022).

Out of scope for v1 (per the ticket): topology composition ("NextJS web + Python ML"), per-team overrides, more than three starter topologies.

### F) Migration shape — `/update` topology-version drift detection

When `/update` runs, it should detect that the adopter's instantiated topology bundle is behind the framework's `topologies/<name>/VERSION`. Two options:

| Option | Pros | Cons |
|--------|------|------|
| **Per-file diff offer (chosen)** — for each file in the topology bundle, diff adopter copy vs framework copy; offer "accept / skip / abort" per file | Operator owns each material change (same shape as deprecated-config offer in step 8 of `/update`, AgDR-0032); idempotent; partial-acceptance possible | Slower than a bulk replace; many prompts for a topology with many files |
| Bulk replace with one operator confirmation | One prompt | Loses local edits the adopter made on top (handbook prose tuning, CI step renames, etc.) |

Chosen: **per-file diff offer**, default "skip — manual sync". Matches the existing per-pair migration convention. Bulk replace is dangerous and the cost of the prompts is acceptable for what's typically a 5-15 file bundle.

## Decision

Chosen: **path-mirrored `topologies/<name>/` directory tree, three starter topologies (TS NextJS / Python FastAPI / Go data pipeline), `VERSION` file per topology, `/handover` early-flow pick (default Skip / custom), `/update` per-file drift detection (default skip), framework-curated only in v1**.

The directory shape:

```
topologies/
├── README.md
└── <name>/                            ← typescript-nextjs / python-fastapi / go-data-pipeline
    ├── VERSION                        ← semver string, e.g. "1.0.0"
    ├── README.md                      ← when to pick this topology, what it bundles
    ├── handbooks/
    │   ├── architecture/*.md          ← curated subset, copied by /handover
    │   ├── language/<lang>/*.md       ← stack-specific (e.g. typescript/, python/, go/)
    │   └── domain/<area>/*.md         ← ≥ 3 concrete examples demonstrating paths: frontmatter
    ├── golden-paths/*.yml             ← stack-specific CI workflows
    └── templates/agdr-<stack>.md      ← stack-specific AgDR prompts
```

Files are **copied, not symlinked**. Symlinks would couple the adopter's instantiated handbook to the framework's evolution — every framework PR that edits a handbook would silently mutate every adopter's instantiated copy. Copies are stable; `/update` detects drift on top and offers re-instantiation per file.

## Consequences

- The `/handover` skill grows an early-flow topology-pick step (step 1.5) with a `--topology <name>` CLI override. Default is "Skip / custom" — zero-regression for adopters who don't want a bundle.
- On pick, the skill copies the topology's `handbooks/` content into the project's `handbooks/` (creating it if needed), copies the topology's `golden-paths/*.yml` into the project's `.github/workflows/`, and seeds `templates/agdr-<stack>.md` into the project's `docs/agdr/` as a `.draft.md` (so it doesn't trigger AgDR-required hooks on first sight).
- The `/update` skill grows a new step (post-step-9-final) that compares each adopter-instantiated topology's `VERSION` file vs the framework's `topologies/<name>/VERSION`. On drift, the skill offers per-file diff acceptance.
- The three v1 starter topologies ship with **9 handbooks total** (3 architecture + 3 language + ~3-4 domain per topology — see file inventory in the PR), **3 CI pipelines**, and **3 stack-specific AgDR template seeds**. Adding a fourth topology is a framework PR + an `5+ adopters asked` gate.
- Topology version bumps follow framework's existing release-cut cadence. A handbook edit inside a topology bumps that topology's `VERSION` patch; a new handbook adds a minor bump; removing a handbook is a major bump (breaks adopter expectations).
- The path-mirroring convention is open — a v2.1 PR can add `<private_repo>/custom-topologies/<name>/` with the same shape, and `/handover` will discover it the same way (sibling to AgDR-0022's custom-skills layer).
- A new row in `CLAUDE.md` quick-reference table names `topologies/` so adopters can find it. The description stays ≤ 25 words to satisfy the Wave 1 invariant.
- Rex does **not** grow topology awareness in v1. Discovery is still per-handbook via the path convention; the topology only seeded the handbooks. Rex's review behaviour stays unchanged.
- Smoke test at `.claude/skills/handover/tests/test_topology_pick.sh` asserts the three starter topology dirs exist + have the five required files (`VERSION`, `README.md`, ≥ 1 handbook per axis). Wave 1 invariants stay green — the new CLAUDE.md row is terse.

## Artifacts

- `topologies/typescript-nextjs/` — full bundle (VERSION, README, handbooks, golden-paths, templates)
- `topologies/python-fastapi/` — full bundle
- `topologies/go-data-pipeline/` — full bundle
- `topologies/README.md` — convention pointer + "how to pick"
- `.claude/skills/handover/SKILL.md` — extended with topology-pick step + bundle-instantiation
- `.claude/skills/update/SKILL.md` — extended with topology-version drift detection
- `.claude/skills/handover/tests/test_topology_pick.sh` — smoke test
- `CLAUDE.md` — new row in QUICK REFERENCE table
- Closes: `me2resh/apexyard#297`
- Related: AgDR-0020 (handbooks foundation), AgDR-0023 (path-mirroring template overrides), AgDR-0032 (per-version migration chain), AgDR-0037 (domain handbooks + `paths:` frontmatter), AgDR-0042 (harnessability dimensions)
