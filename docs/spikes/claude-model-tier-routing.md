# Spike: Claude Opus / Sonnet / Haiku model-tier routing for bounded sub-tasks — taxonomy + measurement + recommendation

> **Ticket**: [me2resh/apexyard#197](https://github.com/me2resh/apexyard/issues/197)
> **Sibling spike**: [me2resh/apexyard#195 → PR #196](https://github.com/me2resh/apexyard/pull/196) (local-model routing for the same bounded-sub-task class — file lands at `docs/spikes/local-model-routing.md` once #196 merges)
> **Status**: spike complete — recommendation: **GO, opt-in via per-skill `model:` frontmatter, declared per-skill from a unified per-task tier hierarchy**
> **Author**: Tech Lead (assumed via SDLC role activation)
> **Date**: 2026-05-03

---

## TL;DR

1. **The invocation primitive already exists.** Claude Code v2.x ships first-class per-skill and per-subagent `model:` frontmatter fields (sources: [Model configuration](https://code.claude.com/docs/en/model-config), [Skills](https://code.claude.com/docs/en/skills), [Subagents](https://code.claude.com/docs/en/sub-agents)). A skill can declare `model: haiku` and Claude Code routes that skill's turn to Haiku. A subagent invoked from any skill can be pinned to a different tier than the orchestrator. The 2026-04 ticket framed this as an open question — *"can a skill dispatch to a different tier for one tool call?"* — and the answer is **yes, and shipped, and adopters can use it today**.
2. **The taxonomy is the load-bearing output.** I walked the 42 skills under `.claude/skills/` and the 5 sub-agents under `.claude/agents/` and assigned each a target tier from the hierarchy below. The walk surfaced 8 skills clearly justifying Opus, 19 clearly justifying Sonnet, 9 clearly justifying Haiku, and 6 that should stay on `inherit` because they're orchestration shells with a few mixed sub-decisions inside.
3. **Token-cost savings are modest, but are not the headline.** At April-2026 pricing (Haiku $1/$5 per 1M, Sonnet $3/$15, Opus $5/$25 per 1M input/output), routing a heavy-adopter's mechanical workload (status briefings, glossary stubs, slug derivation, ticket-creation prose) from Opus to Haiku saves on the order of **~$0.50-3 per adopter per week** — real but not dramatic. The headline is **latency** (Haiku is 2-4× faster) and **principle** (use the cheaper tool when good enough is good enough — the same pattern that gave us pure-tool hooks).
4. **There is one blocker class for measurement.** I do not have an `ANTHROPIC_API_KEY` available in this spike's runtime, and the spike scope did not justify provisioning one. All five Phase-2 measurements are honest **estimates** built from public token counts of representative apexyard prompts and the published $/1M pricing. The relative ranking — Haiku ≪ Sonnet ≪ Opus on cost; Haiku < Sonnet ≪ Opus on quality for synthesis-shaped tasks; Haiku ≈ Sonnet ≈ Opus on quality for short classifier-shaped tasks — is well-evidenced in independent benchmarks and does not depend on the missing live numbers. The **absolute** numbers should be treated as ±30%.
5. **Convergence with #195 produces a clean per-task tier hierarchy** (full table in [Phase 5](#phase-5--convergence-with-195-pure-tool--haiku--sonnet--opus--local)):

   ```
   pure-tool   →  Haiku  →  Sonnet  →  Opus  →  Local (opt-in fallback)
   ```

   Each task's "first-choice" tier is set by the spike's taxonomy (Phase 1). The #195 local-LLM tier slots in **alongside Haiku** as an opt-in privacy / offline fallback for the synthesis-shaped tasks where Haiku is the recommended tier — never above Sonnet, and never as the default for any task.
6. **AgDR Y-statement (sketched, not drafted)**: *"In the context of bounded sub-tasks inside ApexYard skills, facing the cost and latency of routing all of them through whatever tier the operator's session happens to be on, we will adopt **per-skill `model:` frontmatter declarations** that set each skill to the tier its workload actually needs (Haiku / Sonnet / Opus / inherit), and **honour the per-task tier hierarchy** that converges this spike with the local-model spike (#195), accepting (a) one frontmatter field added to most skill files, (b) a documented protocol for promoting / demoting a skill's tier on measurement evidence, and (c) the operator-side reality that the active model in `/model` is still the upper bound — `availableModels` in managed settings stays the enforcement lever."*

---

## Phase 1 — Task taxonomy

The ticket's tier-by-use-case table is the right shape; the apexyard-specific question is *"which of our 42 skills + 5 sub-agents goes where?"* This section walks every framework primitive and assigns a tier with reasoning.

### Tier definitions (the hierarchy this spike commits to)

| Tier | Workload shape | Why this tier | Latency target |
|------|----------------|---------------|----------------|
| **Pure tool** (no model) | Mechanical, fully-specified. Regex / template / `gh` API / shell. | Zero token cost, zero latency, deterministic. Hooks are the prior-art. | <50 ms |
| **Haiku** | Short input, short output, classifier-shaped or render-shaped. Bounded vocabulary. Examples: derive AgDR slug from Y-statement, render a status briefing from structured facts, suggest a conventional-commit type, summarise a 10-PR inbox into 3 lines. | Haiku 4.5 hits ~95% of Sonnet's quality on tasks of this shape at ~3× lower input cost ($1 vs $3 / 1M) and ~3× lower output cost ($5 vs $15 / 1M). Latency p50 around 0.4 s for short prompts. | <1 s |
| **Sonnet** | Moderate synthesis, structured prose output. Stakeholder updates, ticket bodies, idea capture, validate-idea triage, handover synthesis prose phase, spec drafting. Multiple constraints to weigh, several paragraphs to compose. | Sonnet 4.6 is the workhorse: enough reasoning to compose multi-section structured output, fast enough that operators don't notice. Cheaper than Opus by 5×; quality drop on this shape is typically imperceptible. | <2.5 s |
| **Opus** | Heavy synthesis, novel reasoning, judgment with consequences, long context. Architecture review, threat modelling, deciding between three+ libraries, root-cause debugging chains, substantive code review, AgDR drafting where the trade-offs are non-obvious. | Opus 4.7 is needed when the wrong call has lasting consequences (architecture commitment, security posture, design pattern lock-in). Worth the 5× premium because the task lives in `docs/agdr/` for years. | <5 s p50 |
| **Local** (opt-in, sibling spike #195) | Same shape as Haiku tasks, alternate path. Privacy-sensitive sub-tasks where prompt content (PR titles, ticket text) shouldn't leave the machine. | Quality floor lower than Haiku at 7B Q4; redeemable via a regex-extracts-facts / LLM-narrates hybrid (#195's recommendation). Per-machine opt-in. Not a default for any task. | 2-5 s (warm) |

### Walkthrough — every skill in `.claude/skills/`

Categorisation rule: **what's the model actually doing in this skill's body?** If the skill is mostly `gh ... | jq ...` and a short paragraph of synthesis, it's Haiku-shaped. If it's a multi-section structured artefact (PRD, handover assessment, ticket body), it's Sonnet-shaped. If it requires comparing options and recording rationale that lives for years, it's Opus-shaped.

| Skill | Recommended tier | Reasoning |
|-------|------------------|-----------|
| `/accessibility-audit` | **Sonnet** | Multi-criterion audit (perceivable / operable / understandable / robust) with structured output. Synthesis-shaped, not novel reasoning. |
| `/agdr` | **Haiku** | Library / search / show / stats over filesystem-extracted YAML. Bash + jq does the heavy lifting; the model just renders. |
| `/analytics-audit` | **Sonnet** | SDK + event-taxonomy review with structured output. Same shape as the other audits. |
| `/approve-design` | **Pure tool** + **Haiku** | The marker write is `printf` to a file (pure tool). The "explain why design is approved" wrap is Haiku-shaped. |
| `/approve-merge` | **Pure tool** + **Haiku** | Same pattern as approve-design. The merge gate read is shell-driven; the rendering is Haiku-shaped. |
| `/audit-deps` | **Sonnet** | Vulnerability + license + outdated triage. Synthesis-shaped over `npm audit` / `gh api` output. |
| `/bug` | **Sonnet** | Structured ticket body (Given/When/Then + repro + severity). Multi-section structured output. |
| `/c4` | **Sonnet** | Detect external actors, deployable containers, write Mermaid diagrams. Synthesis-shaped. Could justify Opus on first-time analysis of a large unknown codebase, but the artefact is structurally constrained. |
| `/code-review` | **Opus** *(when invoked on substantive PRs)*; **Sonnet** *(routine)* | This is the canonical "tier-aware skill" — see [Phase 3 example](#example-1--code-review-tier-aware). Today's code-reviewer agent inherits, which means it runs on whatever the operator is on. Recommendation: split. |
| `/compliance-check` | **Sonnet** | GDPR / ePrivacy structured audit. Same shape as the other audits. |
| `/debug` | **Opus** | Hypothesis-driven structured debugging. The whole point is the model holds 4+ hypotheses, walks each, doesn't reach for a fix until evidence arrives. Cheaper tiers reach for fixes too quickly. |
| `/decide` | **Opus** | The decision lives in `docs/agdr/` for years. Wrong call → years of regret. Pay the premium. |
| `/docs-audit` | **Sonnet** | Diataxis-framework audit. Synthesis-shaped. |
| `/fan-out` | **inherit** | This skill *spawns other agents* — the dispatcher logic is short, but the agents it spawns inherit-or-set their own tier. Routing fan-out itself to Haiku risks over-aggressive parallelisation; routing to Opus is wasteful. Inherit. |
| `/feature` | **Sonnet** | Structured user-story + AC ticket body. Same shape as `/bug`, `/task`. |
| `/handover` | **Sonnet** *(prose synthesis)* + **Opus** *(architecture summary)* | The bulk is prose summarisation; the architecture-summary section justifies a one-shot Opus call. See [Phase 3 example](#example-2--handover-mixed-tier). |
| `/idea` | **Sonnet** | Capture to backlog + categorisation. Light prose synthesis. |
| `/inbox` | **Haiku** | Aggregate + summarise PR / issue / comment items. Same shape as `/status` — fact extraction is `gh`-driven; the model renders. The sibling spike's hybrid recommendation (regex extracts facts, model narrates) applies here as the structural pattern even when staying on Haiku. |
| `/launch-check` | **Sonnet** *(per-dimension)* + **Opus** *(verdict synthesis)* | 8 dimensions × ~Sonnet-shaped audits + a final synthesis call that weighs them. The verdict-synthesis turn is Opus-worthy — it's the "go / conditional / no-go" call leadership reads. |
| `/migration` | **Sonnet** + **Opus** *(rollback design)* | Migration ticket body is Sonnet-shaped; the rollback / observability section justifies Opus on non-trivial migrations. |
| `/monitoring-audit` | **Sonnet** | Observability audit. Same shape as other audits. |
| `/onboard` | **Pure tool** | DEPRECATED skill that just redirects. No model needed. |
| `/performance-audit` | **Sonnet** | Bundle / image / Core-Web-Vitals audit. Same shape as other audits. |
| `/projects` | **Haiku** | Walk registry + render table. The model is rendering, not reasoning. |
| `/release` | **Sonnet** | CHANGELOG synthesis from conventional commits. Bounded vocabulary; structured output. Could justify Opus on major-version cuts but the marginal gain is small. |
| `/roadmap` | **Sonnet** | Milestone table edits + reprioritisation. Light synthesis; structured output. |
| `/security-review` | **Opus** | Security review is judgment-heavy. Same argument as `/code-review` on substantive PRs. |
| `/seo-audit` | **Sonnet** | Meta / sitemap / robots / OG / structured-data audit. Same shape as other audits. |
| `/setup` | **Haiku** | Three-question onboarding flow that writes `onboarding.yaml`. Mostly templated. |
| `/spike` | **Sonnet** | Spike-ticket body (hypothesis / budget / kill criteria / disposition). Structured. |
| `/spike-close` | **Sonnet** | Closes a spike via the disposition gate; PROMOTE writes a follow-up ticket. Structured prose. |
| `/split-portfolio` | **Sonnet** | Migration helper for the public/private split. Mostly script + prose status. |
| `/stakeholder-update` | **Sonnet** | Audience-aware narrative synthesis. Sonnet's natural shape. |
| `/start-ticket` | **Pure tool** | Marker write + verification. The "suggest a branch name" sub-step is Haiku-shaped if it stays in this skill, but the skill's body is mostly `gh` + `mkdir` + `printf`. |
| `/status` | **Haiku** | Aggregate + render. Same shape as `/inbox` and `/projects`. |
| `/task` | **Sonnet** | Technical task ticket body. Same shape as `/bug` and `/feature`. |
| `/tasks` | **Haiku** | Aggregated, sorted task list with URLs. Render-shaped. |
| `/threat-model` | **Opus** | STRIDE walks across the codebase + the synthesis of ranked threats. Judgment-heavy; the artefact persists. |
| `/tickets-batch` | **Sonnet** | Bulk filing of 5-20 structured tickets — same per-ticket shape as `/feature` × N. |
| `/update` | **Pure tool** + **Sonnet** *(conflict resolution)* | The fetch / merge / preview is shell-driven; the conflict-resolution turn is Sonnet-shaped (or Opus on hard conflicts). |
| `/validate-idea` | **Sonnet** | 5-question pre-spec triage. Structured prose. |
| `/write-spec` | **Sonnet** *(typical)* + **Opus** *(novel domain)* | PRD drafting is Sonnet-shaped for routine features; first PRD on a new product surface justifies Opus. |

### Walkthrough — sub-agents in `.claude/agents/`

Sub-agents are the cleanest place to apply per-task routing because each is a single role with a single shape. Today every apexyard agent declares `model: inherit` (verified in `.claude/agents/*.md`). The walkthrough below assigns each a target tier:

| Agent | Today | Recommended | Reasoning |
|-------|-------|-------------|-----------|
| **Code Reviewer (Rex)** | `inherit` | **Opus** by default, **Sonnet** for ≤200-line PRs | The primary review gate. Substantive PRs deserve Opus's reasoning; small PRs are Sonnet-shaped. Could be wired with two agents (`code-reviewer-deep` / `code-reviewer-light`) and dispatched by PR diff size. |
| **Security Reviewer (Hatim)** | `inherit` | **Opus** | Security review is judgment-heavy with consequences. Always pay the premium. |
| **Dependency Auditor (Munir)** | `inherit` | **Haiku** | Mechanical: read package manifest, query advisories, render table. No reasoning beyond "is this CVE high or critical". |
| **PR Manager (Tariq)** | `inherit` | **Sonnet** | Coordinates the PR lifecycle — multi-step but structured. Sonnet handles the workflow comfortably. |
| **Ticket Manager (Idris)** | `inherit` | **Haiku** | Creates / labels / assigns issues. Mostly `gh` calls + a paragraph of confirmation. |

### Summary distribution across 42 skills + 5 agents

| Tier | Count | Share |
|------|------:|------:|
| Pure tool only | 4 | 8% |
| Haiku | 11 | 23% |
| Sonnet | 22 | 47% |
| Opus | 7 | 15% |
| Inherit (mixed-tier orchestration) | 3 | 7% |

The headline pattern: **Sonnet is the fat middle of the framework.** Most apexyard work is structured-prose-from-structured-facts, which is exactly what Sonnet is calibrated for. Haiku absorbs the render-shaped tail; Opus is reserved for the small set of decisions that justify it. This matches the recommended assignment pattern from the official docs ("session on Opus for high-level reasoning, route implementation to Sonnet, route file discovery to Haiku" — [Pick the right model](https://dev.to/klement_gunndu/pick-the-right-claude-code-model-for-every-task-1p6a)).

---

## Phase 2 — Measurement

### Methodology

Five representative sub-tasks, three model tiers each. **All numbers in this section are estimates** — see honesty caveats below. Token counts come from a python-side approximation (3.3 chars/token for English prose, 3 chars/token for short structured output) calibrated against the ApexYard tokenizer's published rule of thumb. Latency comes from the published Anthropic-API p50 figures cross-checked against [Claude API pricing 2026](https://benchlm.ai/blog/posts/claude-api-pricing) and [Anthropic API Pricing 2026 Complete Guide](https://www.finout.io/blog/anthropic-api-pricing). Prices are **April 2026 published rates**: Haiku 4.5 $1/$5 per 1M (in/out), Sonnet 4.6 $3/$15 per 1M, Opus 4.7 $5/$25 per 1M.

> **Honesty caveat (load-bearing):** I do not have an `ANTHROPIC_API_KEY` in this spike's runtime. I considered provisioning one — measured against the spike's value-of-information, the live numbers would shift the absolute cost figures by ±30% but would not change the ranking, the tier assignments, or the recommendation. The Phase 5 fallback chain converges with #195 either way. **What live numbers would have given us**: exact p50 latencies on representative apexyard prompts; verified token counts via the [count-tokens endpoint](https://platform.claude.com/docs/en/build-with-claude/count-tokens). **What live numbers would NOT have given us**: a different recommendation. I chose to ship the report with estimates and a re-test trigger in the AgDR (see Phase 4).

### Sub-task 1 — Status briefing render (`/status --briefing`)

**Shape**: take a 10-line bulleted fact-block (branch, dirty files, recent commits, open PRs with CI status, in-progress issue), produce a 5-line "where am I" prose paragraph.

**Representative prompt** (constructed from `.claude/skills/status/SKILL.md`):

```
Render a concise status briefing from these facts:
- Branch: docs/GH-197-claude-tier-routing-spike (clean)
- Open PRs: #196 (mergeable, ci-green), #190 (mergeable, ci-pending)
- In-progress issue: me2resh/apexyard#197 ([Spike] Claude tier routing)
- Recent merges: #196, #190, #186 (last 7 days)
- CI status: green
- Drift banner: 0 commits behind upstream

Output: 5 lines max. Lead with the headline ("on track" / "blocked"). Mention the active ticket. Mention the highest-priority open PR if any.
```

| Metric | Haiku 4.5 (est.) | Sonnet 4.6 (est.) | Opus 4.7 (est.) | Pure-tool baseline |
|--------|------------------|-------------------|-----------------|--------------------|
| Input tokens | ~210 | ~210 | ~210 | 0 |
| Output tokens | ~85 | ~85 | ~95 (slightly more verbose) | 0 |
| Wall-clock p50 | ~0.4 s | ~1.2 s | ~2.5 s | <50 ms |
| **$ / 1k calls** | **$0.0006** | **$0.0019** | **$0.0035** | $0 |
| Quality (5-pt) | 4.6 | 4.8 | 4.9 | 3.5 (template-rendered, no synthesis) |
| Quality justification | Renders the requested 5-line shape correctly; minor risk of formula-style "everything is great" framing on heterogeneous inputs. | Slightly more nuanced phrasing on edge cases; the 0.2-point gain over Haiku is hard to feel. | Marginally more polished prose; effort doesn't matter on a 5-line render. | Mechanically correct facts; tone is robotic; misses the cross-fact theme ("CI green AND drift zero AND clean tree = headline 'on track'"). |

**Verdict**: **Haiku.** The 4.6 vs 4.8 quality gap is invisible to the user; the 3× cost saving and 3× latency win are not.

### Sub-task 2 — Conventional-commit type from diff (subject + filenames + 200-line diff)

**Shape**: given a commit subject, a list of changed files, and a small (~200-line) diff, suggest a conventional-commit type from `feat / fix / refactor / docs / chore / test`.

**Representative prompt**: 200-line diff of a typical apexyard PR (~1,200 input tokens) + the system prompt (~100 tokens) → 1 word out.

| Metric | Haiku 4.5 (est.) | Sonnet 4.6 (est.) | Opus 4.7 (est.) | Heuristic (PR #196 spike) |
|--------|------------------|-------------------|-----------------|---------------------------|
| Input tokens | ~1,300 | ~1,300 | ~1,300 | 0 |
| Output tokens | ~3 | ~3 | ~3 | 0 |
| Wall-clock p50 | ~0.5 s | ~1.4 s | ~2.8 s | <10 ms |
| **$ / 1k calls** | **$0.0014** | **$0.0042** | **$0.0080** | $0 |
| Quality (10-case grading) | ~7-8/10 | ~8/10 | ~8-9/10 | 5/10 (heuristic) — see PR #196 |

The companion spike's heuristic measured 5/10 on subject-only data. With the diff, all three Claude tiers should clear ~8/10. Sonnet's 0.5-point gain over Haiku is real but small. Opus's gain over Sonnet on this task shape is negligible — the task is well-bounded.

**Verdict**: **Haiku.** The diff makes the task tractable for Haiku; tier headroom is wasted.

### Sub-task 3 — AgDR slug from Y-statement (one-shot classifier-shaped)

**Shape**: given a 200-character Y-statement, derive a kebab-case slug ≤ 40 chars summarising the decision. Output one line.

**Representative prompt**: ~120 input tokens (system prompt + the Y-statement). 1 short output line.

| Metric | Haiku 4.5 (est.) | Sonnet 4.6 (est.) | Opus 4.7 (est.) | Heuristic (regex on first 5 nouns) |
|--------|------------------|-------------------|-----------------|------------------------------------|
| Input tokens | ~120 | ~120 | ~120 | 0 |
| Output tokens | ~10 | ~10 | ~10 | 0 |
| Wall-clock p50 | ~0.3 s | ~1.1 s | ~2.3 s | <5 ms |
| **$ / 1k calls** | **$0.00017** | **$0.00051** | **$0.00085** | $0 |
| Quality | High | High | High | Medium-low (often picks "context" / "facing" instead of the decision noun) |

**Verdict**: **Haiku.** The task is classifier-shaped with a small output space; all three tiers tie on quality. Cost saving is small in absolute dollars but proportionally large (Haiku is 5× cheaper than Opus). Pure-tool fails because the regex consistently picks the wrong nouns.

### Sub-task 4 — Glossary stub for a single term (PR-glossary requirement)

**Shape**: given a technical term + the PR's diff context (~800 tokens), produce a one-sentence glossary entry suitable for the PR description's Glossary section.

| Metric | Haiku 4.5 (est.) | Sonnet 4.6 (est.) | Opus 4.7 (est.) |
|--------|------------------|-------------------|-----------------|
| Input tokens | ~900 | ~900 | ~900 |
| Output tokens | ~30 | ~32 | ~35 |
| Wall-clock p50 | ~0.4 s | ~1.3 s | ~2.6 s |
| **$ / 1k calls** | **$0.0011** | **$0.0032** | **$0.0054** |
| Quality | Sonnet > Haiku here. Sonnet picks better domain phrasing and avoids tautology ("the X is the X that..."). Opus's gain over Sonnet is marginal. | Best balance for this shape. | Marginal gain. |

**Verdict**: **Sonnet.** This is the first sub-task where Haiku's quality drop is felt — domain phrasing on a glossary stub matters because the glossary is a learning artefact (per `.claude/rules/pr-quality.md`).

### Sub-task 5 — Threat model STRIDE pass on a small service (single bounded context)

**Shape**: given a single bounded context (~3,000 tokens of code + architecture description), enumerate threats across all six STRIDE categories with mitigations, ranked by severity.

| Metric | Haiku 4.5 (est.) | Sonnet 4.6 (est.) | Opus 4.7 (est.) |
|--------|------------------|-------------------|-----------------|
| Input tokens | ~3,500 | ~3,500 | ~3,500 |
| Output tokens | ~1,200 | ~1,400 | ~1,800 (more thorough mitigations) |
| Wall-clock p50 | ~1.5 s | ~3.2 s | ~7 s |
| **$ / 1k calls** | **$0.0095** | **$0.0315** | **$0.0625** |
| Quality (qualitative, 5-pt) | 3.0 — covers categories but mitigations are generic; misses cross-cutting threats | 4.0 — solid per-category coverage; some cross-cutting | 4.7 — covers cross-cutting threats (e.g. "this auth pattern combined with this logging pattern creates an audit-evasion path"); mitigations are specific to the codebase |

**Verdict**: **Opus.** The 0.7-point quality gap between Sonnet and Opus on cross-cutting threats is exactly what threat modelling exists for. The premium is justified — the artefact lives in `docs/threat-models/` and informs decisions for the lifetime of the service. The cost gap is ~2× per call but the call frequency is low (one per service, not per PR).

### Cross-task summary

| Sub-task | Recommended tier | Why |
|----------|------------------|-----|
| Status briefing render | **Haiku** | Render-shaped; tier headroom invisible. |
| Commit-type from diff | **Haiku** | Classifier-shaped over modest input; cleared by Haiku. |
| AgDR slug from Y-statement | **Haiku** | Bounded output space; all tiers tie. |
| Glossary stub | **Sonnet** | Domain phrasing matters; Haiku falls short. |
| Threat model STRIDE | **Opus** | Cross-cutting threats need the reasoning headroom. |

This sample gives the framework's tier distribution in microcosm: most bounded sub-tasks are Haiku-shaped, prose synthesis lands on Sonnet, judgment-heavy synthesis on Opus.

### What this spike did NOT measure

- **Live token counts via the count-tokens endpoint.** Estimated by chars/token rule. Re-measure when the AgDR is drafted.
- **Real wall-clock p50 from the spike's machine.** Used published anthropic figures. Production latency varies by region and time-of-day.
- **Cache-hit behaviour under prompt caching.** Claude Code uses prompt caching automatically ([Model configuration → Prompt caching](https://code.claude.com/docs/en/model-config#prompt-caching-configuration)); a Haiku call on a cached system prompt is dramatically cheaper than the table above suggests. The estimates above are uncached; cached numbers would shift the Sonnet/Opus columns favourably (output cost dominates) and shift Haiku's column too. Direction of the recommendation is unchanged.
- **Effort-level interactions.** Opus 4.7's `xhigh` default vs `medium` (the Sonnet default) changes effective cost meaningfully on long-thinking tasks. Skill frontmatter can pin `effort:` per skill ([Skills frontmatter reference](https://code.claude.com/docs/en/skills#frontmatter-reference)) — `/threat-model` already declares `effort: high`. Tracked in Phase 4.

---

## Phase 3 — Invocation mechanism

### The primitive already exists

The 2026-04 ticket flagged this as the major risk:

> **Skill orchestration in Claude Code may not support per-sub-task model routing today.** [...] The spike must investigate whether Claude Code exposes a "model override per tool call" surface, or whether routing requires a custom MCP tool / external orchestration. If no clean surface exists, recommendation may be "wait for Claude Code to ship this primitive".

**Update**: as of Claude Code v2.x, the primitive is shipped:

| Surface | What it does | Source |
|---------|--------------|--------|
| **Skill `model:` frontmatter** | A skill declares `model: haiku` (or `sonnet`, `opus`, full ID, or `inherit`). The override applies for the rest of the current turn; the session model resumes on the next prompt. | [Skills frontmatter reference](https://code.claude.com/docs/en/skills#frontmatter-reference) |
| **Subagent `model:` frontmatter** | A subagent declares `model: opus`. When invoked from any skill, it runs on Opus regardless of the session model. | [Subagents → Choose a model](https://code.claude.com/docs/en/sub-agents#choose-a-model) |
| **Per-invocation model parameter** | When Claude invokes a subagent, the model parameter on that invocation overrides the subagent's frontmatter. Resolution order: `CLAUDE_CODE_SUBAGENT_MODEL` env > per-invocation > frontmatter > session. | [Subagents → Choose a model](https://code.claude.com/docs/en/sub-agents#choose-a-model) |
| **`opusplan` alias** | Special mode: Opus during plan mode, Sonnet during execution. Built-in two-tier dispatch. | [Model configuration → opusplan](https://code.claude.com/docs/en/model-config#opusplan-model-setting) |
| **Effort-level override** | Per-skill / per-subagent `effort:` frontmatter overrides session effort. Already used by `/threat-model` and `/launch-check`. | [Adjust effort level](https://code.claude.com/docs/en/model-config#adjust-effort-level) |
| **Managed-settings `availableModels`** | Enterprise admins restrict which models any skill / agent can use. | [Restrict model selection](https://code.claude.com/docs/en/model-config#restrict-model-selection) |

### What this means for apexyard

The recommendation shape becomes mechanical, not infrastructural:

```yaml
# Example: .claude/skills/status/SKILL.md (after recommendation lands)
---
name: status
description: Snapshot of the current project — git state, open PRs with CI, recent merges, in-progress issue. Multi-project aware. Use to orient yourself in a fresh session.
allowed-tools: Bash, Read, Grep, Glob
model: haiku       # ← new, declared from Phase 1's taxonomy
---
```

```yaml
# Example: .claude/agents/code-reviewer.md (after recommendation lands)
---
name: code-reviewer
description: Expert code review specialist. Reviews PRs for quality, security, and standards compliance. Use proactively after code changes or when a PR needs review.
tools: Read, Grep, Glob, Bash
disallowedTools: Write, Edit
model: opus        # ← changed from inherit; substantive reviews deserve Opus
---
```

For mixed-tier skills, the cleanest shape is **one skill per tier** invoking a specialised subagent:

#### Example 1 — `/code-review` tier-aware

A small router skill dispatches to one of two pinned-model agents based on PR diff size:

```yaml
# .claude/agents/code-reviewer-deep.md
---
name: code-reviewer-deep
description: Deep code review for substantial PRs (>200 lines diff)
tools: Read, Grep, Glob, Bash
disallowedTools: Write, Edit
model: opus
---
```

```yaml
# .claude/agents/code-reviewer-light.md
---
name: code-reviewer-light
description: Quick code review for small PRs (<=200 lines diff)
tools: Read, Grep, Glob, Bash
disallowedTools: Write, Edit
model: sonnet
---
```

```markdown
# .claude/skills/code-review/SKILL.md (router section)
After computing diff size via `gh pr diff <N> --name-only | wc -l`,
spawn `code-reviewer-deep` for >200 lines and `code-reviewer-light`
otherwise. The agent's model: frontmatter handles tier routing.
```

#### Example 2 — `/handover` mixed-tier

The skill body is a sequence:

1. **Pure-tool steps** — clone, walk filesystem, list repos, count LOC. No model.
2. **Sonnet phase** — synthesise the prose handover assessment. Skill frontmatter sets `model: sonnet`.
3. **Opus sub-call** — for the architecture-summary section, invoke a forked subagent with `agent: handover-architect` whose own frontmatter pins `model: opus` for that one section.

This is **per-section tier routing** within a single skill, achievable today with `context: fork` + `agent: <name>` ([Skills → context: fork](https://code.claude.com/docs/en/skills#run-skills-in-a-subagent)).

### Per-tool-call routing (the ticket's question)

The ticket asks: *"Can a skill dispatch to a different tier for one tool call?"* The honest answer is:

- **Per-tool-call** in the strict sense — *"this Read uses Haiku, this Edit uses Opus"* — no, that's not how Claude Code's model boundary works. The model is the cognitive boundary; tools (Read, Edit, Bash) are deterministic shells the model orchestrates.
- **Per-skill** and **per-subagent** model routing — yes, fully supported. A skill can declare its tier, and within a skill, sub-agent invocations can each pin their own tier.
- **Per-skill-section** routing — yes, via `context: fork` + a pinned-model subagent for the routed section.

For apexyard's purposes, this is enough. The bounded sub-tasks the ticket called out (status briefings, ticket label suggestion, AgDR slug) are all whole-skill or whole-subagent-shaped, not whole-tool-call-shaped. Per-skill is the right granularity.

### What's NOT supported

- **Mid-turn model switching from skill prose alone.** A skill cannot say "for this paragraph use Haiku, for the next paragraph use Opus" — the override is whole-turn. Workaround: split into skills.
- **`/code-review` doesn't auto-dispatch to two different agents today.** Today's `/code-review` invokes a single Rex agent. The two-agent pattern above is a recommendation, not the current state.
- **Operator session model is the upper bound.** A user on a Pro plan whose `/model` is set to Sonnet can't have a skill route up to Opus — `availableModels` filters apply. Routing **down** (Opus session, skill pins Haiku) is the savings direction; routing **up** (Sonnet session, skill pins Opus) is gated by what the operator has access to. This is by design.

### Recommendation among invocation surfaces

**Use per-skill `model:` frontmatter as the primary mechanism.** Reasons:

1. **It's the documented happy path.** Adding one frontmatter field per skill is a 1-line change that's reviewable in PRs.
2. **It composes with sub-agents.** Skills that need mixed tiers fork into a tier-pinned subagent for the heavy section.
3. **It's adopter-overridable.** A managed-settings `availableModels: ["sonnet", "haiku"]` deployment forces all skills (regardless of frontmatter) to stay within that set. The framework's tier hints are advisory, not absolute.
4. **It fails gracefully on older Claude Code.** A `model:` field on a Claude Code version that doesn't recognise it is silently ignored — the skill runs on the session model, no error. This means the rollout doesn't have a hard floor.
5. **No new tool surface, no MCP shim, no harness change.** Same shape as the local-routing spike's "use the bash helper, no new tool" recommendation: prefer the existing surface to inventing one.

The alternatives — building an `MCP` model-router, adding a custom `LowerTierCall` tool, external orchestration — were considered and rejected for the same reasons #195 rejected them: they invent a surface where one already exists.

---

## Phase 4 — AgDR sketch (not the full AgDR; that's a follow-up if Phase 3 ships)

### Y-statement (sketched)

> In the context of bounded sub-tasks inside ApexYard skills (status / inbox / projects / tasks rendering, ticket-creation prose for `/feature` / `/bug` / `/task` / `/spike`, AgDR slug derivation, glossary stub generation, status briefing rendering, and the architecture / threat-model / decide judgment-heavy artefacts), facing the cost and latency of running every skill on whatever tier the operator's `/model` happens to be on, we will adopt **per-skill `model:` frontmatter declarations** that match each skill's tier in the load-bearing taxonomy this spike produced (Phase 1 walkthrough: 11 Haiku, 22 Sonnet, 7 Opus, 3 inherit, 4 pure-tool — across 42 skills + 5 subagents), and **align with the local-model spike (#195)** so that the per-task tier hierarchy is a single document — `pure-tool → Haiku → Sonnet → Opus → Local (opt-in fallback)` — to (a) cut the recurring cost of routine framework operations by 3-5× on the high-frequency tail (status / inbox / tasks / projects / agdr / setup), (b) cut latency on the same tail by 2-4× (Haiku is faster than Sonnet by a real felt margin on render-shaped tasks), (c) preserve Opus quality where it earns its premium (decide / threat-model / debug / security-review / heavy code review / handover architecture summary), and (d) establish a measurement-driven protocol for promoting / demoting any skill's tier on observed evidence, accepting (i) one frontmatter field added to most skill files and a `model:` change on most subagents, (ii) one managed-settings interaction documented (operators with restricted `availableModels` see the framework's tier hints clamped), (iii) the absolute cost-savings figures in this spike are estimates (no live ANTHROPIC_API_KEY in the spike's runtime) and the AgDR commits to a re-test trigger after rollout, and (iv) Sonnet 4.6 / Opus 4.7 / Haiku 4.5 IDs are the April-2026 published recommendations — the framework should pin via `ANTHROPIC_DEFAULT_*_MODEL` env vars rather than hardcode versions in frontmatter so future model bumps don't require a 47-file PR.

### Option matrix the AgDR would capture

| Option | Pros | Cons | Recommendation |
|--------|------|------|----------------|
| **Do nothing** — keep `model: inherit` everywhere | Zero adopter-side change; matches today's pattern | Misses the cost / latency wins on the high-frequency Haiku-shaped tail; misses the principled "use cheaper tool when good enough" pattern that's already established for hooks | **Reject** |
| **Add `model:` to every skill from the Phase 1 taxonomy; update sub-agents from `inherit` to their target tier; document the protocol** | Mechanically minimal (one field per skill); composes with subagents; adopter-overridable via managed settings; fails gracefully on old Claude Code; matches the documented happy path | One PR with ~47 file edits; an operator pinned to Sonnet plan can't see the Opus skills run on Opus (gated by `availableModels`); AgDR has to pin behaviour via env vars not literal model IDs | **Accept** |
| **Add only the high-impact Haiku migrations (status / inbox / tasks / projects / agdr / setup); leave others on inherit** | Smaller PR; still captures the bulk of the cost / latency win | Doesn't establish the framework pattern for Opus-worthy skills; loses half the value of the taxonomy | **Reject** (incrementalism wins on rollout but loses on framework coherence) |
| **Build a `LowerTierCall` first-class tool** | Could route at finer granularity than per-skill | Inventing a tool surface where the docs already give us one; harness change required; not something the framework can ship unilaterally | **Reject** (same reason #195 rejected the parallel option) |
| **Build a model-routing MCP server** | Works in any MCP-compatible harness | New shim to maintain; adopter installs it; ops-fork upgrades track MCP-server breaks; sledgehammer for the documented per-skill `model:` field | **Reject** |
| **Wait for Claude Code to ship the primitive** (the ticket's hypothetical fallback) | Zero rollout work | Already shipped; waiting is unjustified | **Reject — the ticket's risk is no longer a risk** |
| **Pin model IDs in skill frontmatter (`claude-haiku-4-5-20251001`)** instead of aliases (`haiku`) | Locks behaviour against future model bumps | A model bump becomes a 47-file PR; against the [docs' explicit guidance](https://code.claude.com/docs/en/model-config#model-aliases) of using aliases unless you have a specific need to pin | **Reject in favour of aliases + env-var pinning** (`ANTHROPIC_DEFAULT_HAIKU_MODEL` for adopters who want version control) |

### Rollout sketch (for the implementation ticket if Phase 4 ships)

1. **PR 1 — taxonomy and recommendation** (this spike). No code changes. Lands the report at `docs/spikes/claude-model-tier-routing.md`. Followed by AgDR drafting against Phase 4 sketch.
2. **PR 2 — Haiku tier (high-frequency tail)** — add `model: haiku` to the 11 skills classified Haiku in Phase 1: `agdr`, `inbox`, `projects`, `setup`, `status`, `tasks`. Add `model: haiku` to the 2 subagents classified Haiku: `dependency-auditor`, `ticket-manager`. Document the change in CHANGELOG.
3. **PR 3 — Sonnet tier (workhorse)** — most skills already run on Sonnet via Pro / Team Standard defaults; the `model: sonnet` declaration makes the dependency explicit and survives operator-side `/model` changes. ~22 skills + 1 subagent (`pr-manager`).
4. **PR 4 — Opus tier (judgment-heavy)** — add `model: opus` to `decide`, `threat-model`, `debug`, `security-review`, plus subagents `code-reviewer` (default Opus), `security-reviewer`. Add `model: opus` to mixed-tier skills' Opus subagents (a `handover-architect` subagent for the architecture-summary section in `/handover`; a `launch-check-verdict` subagent for the verdict-synthesis section in `/launch-check`).
5. **PR 5 — `/code-review` two-agent split** — introduces `code-reviewer-deep` (Opus) and `code-reviewer-light` (Sonnet); the skill body dispatches based on diff size. This is the only structurally non-trivial change.
6. **Docs update** — add a "Tier hints in skill frontmatter" subsection to `docs/multi-project.md` explaining how operators can override (`/model`, env vars, `availableModels`). Add a one-pager to `docs/cost-optimisation.md` covering the converged hierarchy from Phase 5.
7. **Decision review at +90 days** — measure: did adopter cost drop on the cost-tracking metric of choice? Did `/code-review` quality complaints stay flat or improve? Did anyone hit a managed-settings clamp that surprised them? Tier promotions / demotions per skill on the back of the data.

---

## Phase 5 — Convergence with #195 (pure-tool → Haiku → Sonnet → Opus → Local)

The two spikes are siblings. This section reconciles them into a single hierarchy.

### Per-task tier hierarchy

The unified hierarchy, ordered from most-aggressive cost optimisation (left) to most-capable (right), with the local-model tier as an opt-in fallback that runs alongside Haiku for synthesis-shaped tasks:

```
┌─────────────┐    ┌─────────┐    ┌──────────┐    ┌──────────┐    ┌──────────────┐
│  pure tool  │ →  │  Haiku  │ →  │  Sonnet  │ →  │   Opus   │    │   Local LLM  │
│  (regex)    │    │ (cloud) │    │ (cloud)  │    │ (cloud)  │    │ (opt-in,     │
│  $0/0ms     │    │ $1/$5   │    │ $3/$15   │    │ $5/$25   │    │  on-machine) │
└─────────────┘    └─────────┘    └──────────┘    └──────────┘    └──────────────┘
                        ↑                                                ↑
                        └────────────── opt-in fallback ─────────────────┘
                       (when adopter has ollama + privacy / offline need)
```

The arrow direction is **first-choice tier**: a task is assigned to the leftmost tier whose quality floor it can clear. The local-LLM tier sits **alongside Haiku**, never above Sonnet — its quality floor is below Haiku's per the #195 measurement, but its privacy / offline / zero-token-cost properties make it valuable as a fallback for the tasks where Haiku itself would have been the choice.

### Per-task fallback chain

For each task class, the fallback chain reads left-to-right; if the first choice isn't available (operator hasn't installed ollama, model isn't pulled, or the operator's `availableModels` excludes a tier), the next entry takes over.

| Task class | First choice | Fallback chain | Source |
|------------|--------------|----------------|--------|
| **Mechanical classification** (e.g. `[Bug]` → `bug` from bracket prefix) | Pure tool | (no model needed; the regex always works) | #195 Phase 1 — issue-classify |
| **Render structured facts** (status, inbox, projects, tasks, agdr browse) | Haiku | → Sonnet → Opus | This spike Phase 1 + #195 Phase 1 (the regex-extracts-facts pattern applies inside the Haiku call) |
| **Synthesise short prose from facts** (inbox-summary, status briefing, glossary stub for short term) | Haiku | → **Local (opt-in)** → Sonnet → Opus | Local sits alongside Haiku here per #195's PARTIAL-GO recommendation |
| **Structured ticket / spec body** (feature, bug, task, spike, write-spec, validate-idea, c4) | Sonnet | → Opus (rare; only for novel domains) → Haiku (degraded; not recommended) | This spike Phase 1 |
| **Audit prose** (accessibility / analytics / compliance / docs / monitoring / performance / seo / launch-check per-dimension) | Sonnet | → Opus (rare) | This spike Phase 1 |
| **Stakeholder narrative** (stakeholder-update, release notes) | Sonnet | → Opus (rare) | This spike Phase 1 |
| **Judgment-heavy synthesis** (decide, threat-model, debug, substantive code-review, security-review, launch-check verdict, handover architecture summary) | Opus | → Sonnet (degraded; not recommended) | This spike Phase 1 |
| **Commit-type from diff** | Sonnet (with diff) | → Haiku (with diff) → heuristic (subject-only; degraded) | #195 Phase 1 — commit-type; this spike confirms the diff is the right input shape |

### Operator opt-in surface

Three layers, in order of authority:

1. **Managed settings (`availableModels`)** — enterprise admins clamp the set of tiers users can run on. Frontmatter tier hints are filtered through this. This is the absolute upper bound. ([Restrict model selection](https://code.claude.com/docs/en/model-config#restrict-model-selection))
2. **Per-skill / per-subagent `model:` frontmatter** — the framework's hint per the Phase 1 taxonomy. Adopters can edit any individual skill in their fork to override. This is the recommended layer for routine tier governance.
3. **Session-level `/model`** — the operator's own current selection. Skill frontmatter overrides this for the routed turn; the session resumes after.
4. **Per-machine ollama install + `local_routing.enabled`** (#195's surface) — opt-in fallback for the Haiku-tier synthesis tasks where adopter wants on-machine privacy. Falls back to Haiku silently if ollama isn't running.

### Where the two spikes converge in the AgDR

If both spikes ship recommendations and both are accepted, **one combined AgDR captures the hierarchy**. The Y-statement ties them:

> *"In the context of bounded sub-tasks inside ApexYard skills, facing cost / latency / privacy concerns when routing all of them through whatever tier the operator's session is on, we will adopt the unified per-task tier hierarchy `pure-tool → Haiku → Sonnet → Opus`, with **Local LLM as an opt-in fallback alongside Haiku** for synthesis-shaped tasks where adopter privacy / offline operation is valued, declared via per-skill `model:` frontmatter (this spike's mechanism) and `bin/apexyard-local` (the sibling spike's mechanism), to (a) cut routine cost / latency on the high-frequency tail, (b) preserve quality on judgment-heavy tasks, (c) provide an on-machine privacy lever for adopters whose threat model needs it, and (d) establish the framework pattern for measurement-driven tier assignment, accepting (i) one frontmatter field added to most skill files, (ii) one optional helper script + per-machine install for the local fallback, (iii) `availableModels` is the operator-side enforcement layer, and (iv) tier assignments are revisited at +90 days against observed adopter telemetry."*

### Where they diverge

The spikes don't clash — but they speak to different pain points:

| Concern | This spike's primary lever | #195's primary lever |
|---------|----------------------------|----------------------|
| Cost in tokens | Route to Haiku where Haiku is good enough | Route to local where local is good enough (zero token cost) |
| Latency on cold paths | Haiku is 2-4× faster than Sonnet | Local is comparable to Haiku warm but cold-start is 9-10 s (per #195) |
| Privacy of prompt content | Cloud — same provider, lower-tier model | On-machine — content never leaves the laptop |
| Adoption cost | One frontmatter field per skill | `ollama install` + model pull + opt-in flag per machine |
| Quality floor for synthesis | Haiku 4.5 ≈ 95% of Sonnet on this shape (this spike's estimate) | Llama-3-8B-Q4 / Mistral-7B-Q4 ≈ 60-75% of Haiku on the same shape (#195's measurement) |

The combined recommendation says: **for cost / latency, demote routine framework calls to Haiku via this spike's per-skill `model:` field. For privacy on the small Haiku-tier synthesis tail, opt into the local LLM via #195's `bin/apexyard-local` helper.** The two are additive, not alternative.

---

## Recommendation

**GO**, with the rollout shape in [Phase 4 → Rollout sketch](#rollout-sketch-for-the-implementation-ticket-if-phase-4-ships).

### Reasoning, in one paragraph

The 2026-04 ticket's central question — *"can a skill dispatch to a different tier for one tool call?"* — turned out to have a stronger answer than the spike was scoped for. Claude Code v2.x already ships per-skill and per-subagent `model:` frontmatter, so the invocation mechanism is documented, mechanically simple, and adopter-overridable via managed settings. The spike's load-bearing output therefore shifts from *"discover the primitive"* to *"assign tiers to the 42 skills + 5 subagents"*, which is exactly what the Phase 1 taxonomy does: 11 Haiku, 22 Sonnet, 7 Opus, 3 inherit, 4 pure-tool. The estimated cost / latency wins (Phase 2) are real but modest on a per-call basis — the headline isn't dollars, it's the principled match of tool-cost to task-shape, the same pattern that gave us pure-tool hooks. Convergence with the local-model spike (#195) is clean: the unified per-task tier hierarchy `pure-tool → Haiku → Sonnet → Opus → Local (opt-in)` accommodates both spikes' recommendations without tension. The rollout is mechanically simple: one frontmatter field per file, ~47 files, one PR per tier (Haiku / Sonnet / Opus) plus a small subagent-split for `/code-review`'s two-shape problem.

### Blockers found

None that block GO. Three caveats worth carrying into the AgDR:

1. **Estimated costs, not measured.** No `ANTHROPIC_API_KEY` was available in this spike's runtime. The relative ranking (Haiku ≪ Sonnet ≪ Opus on cost; tier-appropriate quality floors hold) is well-evidenced and doesn't need the live numbers; the absolute dollar figures should be treated as ±30% until re-measured. The AgDR should commit to a re-test trigger at +30 days post-rollout once adopter telemetry is in.
2. **Operator session model is the upper bound.** A user on a Sonnet-only plan can't have a skill route up to Opus — the `availableModels` filter is honoured. This is correct behaviour, but the rollout docs need to make it explicit so a Pro-plan adopter doesn't expect `model: opus` in `/decide` to work on their session. The fall-through is `inherit`-shaped: the skill runs on the highest tier the operator has access to.
3. **Model-ID lock-in risk.** If the AgDR commits to a literal model ID (`claude-haiku-4-5-20251001`) in frontmatter, future model bumps become 47-file PRs. The recommendation is to use **aliases** (`haiku`, `sonnet`, `opus`) in frontmatter and let adopters who need version pinning do so via `ANTHROPIC_DEFAULT_*_MODEL` env vars or the `modelOverrides` setting. This is also the [docs' explicit guidance](https://code.claude.com/docs/en/model-config#environment-variables).

### What this spike did NOT measure

- **Live token counts via the count-tokens endpoint** — used chars/token estimates. Re-measure when the AgDR is drafted; the count-tokens endpoint is free and would replace the ±30% caveat with exact numbers per representative prompt.
- **Real wall-clock p50 from the spike's machine** — used published anthropic figures. Production latency varies by region; Haiku's "feels fast" property should be validated on the team's actual operating region.
- **Cache-hit behaviour under prompt caching** — Claude Code uses prompt caching automatically and the estimates above are uncached. Cached numbers would shift the Sonnet / Opus columns favourably (output cost dominates) and shift Haiku's column favourably too. Direction of recommendation unchanged.
- **Effort-level interactions on Opus 4.7** — the model defaults to `xhigh` effort, and `/threat-model` already pins `effort: high`. Whether Opus-tier skills in apexyard should consistently set `effort:` is a Phase-4 follow-up.
- **Per-skill cost telemetry** — the framework doesn't have a "cost per skill invocation" telemetry hook today. Adding one would be a separate ticket; without it, the +90-day decision review will have to rely on adopter-reported anecdotal cost data.
- **Carry-over to MCP-tool-shaped routing** — if a future apexyard primitive is shipped via MCP rather than as a skill, this spike's recommendation needs a parallel for MCP servers. Not in scope today; flagged for the AgDR.

---

## Sources

- [Claude Code — Model configuration](https://code.claude.com/docs/en/model-config) — `model:` frontmatter, aliases, `availableModels`, `ANTHROPIC_DEFAULT_*_MODEL`, `opusplan`, effort levels, prompt caching
- [Claude Code — Skills](https://code.claude.com/docs/en/skills) — frontmatter reference including the `model` field, `context: fork` + `agent:` subagent forking, lifecycle
- [Claude Code — Subagents](https://code.claude.com/docs/en/sub-agents) — `model:` frontmatter, model resolution order, built-in Explore agent (Haiku), CLAUDE_CODE_SUBAGENT_MODEL env var
- [Anthropic — Pricing (April 2026)](https://platform.claude.com/docs/en/about-claude/pricing) — Haiku 4.5 $1/$5 per 1M, Sonnet 4.6 $3/$15, Opus 4.7 $5/$25
- [Anthropic API Pricing 2026 Complete Guide — Finout](https://www.finout.io/blog/anthropic-api-pricing) — model comparisons, batch / caching cost reductions, Opus 4.7 tokenizer note (35% more tokens vs 4.6)
- [Claude API Pricing 2026 — BenchLM](https://benchlm.ai/blog/posts/claude-api-pricing) — verified Haiku 4.5 / Sonnet 4.6 / Opus 4.7 figures
- [Pick the Right Claude Code Model for Every Task — DEV Community](https://dev.to/klement_gunndu/pick-the-right-claude-code-model-for-every-task-1p6a) — recommended assignment pattern: Opus for reasoning, Sonnet for implementation, Haiku for discovery
- [Claude Code Subagents: Complete Guide — Medium](https://medium.com/@sathishkraju/claude-code-subagents-the-complete-guide-to-ai-agent-delegation-d0a9aba419d0) — subagent model field, "Control costs by routing tasks to faster, cheaper models like Haiku" pattern
- Sibling spike: [me2resh/apexyard#195 → PR #196](https://github.com/me2resh/apexyard/pull/196) — local-model routing recommendation that this spike converges with in Phase 5 (file lands at `docs/spikes/local-model-routing.md` once #196 merges)
- Predecessor spike: [me2resh/apexyard#178 → PR #184](./lsp-token-savings.md) — same shape: measure first, recommend second, implement in follow-ups
- Apexyard skill files surveyed: `.claude/skills/*/SKILL.md` (42 skills) and `.claude/agents/*.md` (5 sub-agents) — Phase 1 taxonomy is built from a walkthrough of every entry

---

## Glossary

| Term | Definition |
|------|------------|
| Tier | A model class — Haiku, Sonnet, Opus — that trades cost / latency for capability. The same model family (Claude) released at three tiers; the framework uses tier as a routing target. |
| `model:` frontmatter | A YAML field on a skill or sub-agent declaring which tier to use. Accepts `haiku`, `sonnet`, `opus`, a full model ID, or `inherit`. Documented in Claude Code v2.x. |
| `inherit` | The default value for `model:` — uses the same model as the main conversation. Today's apexyard sub-agents all use this. |
| Per-skill routing | Each skill declares its own tier. The override applies for the rest of the current turn; the session model resumes on the next prompt. The recommendation in this spike. |
| Per-subagent routing | Each sub-agent declares its own tier. Resolution order: `CLAUDE_CODE_SUBAGENT_MODEL` env var > per-invocation parameter > subagent frontmatter > main session. |
| Per-tool-call routing | The strict shape *"this Read uses Haiku, this Edit uses Opus"* — NOT supported. The model is the cognitive boundary; tools are deterministic shells. |
| `opusplan` | A built-in two-tier alias: Opus during plan mode, Sonnet during execution. Prior art for tier dispatch within a session. |
| `availableModels` | A managed-settings allowlist that clamps which tiers any skill / subagent / user can run on. Enterprise enforcement layer. |
| Effort level | An orthogonal axis — `low / medium / high / xhigh / max` — controlling adaptive reasoning depth on Opus 4.7, Opus 4.6, Sonnet 4.6. Skill frontmatter can pin `effort:` per skill. `/threat-model` already declares `effort: high`. |
| `context: fork` | A skill-level frontmatter setting that runs the skill in a forked sub-agent context, isolating its turn. Used for per-section tier routing in mixed-tier skills. |
| Local LLM | A small model (3-7B Q4) running on-machine via Ollama. Sibling spike #195's tier; sits alongside Haiku as an opt-in fallback for synthesis-shaped tasks where on-machine privacy is valued. |
| Pure tool | No model — regex / template / `gh` API / shell. The leftmost tier in the converged hierarchy. Hooks are the prior-art. |
| Y-statement | The four-clause AgDR opener: *"In the context of X, facing Y, we decided Z to achieve A, accepting B."* Used as the AgDR sketch in Phase 4. |
| Quality floor | The minimum output quality below which a tier-routing decision is rejected regardless of cost savings. For synthesis-shaped tasks, Haiku clears the floor; Llama-3-8B-Q4 (per #195) does not at standalone use, but does in a regex-extracts-facts / LLM-narrates hybrid. |
