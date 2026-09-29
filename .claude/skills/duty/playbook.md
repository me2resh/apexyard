# Duty playbook

The `/duty` skill reads this file at every tick. It is the working agreement for a shift. Each rule
came from a failure that was observed on a real shift. Evidence lines keep the incident behind a
rule, with identifiers removed.

Copy this file to your private portfolio and set `duty.playbook` in `.claude/project-config.json`
to its path before you edit it. Edits to the shipped copy conflict with `/update`.

A section that carries the `duty:protected` marker is protected. Only a section that carries the
`duty:class-a` marker accepts a change without operator approval. Section 10 has the full rule,
and `duty.sh classify` enforces it.

---

## 1. Hard constraints

<!-- duty:protected -->

These rules are absolute. They are not judgement calls.

- Never merge a pull request or merge request.
- Never approve a pull request or merge request.
- Never resolve a review thread. Resolving is the reviewer's act.
- Never propose or perform a production data change.
- Never add attribution lines or AI-generated markers to commits, descriptions, or comments.
- Never use `--no-verify`, `sudo`, a privileged API, or any other bypass to get past a blocked
  check. If the normal path is blocked, stop and report the missing requirement.
- Never force-push. Rebase locally, verify, and give the operator the exact push command.
- Never write `set -- $var`. In zsh an unquoted expansion does not word-split, so `set --` assigns
  nothing and the code continues with empty values that look like real results. Use arrays.

---

## 2. Cadence and thresholds

<!-- duty:protected -->

| Setting | Default | Config key |
|---|---|---|
| Watcher cadence | 15 minutes | `duty.watcher_interval_minutes` |
| Review cadence | 30 minutes | `duty.review_interval_minutes` |
| Watcher stamp is stale after | 45 minutes | `duty.watcher_stale_minutes` |
| Review stamp is stale after | 90 minutes | `duty.review_stale_minutes` |

A change to any of these numbers reduces or changes supervision. It is always class B.

---

## 3. The tick

<!-- duty:protected -->

Every tick runs these steps in this order. `duty.sh plan` prints the order and `duty.sh
verify-tick` checks a completed tick against it.

0. **Liveness gate.** Run `duty.sh liveness`. If a stamp is stale, the loop stopped. Say so in the
   first line of the report, with the minutes that went unwatched.
1. **Watcher pass.** Always. Never conditional. Never skipped because review work looks urgent.
2. **Stamp the watcher** immediately, before any other work. A stamp written after the review work
   backdates the watcher and hides the gap.
3. **Review pass**, only when its own stamp is due. Then stamp it.
4. **Report.** One line if nothing changed. Say whether a timer drives the ticks.
5. **Journal.** Append what happened, now, not from memory later.

A tick that did the review work and skipped the watcher is a failed tick.

Evidence: on one shift the review work displaced the watcher for over ten hours. A high-priority
item assigned to the operator was unseen for 29 minutes, until the operator asked by hand. Nothing
reported the gap, because the loop was not reporting at all.

A staleness check is real only if it reads the field that the writer writes. An early version read
a field that nothing wrote, so the check never ran and still looked implemented. After you rename a
field, search for the old name before you finish.

**Bound the churn.** Compute the partition once per tick and act on it for the whole tick. Revise
it at the next tick. Evidence: four correct revisions in one hour drove zero items.

---

## 4. Reading the tracker

List and view calls go through `.claude/hooks/_lib-tracker.sh`. That library does not return
creation time, comments, or review threads. Read those fields with a read-only call to the CLI
that `tracker_kind` names, and never write through that CLI. For a `custom` or `none` tracker,
set every `*_known` flag to `false`. Identifiers come from `.claude/project-config.json`, never
from this file.

- **A short read looks exactly like a complete read.** Only a result below the requested limit
  proves the end. Run `duty.sh fetch-status <rc> <count> <limit>`. On `TRUNCATED`, double the limit
  and read again. Evidence: an unfiltered first page showed 19 of 28 items.
- **Filter on the server.** Filter by assignee or author in the query, not after the fetch.
- **A failed fetch is not an empty result.** `tracker_list` prints `[]` and returns non-zero on
  failure. Check the return code. On failure, retry once, then report `UNKNOWN`. Never report zero.
  Evidence: a failed call that fell back to an empty list reported zero unresolved threads on an
  item that had two.
- **Match on id, never on display name.** Evidence: two people shared a display name, and a
  name match would have put another person's work on duty.
- **Do not infer your own work from commit metadata.** A rebase keeps the author date and rewrites
  the committer date. A committer-date test admits every rebase. An author-date test misses real
  work. Record each push, rebase, and reply with `duty.sh record-action`, and read that ledger.
- **Read the merge-conflict field.** An item can be green with no open threads and still be
  unmergeable.

---

## 5. Ownership

<!-- duty:protected -->

The scope timestamp is set once per shift, not once per session. Only `stop` clears it.

An item is on duty when **any** of these conditions is true:

- `new_in_scope`: created at or after the scope timestamp, and unassigned or assigned to you.
- `mine_new_comment`: assigned to you, with a comment from someone else after the scope timestamp.
- `acted_this_shift`: the action ledger records an action on it during this shift.
- `reviewer_waiting`: it has an unresolved thread whose last note is not yours.

