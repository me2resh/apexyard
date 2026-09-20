---
name: orbit
description: Run the opt-in ORBIT planning lifecycle for one managed project without replacing ApexYard governance.
argument-hint: "<plan|snapshot|reconcile|slice|validate> --project <name>"
allowed-tools: Bash, Read, Write, Grep, Glob
---

# /orbit — ORBIT planning adapter

Use this skill when an operator explicitly wants ORBIT records for one managed project. The skill is an ApexYard adapter. The ORBIT CLI remains the source of truth for record schemas, lifecycle output, and validation.

The skill does not create issues, branches, commits, code changes, deployments, or external tracker records. Existing ApexYard planning skills remain unchanged.

## Prerequisites

The `orbit` CLI must be available on `PATH`, or the operator must set `ORBIT_BIN` to an executable wrapper. Check it before reading or writing project records:

```bash
ORBIT_BIN="${ORBIT_BIN:-orbit}"
command -v "$ORBIT_BIN" >/dev/null 2>&1 || {
  echo "ORBIT CLI not found. Install orbit-spec or set ORBIT_BIN to the CLI path." >&2
  exit 1
}
```

The active ApexYard ticket remains required for source changes. ORBIT records are planning documents and belong under the managed project's `docs/orbit/` directory.

## Project resolution

Resolve paths through the portfolio helpers. Do not hardcode the registry or workspace directory:

```bash
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-read-config.sh"
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-portfolio-paths.sh"
registry=$(portfolio_registry)
workspace_dir=$(portfolio_workspace_dir)
```

Require `--project <name>`. Resolve that project in the registry and stop if it is missing or has no local workspace. Set:

```text
project_root = <workspace_dir>/<project>
orbit_root   = <project_root>/docs/orbit
```

Use these subdirectories:

```text
docs/orbit/plans/
docs/orbit/snapshots/
docs/orbit/reconciliations/
docs/orbit/slices/
```

Create directories only when the selected operation needs to write a record.

## Operations

### `/orbit plan --project <name> --input <file>`

Validate the supplied Plan, then write it to `docs/orbit/plans/`. Preserve the Plan ID and revision in the filename. Do not invent intent or acceptance criteria.

### `/orbit snapshot --project <name>`

Capture the managed project's current Git branch and commit:

```bash
"$ORBIT_BIN" snapshot \
  --project "<project>" \
  --repository "<repository-id>" \
  --path "$project_root" \
  --output "$orbit_root/snapshots/snapshot-<timestamp>.json"
```

The snapshot is evidence only. It does not claim that a criterion is achieved.

### `/orbit reconcile --project <name> --plan <file> --snapshot <file>`

Build a Reconciliation from the selected Plan and Snapshot:

```bash
"$ORBIT_BIN" reconcile \
  --plan "$plan_file" \
  --snapshot "$snapshot_file" \
  --output "$orbit_root/reconciliations/reconciliation-<timestamp>.json"
```

The first CLI implementation marks criteria `not-verified` until explicit evidence is supplied. Do not upgrade a status from inference.

### `/orbit slice --project <name> --plan <file> --reconciliation <file>`

Ask for the bounded objective, outcome, reason, included work, and excluded work. Then create the slice with the plan revision and reconciliation ID as provenance:

```bash
"$ORBIT_BIN" slice \
  --plan "$plan_file" \
  --reconciliation "$reconciliation_file" \
  --outcome "<outcome-id>" \
  --objective "<bounded objective>" \
  --why "<evidence-based reason>" \
  --include "<item>,<item>" \
  --exclude "<item>,<item>" \
  --output "$orbit_root/slices/slice-<timestamp>.json"
```

The slice is a handoff artifact. ApexYard's normal build, review, QA, and deployment gates still apply.

### `/orbit validate --project <name>`

Validate the complete ORBIT record set before handoff:

```bash
"$ORBIT_BIN" validate --all
```

Return the CLI exit status. A non-zero result blocks the handoff until the record or provenance is corrected.

## Required response

Report:

- project name and resolved workspace
- operation performed
- records read and written
- validation result
- provenance commit and branch when a snapshot or slice was created
- next ApexYard gate, if the operator is handing off a slice

Do not report a slice as executed. ORBIT describes intent and bounded handoff; execution remains provider-specific.
