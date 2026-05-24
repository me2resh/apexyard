<!-- Source: ApexYard · templates/audits/geo-audit.md · github.com/me2resh/apexyard · MIT -->

# GEO Audit — {project} @ {short-sha}

> Persisted by `/geo-audit` via `_lib-audit-history.sh`. Frontmatter (above) is structured; the body is freeform per dimension. See `docs/agdr/AgDR-0019-audit-artefact-persistence.md` for the schema rationale.

## Scope

How well the project's documentation and content surface is discoverable, parsable, and citable by **LLM/agent crawlers** (ChatGPT, Claude, Perplexity, Gemini) and **AI coding agents** (Claude Code, Cursor, Aider, Cline). Covers two related sub-scopes:

- **GEO** (Generative Engine Optimization) — content optimisation for LLM citations
- **AEO** (Agentic Engine Optimization) — documentation optimisation for coding-agent consumption

Out of scope: auto-generating the missing artefacts, content-quality grading for LLM extraction, live testing against real LLM crawlers, per-LLM scoring.

## Findings

| # | Bucket | Area | Status | Detail | Severity |
|---|---|---|---|---|---|
| G1 | Discovery | `llms.txt` at site root | FAIL | Not found at `/llms.txt` — LLM crawlers and agents have no curated index | high |
| G2 | Discovery | `llms-full.txt` at site root | WARN | Not found — `llms.txt` exists but the full-content companion does not | medium |
| G3 | Discovery | AI-crawler directives in `robots.txt` | INFO | `GPTBot`, `ClaudeBot`, `PerplexityBot` not named — site behaviour is implicit-allow | info |
| G4 | Discovery | `/.well-known/ai-plugin.json` | INFO | Not present (advisory only — relevant for OpenAI-plugin-shaped surfaces) | info |
| G5 | Discovery | `agent-permissions.json` | INFO | Not present (advisory — emerging declarative spec) | info |
| G6 | Discovery | `AGENTS.md` at repo root | WARN | Missing sections: sandbox links, MCP pointers | medium |
| G7 | Capability-signaling | `skill.md` at site root | PASS | Present, 320 lines, names primary capabilities + entry points | — |
| G8 | Content-format | JSON-LD citation metadata | FAIL | Missing `author` / `dateModified` / `datePublished` / `publisher` on blog templates | high |
| G9 | Content-format | Snippet-extractable Q&A shape | WARN | 3 of 8 docs pages lack H2 question boundaries — FAQ schema absent | medium |
| G10 | Content-format | Markdown alternates | WARN | No `Link: rel="alternate"; type="text/markdown"` header; no `/foo.md` route | medium |
| G11 | Content-format | Heading hierarchy | PASS | Single H1, no skipped levels detected across 12 sampled pages | — |
| G12 | Content-format | First-500-tokens lead | WARN | Two key docs lead with marketing prose, not "what / can-do / needed-to-start" | medium |
| G13 | Content-format | Prompt-injection hygiene | PASS | No literal `<system>`, `<assistant>`, or instruction-style tags found | — |
| G14 | Token-economics | Per-page token estimates | FAIL | `/api/reference/full` ≈ 38K tokens (over 25K threshold) — agent fetches will truncate | high |
| G15 | Token-economics | Token-count surfacing | INFO | No meta tag, HTTP header, or `llms.txt` entry surfaces token counts | info |
| G16 | Analytics | AI-traffic fingerprint advisory | INFO | Server-log snippet emitted — operator to run against access logs (user-agents: `axios/1.8.4`, `curl/8.4.0`, `got`, `colly`, Playwright Chromium) | info |
| G17 | UX | "Copy for AI" affordance | INFO | No copy-as-markdown button on docs pages (advisory) | info |

## Recommended priority

1. **G1** — author `/llms.txt` listing the canonical URLs the LLM ecosystem should index (start with the docs root, API reference, changelog)
2. **G8** — add JSON-LD `author` / `dateModified` / `datePublished` / `publisher` to blog and docs templates (citation grounding)
3. **G14** — split `/api/reference/full` into chunked pages under the 25K-token threshold (or surface a `tokens=...` query param for agent budgeting)
4. **G6** — extend `AGENTS.md` with sandbox links + MCP pointers
5. **G2, G9, G10, G12** — content-format polish

## Notes

- AI-crawler reference list: `.claude/registries/ai-crawlers.json` — 12 entries spanning training-time and retrieval-at-inference crawlers.
- Token-count heuristic: `char_count / 4`. Adopters who want precision should swap in `tiktoken` (OpenAI) or Anthropic's tokens API.
- This audit is **advisory** — severity ceiling is `high`, not `critical`. Hostile robots.txt against AI crawlers reports as `info` (policy choice, not defect).
- GEO vs AEO sub-scope distinction: GEO = "will an LLM cite this?", AEO = "will a coding agent prefer this docs over its training data?". Both consume the same artefacts (`llms.txt`, `AGENTS.md`, JSON-LD), so they share the audit.

## See also

- `docs/agdr/AgDR-0043-geo-audit-skill.md` — design rationale, including the `skill.md` vs Claude Code `SKILL.md` naming clash
- `.claude/skills/seo-audit/SKILL.md` — the Google-shaped SEO sibling
- `.claude/skills/launch-check/SKILL.md` — milestone-boundary audit that fans out to both
