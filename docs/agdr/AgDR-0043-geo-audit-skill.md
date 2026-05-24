# AgDR-0043 — `/geo-audit`: GEO + AEO sibling to `/seo-audit`

> In the context of LLM/agent crawlers becoming a meaningful share of inbound traffic to documentation sites and product pages, facing the choice of whether to extend `/seo-audit` with a new dimension or ship a dedicated sibling skill, I decided to ship a **standalone `/geo-audit`** (originally shipped as `/generative-engine-audit`; renamed in #334 — see Consequences) that mirrors `/seo-audit`'s shape (findings table + score + verdict + opt-in persistence via `_lib-audit-history.sh`), covers the two related sub-scopes **GEO** (Generative Engine Optimization — content for LLM citations) and **AEO** (Agentic Engine Optimization — docs for coding-agent consumption), is fanned out from `/launch-check` alongside `/seo-audit`, and pins its v1 AI-crawler list in a dedicated registry file, accepting that the sub-scope merge means one skill carries two related but distinct evaluation lenses and that the on-disk `skill.md` capability-manifest convention now collides nominally with Claude Code's `SKILL.md` slash-command spec.

## Context

Industry-standard prior art on Generative Engine Optimization (GEO) and Agentic Engine Optimization (AEO) has crystallised into a small set of cross-vendor conventions that web projects can be checked against:

- **Discovery files** at the site root that LLM crawlers and coding agents are starting to look for: `llms.txt` / `llms-full.txt` (analogue of `sitemap.xml` but for LLM-friendly content), `/.well-known/ai-plugin.json`, `agent-permissions.json`, and at the source-repo root `AGENTS.md`.
- **AI-crawler directives** in `robots.txt` — distinct from the SEO-shaped `Googlebot` and `Bingbot` directives. The v1 list spans 11 user-agents covering training, retrieval-at-inference, and both: `GPTBot`, `ChatGPT-User`, `OAI-SearchBot`, `ClaudeBot`, `Claude-Web`, `anthropic-ai`, `Google-Extended`, `PerplexityBot`, `CCBot`, `Bytespider`, `Applebot-Extended`, `cohere-ai`. (We ship 12 in `ai-crawlers.json`; the README list in the ticket was 11 — the addition is `OAI-SearchBot`, the SearchGPT indexer.)
- **Capability manifests** at the site root — the upstream `skill.md` convention (a one-page capability description, distinct from Claude Code's `.claude/skills/<name>/SKILL.md` slash-command spec — the naming clash is a known footgun, addressed below).
- **Content-format signals** that improve LLM extractability: JSON-LD with `author` / `dateModified` / `datePublished` / `publisher` for citation grounding; Q&A-shaped H2 sections that snippet-extract cleanly; markdown alternates served via `Link: <foo.md>; rel="alternate"; type="text/markdown"` or a `/foo.md` route; first-500-tokens lead that answers "what / can-do / needed-to-start".
- **Token economics** — coding agents and LLM crawlers fetch pages and pay token costs at inference. Pages over ~25K tokens (≈ 100KB of plain markdown) get truncated or expensive. Surfacing per-page token estimates (meta tag, HTTP header, or `llms.txt` entry) lets agents budget their reads.
- **Prompt-injection hygiene** — pages that include literal `<system>`, `<assistant>`, or instruction-style tags can be picked up as prompts when an agent feeds the page into its own context. A page-level audit can flag this.

The existing `/launch-check` row 5 ("SEO") + `/seo-audit` deep-dive together cover the *Google-shaped* SEO surface (title / description / og / sitemap / robots.txt / schema). They do **not** cover any of the GEO/AEO surface above — that's a different audience (LLM crawlers and coding agents, not Googlebot), a different set of artefacts (`llms.txt`, `AGENTS.md`, `skill.md`, JSON-LD `dateModified`, token counts), and a different output (does an LLM cite this site? does a coding agent prefer this docs over its training data?).

Three live problems followed:

1. **`/seo-audit` is already long** — extending it with 10+ GEO/AEO checks would push the audit past the 5-minute one-pager shape and force the operator to mentally separate "Google" vs "LLM" findings inside one table.
2. **`/launch-check` only knows about SEO** — when a project's SEO row shows PASS but the site is invisible to LLMs (no `llms.txt`, hostile robots.txt against `GPTBot`, no JSON-LD), the operator gets no signal at all.
3. **GEO and AEO are related but not the same** — GEO is "will an LLM cite this when a user asks?", AEO is "will Claude Code / Cursor / Aider prefer this doc over its training data when coding against this product?". They share infrastructure (`llms.txt`, `AGENTS.md`, JSON-LD) but emphasise different consumers. Splitting them into two skills doubles the surface; merging them under one umbrella keeps the operator's mental model simple.

## Options Considered

### Axis 1 — Extend `/seo-audit` vs ship a sibling

| Option | Pros | Cons |
|--------|------|------|
| Extend `/seo-audit` with a GEO+AEO sub-section | One skill to learn. One audit run covers Google + LLM surfaces. | Forces every adopter to pay the GEO+AEO cost on every SEO audit, even when they only care about Google. Doubles the table length on a one-pager-shaped audit. Conflates two audiences whose findings rarely apply to the same fix list. |
| New sibling `/geo-audit` (chosen — originally shipped as `/generative-engine-audit`, renamed in #334) | Independently invokable. Operators who only care about Google keep using `/seo-audit`. `/launch-check` fans out to both, so the milestone-boundary audit covers both. Output, persistence, and verdict shape mirror `/seo-audit` byte-for-byte so the audit family stays consistent. | One more skill to maintain. Adopters discover the GEO/AEO surface only through `/launch-check` or this AgDR (mitigated by the cross-link in `/seo-audit` SKILL.md). |
| Two sibling skills — `/geo-audit` and `/aeo-audit` | Cleanest mental model — one audience per skill. | Doubles the skill surface for what is, on average, the same set of 10-15 checks with subtly different framing. Most checks overlap (e.g. `llms.txt` matters for both; JSON-LD with `dateModified` matters for both). The 80% overlap dwarfs the 20% difference. |

### Axis 2 — `skill.md` (the upstream capability-manifest convention) vs the existing `SKILL.md` Claude Code uses

The upstream GEO/AEO prior art proposes a `skill.md` file at the site or project root as a *capability manifest* — a one-page description of what a product / docs site offers, addressed at coding agents. This is **not** the same as Claude Code's `.claude/skills/<name>/SKILL.md` (which is a slash-command spec read by the harness). The two filenames differ only in case (`skill.md` vs `SKILL.md`); on case-insensitive filesystems (macOS default, Windows always) they're the same file.

| Option | Pros | Cons |
|--------|------|------|
| Check for `skill.md` at site root, call it out as upstream's convention | Stays compatible with the upstream GEO/AEO ecosystem. Operators who already publish a `skill.md` get credit. | Naming clash with Claude Code's `SKILL.md`. On case-insensitive FS, an adopter who drops a Claude Code skill spec at the repo root accidentally fulfils the capability-manifest check. |
| Rename the check target to e.g. `capabilities.md` | No naming clash inside ApexYard. | Diverges from the upstream convention — adopters publishing a `skill.md` per the prior art get no credit. Loses the cross-vendor signal. |
| Check for `skill.md` AND document the naming clash explicitly (chosen) | Stays cross-vendor-compatible. AgDR + SKILL.md both name the clash, so adopters discovering the convention through this skill don't conflate the two. | One more thing to remember. Mitigated by the SKILL.md "naming clash" callout (test-pinned). |

### Axis 3 — Strict-vs-advisory posture

| Option | Pros | Cons |
|--------|------|------|
| Strict — fail the audit on missing `llms.txt`, missing `AGENTS.md`, hostile robots.txt | Forces the conversation. Adopters who don't care about LLM traffic see a loud signal. | Many adopters legitimately don't want LLM crawler traffic (paywalled content, training-opt-out by policy). A strict posture punishes them for the right reason. |
| Advisory — describe, don't grade harshly (chosen) | Operator decides. The audit surfaces findings as PASS / WARN / FAIL with the same severity calculus as `/seo-audit`, but a missing `llms.txt` is `medium`, not `critical`. Hostile robots.txt against `GPTBot` reports as `info` (the audit notices but doesn't grade — it's a policy choice, not a defect). | Adopters who *do* want LLM traffic but didn't realise their robots.txt was blocking `GPTBot` see a lower-priority signal than a strict posture would deliver. |
| Configurable strict-mode flag (`--strict`) | Operators choose | Adds surface to a v1 skill that already has 6 buckets. Deferred to v1.5 if demand surfaces. |

### Axis 4 — Where the AI-crawler list lives

| Option | Pros | Cons |
|--------|------|------|
| Inline in `SKILL.md` as a markdown table | One file to read. | Skill body becomes the source of truth for a list that adopters might legitimately want to extend (e.g. an enterprise that wants to allow-list a specific internal crawler). Edits collide with skill prose changes. |
| Inline in `_lib-ai-crawlers.sh` as an associative array | Easy to source. | Shell-only consumption locks out future TypeScript / Python tooling that might want to read the list. |
| Dedicated registry file at `.claude/registries/ai-crawlers.json` (chosen) | Single source of truth. Easy to extend (PR a JSON entry). Adopters can override in their fork without forking the skill. Consumable by any language. | One new dir (`.claude/registries/`) — no current sibling, so this is a precedent. Acceptable: the framework has set similar precedents (`golden-paths/`, `handbooks/`, `custom-skills/`) every time a new file class earns its own home. |

## Decision

### Chosen on axis 1 — **Sibling skill**

`/geo-audit` ships as a standalone slash command, separately invokable, and is fanned out by `/launch-check` alongside `/seo-audit`. The two skills share zero code (each owns its own SKILL.md flow), share the persistence library (`_lib-audit-history.sh`), and cross-link in prose.

The one-pager shape is preserved: findings table → score → verdict → opt-in persistence — byte-for-byte the same shape as `/seo-audit`.

### Chosen on axis 2 — **Check `skill.md`, name the clash**

The audit checks for `skill.md` at the site root (capability-manifest convention). The SKILL.md for `/geo-audit` contains a verbatim callout: *"This is the upstream `skill.md` convention (a capability manifest). It is **distinct from Claude Code's `SKILL.md`** (the slash-command spec at `.claude/skills/<name>/SKILL.md`)."* The smoke test pins the presence of this exact phrase so the callout can't silently drift.

On case-insensitive filesystems an adopter could in principle have one file serve both purposes, but this is rare in practice — Claude Code skill specs live under `.claude/skills/<name>/`, not at the site root.

### Chosen on axis 3 — **Advisory**

Severity ceiling for the GEO/AEO checks is `high` (not `critical`). Missing `llms.txt` is `medium`. Hostile robots.txt against AI crawlers reports as `info` — the audit names the directive and the affected crawlers, but does not grade. This matches the existing `/seo-audit` posture (which doesn't grade "site chose to block all crawlers" either).

A future `--strict` flag is left open; v1 is advisory-only.

### Chosen on axis 4 — **`.claude/registries/ai-crawlers.json`**

The file ships with 12 entries (the 11 named in the ticket plus `OAI-SearchBot`, the SearchGPT indexer — surfaced during research and added for completeness). Schema is intentionally tiny:

```json
{
  "schema_version": 1,
  "crawlers": [
    {"name": "...", "user_agent": "...", "scope": "training|retrieval|both", "primary_use": "..."}
  ]
}
```

Adopters who want to add an internal crawler edit the file in their fork. Upstream extends it via PR.

## Consequences

### Positive

- **One audience per skill.** `/seo-audit` stays focused on Google; `/geo-audit` focuses on LLMs + agents. Operators reach for the right one based on the question they're asking.
- **`/launch-check` covers both** at milestone boundaries — the milestone-shaped audit gets the LLM/agent surface for free without forcing every PR-level SEO audit to pay the cost.
- **Persistence + trend tracking via the shared lib** — `_lib-audit-history.sh` (AgDR-0019) treats this as one more dimension. Adopters get the trend chart, score deltas, and opt-in commit marker behaviour they already know from `/seo-audit`, `/threat-model`, and the rest of the audit family.
- **Registry file is reusable.** Future skills that need the AI-crawler list (a hypothetical `/llms-txt-generator`, `/robots-audit`) read the same JSON. No drift.
- **GEO/AEO sub-scope distinction is documented but not enforced.** The findings table groups checks by bucket (Discovery / Capability-signaling / Content-format / Token-economics / Analytics / Governance), so an operator can see "the GEO half is fine, but AEO is missing" without the skill having to split into two outputs.

### Negative

- **One more skill.** Skill count goes from 51 to 52. Mitigated by the shared shape — operators who know `/seo-audit` know this skill within 30 seconds.
- **The `skill.md` naming clash.** Real, documented, will surface as adopter confusion at least once. The verbatim AgDR + SKILL.md callout is the long-term mitigation; the smoke test pins the callout so future maintainers don't drop it.
- **Registry file is a v1 — adopters will request extensions.** Adding a crawler is a PR with one JSON entry; we'll accept community PRs for new entries as the ecosystem matures.
- **Token-count heuristic is rough.** `char_count / 4` is the cross-vendor industry-standard estimate; the real count varies by tokeniser. Skill names the heuristic explicitly so adopters who want precision can swap in `tiktoken` / Anthropic's `tokens` API.
- **Advisory posture means low-grade findings can be ignored.** Some adopters will see "WARN: no llms.txt" three audits in a row and never act. This is the right failure mode for a v1 skill in a still-emerging convention space — strict mode is deferred until the underlying conventions stabilise further.

### Migration / rollback

- **No data migration.** The skill is purely additive — no existing artefact is touched.
- **Rollback** is `git revert` of the introducing PR. No state in `.claude/session/` is created. The registry file sits at `.claude/registries/ai-crawlers.json`; adopters who delete the file will get a no-op skill (the SKILL.md flow checks for the file and exits with an advisory when missing).
- **Future evolution path.** When the upstream conventions stabilise (the `skill.md` capability-manifest naming clash gets resolved by the wider ecosystem, the `llms.txt` spec ships a v1.0), we re-evaluate the advisory→strict posture and the registry schema in a follow-up AgDR.

### Post-v1 rename — `/generative-engine-audit` → `/geo-audit`

2026-05-20 — renamed from `/generative-engine-audit` per #334; clean rename, no shim. Reason: industry GEO term + `/seo-audit` sibling shape + terseness in `/launch-check` output tables. The skill shipped under the original name on 2026-05-19 (PR #315) and was renamed less than a week later, before any meaningful adopter usage accrued. No backward-compatibility symlink — adopters who typed the old name see "command not found" and switch. The AI-crawler registry file (`.claude/registries/ai-crawlers.json`) keeps its path; only the skill name (and its directory, AgDR filename, template filename, and cross-reference text) changed.

## Artifacts

- Issue: [me2resh/apexyard#311](https://github.com/me2resh/apexyard/issues/311) (original v1 ship), [me2resh/apexyard#334](https://github.com/me2resh/apexyard/issues/334) (rename)
- Skill: `.claude/skills/geo-audit/SKILL.md`
- Registry: `.claude/registries/ai-crawlers.json`
- Audit template: `templates/audits/geo-audit.md`
- Smoke test: `.claude/skills/geo-audit/tests/smoke.sh`
- Related: AgDR-0019 (audit-artefact persistence), AgDR-0014 (launch-check trend tracking), `.claude/skills/seo-audit/SKILL.md` (the SEO sibling)
