# Gate state contract

This page lists each record that the framework gates read or write.
For each record it says the path, who writes it, who reads it, its scope, when it goes stale, and how it is revoked today.
It describes the code at the time of writing. It changes no behavior.
Where a record is not revoked, the page says so.

There is no single "ready to merge" record.
A merge needs several independent records plus live forge state.
The merge gates in `.claude/hooks/dispatch-bash.sh:427-445` check them one by one.

## Terms

- Ops root is the root of the ops fork. A linked worktree of the fork resolves to the main checkout (`.claude/hooks/_lib-ops-root.sh:286`). Linked worktrees share one ops root.
- Tree git dir is the git directory of one working tree. The main clone uses `<repo>/.git`. A linked worktree uses `<repo>/.git/worktrees/<id>`.
- Key `K` is `<owner>__<repo>__<pr>`. Owner and repo are those of the base repository of the PR (`.claude/hooks/_lib-review-markers.sh:85-110`).
- Head is the head commit of the PR, as the forge reports it.
- Carry-over means a record made at an older commit still counts after the PR branch took a verified base merge.
- Scope says what the record is tied to: a worktree, a session, or a PR.

All records under `.claude/session/` are local files.
The folder is ignored by git (`.gitignore:3`).
A record is not a security boundary: anyone who can write the file can forge it.
The gates are process checks.

## Overview

| Record | Path | Written by | Read by | Scope |
|--------|------|-----------|---------|-------|
| Active ticket | `<tree git dir>/apexyard-ticket` | `bin/apexyard-start-ticket`, `/start-ticket`, `/fan-out` | `require-active-ticket.sh`, `require-migration-ticket.sh` and other readers of `_lib-active-ticket.sh` | One working tree |
| Active ticket, legacy | `<ops root>/.claude/session/tickets/<project>[/<branch>]` and `<ops root>/.claude/session/current-ticket` | The same writers, during the transition | The same readers, when the tree marker is absent or not trusted | Project or session, so more than one tree |
| Active reviewer | `<ops root>/.claude/session/active-reviewers/<session>/<K>-<kind>` | `/code-review`, `/security-review`, `/design-review` | The reviewer locks and the marker-write warning | One session, one review |
| Rex approval | `<ops root>/.claude/session/reviews/<K>-rex.approved` | Rex, through `review_write_rex_approved` | `block-unreviewed-merge.sh`, the approval skills | One PR |
| Design approval | `<ops root>/.claude/session/reviews/<K>-design.approved` | `/approve-design`, or the approval menu | `require-design-review-for-ui.sh` | One PR |
| Architecture approval | `<ops root>/.claude/session/reviews/<K>-architecture.approved` | Tariq, `/approve-architecture`, or the approval menu | `require-architecture-review.sh` | One PR |
| Human approval | `<ops root>/.claude/session/reviews/<K>-ceo.approved` | `/approve-merge`, or the approval menu | `block-unreviewed-merge.sh` | One PR |
| Pending review | `<creation root>/.claude/session/pending-reviews/<pr>` | `auto-code-review.sh` | No hook | The folder where `gh pr create` ran |
| Menu approval | The design, architecture or human approval path | `record-menu-approval.sh` | The same gate as the typed record | One PR |

The file name of the human approval is always `-ceo.approved`.
This holds even when `review_markers.human_approver_title` sets another title.

## Active ticket

**Path.**
`<tree git dir>/apexyard-ticket` (`.claude/hooks/_lib-active-ticket.sh:1-13`).
One tree has one ticket.

**Format.**
Key and value lines: `repo`, `number`, `title`, `url`, `suggested_branch`, `session_id`, `branch` and `started_at` (`_lib-active-ticket.sh:1442-1449`).

**Writer.**
`bin/apexyard-start-ticket` and `/start-ticket` call `active_ticket_write` (`_lib-active-ticket.sh:1382`).
`/fan-out` writes it for its worktrees.
The writer also writes the legacy record during the transition (`_lib-active-ticket.sh:1699-1703`).
A write that would replace a different ticket held by another session is refused unless the operator chooses take over (`_lib-active-ticket.sh:1187`, `:1676-1683`).

