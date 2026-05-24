# `/dfd` tests

## Smoke test

```bash
bash .claude/skills/dfd/tests/smoke.sh
```

Builds three synthetic fixtures under `$TMPDIR`, runs the discovery + classification + generator scripts against them, and asserts:

| Fixture | Asserts |
|---------|---------|
| 1. Single-service Express + Prisma + BullMQ + Stripe + SendGrid + Auth0 + admin route | All six discovery axes produce non-empty findings; trust boundaries (public ↔ backend, user ↔ admin, backend ↔ data, us ↔ third-party) all detected |
| 2. Two synthetic services with cross-service flow + Stripe URL | `mrt_resolve_target` resolves the registered cross-service hostname to the right project; `mrt_is_third_party` flags Stripe; `mrt_workspace_for` resolves to the right clone |
| 3. Code with `@PII` annotations + `EMAIL_*`/`*_SECRET` env vars + `email`/`phone_number`/`card_number` columns | All three classification pathways fire; PCI labels emitted for card data; no false positive on `SOME_PUBLIC_FLAG` |
| 4. Mermaid generator output | Has top-level heading, source-of-truth declaration, flowchart block, subgraphs, trust-boundaries table, classifications table, provenance section, footer signature |
| 5. Threat Dragon JSON serialiser (skipped if `jq` missing) | Output is valid JSON; has `version` / `summary` / `detail` top-level keys; cells include `tm.actor` / `tm.process` / `tm.store` / `tm.boundary` / `tm.flow`; STRIDE threats are attached to their parent element |
| 6. Downstream-consumer refactor verification | `/threat-model` SKILL.md references `projects/.../architecture/dfd.md` AND has an offer-to-run-/dfd-first path; `/compliance-check` SKILL.md references the same DFD path |

## Running individual scripts manually

```bash
# Discovery axes 1–5 (grep-fallback path)
bash .claude/skills/dfd/discover.sh /path/to/project [scope-hint]

# Classification heuristics (axis 6)
bash .claude/skills/dfd/classify.sh /path/to/project

# Mermaid markdown generator
bash .claude/skills/dfd/generate-mermaid.sh <project-name> [discovery.yaml] [classifications.yaml]

# Threat Dragon JSON serialiser
echo "$MODEL_JSON" | bash .claude/skills/dfd/generate-dragon.sh
```

The skill itself dispatches richer logic via LSP when enabled and presents a candidate-model review interview before generating any file. The smoke test verifies the grep-fallback path the skill documents — if the regexes in `discover.sh` / `classify.sh` drift from what they're supposed to match, the smoke test catches it.

## Shared trace helper

The `_lib-multi-repo-trace.sh` helper is also exercised by Fixture 2. The helper is shared with `/process` (#256) — if `/process` ships its own version, the consumer that lands later should consolidate to a single file.

---

*Part of [ApexYard](https://github.com/me2resh/apexyard) — multi-project SDLC framework for Claude Code · MIT.*
