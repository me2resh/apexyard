# Notes for plan-apexyard-harness-golden-path (current: revision 3)

These notes sit beside the Plan record because the ORBIT v0.1 Plan schema has no fields for constraints, decisions, or revision history. The Plan record stays valid ORBIT.

## Constraints

- **C1. ApexYard governance wins.** No slice bypasses tickets, reviews, review markers, or merges.
- **C2. One slice, one ticket, one PR.** Each outcome has one slice. A bug found inside a slice is a step in that slice, not a new slice.
- **C3. Opt-in for adopters.** New CI checks run only when a project adds their config (dependency-cruiser), and new handbooks keep the existing advisory-or-blocking marker convention.
- **C4. No machine-wide install.** Codex hook trust is per user. No slice needs sudo.

## Operator decisions

- **Logging:** recommend `@aws-lambda-powertools/logger` for TypeScript backends, but do not mandate a library. A blocking handbook makes Rex request changes on PII or secrets in a log statement. Missing logging is advisory.
- **DDD boundaries:** CI enforces the dependency-cruiser rules when a project has the config. The clean-architecture handbook stays advisory and says that CI enforces.
- **Escape hatch for fail-closed gates:** the existing `claude --settings '{"disableAllHooks": true}'` launch override, documented and tested. No new environment variable.
- **Codex hook trust:** per-user trust only, with a warning when trust is missing or stale.
- **Token trim:** `omitClaudeMd`, a short block of the floor rules in each agent, and a trimmed Rex prompt.

## Order

o1 first, because the later slices add gates. Then o2, o3, o4, o5, o6, o7. o6 lands after o5, because it reuses the Node CI job that o5 adds.

## Revision history

Revisions 1 and 2, and their reconciliations, are in `docs/orbit/history/`.

- **Revision 1** set seven outcomes: fail-closed gates, Cursor coverage, Codex native gates, review-agent token trim, DDD boundaries, a logging standard, and an offload result schema.
- **Revision 2** changed o6. The operator chose to recommend a logger instead of mandating one, and to have Rex block PII or secrets in logs through a blocking handbook.
- **Revision 3** reworded ac3-1, ac3-3, and ac4-1 to ac4-3 after vendor-doc checks. Codex managed hooks need a machine-wide sudo install, so ac3-1 uses per-user trust instead. `autoCompactWindow` is not a subagent setting, so ac4-1 uses `omitClaudeMd` with a floor-rules block and a prompt trim. ac4-2 and ac4-3 now name the token measurement and the corpus size.

## Upstream gaps

- **me2resh/orbit-spec#21:** `orbit validate --all` rejects a second revision of the same Plan in one record root. Superseded revisions live in `docs/orbit/history/` until it is fixed.
- The CLI's default slice ID contains uppercase timestamp letters, which the `/orbit` handoff path rejects. Pass `--id` with a lowercase ID.
