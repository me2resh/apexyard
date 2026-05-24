# `/feature-diagram` tests

## Smoke test

```bash
bash .claude/skills/feature-diagram/tests/smoke.sh
```

Builds a synthetic feature inventory under `$TMPDIR` with three features (one full-coverage, one full-coverage, one routes + screens only), runs `generate.sh` against each, and asserts:

| Fixture | Asserts |
|---------|---------|
| 1. Inventory with 3 features → 3 per-feature files emitted | Each output file exists, has a feature-title heading, contains a `flowchart LR` Mermaid block with four named subgraphs, links back to the inventory, and ends with the regenerable footer signature |
| 2. Each emitted file passes the shared `_lib-mermaid-lint.sh` | mmdc parses every Mermaid block cleanly (exit 0) — graceful-skips (exit 3) when Node/npx isn't installed so CI without Node still passes |
| 3. Feature with only routes + screens (no models, no jobs) | The Models + Jobs subgraphs still render with `(none)` placeholders — four-quadrant shape is constant across features, and Mermaid stays valid |
| 4. Unknown feature slug → exit 2 | stderr names the missing slug AND lists "Available slugs:" with the real options so the operator can self-correct |
| 5. Missing inventory file → exit 2 | stderr says "not found" — refuses to silently fall back to a stub |

## Running the helper manually

```bash
# Emit a per-feature diagram to stdout
bash .claude/skills/feature-diagram/generate.sh path/to/feature-inventory.md create-order curios-dog

# Lint a generated file
bash .claude/skills/feature-diagram/lint.sh projects/curios-dog/features/create-order.md
```

The skill itself (run inside Claude Code) builds the per-feature diagram with a richer model — it disambiguates ambiguous matches, follows file references into the project's source for handler / model / job / component names, and presents a candidate review before writing. The smoke test verifies the **grep-fallback** path the helper documents — if `generate.sh` drifts from the inventory format documented in `/extract-features` SKILL.md § "Write the inventory", the smoke test catches it.

## Notes for adopters

- The smoke test does NOT require Node/npx — the Mermaid lint graceful-skips on exit 3 if `mmdc` isn't installable. CI environments without Node will still see all five fixtures pass.
- The smoke test does NOT require the apexyard fork's full registry — it builds its own fixture inventory inline. No portfolio dependency.
- The helper is deliberately conservative: when a row's `Source` column doesn't mention an axis, that subgraph is rendered as `(none)`. Re-runs in Claude Code may populate axes that pure-grep misses; that's the point of the LLM-driven path.

---

*Part of [ApexYard](https://github.com/me2resh/apexyard) — multi-project SDLC framework for Claude Code · MIT.*
