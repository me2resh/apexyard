## graphify (query-first)

This project has a knowledge graph at `graphify-out/`.

**Before** grepping or reading more than 3 source files for architecture or flow questions:

1. Run `graphify query "<question>"` (or `graphify path "A" "B"` / `graphify explain "Symbol"`).
2. Open only the files returned in the subgraph.
3. Use `GRAPH_REPORT.md` only for broad orientation.

After code changes in a session: `graphify update .` (AST-only, no API cost).

Rebuild full graph (code + docs): `/graphify .` or `bin/graphify-bootstrap workspace/<name> <name>` from the ops repo.
