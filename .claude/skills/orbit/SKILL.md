---
name: orbit
description: Run the opt-in ORBIT planning lifecycle for one managed project without replacing ApexYard governance.
argument-hint: "<plan|snapshot|reconcile|slice|validate|lint|status|handoff> --project <name> [--no-challenge]"
allowed-tools: Bash, Read, Write, Grep, Glob, AskUserQuestion
---

# /orbit - ORBIT planning adapter

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

Require `--project <name>`. Resolve the project in the registry. Stop if it has no registry entry or local workspace. Use its explicit `workspace:` value when present. Resolve relative values against the portfolio root. Otherwise use `portfolio_workspace_dir()`. For example:

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
reconciliation_file="$orbit_root/reconciliations/reconciliation-<timestamp>.json"
"$ORBIT_BIN" reconcile \
  --plan "$plan_file" \
  --snapshot "$snapshot_file" \
  --output "$reconciliation_file"
cli_status=$?
if [ "$cli_status" -eq 0 ]; then
  if ! "$(git rev-parse --show-toplevel)/.claude/skills/orbit/lib/warn-uncovered-outcomes.sh" \
    --orbit-root "$orbit_root" --plan "$plan_file" \
    --reconciliation "$reconciliation_file"; then
    echo "ORBIT coverage check failed; reconcile status is unchanged." >&2
  fi
  if ! "$(git rev-parse --show-toplevel)/.claude/skills/orbit/lib/warn-criterion-shape.sh" \
    --orbit-root "$orbit_root" --plan "$plan_file" \
    --reconciliation "$reconciliation_file"; then
    echo "ORBIT criterion shape check failed; reconcile status is unchanged." >&2
  fi
fi
(exit "$cli_status")
```

The first CLI implementation marks criteria `not-verified` until explicit evidence is supplied. Do not upgrade a status from inference.
Report each `WARNING` line. If the CLI fails, report its failure.

**Write a record only when a status changes (AgDR-0225).** Write the CLI output to a scratch file, not to `$orbit_root/reconciliations/`. Then compare it with the newest Reconciliation of the same Plan:

```bash
"$(git rev-parse --show-toplevel)/.claude/skills/orbit/lib/record-check.sh" \
  --previous "$previous_reconciliation" --candidate "$scratch_reconciliation" \
  --notes "$orbit_root/plans/<plan-id>.notes.md" --commit "$(git -C "$project_root" rev-parse --short HEAD)"
```

- `changed: <ids>`: a criterion status changed. Move the scratch file to `$orbit_root/reconciliations/reconciliation-<timestamp>.json` and add it to the next cycle PR.
- `unchanged`: the script deletes the scratch file and adds one line to the `## Checks` section of the Plan notes: `- <date>, <commit>: checked, no change.` Add no record. The next cycle PR carries the line.

### `/orbit slice --project <name> --plan <file> --reconciliation <file>`

For a slice PR proposal, draft the record only. Use the PR Plan revision and Reconciliation.
Run Naqid with `/challenge`. The owner confirms the scope in PR review before merge.
A scope change needs new confirmation. A basedOn-only change does not.
After merge, `/orbit handoff` needs a yes before it files the ticket.

Ask for the bounded objective, outcome, reason, included work, excluded work, and the acceptance criterion IDs this slice advances. Pass those criterion IDs to `--contributes` as a comma-separated list. The validator accepts criterion IDs only, and each must belong to the slice's `--outcome`. Pass `--id` with a lowercase slice ID. The CLI default ID contains uppercase timestamp letters. Then create the slice with the plan revision and reconciliation ID as provenance:

```bash
"$ORBIT_BIN" slice \
  --plan "$plan_file" \
  --reconciliation "$reconciliation_file" \
  --outcome "<outcome-id>" \
  --id "slice-<lowercase-name>" \
  --contributes "<criterion-id>,<criterion-id>" \
  --objective "<bounded objective>" \
  --why "<evidence-based reason>" \
  --include "<item>,<item>" \
  --exclude "<item>,<item>" \
  --output "$orbit_root/slices/slice-<timestamp>.json"
```

Read the generated `contributesTo` array. Confirm it contains the selected
criterion IDs before handoff. Correct the record and rerun
validation if the CLI leaves the array empty or omits a selected ID.

Read the generated `id`, require the `slice-` prefix and lowercase letters,
digits, and single hyphen separators, then rename the file to
`$orbit_root/slices/<id>.json`. The issue guard checks that exact path. Do not
file the issue while the record exists only on a working branch. Have the
record PR reviewed and merged, then run the handoff steps below. `/orbit slice`
is complete when the issue URL is reported. ApexYard's normal build, review,
QA, and deployment gates still apply.

