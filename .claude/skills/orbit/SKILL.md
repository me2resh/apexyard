---
name: orbit
description: Run the opt-in ORBIT planning lifecycle for one managed project without replacing ApexYard governance.
argument-hint: "<plan|snapshot|reconcile|slice|validate|handoff> --project <name> [--no-challenge]"
allowed-tools: Bash, Read, Write, Grep, Glob, AskUserQuestion
---

# /orbit — ORBIT planning adapter

Use this skill when an operator explicitly wants ORBIT records for one managed project. The skill is an ApexYard adapter. The ORBIT CLI remains the source of truth for record schemas, lifecycle output, and validation.

Use the controlled technical writing profile for prompts, record explanations, and any durable handoff text.

The skill does not create branches, commits, code changes, or deployments. Existing ApexYard planning skills remain unchanged. `slice` ends with the `handoff` issue step when ORBIT planning is on. The issue step uses the ORBIT GitHub adapter preview, a leak scrub, and operator confirmation (AgDR-0179, partly superseding AgDR-0164).

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

Read the generated `id`, require the `slice-` prefix and lowercase letters,
digits, and single hyphen separators, then rename the file to
`$orbit_root/slices/<id>.json`. The issue guard checks that exact path. Do not
file the issue while the record exists only on a working branch. Have the
record PR reviewed and merged, then run the handoff steps below. `/orbit slice`
is complete when the issue URL is reported. ApexYard's normal build, review,
QA, and deployment gates still apply.

### `/orbit validate --project <name>`

Validate the complete ORBIT record set before handoff:

```bash
(
  cd "$orbit_root"
  "$ORBIT_BIN" validate --all --root "$orbit_root"
)
```

Return the CLI exit status. A non-zero result blocks the handoff until the record or provenance is corrected.

### `/orbit handoff --project <name> --slice <file>`

Turn one validated execution slice into one tracker issue, through the existing single-issue `orbit sync github` adapter. This is the only `/orbit` operation that writes to an external tracker. No other ApexYard skill calls the ORBIT CLI (ac1-5) — keep that boundary when you extend this operation.

Resolve `project_root` and `orbit_root` as in "Project resolution" above. Also resolve the project's tracker repo from the same registry entry — the handoff files the issue against this repo, and every other step below (the duplicate check, the leak scrub, the sync, the confirmation prompt) uses this same value, never a placeholder typed by hand. Use the helper, not a hand-rolled `awk` line — a project that is not the last registry entry needs the `found`-flag fix the helper carries (apexyard#1446, Hakim N1):

```bash
project_repo=$("$(git rev-parse --show-toplevel)/.claude/skills/orbit/lib/resolve-project-repo.sh" "$registry" "$project") || {
  echo "No repo: field for project $project in the registry. /orbit handoff needs a target repo." >&2
  exit 1
}
```

The slice file's `basedOn` names the Plan revision and the Reconciliation it was cut from; resolve the matching records from `orbit_root` before doing anything else:

- Plan: the record in `docs/orbit/plans/` whose `id` equals the slice's `planId` and whose `revision` equals `basedOn.planRevision`.
- Reconciliation: the record in `docs/orbit/reconciliations/` whose `id` equals `basedOn.reconciliationId`.
- Snapshot: the record in `docs/orbit/snapshots/` whose `id` equals the resolved Reconciliation's `projectSnapshotId`.

Stop and report if any of the three is missing or ambiguous. Do not guess a record when more than one file matches.

Run the mechanical preflight helper. It performs steps 1–5 below and prints the leak-scrubbed dry-run preview on stdout, or stops with a reason on stderr and a non-zero exit:

```bash
preview=$("$(git rev-parse --show-toplevel)/.claude/skills/orbit/lib/handoff-preflight.sh" \
  --slice "$slice_file" \
  --repo "$project_repo" \
  --orbit-root "$orbit_root") || exit $?
```

The helper's flow, in order:

1. **CLI check.** If `$ORBIT_BIN` (default `orbit`) is not on `PATH`, stop with one install note (ac1-4): "ORBIT CLI not found. Install orbit-spec ... or set ORBIT_BIN to the CLI path." Take no further action.
2. **Validate.** Run `orbit validate --all --root "$orbit_root"`. On a non-zero exit, stop and state the reason from the CLI's own error text (ac1-3).
3. **Duplicate check.** Search open issues in `$project_repo` for the slice ID, but only *count* a hit when an issue's body contains the exact backtick-quoted token the adapter renders under "Orbit identifiers" (`` `<slice-id>` ``) — a shared word or a prefix is not a match. When the search itself fails (auth, network, rate limit), stop with a "cannot verify" error; never treat a failed search as "no duplicate found".
4. **Dry-run preview.** Run `orbit sync github --dry-run --plan <plan_file> --snapshot <snapshot_file> --reconciliation <reconciliation_file> --slice <slice_file> --repo "$project_repo"`. The adapter renders the issue title and body with the Plan ID and revision, objective, scope, and identifiers. Keep that content.
5. **Leak scrub.** Extract the plain-text title and body from the preview with `jq -r '.title'` / `jq -r '.body'` — not the raw JSON, where a name at the start of a body line is preceded by the two characters `\n` rather than a real newline, and the scrub's word-boundary rule misses it. Run `check-private-refs-runtime.sh` against `$project_repo`, the plain-text title, and the plain-text body written to a file. A non-zero exit blocks the handoff (ac1-6).