**Readers.**
`require-active-ticket.sh` (`:995-1003`) and `require-migration-ticket.sh` call `active_ticket_lookup` (`_lib-active-ticket.sh:907`).
`require-agdr-for-arch-changes.sh`, `require-agdr-for-arch-pr.sh` and `block-ambient-tracker-repo.sh` use the same library.

**Scope.**
One working tree.
A marker in the main clone does not govern a linked worktree (`.claude/skills/start-ticket/SKILL.md:302`).
The marker is per machine and is never committed.

**Expiry.**
It does not expire.
It survives new commits, a merge, and a new session.
Nothing ties it to the state of the PR.
A session or branch that differs from the marker only prints a warning. The edit still runs (`_lib-active-ticket.sh:1247-1277`, `require-active-ticket.sh:1001`).

**Revocation.**
There is no revoke command.
The operator deletes `<tree git dir>/apexyard-ticket`.
`git worktree remove` deletes it with the worktree (`.claude/skills/start-ticket/SKILL.md:301`).
A merge does not clear it. `/approve-merge` only offers to remove the worktree, and the operator must say yes (`.claude/skills/approve-merge/SKILL.md:284`).

**Legacy fallback.**
The reader uses the tree marker when it exists and the tree passes validation.
Otherwise it reads the legacy files (`_lib-active-ticket.sh:15-20`, `:676-690`).
So deleting only the tree marker can leave a legacy marker in force.
A legacy project marker or `current-ticket` can cover more than one worktree.
A session notice lists legacy files (`.claude/hooks/warn-legacy-ticket-markers.sh`).
The start-ticket skill says a breaking release will stop reading and writing them (`.claude/skills/start-ticket/SKILL.md:304`).

## Active reviewer

**Path.**
`<ops root>/.claude/session/active-reviewers/<session>/<K>-<kind>`, where kind is `rex`, `security` or `architecture` (`_lib-review-markers.sh:173-210`).
The older single file `<ops root>/.claude/session/active-reviewer.<session>` is still read.
The file holds `<owner/repo>#<pr>:<kind>`.

**Writer.**
The review skill writes it before it spawns the reviewer, for example `.claude/skills/code-review/SKILL.md:79-92`.
The review agent does not write it.

**Readers.**

- `block-reviewer-repo-mutation.sh` locks `git clone`, `git fetch` and `git checkout` for a review agent. A typed review agent is locked with or without the file. An untyped sub-agent is locked only while a file exists for the session (`block-reviewer-repo-mutation.sh:254-308`).
- `block-reviewer-ci-wait.sh` and `limit-reviewer-writes.sh` use the same rule to decide who is a review agent.
- `warn-review-marker-write.sh` reads it to tell a sanctioned approval write from a forged one. It only warns.
- `require-active-ticket.sh` lets a reviewer write under the session scratchpad without a ticket while the file exists (`require-active-ticket.sh:61-70`).

**Scope.**
One session and one review.
Two reviews in one session use two files.
Another session never sees the file.

**Expiry.**
The skill removes its own file after the review is posted (`.claude/skills/code-review/SKILL.md:95-103`).
At the start of a session, `clear-active-reviewer-marker.sh` removes the files of the same session id (`:75-98`).
Ending a session does not remove the file by itself.
A file left by a crashed session stays until a session with the same id starts again.

**Revocation.**
Only the two removals above.
No hook removes the file of another session.

## Rex approval

**Path.**
`<ops root>/.claude/session/reviews/<K>-rex.approved` (`_lib-review-markers.sh:67-110`).
The file holds the bare 40 character commit SHA and a newline.
The review body is a separate file in `.claude/session/reviews/bodies/<K>-rex.md` (`_lib-review-markers.sh:122-135`).

**Writer.**
Rex calls `review_write_rex_approved` (`_lib-review-markers.sh:677-711`).
The function checks the body, the reviewed-commit footer, and an exact `**APPROVED**` verdict.
It then writes the SHA.
A bare number path (`<pr>-rex.approved`) is not read by any gate.

**Reader.**
`block-unreviewed-merge.sh` compares the SHA in the file with the head (`:449-493`).
`/approve-design` and `/approve-architecture` also require the SHA to equal the head (`.claude/skills/approve-design/SKILL.md:95-129`, `.claude/skills/approve-architecture/SKILL.md:93-127`).

