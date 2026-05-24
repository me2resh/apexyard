---
name: geo-audit
description: GEO + AEO audit — `llms.txt`, `AGENTS.md`, AI-crawler robots, JSON-LD citation grounding. Sibling to /seo-audit.
disable-model-invocation: false
argument-hint: "[project-path]"
effort: medium
---

# /geo-audit — LLM/Agent Discoverability Audit

Deep-dive audit against the emerging GEO + AEO conventions. Checks discovery files (`llms.txt`, `AGENTS.md`), AI-crawler directives in `robots.txt`, capability manifests, citation-friendly metadata, snippet-extractable content shape, and token economics. Invoke when `/launch-check` flags the generative-engine row, or directly during docs/landing-site work.

**Sibling to `/seo-audit`** (NOT an extension). The two skills run independently:

- `/seo-audit` — Google-shaped SEO: title, description, og, sitemap, robots.txt, schema for Googlebot
- `/geo-audit` — LLM/agent surface: `llms.txt`, `AGENTS.md`, AI-crawler directives, citation JSON-LD, token economics

`/launch-check` fans out to both at milestone boundaries so the production-readiness verdict covers both audiences.

## Two sub-scopes — GEO and AEO

| Sub-scope | Question | Primary consumers |
|-----------|----------|-------------------|
| **GEO** (Generative Engine Optimization) | Will an LLM cite this page when a user asks? | ChatGPT, Claude.ai, Perplexity, Gemini, You.com |
| **AEO** (Agentic Engine Optimization) | Will a coding agent prefer this doc over its training data when coding against this product? | Claude Code, Cursor, Aider, Cline, Continue |

Both consumers read the same artefacts (`llms.txt`, JSON-LD metadata, `AGENTS.md`), so they share this audit. The findings table groups checks by bucket so an operator can read "the GEO half is fine, but AEO is missing" without re-running anything.

## The `skill.md` naming clash — important

One of the v1 capability-signaling checks looks for **`skill.md`** at the site or project root. This is the upstream GEO/AEO capability-manifest convention — a one-page description of what a product / docs site offers, addressed at coding agents.

**This `skill.md` is distinct from Claude Code's `SKILL.md`** (the slash-command spec at `.claude/skills/<name>/SKILL.md` that this very file is an instance of). The two filenames differ only in case:

- Upstream GEO/AEO **`skill.md`** = capability manifest at site root, lowercase, one per project
- Claude Code **`SKILL.md`** = slash-command spec under `.claude/skills/<name>/`, uppercase, one per slash command

On case-insensitive filesystems (macOS default, Windows always) the two filenames resolve to the same on-disk file, but the convention places them in distinct directories so the clash is nominal, not structural. This skill's check is for the upstream **lowercase `skill.md`** at the site root — not for the Claude Code spec inside `.claude/skills/`.

## The 6 check buckets

The audit runs 17 checks across these six buckets:

1. **Discovery** — `llms.txt`, `llms-full.txt`, AI-crawler directives in `robots.txt`, `/.well-known/ai-plugin.json`, `agent-permissions.json`, `AGENTS.md`
2. **Capability-signaling** — `skill.md` capability manifest at site root (see naming-clash callout above)
3. **Content-format** — JSON-LD citation metadata, snippet-extractable Q&A shape, markdown alternates, heading hierarchy, first-500-tokens lead, prompt-injection hygiene
4. **Token-economics** — per-page token-count estimates, token-count surfacing recommendations
5. **Analytics** — AI-traffic fingerprint advisory (server-log snippet, not a hard check)
6. **UX** — "Copy for AI" affordance (advisory)

## Process

### Step 1: Determine the project + auto-PASS guard

If invoked with a path argument, use that. Otherwise use the current working directory. Verify it's a web project:

- Has `index.html`, `pages/`, `src/pages/`, `app/`, or a known web-framework marker (Next.js, Nuxt, Astro, Eleventy, Hugo, Jekyll, Docusaurus, MkDocs)
- OR has a `docs/` directory with `.md` files served on a public site

