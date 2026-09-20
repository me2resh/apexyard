# ORBIT adapter pilot

The `/orbit` skill is an opt-in ApexYard adapter for the portable ORBIT CLI. It stores planning records under the selected managed project's `docs/orbit/` directory.

The adapter keeps responsibilities separate:

- ORBIT owns record shapes, provenance fields, lifecycle commands, and validation.
- ApexYard owns ticket-first editing, AgDRs, review, QA, deployment, and project resolution.
- The adapter does not create external issues or execute code.

Install the `orbit-spec` CLI before using the skill. Set `ORBIT_BIN` when the CLI is installed outside `PATH`.

Example:

```text
/orbit snapshot --project example-app
/orbit reconcile --project example-app --plan docs/orbit/plans/plan.json --snapshot docs/orbit/snapshots/snapshot.json
/orbit slice --project example-app --plan docs/orbit/plans/plan.json --reconciliation docs/orbit/reconciliations/reconciliation.json
/orbit validate --project example-app
```

The pilot is opt-in. Existing planning skills continue to work independently.