A slice ID exists only when its record exists. Never reserve a slice number in
prose. When work is planned, create the slice record. Set `contributesTo` to
the criterion IDs that the slice advances. A slice with
an empty `contributesTo` list does not cover an outcome.

### `/orbit validate --project <name>`

Validate the complete ORBIT record set before handoff:

```bash
(
  cd "$orbit_root"
  "$ORBIT_BIN" validate --all --root "$orbit_root"
)
cli_status=$?
if [ "$cli_status" -eq 0 ]; then
  if ! "$(git rev-parse --show-toplevel)/.claude/skills/orbit/lib/warn-uncovered-outcomes.sh" \
    --orbit-root "$orbit_root"; then
    echo "ORBIT coverage check failed; validate status is unchanged." >&2
  fi
  if ! "$(git rev-parse --show-toplevel)/.claude/skills/orbit/lib/warn-criterion-shape.sh" \
    --orbit-root "$orbit_root"; then
    echo "ORBIT criterion shape check failed; validate status is unchanged." >&2
  fi
fi
(exit "$cli_status")
```

Return the CLI exit status. A non-zero result blocks the handoff until the record or provenance is corrected.
Report each `WARNING` line after successful validation.

### `/orbit lint --project <name>`

Lint the records before a records PR (AgDR-0225). `/orbit` runs this step itself before it asks to open a records PR. Do not open the PR when the lint fails. Resolve `project_repo` as in `handoff`.

```bash
"$(git rev-parse --show-toplevel)/.claude/skills/orbit/lib/records-lint.sh" \
  --orbit-root "$orbit_root" --repo "$project_repo"
```

The script checks the record files changed against `origin/dev`. Pass `--base <ref>` to change the base. Pass `--all` to check every record file. It checks initiative ownership on `orbit/` branches (exit 15), then runs six checks in order and stops on the first fault:

1. `orbit validate --all`. Exit 10.
2. The leak scrub, `check-private-refs-runtime.sh`. Exit 11.
3. The sentence check: no sentence of a record text field has more than 25 words. Exit 12.
4. The `Missing: ... Next: ...` rule: a criterion that is not `achieved` has an explanation in this form. Exit 13.
5. The local-path check: no record or notes file holds an absolute local path. Exit 14.
6. The Plan interview check: new or changed Plans need six dated answers in their notes. Exit 16.

The message names the check, the file, and the fault. Fix the fault, then run the lint again. Report the exit code and message when the lint stops.

For a slice PR, pass `--tickets <file>` with one slice ID per line from open and closed issue bodies.
Count only exact backtick tokens. Without this file, the lint warns and skips the C6 check.
C6 permits one open slice per outcome. A filed or withdrawn slice does not block a proposal.

### `/orbit status --project <name> --plan <plan-id>`

Show the live state of a Plan. This operation writes no record, no file, and no notes line.

```bash
"$(git rev-parse --show-toplevel)/.claude/skills/orbit/lib/status-live.sh" \
  --orbit-root "$orbit_root" --plan "<plan-id>" --repo-path "$project_root"
```

The output has two parts:

- The `orbit progress` output for the Plan: outcome progress and criterion statuses as recorded.
- The commits since the newest Reconciliation snapshot, or its slice squash commit when it has a `Slice PR: #N` observation.

Recorded statuses do not change. A status changes only through `/orbit reconcile`. The record ships in a cycle PR or a slice build PR.

### `/orbit handoff --project <name> --slice <file>`

Turn one validated execution slice into one tracker issue, through the existing single-issue `orbit sync github` adapter. This is the only `/orbit` operation that writes to an external tracker. No other ApexYard skill calls the ORBIT CLI (ac1-5) - keep that boundary when you extend this operation.