**If the project is a backend API only, a CLI, or a library, auto-PASS.** Emit a one-line note and skip the audit — there's no content for LLM crawlers to index. Same auto-PASS rule as `/seo-audit`.

### Step 2: Discovery checks

For each, report PASS / WARN / FAIL with the severity listed:

| ID | Check | PASS | WARN | FAIL | Severity |
|----|-------|------|------|------|----------|
| G1 | `/llms.txt` exists | File present, lists URLs that resolve | File present but some listed URLs 404 | Not present | high (FAIL) |
| G2 | `/llms-full.txt` exists | Present (companion to `llms.txt`) | `llms.txt` present but no `llms-full.txt` | Both missing | medium (WARN) |
| G3 | AI-crawler directives in `robots.txt` | All v1 crawlers explicitly named (Allow or Disallow) | Some named, others implicit | None named (implicit-allow) | info |
| G4 | `/.well-known/ai-plugin.json` | Present and valid JSON | Present but malformed | Not present | info (advisory) |
| G5 | `agent-permissions.json` at site root | Present | — | Not present | info (advisory) |
| G6 | `AGENTS.md` at repo root | Present with required sections (project structure, file locations, sandbox links, MCP pointers) | Present but missing 1-2 sections | Not present or template-only | medium (WARN) |

**G3 detail.** The skill iterates the AI-crawler list at `.claude/registries/ai-crawlers.json` (12 entries spanning training and retrieval scopes). For each crawler it reports:

```
GPTBot           Allow      (training)
ChatGPT-User     Disallow   (retrieval)
OAI-SearchBot    (implicit) (retrieval)
ClaudeBot        Allow      (training)
...
```

Reporting "implicit" is informational, not a defect — the audit names which crawlers are explicitly addressed so the operator can decide.

### Step 3: Capability-signaling checks

| ID | Check | PASS | WARN | FAIL | Severity |
|----|-------|------|------|------|----------|
| G7 | `skill.md` at site root (capability manifest) | Present, names primary capabilities + entry points | Present but stub-only | Not present | medium (WARN) |

**Reminder**: this is the upstream `skill.md` convention, **distinct from Claude Code's `SKILL.md`**. See the naming-clash section above.

### Step 4: Content-format checks

| ID | Check | PASS | WARN | FAIL | Severity |
|----|-------|------|------|------|----------|
| G8 | JSON-LD citation metadata | `author` + `dateModified` + `datePublished` + `publisher` on article-shaped pages | 2-3 of the 4 fields present | None or only `author` | high (FAIL) |
| G9 | Snippet-extractable Q&A shape | H2s framed as questions on docs / FAQ pages, FAQ schema present where appropriate | Some pages H2-shaped, others freeform | Walls of text, no H2 boundaries | medium (WARN) |
| G10 | Markdown alternates | `Link: <foo.md>; rel="alternate"; type="text/markdown"` header OR `/foo.md` route | Some pages have alternates | None | medium (WARN) |
| G11 | Heading hierarchy | Single H1, H1→H2→H3 no skipping, sampled across 5+ pages | Occasional skip | Multiple H1s or systematic skipping | medium (WARN) |
| G12 | First-500-tokens lead | Lead answers "what is this / what can it do / what's needed to start" | Lead is partial — answers one or two | Lead is marketing prose | medium (WARN) |
| G13 | Prompt-injection hygiene | No literal `<system>`, `<assistant>`, or instruction-style tags | One or two instances in docs samples | Systematic use of instruction-style tags | high (FAIL — security risk) |

### Step 5: Token-economics checks

| ID | Check | Logic | Severity |
|----|-------|-------|----------|
| G14 | Per-page token-count check | Estimate via `char_count / 4`. Thresholds: Quick Start > 15K, API reference > 25K, conceptual guides > 20K. FAIL on threshold cross. | high (FAIL on cross) |
| G15 | Token-count surfacing | Is there a meta tag, HTTP header, or `llms.txt` entry that exposes the token count? If not, INFO advisory recommending one. | info |