Run `duty.sh partition`. It evaluates every condition independently over the full set, then
unions the results. It records every condition that matched. A condition whose input is missing is
recorded as `unknown`, never as false.

Evidence: a first-match evaluation put one item in a bucket, and that item never reached the one
check that would have disproved the bucket. Two runs over the same data disagreed.

Everything else is backlog. Report the backlog once in the baseline as a count and a list. Do not
drive backlog items. Taking on backlog is the operator's decision.

---

## 6. Done

<!-- duty:protected -->

An item is done when all of these are true at the same time:

| Check | Done when |
|---|---|
| Pipeline | green on the **current** head commit |
| Threads | every unresolved thread has your reply as its last note |
| Conflicts | the tracker reports no merge conflict |
| Merge status | the tracker reports the item as mergeable |
| Ticket | in the ready-for-testing state, with testing steps posted |

Done means the next move belongs to the reviewer. It never means you resolved a thread or merged.

Anything short of done is work. Each failing check has one owner move:

- **Red pipeline.** Read the failure log before you name a cause. Fix a code failure. Retry an
  infrastructure failure once. If the same job fails twice on infrastructure, escalate.
- **Thread whose last note is the reviewer's.** Verify the claim, act, and reply.
- **Thread whose last note is yours.** Waiting on the reviewer. Do not reply again.
- **Merge conflict.** Rebase locally, verify, and give the operator the push command.
- **Ticket not in ready-for-testing while its pull request is open.** Move it and post testing
  steps.

---

## 7. Escalation

<!-- duty:protected -->

Bring these to the operator. Do not decide them alone:

- Any merge or approval.
- Any production data change, including whether a backfill runs.
- Any schema migration, including an index.
- A force-push.
- Repeated retries against failing infrastructure.
- A fix whose blast radius is much larger than the ticket.

Everything else: choose the option you would recommend, do it, and report it afterwards.

**Escalation states.** Each escalated item is in exactly one state. `duty.sh item` enforces the
transitions.

| State | Meaning | Reported |
|---|---|---|
| `open` | waiting on the operator | every report, until it changes |
| `parked` | the operator deferred it, no longer waiting | handover and weekly report only |
| `closed` | resolved | not reported |

Only the operator parks or unparks an item. The loop does not repeat reminders for a parked item,
and the handover never drops one.

---

## 8. Unattended work

<!-- duty:protected -->

When the operator is away, keep working. Take new work as far as it goes without an externally
visible act, then stop before you open a pull request. Record it as held.

An item that is already public keeps moving: pushes to an open pull request, thread replies,
infrastructure retries, and local rebases.

**A write path that has never executed does not get its first run unattended if what it writes is
externally visible.** Being permitted in daylight is not the test. The test is whether this shift
has run that path and read what came back. Draft the write, hold it, and show it when the operator
returns.

**Report what came back.** Read the response and quote the resulting state. A write whose result
you did not read is an assumption.

---

## 9. Traps

<!-- duty:class-a -->

Add a trap here when it produced a confident wrong claim or cost more than an hour. Lead with the
rule and keep the incident below it as evidence.

- **zsh and `"$var:c"`.** zsh reads `:c` after a variable as a history modifier and changes the
  path without an error. Write `"${var}:c"`.

---

## 10. The learning loop

<!-- duty:protected -->

Three artifacts, all in the state directory, outside every repository:

| Path | Holds | Written |
|---|---|---|
| `journal/YYYY-MM-DD.md` | what happened, as it happened | every tick that did something |
| `retro/YYYY-MM-DD.md` | the day read back | once per day |
| `proposals.json` | proposed playbook changes, each tied to evidence | by the retro |

The retro answers four questions: what the shift delivered, what went wrong and why, what would
have prevented it, and what this playbook said that was wrong, missing, or ignored.

**Class A** is a factual entry or correction in a section that carries the `duty:class-a` marker.
Only the trap log in section 9 carries it. A class A proposal applies immediately, and `duty.sh
apply` writes a revert proposal beside it. **Class B** is everything else, including a correction
to any other section. It waits for per-item operator approval. An unclear case is class B.

**The rail.** Classify a proposal by its effect, not by its framing. `duty.sh classify` returns
class B when a proposal:

- targets any section without the `duty:class-a` marker
- adds a heading or a section marker
- adds a normative word, such as never, must, only, except, or instead
- removes or rewrites a normative line
- changes any number
- names a gated action, such as merge, approve, resolve, force, push, deploy, or delete, or
  widens unattended action.

`duty.sh apply` refuses a class B proposal without operator approval. The loop may argue for less
supervision. It may never grant less supervision to itself.

**Precedence.** A trap entry records evidence. It never overrides sections 1 to 8 or this
section. When a trap entry conflicts with one of those sections, the earlier section wins, and
the conflict is an escalation. The word checks in `duty.sh classify` catch common phrasings of a
widening change, but they cannot prove intent. This precedence rule is the backstop.

A trap entry with numeric evidence changes a number, so it is class B. That is intended: the
operator sees each entry whose evidence carries a count or a duration.

To revert an applied change, the operator runs `revert <id>`. It applies the revert proposal that
`apply` wrote.

The weekly report presents each proposal for its own decision. It never bundles proposals. Record
each verdict against the proposal id. A proposal rejected twice stays closed unless new evidence
arrives.
