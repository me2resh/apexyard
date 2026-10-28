# Notes for plan-apexyard-harness-golden-path (current: revision 4)

These notes sit beside the Plan record because the ORBIT v0.1 Plan schema has no fields for constraints, decisions, or revision history. The Plan record stays valid ORBIT.

## Interview

- 2026-10-10, q1-outcome: Gates fail closed without locking the operator out. Hook cost is measured. Gates run in Claude Code, Codex, and Cursor.
- 2026-10-10, q2-intent: Keep one DDD rule set, one logging standard, and native gates on each harness. Do not mandate one logger.
- 2026-10-10, q3-outcomes: Seven outcomes: fail-closed gates, Cursor coverage, Codex native gates, review-agent token trim, DDD boundaries, a logging standard, and an offload result schema.
- 2026-10-10, q4-acceptance: Each outcome has acceptance criteria in the Plan record. Proof stays in these notes.
- 2026-10-10, q5-constraints: C1 governance wins. C2 one slice, one ticket, one PR. C3 opt-in for adopters. C4 no machine-wide install.
- 2026-10-10, q6-save: Saved with the plan record on 2026-10-10. Revision history below records revisions 1 to 3.
- 2026-10-28, q1-outcome: In Claude Code, the operator sees gate state in a band above the prompt and gives per-PR merge and design approvals from a pane. The bash hooks stay the enforcement core. The mod only shows state and collects the human approval.
- 2026-10-28, q2-intent: Keep the intent. Add one sentence: "In Claude Code, a mod shows gate state and collects approvals; it never replaces the hooks."
- 2026-10-28, q3-outcomes: Add one outcome, o8-claude-code-gate-mod, to the seven that exist.
- 2026-10-28, q4-acceptance: o8 has six criteria, ac8-1 to ac8-6, in the Plan record: an AgDR for the split, the band, the approval pane, hook-path approval recording, an opt-in plugin, and a Hakim review with tests.
- 2026-10-28, q5-constraints: Keep C1 to C4. Add C5 to C7: the mod is Claude Code only, it is a guardrail and not a security boundary, and the harness-agnostic bash core does not change.
- 2026-10-28, q6-save: Saved as revision 4 with the records PR on 2026-10-28.

## Constraints

- **C1. ApexYard governance wins.** No slice bypasses tickets, reviews, review markers, or merges.
- **C2. One slice, one ticket, one PR.** Each outcome has one slice. A bug found inside a slice is a step in that slice, not a new slice.
- **C3. Opt-in for adopters.** New CI checks run only when a project adds their config (dependency-cruiser), and new handbooks keep the existing advisory-or-blocking marker convention.
- **C4. No machine-wide install.** Codex hook trust is per user. No slice needs sudo.
- **C5. The gate mod is Claude Code only.** Other harnesses keep the bash hooks and get no mod.
- **C6. The gate mod is a guardrail, not a security boundary.** This follows the owner decision of 21 Oct 2026. The hooks and the head-SHA match stay the control.
- **C7. The harness-agnostic bash core does not change.** The mod reads gate state and sends approvals through the existing hook path.

## Operator decisions

- **Logging:** recommend `@aws-lambda-powertools/logger` for TypeScript backends, but do not mandate a library. A blocking handbook makes Rex request changes on PII or secrets in a log statement. Missing logging is advisory.
- **DDD boundaries:** CI enforces the dependency-cruiser rules when a project has the config. The clean-architecture handbook stays advisory and says that CI enforces.
- **Escape hatch for fail-closed gates:** the existing `claude --settings '{"disableAllHooks": true}'` launch override, documented and tested. No new environment variable.
- **Codex hook trust:** per-user trust only, with a warning when trust is missing or stale.
- **Token trim:** `omitClaudeMd`, a short block of the floor rules in each agent, and a trimmed Rex prompt.

## Order

o1 first, because the later slices add gates. Then o2, o3, o4, o5, o6, o7. o6 lands after o5, because it reuses the Node CI job that o5 adds. o8 is last, after the outcomes in progress.

## Revision history

Revisions 1 to 3, and their reconciliations, are in `docs/orbit/history/`.

- **Revision 1** set seven outcomes: fail-closed gates, Cursor coverage, Codex native gates, review-agent token trim, DDD boundaries, a logging standard, and an offload result schema.
- **Revision 2** changed o6. The operator chose to recommend a logger instead of mandating one, and to have Rex block PII or secrets in logs through a blocking handbook.
- **Revision 3** reworded ac3-1, ac3-3, and ac4-1 to ac4-3 after vendor-doc checks. Codex managed hooks need a machine-wide sudo install, so ac3-1 uses per-user trust instead. `autoCompactWindow` is not a subagent setting, so ac4-1 uses `omitClaudeMd` with a floor-rules block and a prompt trim. ac4-2 and ac4-3 now name the token measurement and the corpus size.
- **Revision 4** (2026-10-28) added outcome o8, the Claude Code gate mod, with criteria ac8-1 to ac8-6. It added one intent sentence and constraints C5 to C7. The seven slices of revision 3 now point at revision 4 and its reconciliation, with no scope change.

## Upstream gaps

- **me2resh/orbit-spec#21:** `orbit validate --all` rejects a second revision of the same Plan in one record root. Superseded revisions live in `docs/orbit/history/` until it is fixed.
- The CLI's default slice ID contains uppercase timestamp letters, which the `/orbit` handoff path rejects. Pass `--id` with a lowercase ID.