Token-count heuristic is `char_count / 4` (cross-vendor estimate). Adopters who want precision can swap in `tiktoken` (OpenAI) or Anthropic's tokens API.

### Step 6: Analytics + UX

| ID | Check | Output | Severity |
|----|-------|--------|----------|
| G16 | AI-traffic fingerprint advisory | Emit a server-log analysis snippet the operator runs against access logs. User-agents to look for: `axios/1.8.4`, `curl/8.4.0`, `got`, `colly`, Playwright Chromium fingerprints. Informational. | info |
| G17 | "Copy for AI" button check | Look for a copy-as-markdown button on docs pages. Advisory only. | info |

### Step 7: Output

```
GEO AUDIT — <project> @ <sha>

| #   | Bucket             | Area                                  | Status | Severity | Finding                                          |
|-----|--------------------|---------------------------------------|--------|----------|--------------------------------------------------|
| G1  | Discovery          | llms.txt                              | FAIL   | high     | Not present at /llms.txt                         |
| G2  | Discovery          | llms-full.txt                         | WARN   | medium   | Not present (companion to llms.txt)              |
| G3  | Discovery          | AI-crawler directives in robots.txt   | INFO   | info     | GPTBot / ChatGPT-User / ClaudeBot implicit-allow |
| G4  | Discovery          | /.well-known/ai-plugin.json           | INFO   | info     | Not present (advisory)                           |
| G5  | Discovery          | agent-permissions.json                | INFO   | info     | Not present (advisory)                           |
| G6  | Discovery          | AGENTS.md                             | WARN   | medium   | Missing sandbox + MCP sections                   |
| G7  | Capability-signal  | skill.md (capability manifest)        | PASS   | —        | Present, 320 lines                               |
| G8  | Content-format     | JSON-LD citation metadata             | FAIL   | high     | Missing dateModified + publisher on blog        |
| G9  | Content-format     | Snippet-extractable Q&A shape         | WARN   | medium   | 3 of 8 docs pages lack H2 question boundaries    |
| G10 | Content-format     | Markdown alternates                   | WARN   | medium   | No /foo.md alternate route                       |
| G11 | Content-format     | Heading hierarchy                     | PASS   | —        | Clean across 12 sampled pages                    |
| G12 | Content-format     | First-500-tokens lead                 | WARN   | medium   | Two key docs lead with marketing prose           |
| G13 | Content-format     | Prompt-injection hygiene              | PASS   | —        | No literal <system>/<assistant> tags             |
| G14 | Token-economics    | Per-page token estimates              | FAIL   | high     | /api/reference/full ~38K tokens (>25K threshold) |
| G15 | Token-economics    | Token-count surfacing                 | INFO   | info     | No meta/header/llms.txt entry                    |
| G16 | Analytics          | AI-traffic fingerprint                | INFO   | info     | Server-log snippet emitted (run against logs)    |
| G17 | UX                 | Copy-for-AI affordance                | INFO   | info     | No copy-as-markdown button on docs pages         |

AI-discoverability readiness: NEEDS WORK (3 fail, 4 warnings — address G1 + G8 + G14 before declaring LLM-ready)
```

## Persist the run + render trend

Same shape as `/seo-audit`. After printing the table, persist via the shared audit-history lib so the GEO/AEO trend across runs is legible. See `docs/agdr/AgDR-0019-audit-artefact-persistence.md`.

### Resolve project name + score + verdict

`<project-name>` from `apexyard.projects.yaml` (or basename + `/handover` reminder if unregistered).

Score: `score = max(0, 100 - 25*critical - 10*high - 3*medium - 1*low)`. Severity ceiling is `high` (not `critical`) — the v1 audit is advisory. Verdict by worst-severity: high → `fail`, medium → `conditional`, low/info/none → `pass`.