**Scope.**
One PR, keyed on the base repository.
The key has no session and no commit.
A second review of the same PR replaces the file.

**Stale when.**
The head differs from the SHA in the file.
The exception is carry-over.
The gate accepts the old SHA when `rex_approval_carries_over` proves a chain.
The chain has at most 10 two-parent merges of the base branch.
It starts at the approved commit and ends at the head (`_lib-merge-behind.sh:88-124`, `:389`, `:434`).
The proof uses forge data and a rebuilt merge tree.
The file keeps its old SHA.

**Revocation.**
There is none.

- A later review that is not approved writes no file. It does not delete the earlier file either. The writer refuses the write and leaves the old file in place (`_lib-review-markers.sh:698-711`, `.claude/agents/code-reviewer.md:673-675`). An approval at the same head therefore stays in force after a later `CHANGES REQUESTED` review.
- No hook or skill removes the file when the PR merges or closes.
- The push-time check `warn-stale-review-markers.sh` compares the SHA with the head by simple equality. By default it only warns. It deletes files only when `review_markers.on_stale` is `delete` (`:231-246`, `.claude/project-config.defaults.json:190`). That check has no carry-over rule, so it can warn about or delete a file that the merge gate would accept. It also takes the repository from the head repository of the PR (`warn-stale-review-markers.sh:150-163`), while the key uses the base repository.

An optional check can also require that the forge shows a posted review at the head.
It is off by default, and it checks only that a review exists (`block-unreviewed-merge.sh:496`).

## Design approval

**Path.**
`<ops root>/.claude/session/reviews/<K>-design.approved`.

**Format.**
The typed path writes the bare SHA.
The menu path writes the structured record described in the menu section below.

**Writer.**
`/approve-design` writes it after it checks that the Rex file matches the head and that the PR touches UI files (`.claude/skills/approve-design/SKILL.md:95-165`).

**Reader.**
`require-design-review-for-ui.sh` reads it only when the PR changes a UI path (`:321`, `:403`).

**Scope.**
One PR.

**Stale when.**
The head differs from the SHA.
This gate has no carry-over.
A clean base merge makes the file stale (`require-design-review-for-ui.sh:431`).

**Revocation.**
There is none. The same points as for the Rex file apply.
Neither a changed head nor a later review deletes the file.

## Architecture approval

**Path.**
`<ops root>/.claude/session/reviews/<K>-architecture.approved`.

**Writer.**
Tariq writes it on an `APPROVED` verdict (`.claude/agents/solution-architect.md:186-190`).
`/approve-architecture` writes the same record for the operator after it checks the Rex file (`.claude/skills/approve-architecture/SKILL.md:93-150`).
The approval menu can also write it.

**Reader.**
`require-architecture-review.sh` reads it only when the PR carries a design artifact (`:292`, `:364`).

**Scope.**
One PR.

**Stale when.**
The head differs from the SHA.
This gate has no carry-over (`require-architecture-review.sh:392`).

**Revocation.**
There is none.
A non-approved review writes no file and deletes none.

## Human approval

**Path.**
`<ops root>/.claude/session/reviews/<K>-ceo.approved` (`block-unreviewed-merge.sh:309`).

**Format.**
Key and value lines.
The typed form has `sha`, `approved_by=user`, `approved_at`, `skill_version=2` and `approval_summary` (`.claude/skills/approve-merge/SKILL.md:148-180`).
The gate rejects a file without `sha`, without `approved_by=user`, or with a `skill_version` below 2 (`block-unreviewed-merge.sh:686-757`).
The menu form is described in the next section.

**Writer.**
`/approve-merge` writes it after an explicit approval of this PR.
The approval menu can also write it.
A plan-level "go" is not an approval.

**Reader.**
`block-unreviewed-merge.sh` (`:686-824`).

**Scope.**
One PR.

**Stale when.**
The head differs from `sha`.
Carry-over applies, with the same proof as for Rex (`block-unreviewed-merge.sh:794-824`).
The decision to allow carry-over for the human record is recorded in AgDR-0178.

**Revocation.**
There is none.
A failed merge leaves the file in place for a retry (`.claude/skills/approve-merge/SKILL.md:229`).
No session end and no later review removes it.
The only automatic removal is the optional `delete` mode of `warn-stale-review-markers.sh`, which uses simple equality.

