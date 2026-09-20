---
name: orbit
description: Run the opt-in ORBIT planning lifecycle for one managed project without replacing ApexYard governance.
argument-hint: "<plan|snapshot|reconcile|slice|validate> --project <name> [--no-challenge]"
allowed-tools: Bash, Read, Write, Grep, Glob
---

# /orbit — ORBIT planning adapter

Use this skill when an operator explicitly wants ORBIT records for one managed project. The skill is an ApexYard adapter. The ORBIT CLI remains the source of truth for record schemas, lifecycle output, and validation.

Use the controlled technical writing profile for prompts, record explanations, and any durable handoff text.

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

Require `--project <name>`. Resolve that project in the registry and stop if it is missing or has no local workspace. Use the entry's `workspace:` value when it is present. Resolve relative values against the portfolio root; use `portfolio_workspace_dir()` only as the fallback for entries without an explicit workspace path. For example:

```bash
project_workspace=$(awk -v target="$project" '
  function value(line) { sub(/^[^:]+:[[:space:]]*/, "", line); gsub(/^['"'"']|['"'"']$/, "", line); return line }
  /^[[:space:]]*- name:/ { if (name == target) { print workspace; exit }; name=value($0); workspace=""; next }
  /^[[:space:]]*workspace:/ { workspace=value($0) }
  END { if (name == target) print workspace }
' "$registry")
if [ -z "$project_workspace" ]; then
  project_workspace="$workspace_dir/$project"
elif [[ "$project_workspace" != /* ]]; then
  project_workspace="$(cd "$(dirname "$registry")" && pwd)/$project_workspace"
fi
project_root="$(cd "$project_workspace" && pwd)"
```

Stop if the resolved path does not exist or is not a Git repository. Set:

```text
project_root = <resolved registry workspace path>
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
(
  cd "$orbit_root"
  "$ORBIT_BIN" validate --all
)
```

Return the CLI exit status. A non-zero result blocks the handoff until the record or provenance is corrected.

## End-to-end planning workflow

When the operator asks for the full lifecycle, run these stages in order. Do not skip a stage because a later record can be written without it.

1. **Plan.** Ask for the project intent, desired outcomes, acceptance criteria, constraints, and assumptions. Draft the Plan JSON in the project record directory. Preserve the operator's wording. Validate it with `orbit plan --input <file> --output <file>`. Do not invent outcomes or criteria.
2. **Snapshot.** Capture the current branch and commit with `/orbit snapshot`. Treat the result as observed evidence, not as a claim that the Plan is achieved.
3. **Reconcile.** Read the Plan and Snapshot. For every acceptance criterion, inspect the repository evidence and ask for or record a factual status: `not-verified`, `partially-verified`, `achieved`, or `contradicted`. The CLI creates a `not-verified` scaffold. Fill in evidence and explanations before handoff, then run `orbit validate`.
4. **Slice.** Ask which one bounded outcome should be advanced, why the evidence justifies it, what is included, and what is excluded. Create the Execution Slice with `/orbit slice`. Keep the Plan revision, Reconciliation ID, and repository commits unchanged.
5. **Validate and hand off.** Run `/orbit validate`. Report the records and provenance. Hand the slice to the normal ApexYard build gate; do not execute it from this skill.

If a required input is missing, stop at that stage and report the missing evidence. Do not silently create a partial Plan or treat an unverified criterion as achieved.

## Interaction script

Ask one question at a time. Show the proposed record before writing it.

After each Plan, Reconciliation, and Execution Slice draft, run `/challenge` with the draft as the target. Naqid must steelman the draft, identify hidden assumptions, failure modes, missing evidence, and cheaper alternatives, then return an advisory verdict. Relay the result without softening it. The operator may revise the draft, accept it, or stop. Naqid never writes records and never blocks an ApexYard gate.

The operator may pass `--no-challenge` when a challenge was already run for the same unchanged draft. Report that the challenge was skipped and preserve the reason.

### Plan interview

1. `What project outcome are you trying to achieve?`
2. `What durable intent should the Plan preserve?`
3. `What outcomes must be true when the work is complete?`
4. `What acceptance criteria will prove each outcome?`
5. `What constraints or assumptions must the Plan record?`
6. Show the complete Plan JSON, run Naqid, then ask: `Save this Plan revision?`

If the operator declines, revise only the requested fields and show the draft again. Do not write a Plan without confirmation.

### Snapshot interaction

Confirm the selected project and resolved repository path:

`I will capture branch <branch> and commit <commit> for <project>. Continue?`

The snapshot command is read-only against the repository. Do not ask for or expose credentials.

### Reconciliation interview

For each acceptance criterion, ask:

1. `What repository evidence supports this criterion?`
2. `Which status applies: not-verified, partially-verified, achieved, or contradicted?`
3. `What explanation should remain with the evidence?`

Show the complete Reconciliation, run Naqid, and ask: `Save this Reconciliation?` A missing answer remains `not-verified`.

### Slice interview

Ask:

1. `Which Plan outcome should this slice advance?`
2. `What is the smallest bounded objective?`
3. `Why does the current evidence justify it now?`
4. `What work is included?`
5. `What work is excluded?`
6. Show the complete Execution Slice, run Naqid, and ask: `Save this slice for the ApexYard build gate?`

The final question hands off the artifact. It does not authorize code execution or deployment.

## Required response

Report:

- project name and resolved workspace
- operation performed
- records read and written
- validation result
- provenance commit and branch when a snapshot or slice was created
- next ApexYard gate, if the operator is handing off a slice

Do not report a slice as executed. ORBIT describes intent and bounded handoff; execution remains provider-specific.
