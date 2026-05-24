# AgDR-0014 — `/launch-check` historical trend tracking (chart format, schema, opt-in)

> In the context of making slide 13's "Readiness Trend (last 5 runs)" graph real, facing several non-obvious choices (chart rendering, JSON schema shape, commit-vs-gitignore default), I decided **ASCII chart embedded in the per-run markdown, open JSON schema, gitignored-by-default with a presence-only opt-in marker**, to achieve a low-friction trend feature that adopters can adopt or ignore with zero ceremony, accepting that the ASCII chart is less visually polished than a rendered SVG but renders identically in every Markdown viewer (terminal, GitHub, IDE, blog).

## Context

apexyard#183 asks for persistent run history + trend rendering for `/launch-check`, so marketing slide 13 ("Readiness Trend (last 5 runs)") becomes a real feature instead of a mockup. The acceptance criteria leave three things deliberately open:

1. **Chart format** — "ASCII / Mermaid chart renders correctly in GitHub markdown preview"
2. **History storage** — "opt-in per project — `.launch-check-history-tracked` file marker decides committed-vs-gitignored"
3. **Schema** — sketched in the ticket but with no compatibility commitment

Each of these becomes a load-bearing decision that shapes adoption — get any one wrong and the feature feels like ceremony rather than value. This AgDR documents the choices.

## Options Considered

### A. Chart format

| Option | Pros | Cons |
|--------|------|------|
| **ASCII chart** (chosen) | Renders identically in every viewer (terminal, GitHub, IDE, blog). Zero dependencies. Composable with the rest of the markdown report. Easy to test deterministically. | Less visually polished than a rendered chart. Coarse y-axis resolution (~5 rows). |
| Mermaid pie/bar chart | Modern. GitHub renders it inline. Familiar to ApexYard users (already used in C4 diagrams). | Mermaid `xychart-beta` and `gantt` are awkward for time-series score data. Renders a "time" axis poorly when dates are coarse and irregular (the realistic /launch-check cadence). Doesn't render in the terminal at all — which is exactly where /launch-check output is read most often. |
| Rendered PNG/SVG | Pretty. | Requires rendering at run time + a binary file in the repo. Cannot be regenerated trivially across machines. Defeats "trend lives in markdown" simplicity. |
| GitHub Issues sparkline (UTF-8 block chars `▁▂▃▄▅▆▇█`) | One line; embeds in tables. | Less informative than the box-drawn ASCII chart. Loses the y-axis / date-axis context that makes the trend interpretable at a glance. |

### B. JSON schema for run files

| Option | Pros | Cons |
|--------|------|------|
| **Open schema, additive evolution** (chosen) | Forward-compatible — adopters who upgrade framework versions don't lose existing run files. Future fields (notes, actor, weighting) slot in without migration. | Not strictly typed; field-presence varies across run-file generations. |
| Versioned schema (`"schema": 1` field + migration script) | Explicit compatibility story. | Heavyweight for a feature with O(N) trivial JSON files. The fields the renderer reads are stable (`ts`, `scores`, `verdict`); additions are additive; deletions don't happen. A version field would be ceremony. |
| External schema file (JSON Schema validator) | Rigorous. | For an internal-only data store of <1KB files, ceremony exceeds value. Adopters who want strictness can lint locally — the framework doesn't impose it. |

### C. Commit-vs-gitignore default

| Option | Pros | Cons |
|--------|------|------|
| **Gitignored by default, presence-only marker file opts in** (chosen) | Most adopters won't want O(N) JSON files in the repo polluting diffs. Zero-config silence is the right default. Single-file opt-in is unambiguous. | Adopters who DO want trend history archived must remember to `touch .launch-check-history-tracked` once per project. |
| Committed by default | Trend visible to teammates without setup. | Bloat for adopters who don't care about historical trend. PR diffs noisy on every audit run. Common case loses. |
| Config-block toggle in `.claude/project-config.json` | Centralised. | Adopters managing multiple projects need to know which projects opted in; a per-project marker is more locally readable. |

## Decision

Chosen: **ASCII chart in the per-run markdown report, open additive JSON schema, gitignored-by-default with a presence-only `.launch-check-history-tracked` opt-in marker** — because:

1. **ASCII** maximises portability. /launch-check output is read in terminals, IDEs, GitHub PR comments, and blog posts. ASCII renders identically in all four; Mermaid renders only in GitHub-rendered markdown and breaks on terminal copy-paste.
2. **Open schema** matches the constraint in the ticket ("adopters with existing runs/ shouldn't lose them on framework upgrade"). The renderer reads only stable fields; additions are forward-compatible by construction.
3. **Gitignored-by-default with presence-only marker** matches the ticket's risk note ("History bloat — JSON files are tiny but accumulate over a year"). Most adopters never need history in the repo; making them un-ignore feels right.

## Consequences

- The `render-trend.sh` helper is the single source of truth for trend rendering. It can be invoked standalone (e.g. by a CI job that posts trend updates to Slack) — not just from the SKILL.
- The skill's per-run markdown summary at `<lc_dir>/<ts>.md` is the durable artefact; the JSON files are a build-input for the chart, not the user-facing artefact. Adopters who want a custom dashboard can read the JSON directly.
- If a future framework version adds operator-supplied notes (apexyard#183 v2 scope), the schema absorbs the new field without migration; older `.json` files continue to render. The "Notes" column in the trend table will source from `notes` if present, fall back to the auto-derived score-delta string otherwise.
- Adopters running on managed-project working trees inside `workspace/<name>/` should NOT confuse history files with project source. The launch-check dir lives under `projects/<name>/`, not in the project's own clone — a deliberate split that keeps audit history with the operator's docs, not the project's commit tree.
- The decision to use ASCII over Mermaid is reversible — if a future iteration wants Mermaid output (e.g. for a web dashboard), `render-trend.sh` can grow a `--format=mermaid` flag without breaking existing callers.

## Artifacts

- PR: feature/GH-183-launch-check-trend → me2resh/apexyard#183
- Skill: `.claude/skills/launch-check/SKILL.md`
- Renderer: `.claude/skills/launch-check/render-trend.sh`
- Test: `.claude/hooks/tests/test_launch_check_trend.sh`