## Menu approval

**Path.**
The same path as the design, architecture or human record.
The menu adds no new file.

**Format.**
`sha`, `approved_by=user`, `skill_version=3`, `approval_channel=menu`, `approved_at` and `approval_summary` (`.claude/hooks/_lib-menu-approval.sh:130-150`).
The gates accept this form through `menu_approval_record_sha` (`_lib-menu-approval.sh:41-60`).

**Writer.**
`record-menu-approval.sh` runs after an `AskUserQuestion` call.
It writes only when the question has the exact shape `Approve and merge <owner>/<repo>#<pr> at <40 hex>?`, `Approve design review for ...` or `Approve architecture review for ...`, and the selected answer equals the approve label.
A timeout or any other answer writes nothing (`record-menu-approval.sh:31-65`, `_lib-menu-approval.sh:64-100`).
`block-forged-menu-approval.sh` blocks a model write of `approval_channel=menu` by a text match.

**Reader.**
The same gate as the typed record.
The merge gate rejects a menu form written inside the merge command itself (`block-unreviewed-merge.sh:614-632`).

**Scope, stale and revocation.**
The same as the typed record for the same role.
The human record carries over. The design and architecture records do not.

**Limits.**
The recorder checks the question shape and the answer.
It does not read the current head from the forge, and it does not check that a Rex approval exists.
The typed design and architecture skills do check the Rex file.
The record has the same trust level as a typed record (AgDR-0234).
A crafted input to the recorder can also write a record.
The text match in `block-forged-menu-approval.sh` is a guard for honest mistakes (AgDR-0104).

## Pending review

**Path.**
`<creation root>/.claude/session/pending-reviews/<pr>`.
The creation root is the git top level of the folder where `gh pr create` ran.
It is not the ops root.
The name is the bare PR number, with no repository in it.
The file holds the PR URL.

**Writer.**
`auto-code-review.sh` after a successful `gh pr create` (`:78-92`).

**Readers.**
No hook or skill reads it.
The header comment of `auto-code-review.sh` (`:11-13`) says the merge gate reads it.
That is not true today.
The merge gate decides on the Rex approval file only.

**Scope and expiry.**
It has no scope and no expiry.
Nothing removes it.
Treat it as a reminder that a review is due, not as a gate record.

## Records that do not exist

- **Security review.** No file records it. The security reviewer posts its review, and the posted review is its whole output (`.claude/agents/security-reviewer.md:44-49`). The merge gates do not check a security record (`dispatch-bash.sh:440-443`).
- **QA.** No file records it, and no gate checks it. QA sign-off is a procedure (`.claude/rules/workflow-gates.md`, gate 6).
- **Plan accepted.** No file records it. It is a rule of conduct (`.claude/rules/plan-mode.md`).

## Where the records disagree

Read these before you rely on a record.

1. **Worktree scope differs by record.** A ticket belongs to one working tree. A review or approval record sits in the ops root and is shared by all worktrees of the fork. A session record belongs to one session.
2. **A later non-approved review does not revoke an earlier approval.** See the Rex section.
3. **Carry-over is not uniform.** The merge gate carries over the Rex and human records. The design and architecture gates do not. The approval skills for design and architecture also need the Rex file to equal the head exactly.
   The merge gate would accept a carry-over there.
4. **The push-time warning uses a different test.** It does not know carry-over.
   When `on_stale` is `delete`, it can delete a file that the merge gate would accept.
5. **Two reviews of one role on one PR write the same approval file.** The file has no session and no commit in its name. The last write wins.
6. **The posted-review check is weak.** When it is on, any review at the head satisfies it. It does not check who posted it or the verdict.
7. **A local approval does not clear a change request on the forge.** The forge can still block the merge.
8. **The merge is not atomic with the check.** The dispatcher reads the head again after the gates for eligible commands (`dispatch-bash.sh:400-415`). The head can still change between that read and the merge.

For how each gate fails when it crashes, see [Fail-closed gates and the escape hatch](hooks-fail-closed.md).
For the gate numbers and the gate table, see `.claude/rules/workflow-gates.md`.