Resolve `project_root` and `orbit_root` as in Project resolution. Resolve the tracker repository from the same registry entry. Use this value for the duplicate check, leak scrub, sync, and confirmation prompt. Use the helper below. Its `found` flag supports entries before the last registry entry (apexyard#1446, Hakim N1).

```bash
project_repo=$("$(git rev-parse --show-toplevel)/.claude/skills/orbit/lib/resolve-project-repo.sh" "$registry" "$project") || {
  echo "No repo: field for project $project in the registry. /orbit handoff needs a target repo." >&2
  exit 1
}
```

The slice `basedOn` field names its Plan revision and source Reconciliation. Resolve the matching records from `orbit_root` first:

- Plan: the record in `docs/orbit/plans/` whose `id` equals the slice's `planId` and whose `revision` equals `basedOn.planRevision`.
- Reconciliation: the record in `docs/orbit/reconciliations/` whose `id` equals `basedOn.reconciliationId`.
- Snapshot: the record in `docs/orbit/snapshots/` whose `id` equals the resolved Reconciliation's `projectSnapshotId`.

Stop and report if any of the three is missing or ambiguous. Do not guess a record when more than one file matches.

Run the mechanical preflight helper. It performs steps 1-5 below and prints the leak-scrubbed dry-run preview on stdout, or stops with a reason on stderr and a non-zero exit:

```bash
preview=$("$(git rev-parse --show-toplevel)/.claude/skills/orbit/lib/handoff-preflight.sh" \
  --slice "$slice_file" \
  --repo "$project_repo" \
  --orbit-root "$orbit_root") || exit $?
```

The helper's flow, in order:

1. **CLI check.** If `$ORBIT_BIN` (default `orbit`) is not on `PATH`, stop with one install note (ac1-4): "ORBIT CLI not found. Install orbit-spec ... or set ORBIT_BIN to the CLI path." Take no further action.
2. **Validate.** Run `orbit validate --all --root "$orbit_root"`. On a non-zero exit, stop and state the reason from the CLI's own error text (ac1-3).
3. **Duplicate check.** Search open issues in `$project_repo` for the slice ID. Count only an exact backtick-quoted token under Orbit identifiers. A shared word or prefix does not match. Stop with a cannot verify error if the search fails. Never treat a failed search as no duplicate found.
4. **Dry-run preview.** Run `orbit sync github --dry-run --plan <plan_file> --snapshot <snapshot_file> --reconciliation <reconciliation_file> --slice <slice_file> --repo "$project_repo"`. The adapter renders the issue title and body with the Plan ID and revision, objective, scope, and identifiers. The preflight requires a `[Slice]` title. Keep that content.
5. **Leak scrub.** Extract the plain-text title and body with `jq -r '.title'` and `jq -r '.body'`.
   JSON encodes a newline as `\n`. The scrub can miss a private name after this encoding.
   Write the plain-text body to a file. Run `check-private-refs-runtime.sh` against `$project_repo`, the title, and that file.
   A non-zero exit blocks the handoff (ac1-6).

After the helper exits 0, continue with these steps in the skill. They request and use operator input.

6. **Operator confirmation.** Show the target repo, the preview title, and the preview body, and ask: `Create this issue in <owner/repo> for slice <slice-id>? (y/n)`. A "no", an unclear answer, or no answer stops the handoff. Only a clear "yes" continues.

On a no, add `- Withdrawn: <slice-id>` under `## Withdrawn slices` in the Plan notes.
Carry this line in the next records or slice PR. A later slice PR may propose that outcome again.
An unclear or missing answer does not mark a slice withdrawn.

7. **File the issue.** Only after a yes, resolve the merged slice PR's base branch.
   Use its PR base, with `dev` as the framework default. Check the record on `refs/remotes/origin/<base>`.
   Check that branch, not only `origin/HEAD`. Stop until its local ref contains `docs/orbit/slices/<slice-id>.json`.
   Write the adapter preview's `.body` to a temporary file, with
   `` **ORBIT slice:** `<slice-id>` `` as its first line and one blank line before
   the preview body. Use the preview's `.title`. Before the create call, write
   `orbit` to the path from `active_issue_skill_marker_path`. Resolve
   the ops root with `resolve_ops_root` from `_lib-ops-root.sh`, as the ticket
   creation gate does. Source `_lib-session-markers.sh` from that root and call
   `active_issue_skill_marker_path "$ops_root"` for the `active-issue-skill` marker. Stop if the root or session id
   is unknown. Remove the marker on
   every exit path, including cancellation and create failure.

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

The helper uses these non-zero exit codes:

- `10`: CLI absent.
- `11`: validation failed.
- `12`: an open issue carries the exact slice-ID token.
- `13`: usage error, record resolution failure, or duplicate check failure. The search failed or returned no JSON array.
- `14`: the leak scrub blocked the preview.

Report the stderr message for each fault. Preserve its stated reason.

Later ORBIT slices cover these items:

- Sidecar mapping and idempotent handoff.
- Leak scrub on committed records.
- Slice ID recording in `/start-ticket`.
- `Slice:` references in PR bodies.
- Projects v2 board.

## End-to-end planning workflow

When the operator asks for the full lifecycle, run these stages in order. Do not skip a stage because a later record can be written without it.

1. **Plan.** Ask for the project intent, desired outcomes, acceptance criteria, constraints, and assumptions. Draft the Plan JSON in the project record directory. Preserve the operator's wording. Validate it with `orbit plan --input <file> --output <file>`. Do not invent outcomes or criteria.
2. **Snapshot.** Capture the current branch and commit with `/orbit snapshot`. Treat the result as observed evidence, not as a claim that the Plan is achieved.
3. **Reconcile.** Write a record only when a status changes (see `reconcile`). Read the Plan and Snapshot. For every acceptance criterion, inspect the repository evidence and ask for or record a factual status: `not-verified`, `partially-verified`, `achieved`, or `contradicted`. The CLI creates a `not-verified` scaffold. Fill in evidence and explanations before handoff, then run `orbit validate`.
4. **Slice.** Ask which one bounded outcome should be advanced, why the evidence justifies it, what is included, and what is excluded. Create the Execution Slice with `/orbit slice`. Keep the Plan revision, Reconciliation ID, and repository commits unchanged.
5. **Validate and hand off.** Run `/orbit validate` and `/orbit lint`. Merge the slice record, then run `/orbit handoff` to file its issue. Report the records, provenance, and issue URL. Hand the issue to the normal ApexYard build gate. Do not execute it from this skill.

### Progress in a slice PR

A slice build PR may carry its own Reconciliation (AgDR-0239).
The ORBIT pane reads its statuses when the PR merges on dev.
A merge alone changes no status.

1. Resolve the slice record and read its `contributesTo` list.
2. Find the dev merge-base with `git merge-base origin/dev HEAD`.
3. Run snapshot against that commit in a local worktree.
4. Run reconcile with that Snapshot and the current Plan.
5. Copy statuses from the newest Reconciliation on dev.
6. Change only the `contributesTo` criteria.
7. Cite changed PR paths as evidence for each raised status.
8. Add this observation: `Slice PR: #N; dev merge-base <sha>.`
9. Run `records-lint.sh --orbit-root docs/orbit --base origin/dev --slice <slice-id> --pr <number>`. Run `git fetch` first, so the base is current.
10. Include the Snapshot and Reconciliation in the slice build PR.
11. **Propose the next slice.** Read the Plan notes `Order` section and the PR Reconciliation.
    Select the first outcome with unmet criteria and no open slice. Count the PR's own slice as delivered at merge.
    Draft one proposal with `/orbit slice`, using the PR Plan revision and Reconciliation. Run Naqid with `/challenge`.
    Add the record to the PR. Describe its scope under `## Proposed next slice` in the PR body.
    The owner confirms or changes its scope during PR review, before merge. A scope change needs new confirmation.
    A basedOn-only change needs no new confirmation. File no ticket before merge and a yes at handoff.
    When every outcome is achieved, add no slice. Write `No next slice: every outcome is achieved.` under that heading.

The lint rejects scope faults with exit 17, evidence faults with exit 18, and provenance faults with exit 19.
A slice PR without a Reconciliation produces a warning.
Use `--pr-body <file>` to check the next slice statement.
The lint warns when the body has neither `## Proposed next slice` nor `No next slice: every outcome is achieved.`
This warning does not change the exit code.
The lint rejects a PR that states `No next slice: every outcome is achieved.` and adds a slice record.
This fault uses exit 17.
After each branch update, run `refresh-slice-record.sh --orbit-root docs/orbit --base origin/dev --pr <number>` from the skill lib directory.
The script refreshes merge-base observations and the Snapshot. It changes no status or scope.
It updates proposal `basedOn` fields when needed. A basedOn-only change needs no new owner confirmation.
A scope change needs new owner confirmation. Repeat the lint with `--tickets <file>` after each branch update.
A slice PR with a Reconciliation does not count as a records PR for ac8-5.
Plan revisions keep the records PR flow below. A slice PR may add one proposed slice.

### Planning cycle: one records PR

One planning cycle ships one records PR (AgDR-0225). Run these steps in order:

1. Write the Plan revision, with the old revision in `docs/orbit/history/`.
2. Capture the Snapshot.
3. Run `/orbit reconcile`. Keep the Reconciliation only when a status changes. Otherwise the `## Checks` line is the record.
4. Cut every slice of the cycle with `/orbit slice`. Each slice uses this Plan revision and this Reconciliation.
5. Run `/orbit lint`. Stop on the first fault.
6. Ask the operator to open one PR with all records of the cycle. Follow the normal ApexYard review and merge gates. Use `orbit/<initiative-id>-<description>` without a ticket only when the PR changes only `docs/orbit/`.
   Use the title `docs(orbit/<initiative-id>): <description>` for that records PR.
   Derive `<initiative-id>` from the Plan's `id` by removing `plan-`.
   Write `Initiative: plan-<initiative-id>` in the PR body instead of `Closes` or `Refs`.
   When committing the cycle records, write the same trailer in every commit:
   `git commit -m "docs: update ORBIT records" -m "Initiative: plan-<initiative-id>"`.
   Use `git log --grep "Initiative: plan-<initiative-id>"` to find every change.
   Lint blocks records from other initiatives, including Plan notes and history.
   A changed Snapshot must be referenced by a changed Reconciliation of this Plan.
   This branch name and title exemption does not change review or merge gates.
7. After the merge, run `/orbit handoff` for each slice.

A slice found in the middle of a cycle waits for the next cycle PR. It gets its own PR only when its build cannot wait. Count that PR as an exception PR.

If a required input is missing, stop at that stage and report the missing evidence. Do not silently create a partial Plan or treat an unverified criterion as achieved.

## Interaction script

Use `AskUserQuestion` for every operator choice between options in this skill.
Follow `.claude/rules/reporting-style.md section Operator choices`.
Keep single yes/no and ticket confirmation prompts as written.
The prose option prompts below are fallbacks only when the harness lacks `AskUserQuestion`.

Ask one question at a time. Show the proposed record before writing it.

Run `/challenge` by default on Plan and Execution Slice drafts. For Reconciliation, run only when a status changes against the previous Reconciliation or the operator asks.

Naqid must steelman it. Challenge assumptions, failure modes, missing evidence, and cheaper alternatives. Relay its verdict intact. You may revise, accept, or stop. Naqid cannot write records or block gates.

The operator may pass `--no-challenge` when a challenge was already run for the same unchanged draft. Report that the challenge was skipped and preserve the reason.

### Plan interview

Run this six-question interview. Ask questions 1–5 BEFORE drafting, then complete question 6 after showing the draft.
Write the operator's answers in their words under `## Interview` in `docs/orbit/plans/<plan-id>.notes.md`.
Use one dated bullet per question: `- YYYY-MM-DD, <key>: <answer>`. Records lint enforces all six answers.

Each acceptance criterion has one or two sentences, each with at most 25 words (the STE100 descriptive limit).
The statement says what must be true, never how to prove it. Proof belongs elsewhere.

Until the ORBIT schema has a proof field, store proof instructions in `docs/orbit/plans/<plan-id>.notes.md` under `## Proof`.
Use one bullet per criterion ID, for example `- ac1-2: <command or artifact>`.
Record observed results in the Reconciliation evidence.

1. `q1-outcome`: `What project outcome are you trying to achieve?`
2. `q2-intent`: `What durable intent should the Plan preserve?`
3. `q3-outcomes`: `What outcomes must be true when the work is complete?`
4. `q4-acceptance`: `What acceptance criteria state what must be true for each outcome?`
5. `q5-constraints`: `What constraints or assumptions must the Plan record?`
6. `q6-save`: Show the complete Plan JSON, run Naqid, then ask: `Save this Plan revision?`

If the operator declines, revise only the requested fields and show the draft again. Do not write a Plan without confirmation.

### Snapshot interaction

Confirm the selected project and resolved repository path:

`I will capture branch <branch> and commit <commit> for <project>. Continue?`

The snapshot command is read-only against the repository. Do not ask for or expose credentials.

### Reconciliation interview

For every assessment that is not `achieved`, start its explanation with this prefix:

```text
Missing: <what is still missing>. Next: <the step that closes it>.
```

Put other facts after this prefix.

For each acceptance criterion, ask:

Use `AskUserQuestion` for the status choice. Recommend `not-verified` first until evidence supports another status.
The status list below is a prose fallback only when the harness lacks the tool.

1. `What repository evidence supports this criterion?`
2. `Which status applies: not-verified, partially-verified, achieved, or contradicted?`
3. `What explanation should remain with the evidence?`

Show Reconciliation. Run Naqid only when a status changes or the operator asks. Ask: `Save this Reconciliation?` A missing answer remains `not-verified`.

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
- for `handoff`: resolved record files, preflight exit code, leak scrub result, operator confirmation, and issue URL
- for a stopped `handoff`: refusal reason and exit code

Do not report a slice as executed. ORBIT describes intent and bounded handoff. Execution remains provider-specific. For `handoff`, report the issue as created. Filing a ticket does not execute its work.
