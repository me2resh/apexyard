# smartmomlabs

## Impeccable (consumer sidecars)

This site is an Impeccable **consumer**. Before design work, read:

- `PRODUCT.md` — strategy, register, anti-references
- `DESIGN.md` — tokens, typography, do/don't

Live Mode config: `.impeccable/live/config.json` (sessions under `.impeccable/live/sessions/` are local only).

Tooling repo (skills, CLI): `workspace/impeccable/` — see [projects/impeccable/consumers.md](../../impeccable/consumers.md). Do **not** move site sidecars into the tooling repo.

## graphify (query-first)

This project has a knowledge graph at `graphify-out/`.

**Before** grepping or reading more than 3 source files for architecture or flow questions:

1. Run `graphify query "<question>"` (or `graphify path "A" "B"` / `graphify explain "Symbol"`).
2. Open only the files returned in the subgraph.
3. Use `GRAPH_REPORT.md` only for broad orientation.

After code changes in a session: `graphify update .` (AST-only, no API cost).

Rebuild full graph (code + docs): `/graphify .` or `bin/graphify-bootstrap workspace/<name> <name>` from the ops repo.
