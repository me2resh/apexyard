# Graphify

**Repo**: https://github.com/safishamsi/graphify  
**Workspace**: `workspace/graphify/`  
**Status**: active (tool-only)  
**Tier**: P1

## What it is

Portfolio-wide knowledge graphs for Cursor — query a map before grepping the repo.

## Quick commands

```bash
source ~/.local/bin/env   # graphify on PATH

bin/graphify-project list
bin/graphify-project koraid query "how does auth reach the database?"
bin/graphify-bootstrap workspace/koraid koraid   # full rebuild
```

## Doc-aware graphs (LLM optional)

1. **Without API key** — `bin/graphify-bootstrap` uses lightweight markdown extraction (`bin/_graphify_doc_extract.py`) + doc→code label bridges.
2. **With API key** — copy `.env.graphify.example` → `.env.graphify` and set `GEMINI_API_KEY` (or `GOOGLE_API_KEY`, etc.). Bootstrap uses graphify's full semantic extractor automatically.

## Agent behavior (query-first)

Each workspace project gets:

- `.cursor/rules/graphify.mdc` — graphify upstream rule
- `.cursor/rules/graphify-query-first.mdc` — **mandatory** query before broad grep/read
- `.agents/skills/graphify/SKILL.md` — `/graphify .` skill
- `AGENTS.md` section — `## graphify (query-first)`

Ops repo root has the same query-first rule. Run `bin/install-graphify-skill` once after clone to install the `/graphify` Cursor agent skill (copied from `workspace/graphify`, not committed — avoids linting upstream skill body).

## Portfolio graphs

Graphs live in `workspace/<name>/graphify-out/` (gitignored clones). Rebuild with `bin/graphify-bootstrap workspace/<name> <name>`.

Open graphs: `file:///…/workspace/<name>/graphify-out/graph.html`

## Upgrade graphify CLI

```bash
cd workspace/graphify && git pull origin v8
uv tool install --editable --force .
```
