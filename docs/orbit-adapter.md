# ORBIT adapter pilot

The `/orbit` skill is an opt-in ApexYard adapter for the portable ORBIT CLI. It stores planning records under the selected managed project's `docs/orbit/` directory.

The adapter keeps responsibilities separate:

- ORBIT owns record shapes, provenance fields, lifecycle commands, and validation.
- ApexYard owns ticket-first editing, AgDRs, review, QA, deployment, and project resolution.
- The adapter can create one issue for a validated slice on confirmed handoff. It does not execute slice work.

## Lifecycle workflow

The full workflow is interactive and evidence-based:

1. Collect intent, outcomes, acceptance criteria, constraints, and assumptions for a Plan.
2. Capture the managed repository branch and commit in a Project Snapshot.
3. Assess every Plan criterion against the Snapshot and record evidence in a Reconciliation.
4. Select one bounded outcome and create an Execution Slice with the Plan revision, Reconciliation ID, and repository provenance.
5. Validate the complete record set and hand the slice to the normal ApexYard build gate.

The CLI supplies deterministic record construction and validation. The skill supplies the operator prompts and evidence workflow. It does not infer intent or mark criteria as achieved without evidence.

Before saving each Plan, Reconciliation, or Execution Slice, the skill runs Naqid's advisory challenge pass. Naqid steelmans the draft, then identifies assumptions, failure modes, missing evidence, and cheaper alternatives. The operator decides whether to revise, accept, or stop. The challenge does not block ApexYard gates.

Install the `orbit-spec` CLI before using the skill. Set `ORBIT_BIN` when the CLI is installed outside `PATH`.

Example:

```text
/orbit snapshot --project example-app
/orbit reconcile --project example-app --plan docs/orbit/plans/plan.json --snapshot docs/orbit/snapshots/snapshot.json
/orbit slice --project example-app --plan docs/orbit/plans/plan.json --reconciliation docs/orbit/reconciliations/reconciliation.json
/orbit validate --project example-app
```

The validation step passes the managed project's `docs/orbit/` directory to
`orbit validate --all --root <directory>`. The pilot is opt-in. Existing
planning skills continue to work independently.

After successful reconcile and validate calls, the adapter checks the local
Plan, Reconciliation, and slice records. It warns for each outcome with an
unachieved criterion and no slice reference. A slice covers an outcome when
`contributesTo` names its outcome ID or one of its criterion IDs. The warning
does not change the CLI exit status.

A slice ID exists only with its slice record. Create the record when planning
work. Do not reserve slice numbers in prose.

The external `orbit-spec` CLI owns `orbit validate` output, `PROGRESS.md`, and
the status pane. Its follow-up must add the same advisory warning to CLI
reconcile and validate, then mark uncovered outcomes `no slice` in both views.
The adapter does not generate or edit those views.
