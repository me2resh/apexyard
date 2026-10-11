---
id: AgDR-0225
timestamp: 2026-10-11T06:20:00Z
agent: claude
model: claude-opus-5-5
trigger: user-prompt
status: accepted
---

# Light ceremony for ORBIT records

> In the context of ORBIT records PRs that each take a full Rex review, facing 80k to 120k tokens and one round trip per review round, I decided to batch records into one PR per planning cycle, to stop committing reconciliations that change no status, and to lint records before the PR, to achieve one short review per cycle, accepting that records PRs keep a Rex review and that a status change still needs a PR.

## Context

- An ORBIT records PR changes only JSON records and a notes file under `docs/orbit/`. PR #1620 (Plan r1, Snapshot, Reconciliation) took four Rex rounds. The findings in rounds 2 to 4 were number precision and wording.
- Each record is a separate PR today: a Plan revision, each Reconciliation and each Slice. A Plan revision also writes the old revision to `docs/orbit/history/`.
- AgDR-0116 keeps a Rex marker on every PR. It defers a path-based gate exemption until a third incident of re-review churn shows that the reduced-scope Rex review is not enough. `code-reviewer.md` § "Reduced-Scope Review" already exists for Lean diffs.
- Plan constraint C1 says the merge-gate scripts are not edited.

## Options Considered

### Gate for records-only PRs

| Option | Pros | Cons |
|--------|------|------|
| A. Full Rex review on every records PR (today) | No change | 80k to 120k tokens per Rex round (PRs #1621 and #1622) |
| B. Reduced-scope Rex on records PRs, with a lint in `/orbit` before the PR | No gate edit; uses an existing mode | Still one Rex spawn per PR |
| C. A script runs the lint and writes the Rex marker | No gate edit | A script-written approval records a review that did not happen |
| D. The merge gate skips the Rex marker when the forge file list matches a records allowlist and a required check is green | No Rex spawn | Edits the gate; see "Why not D" |

### Batching

| Option | Pros | Cons |
|--------|------|------|
| E. One PR per record (today) | Small diffs | One review and one wait per record |
| F. One PR per planning cycle: Plan revision, Snapshot, Reconciliation and the slices of the cycle together | One review per cycle | A slice found mid-cycle waits for the next cycle PR, or gets its own PR |

### Reconciliations

| Option | Pros | Cons |
|--------|------|------|
| G. Commit a Reconciliation for each check (today) | Full history | One PR per check, also when no status changes |
| H. A bot commits a Reconciliation after each merge | No human step | A bot push to the default branch bypasses the merge gates |
| I. The viewer and the pane show a live view. Commit a Reconciliation only when a status changes, in the cycle PR | No PR without a status change | A status change still needs a human and a PR |

## Decision

Chosen: **B + F + I**, because together they cut the review count to one short pass per cycle with no gate edit.

- **B.** `/orbit` runs a records lint before it opens a PR. The lint covers `orbit validate --all`, the leak scrub, the 25-word check, the `Missing: … Next:` rule and the local-path check. Rex reviews a records PR in reduced scope when it meets the eligibility rules in `code-reviewer.md` § "Reduced-Scope Review". Otherwise Rex reviews it in full.
- **F.** Cut the slices of a cycle with the Plan revision, then open one PR. A slice found mid-cycle may still get its own PR when its build cannot wait.
- **I.** The live view shows recorded statuses, commits since the last reconciliation, and criteria a script can check. `/orbit reconcile` writes a record only when a status changes. When a check changes nothing, the next cycle PR adds one append-only "checked, no change" line, with the date and commit.

### Why not D

Naqid's challenge found four faults in D:

1. A Plan revision writes to `docs/orbit/history/`, so every cycle PR would fall outside the allowlist.
2. An agent token can post a commit status with the check name. Strict required checks are off, so a green check does not prove the lint ran on the merged head.
3. The notes file is prose. Prose caused the wording findings, and a script cannot check it.
4. One incident does not meet the AgDR-0116 condition of a third incident.

Revisit D only if Rex rounds per records PR stay above one after a full cycle. A new proposal must cover these four faults and test symlinks, gitlinks, status spoofing and a head change after the check.

## Consequences

- AgDR-0116 and plan constraint C1 stay unchanged. Every PR keeps a Rex marker and the CEO marker.
- The `/orbit` skill gains the pre-PR lint, the cycle-PR flow and the reconcile-only-on-change rule.
- The viewer and the pane gain the live view.
- `.claude/skills/orbit/lib/warn-uncovered-outcomes.sh` reads the last recorded reconciliation, so a status change committed late leaves its warning stale until the cycle PR.
- Under o7, ac7-1 makes `docs/orbit/slices/` Full because a hook reads it. A cycle PR with slices then gets a full Rex review, and ac8-5 measures whether the lint keeps it to one round.
- Plan revision 2 of plan-apexyard-token-efficiency carries this as outcome o8. The o1 script measures it: Rex rounds per records PR and records PRs per cycle.

## Artifacts

- Owner decisions: 2026-10-11 (ideas 2 and 3 kept, idea 1 dropped after the challenge).
- Challenge: Naqid, 2026-10-11, verdict "reconsider D, proceed with F + I".
- Records ticket: #1619.