After the helper exits 0 with the scrubbed preview on stdout, continue in the skill itself (these two steps ask for and act on operator input, so they stay outside the mechanical helper):

6. **Operator confirmation.** Show the target repo, the preview title, and the preview body, and ask: `Create this issue in <owner/repo> for slice <slice-id>? (y/n)`. A "no", an unclear answer, or no answer stops the handoff. Only a clear "yes" continues.

7. **File the issue.** Only after a "yes", confirm that
   `docs/orbit/slices/<slice-id>.json` exists on the project's local
   `origin/HEAD` default-branch ref. If the ref is missing or the record is
   absent, stop until the record PR merges and the local ref is updated. Write
   the adapter preview's `.body` to a temporary file, with
   `**ORBIT slice:** \`<slice-id>\`` as its first line and one blank line before
   the preview body. Use the preview's `.title`:

   ```bash
   slice_id=$(jq -r '.id' "$slice_file")
   issue_body_file=$(mktemp)
   { printf '**ORBIT slice:** `%s`\n\n' "$slice_id";
     printf '%s' "$preview" | jq -r '.body'; } > "$issue_body_file"
   issue_title=$(printf '%s' "$preview" | jq -r '.title')
   printf 'Body file: %s\nTitle: %s\n' "$issue_body_file" "$issue_title"
   ```

   File one issue in a separate Bash call with
   `gh issue create --repo <project_repo> --title <preview-title> --body-file
   <literal-temp-path>`. Use the literal path in this Bash call so the
   PreToolUse guard can read the file. Remove the temporary file and report
   the created issue URL. The adapter's real sync does not support this body
   prefix, so use its validated preview as the source for the issue content.

The helper's non-zero exit codes: `10` CLI absent, `11` validate failed, `12` an open issue already carries the exact slice-ID token, `13` a usage error, a record-resolution failure, or a duplicate check that could not be verified (the search failed or returned something other than a JSON array), `14` the leak scrub blocked the preview. Surface the stderr message in each case; do not paraphrase it into a different reason.

Out of scope for this operation (later ORBIT slices): the sidecar mapping file and idempotent re-handoff, the leak scrub on committed ORBIT records, `/start-ticket` recording the slice ID, the `Slice:` reference check in PR bodies, and the Projects v2 board.

## End-to-end planning workflow

When the operator asks for the full lifecycle, run these stages in order. Do not skip a stage because a later record can be written without it.

1. **Plan.** Ask for the project intent, desired outcomes, acceptance criteria, constraints, and assumptions. Draft the Plan JSON in the project record directory. Preserve the operator's wording. Validate it with `orbit plan --input <file> --output <file>`. Do not invent outcomes or criteria.
2. **Snapshot.** Capture the current branch and commit with `/orbit snapshot`. Treat the result as observed evidence, not as a claim that the Plan is achieved.
3. **Reconcile.** Read the Plan and Snapshot. For every acceptance criterion, inspect the repository evidence and ask for or record a factual status: `not-verified`, `partially-verified`, `achieved`, or `contradicted`. The CLI creates a `not-verified` scaffold. Fill in evidence and explanations before handoff, then run `orbit validate`.
4. **Slice.** Ask which one bounded outcome should be advanced, why the evidence justifies it, what is included, and what is excluded. Create the Execution Slice with `/orbit slice`. Keep the Plan revision, Reconciliation ID, and repository commits unchanged.
5. **Validate and hand off.** Run `/orbit validate`. Merge the slice record, then run `/orbit handoff` to file its issue. Report the records, provenance, and issue URL. Hand the issue to the normal ApexYard build gate; do not execute it from this skill.

If a required input is missing, stop at that stage and report the missing evidence. Do not silently create a partial Plan or treat an unverified criterion as achieved.

## Interaction script

Use `AskUserQuestion` for every operator choice between options in this skill.
Follow `.claude/rules/reporting-style.md § Operator choices`.
Keep single yes/no and ticket confirmation prompts as written.
The prose option prompts below are fallbacks only when the harness lacks `AskUserQuestion`.

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

Use `AskUserQuestion` for the status choice. Recommend `not-verified` first until evidence supports another status.
The status list below is a prose fallback only when the harness lacks the tool.

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
6. Show the complete Execution Slice, run Naqid, and ask: `Save this slice and file its issue after the record merges?`

The final question authorizes the record and issue handoff. It does not authorize code execution or deployment.

## Required response

Report:

- project name and resolved workspace
- operation performed
- records read and written
- validation result
- provenance commit and branch when a snapshot or slice was created
- next ApexYard gate, if the operator is handing off a slice
- for `handoff`: the resolved Plan/Snapshot/Reconciliation files, the preflight exit code, the leak scrub result, the operator's confirmation, and the created issue URL (or the refusal reason and exit code, if the handoff stopped)

Do not report a slice as executed. ORBIT describes intent and bounded handoff; execution remains provider-specific. `handoff` is the exception: report the created issue as created, not as executed — filing a ticket is not running the work.
