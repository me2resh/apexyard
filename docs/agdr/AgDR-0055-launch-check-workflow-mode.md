# Add an opt-in `--workflow` mode to `/launch-check` (parallel + adversarial verify)

> In the context of `/launch-check` being a 10-dimension, independent, read-only production-readiness audit, facing the wish for a faster and higher-confidence milestone sweep, I decided to add an **opt-in `--workflow` mode** that authors and runs a Claude Code `Workflow` to fan the dimensions out concurrently and adversarially verify each FAIL/WARN finding before it reaches the verdict, to achieve lower wall-clock latency and fewer false positives, accepting a higher per-run token cost — which is why the mode is opt-in and the serial path stays the default.

## Context

`/launch-check` evaluates 10 dimensions (security, accessibility, compliance, analytics, SEO, generative-engine, performance, monitoring, docs, behaviour-quality). They are mutually independent, read-only, and have no human gate — the textbook fan-out shape. The default skill runs them serially in one agent context.

Claude Code ships a `Workflow` primitive for deterministic multi-agent orchestration (parallel/pipeline fan-out, adversarial verification, synthesis). `/launch-check` is the framework's best-fit consumer: pure audit, no merges or approvals to serialize. The question was whether — and how — to wire it in without regressing the cheap default or the persisted trend history.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| **Leave `/launch-check` serial only** | Cheapest; zero new surface | Slow wall-clock on a 10-dimension sweep; single-context evaluation is more prone to plausible-but-wrong findings (no independent check) |
| **Use the existing `/fan-out` skill** | Already in the framework | `/fan-out` spawns parallel agents but has no built-in adversarial-verify / synthesize / structured-output stage; we'd rebuild the verify loop by hand each time |
| **Make `Workflow` the default for `/launch-check`** | Best output every run | Every run spawns ~10–20 agents — large token cost for a routine audit; violates the "Workflow requires explicit opt-in" norm |
| **Opt-in `--workflow` mode (chosen)** | Faster + adversarially-verified when you want it; serial default unchanged; reuses the same persistence + trend | One more mode to document; the workflow script lives in the skill as the canonical shape |

## Decision

Chosen: **opt-in `--workflow` mode.**

1. **Opt-in, never default.** A workflow run spawns ~10–20 agents vs one serial pass. Per the `Workflow` tool's own rule, multi-agent orchestration needs explicit opt-in — the `--workflow` flag *is* that opt-in. No flag → serial path, no `Workflow` invocation.

2. **Fan-out + pipeline, not a barrier.** Each dimension is evaluated by its own agent, and each FAIL/WARN finding is adversarially verified *as soon as that dimension returns* (pipeline, no barrier) — the slowest dimension doesn't hold up the others' verification.

3. **Adversarial verify is the value-add.** A second independent agent is prompted to *refute* each WARN/FAIL (default `upheld=false` if it can't independently confirm). A refuted finding is downgraded to PASS with a note. This is the false-positive cut that single-context serial evaluation can't do. PASS findings are not re-verified (nothing to refute).

4. **Same output, same persistence, same trend.** The workflow synthesizes the identical verdict table + four-state verdict vocabulary, and persistence resumes at the existing Step 6 — same `_lib-audit-history.sh` (`audit_run_persist` / `audit_render_trend`), same superset JSON schema, same `render-trend.sh` chart. Trend history is continuous across serial↔workflow runs; no schema migration.

5. **Graceful degrade.** If `Workflow` isn't available in the installation, the skill falls back to the serial path with a one-line notice. `--workflow` is an optimisation, not a hard dependency.

## Consequences

- `/launch-check` gains a third mode; frontmatter `argument-hint` + the modes list + a "Workflow mode" section (with the canonical workflow script, dimension/verdict schemas, and the after-the-workflow synthesis+persist steps) are added to the skill.
- No new skill / hook / role / agent — the framework counts are unchanged (this is a mode added to an existing skill), so `test_site_counts.sh` is unaffected.
- The canonical workflow script is documented in-skill so each run authors a consistent workflow (stable phases, structured output, dedupe, persist) rather than an ad-hoc one.
- Establishes the **pattern** for wiring `Workflow` into other multi-dimension audit skills (`/threat-model`, `/accessibility-audit`, etc.) the same way if it proves useful — opt-in flag, reuse the dimension criteria, synthesize to the existing output + persistence.

## Artifacts

- Issue: me2resh/apexyard#473
- Edited: `.claude/skills/launch-check/SKILL.md` (frontmatter, modes list, new "Workflow mode" section), `CLAUDE.md` (skill blurb)
- Related: the `Workflow` tool (Claude Code harness primitive), `/fan-out` (the lighter parallel-agent skill), `_lib-audit-history.sh` + `render-trend.sh` (unchanged persistence/trend), `.claude/rules/parallel-work.md` (when to offer parallel execution).
