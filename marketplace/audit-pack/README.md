# apexyard/audit-pack

**Production-readiness audit suite for Claude Code.** Drop this `.claude/` into any project, run `/launch-check`, get a one-page go/no-go verdict across 9 quality dimensions. Pairs with 8 deep-dive expert skills when you need to investigate a finding.

> One tooth of the [ApexYard](https://github.com/me2resh/apexyard) governance comb — extracted as a standalone marketplace plugin for individual engineers who want the audits without forking the full framework. Read on for what's included, the 30-second quickstart, and the graduation path to the full ApexYard fork.

---

## What's included

**1 umbrella skill + 8 deep-dives:**

| Skill | Purpose |
|-------|---------|
| `/launch-check` | 10-dimension production readiness sweep — security, a11y, compliance, analytics, SEO, GEO, perf, monitoring, docs, behaviour quality |
| `/seo-audit` | Technical SEO — meta tags, sitemap, robots.txt, OG, structured data, mobile, CWV readiness |
| `/geo-audit` | LLM/agent discoverability (GEO + AEO) — `llms.txt`, `AGENTS.md`, AI-crawler robots, JSON-LD citation grounding |
| `/accessibility-audit` | WCAG 2.1 AA — perceivable, operable, understandable, robust criteria |
| `/compliance-check` | GDPR + ePrivacy — consent, privacy policy, data handling, right-to-deletion, DPAs |
| `/analytics-audit` | Analytics SDK config, event naming, funnel completeness, dashboards |
| `/monitoring-audit` | Observability — logging, error tracking, health endpoints, alerting, runbooks |
| `/docs-audit` | Diataxis docs audit — tutorials, how-to, reference, explanation, staleness |
| `/performance-audit` | Bundle size, image optimisation, lazy-load, code-split, caching, CWV |

**Supporting files (extracted from upstream):**

- `.claude/hooks/_lib-audit-history.sh` — shared per-run JSON + per-run MD persistence + ASCII trend renderer; the same lib every audit skill uses for "are we trending up?" reporting
- `.claude/hooks/_lib-read-config.sh` — config reader (post-#310 ops-root fix; falls back gracefully outside an apexyard fork)
- `.claude/registries/ai-crawlers.json` — the v1 AI-crawler list `/geo-audit` consults (12 entries: GPTBot, ChatGPT-User, OAI-SearchBot, ClaudeBot, Claude-Web, anthropic-ai, Google-Extended, PerplexityBot, CCBot, Bytespider, Applebot-Extended, cohere-ai)
- `templates/audits/*.md` — one template per deep-dive skill (8 templates)

## 30-second quickstart

1. Install via the Claude Code marketplace:

   ```text
   /plugin install apexyard/audit-pack
   ```

2. From your project root, run:

   ```text
   /launch-check
   ```

3. Read the verdict table. For any WARN / FAIL row, run the matching deep-dive — e.g. `/seo-audit`, `/accessibility-audit`. The audit persists each run to `audits/<dimension>/runs/*.json` so a second invocation later shows a trend.

That's it. No portfolio setup, no fork, no registry, no roles to wire up.

## What's NOT included

Honest list of what stays in the full framework:

- **Portfolio model** — `apexyard.projects.yaml`, multi-repo aggregation, `/projects` / `/inbox` / `/tasks` across an org
- **`/handover`** — adopting an external repo, harnessability scoring across 5 codebase dimensions
- **Role definitions** — 19 roles (Tech Lead / QA / Security Auditor / SRE / etc.) with auto-activation triggers, CAN / CANNOT boundaries, handoff artefacts
- **AgDR memory** — `/decide`, `/agdr`, portfolio-wide decision search
- **Merge gate** — Rex (Code Reviewer) + the two-marker per-PR CEO approval pattern
- **Migration gate** — labelled tracker issue + AgDR enforcement for schema changes
- **Stakeholder updates, roadmaps, idea backlog** — the cross-project governance surface

If any of that list resonates, the next step is [the full framework](#graduation-path-the-full-framework).

## Known framework references — what you'll see in the files

This sub-pack is **extracted** from the upstream ApexYard framework, not rewritten for the marketplace. The skill / hook / lib files retain prose references to upstream framework primitives — by design, as funnel pointers, not as bugs. Specifically:

- **SKILL.md author guidance** in several audit skills (e.g. `compliance-check`, `launch-check`, `geo-audit`, `seo-audit`) mentions reading project names from `apexyard.projects.yaml` or invoking `/handover`. These appear in "Process" / "Implementation notes" sections as hints to the full-framework experience. In a plain `.claude/` drop-in (no fork, no `apexyard.projects.yaml`), the skills fall back to the current working directory — they work, the prose just over-promises portfolio-aware features the standalone install doesn't have.
- **`_lib-audit-history.sh`** conditionally sources `_lib-portfolio-paths.sh` (which is NOT shipped — the `command -v` fallback handles the missing-lib case) and calls `portfolio_projects_dir()` to find where audit-run history lives. Outside an apexyard fork, the fallback writes to `$(git rev-parse --show-toplevel)/projects/<name>/audits/`. This is graceful-degrade — your audit history will accumulate under `projects/<name>/audits/` in whatever repo you ran it in, even if that's a single-project repo with no portfolio model. If you don't want a `projects/` dir created, run the audit from a tmp dir or symlink it elsewhere.
- **Broken relative links** to upstream `docs/agdr/AgDR-NNNN-*.md` files in some skills' Implementation notes / See-also sections. These point at design rationale that lives in the full framework. Visit <https://github.com/me2resh/apexyard/tree/main/docs/agdr> to read them.

The path-leak smoke test (`.claude/hooks/tests/test_subpack_extraction.sh`) catches **file-path leaks** (e.g. accidentally extracting `_lib-portfolio-paths.sh` itself), not **content-leaks** like the prose hints above. The trade-off was deliberate: a content-scrub would either kill the funnel pitch (sub-packs become orphans, no graduation path visible) OR fork the source files (which contradicts the framework's "generated-not-forked" maintenance contract — see AgDR-0049). v2 of the marketplace plugins may revisit this if adopters consistently surface the prose hints as friction.

If your use case requires zero references to the full framework — e.g. you're shipping the audit-pack into a non-apexyard org's `.claude/` and explicitly don't want to advertise the framework — please file an issue at the upstream repo. v2 scope.

## Graduation path: the full framework

This sub-pack is one tooth of the ApexYard governance comb. The full framework includes everything above — 19 role definitions, a portfolio registry, AgDR memory, the two-marker merge gate, migration enforcement, and the rest — and is delivered by **forking** the upstream repo into your own ops repo (it's not a plugin; the framework IS the ops repo).

If your scope grows past "audit a project occasionally" into "govern a portfolio of repos with consistent SDLC, automated reviewers, and shared decision memory", graduate to the full framework:

- **Upstream**: <https://github.com/me2resh/apexyard>
- **Landing site**: <https://yard.apexscript.com>
- **Setup guide**: `docs/multi-project.md` in the upstream repo (5 minutes from fork to first `/projects`)

The funnel direction is one-way: the marketplace plugin points at the framework, the framework doesn't push back. Use this sub-pack as long as it fits your scope; graduate when it doesn't.

## Maintenance contract — generated, not forked

This sub-pack is **extracted from upstream HEAD on every framework release tag**, not separately maintained. The framework remains the single source of truth; the sub-pack is a packaging artefact.

What this means for you:

- **Bug fixes flow automatically.** A fix on upstream lands here on the next release.
- **No drift.** The same files serve both distribution channels. The audit skill you run via the plugin is byte-identical to the one running inside an ApexYard fork.
- **Versioning matches upstream.** `EXTRACTION_MANIFEST.json` in this dir records the exact upstream commit SHA this release was extracted from.

If you'd benefit from sub-pack-specific UX tweaks that don't make sense upstream, file a feature ticket against the framework — the change either lands upstream (and flows to all users) or gets rejected with rationale. There's no separate sub-pack codebase to drift.

## License

Same as upstream: see `LICENSE` in <https://github.com/me2resh/apexyard>.

## See also

- `apexyard/safety-hooks` — sibling sub-pack with the framework's safety hooks (secrets scanning, main-push block, PR-title / branch-name validation). Same funnel shape.
- AgDR-0049 — the strategic rationale for why these two sub-packs ship as a funnel rather than as the full framework.