### Persist + render

```bash
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-audit-history.sh"

# Lowercase severity in the payload — the lib expects critical/high/medium/low/info.
payload=$(mktemp); cat > "$payload" <<'EOF'
{
  "schema_version": 1,
  "findings": [
    {"id": "G1",  "severity": "high",   "status": "open", "summary": "llms.txt not present at site root"},
    {"id": "G8",  "severity": "high",   "status": "open", "summary": "JSON-LD missing dateModified + publisher on blog templates"},
    {"id": "G14", "severity": "high",   "status": "open", "summary": "/api/reference/full ~38K tokens — over 25K threshold"},
    {"id": "G6",  "severity": "medium", "status": "open", "summary": "AGENTS.md missing sandbox + MCP sections"},
    {"id": "G9",  "severity": "medium", "status": "open", "summary": "snippet-extractable Q&A shape partial"},
    {"id": "G10", "severity": "medium", "status": "open", "summary": "no markdown alternates served"},
    {"id": "G12", "severity": "medium", "status": "open", "summary": "first-500-tokens lead is marketing prose on 2 docs"},
    {"id": "G3",  "severity": "info",   "status": "open", "summary": "AI-crawler directives not explicit in robots.txt"}
  ]
}
EOF

# Body: per templates/audits/geo-audit.md
body=$(mktemp); cat > "$body" <<'EOF'
... (filled-in body — findings table + Recommended priority) ...
EOF

ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
audit_run_persist "<project-name>" "geo-audit" "$ts" "fail" 55 "$body" < "$payload"
rm -f "$payload" "$body"

audit_render_trend "<project-name>" "geo-audit" 5
```

### Opt-in commit

```bash
touch projects/<name>/audits/geo-audit/.audit-history-tracked
```

## Rules

1. **Auto-PASS for non-web projects.** APIs, CLIs, libraries, backend-only services don't need an LLM/agent-discoverability audit — there's no content surface for crawlers to index.
2. **Advisory posture.** Severity ceiling is `high`, not `critical`. Hostile robots.txt against AI crawlers reports as `info` — the audit names the directive but does not grade (policy choice, not defect).
3. **Distinct from `/seo-audit`.** Different audience (LLM crawlers + coding agents, not Googlebot), different artefacts (`llms.txt` + `AGENTS.md` + JSON-LD citation grounding, not sitemap + og:image + meta description). Each is independently invokable.
4. **`skill.md` (the audit's capability-manifest check) is distinct from Claude Code's `SKILL.md`** — see the naming-clash callout at the top of this file. The check is for the **lowercase `skill.md` at site root**.
5. **AI-crawler list lives in the registry.** `.claude/registries/ai-crawlers.json` is the single source of truth. The G3 check iterates the list. Adopters who want to add an internal crawler edit the JSON.
6. **Always persist via the lib.** The persist step runs regardless of opt-in commit state. Same shape as the rest of the audit family.
7. **Don't auto-fix.** Out of scope: auto-generating `llms.txt`, scaffolding `AGENTS.md`, splitting oversized pages. The audit names the gap; the operator decides whether to act.

## Implementation notes

| File | Purpose |
|------|---------|
| `.claude/registries/ai-crawlers.json` | v1 AI-crawler list (12 entries) consumed by the G3 check |
| `templates/audits/geo-audit.md` | Per-run body template (audit family standard, AgDR-0019) |
| `.claude/hooks/_lib-audit-history.sh` | Shared persistence + trend rendering (audit family standard, AgDR-0019) |
| `.claude/skills/seo-audit/SKILL.md` | Google-shaped SEO sibling — independent, complementary |
| `.claude/skills/launch-check/SKILL.md` | Fans out to both this skill and `/seo-audit` at milestone boundaries |

Design rationale: [`docs/agdr/AgDR-0043-geo-audit-skill.md`](../../../docs/agdr/AgDR-0043-geo-audit-skill.md).
