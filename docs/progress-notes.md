# Resume ticket work

A progress note records the current ticket state beside `apexyard-ticket` in the worktree's git directory.
The file is `apexyard-progress.md`. Git never commits it.
Each worktree has one note. Starting another ticket replaces the previous note.
Starting the same ticket preserves its evidence.

The fixed fields are Task, Outputs, Completed, Decisions, Open issues, and Next action.
Outputs names the branch, PR, and files. Completed records stages, checks, and evidence.
Next action states one concrete step.

## Create the note

For the interactive fallback, source `.claude/hooks/_lib-progress-note.sh` from the ops root.
Call `progress_note_create "$tree"` after the marker write succeeds.
Report any failure and stop. Preserve the note when resuming the same ticket.

## Update the note

The orchestrator updates the progress note at PR opened, CI result, review verdict, fix pushed, and merge.
Source `.claude/hooks/_lib-progress-note.sh` from the framework checkout.
Set `$tree` to the ticket worktree, including when the orchestrator runs elsewhere.
Call `progress_note_update "$tree" Completed '<stage>: <evidence and head SHA>'` after each observed result.
Record failures and requested changes too. Update Outputs and Next action with separate calls.
Do not call the helper from gate hooks.

The orchestrator sources the library from the framework checkout:

```bash
. .claude/hooks/_lib-progress-note.sh
progress_note_update "$PWD" Outputs 'branch=feature/GH-42-example; PR=42; files=example.sh'
progress_note_update "$PWD" Completed 'PR opened: PR 42, head <SHA>'
progress_note_update "$PWD" Completed 'CI result: green, head <SHA>, run <URL>'
progress_note_update "$PWD" Completed 'Review verdict: Rex APPROVED, head <SHA>, review <URL>'
progress_note_update "$PWD" Completed 'Fix pushed: head <SHA>, checks pending'
progress_note_update "$PWD" Completed 'Merge: PR 42, commit <SHA>'
progress_note_update "$PWD" 'Next action' 'Verify the acceptance criteria against the merged commit'
```

Replace examples with observed evidence. Record failed checks and requested changes too.
Update one field per call. Completed appends evidence. Other fields replace their previous value.
The helper serializes writers with a lock and atomically renames a temporary file.
A lock conflict fails visibly. Report the error instead of removing another writer's lock.
The note never grants approval or changes a gate decision.

## Resume in another session

1. Enter the same worktree.
2. Read the SessionStart output, including the note's age.
3. Verify the recorded branch, PR head, CI result, and review evidence against current state.
4. Read the full note when the printed field text ends early.
5. Update Open issues and Next action with current evidence.
6. Continue with Next action.

SessionStart prints the six fields on startup and after compaction.
It caps each field at 2,000 characters and warns after 24 hours.
A different machine or removed worktree has no saved note.
Run `/start-ticket` there and reconstruct evidence before continuing.

## Set the done condition

A done condition states the evidence that ends a run.
Set Claude Code's `/goal` before building with the ticket acceptance criteria and these required facts.
The shared condition is: PR open, CI green on the current head SHA, Rex APPROVED at that head, progress note current.

- A PR is open.
- CI is green on the current head SHA.
- Rex reports APPROVED at that same head SHA.
- The progress note reflects the current evidence and next action.

Set a limit of 20 turns. Stop at that limit and report the blocker with evidence.
Give build agents the same condition and limit in their brief.
Build agents report results to the orchestrator for independent review.
The goal does not authorize a merge.
