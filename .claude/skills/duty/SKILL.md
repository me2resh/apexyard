---
name: duty
description: Long-running on-call or support shift mode with a liveness-gated tick and an operator-approved learning loop.
disable-model-invocation: false
argument-hint: "[start | tick | retro | week | handover | stop | approve <id> | reject <id> | revert <id> | park <item> | unpark <item>]"
effort: high
---

## Writing rule

When this skill writes a durable artifact, read .claude/rules/writing-standard.md. Use the controlled technical writing profile.

# /duty - Shift Mode

`/duty` runs an on-call or support shift. After `start`, it owns a watcher pass and a review pass
and runs them on a timer until the operator says `stop`. The loop acts on what it finds. It halts at
every human approval gate and never approves its own work.

The behaviour lives in two files beside this one:

| File | Role |
|---|---|
| `playbook.md` | The rules. Read it end to end before the first tick of a session. Reread the relevant section before each act. |
| `duty.sh` | The deterministic parts: tick order, liveness, the ownership partition, escalation states, and the proposal rail. |

If `duty.playbook` is set in config, read that file instead of the bundled playbook.

**Provenance.** This skill generalises an on-call mode that was running its first shift when this
skill was written. An observed failure prompted each rule. A completed shift has not validated the
design yet, and the learning loop has not completed a cycle.

## Configuration

All identifiers come from `.claude/project-config.json` under `duty`. Nothing is hardcoded.

| Key | Meaning | Default |
|---|---|---|
| `duty.repo` | `owner/repo` that the watcher and review passes read through `_lib-tracker.sh` | none, preflight asks |
| `duty.assignee_id` | your tracker account id or login, never a display name | none, preflight asks |
| `duty.ready_state` | the tracker state or transition id that means ready for testing | none, preflight asks |
| `duty.state_dir` | state directory, which must be outside every git repository | `~/.apexyard-duty/<repo slug>` |
| `duty.playbook` | path to an adopter copy of the playbook | the bundled `playbook.md` |
| `duty.watcher_interval_minutes` | watcher cadence | `15` |
| `duty.review_interval_minutes` | review cadence | `30` |
| `duty.watcher_stale_minutes` | watcher stamp age that means the loop stopped | `45` |
| `duty.review_stale_minutes` | review stamp age that means the loop stopped | `90` |

Load config and the helper at the top of each bash block:

```bash
root=$(git rev-parse --show-toplevel)
source "$root/.claude/hooks/_lib-read-config.sh"
source "$root/.claude/hooks/_lib-tracker.sh"
duty="$root/.claude/skills/duty/duty.sh"
export DUTY_CONFIG_JSON="$(config_get '.duty // {} | tojson')"
repo=$(config_get '.duty.repo // empty')
state_dir=$(config_get '.duty.state_dir // empty')
[ -n "$state_dir" ] || state_dir="$HOME/.apexyard-duty/${repo//\//__}"
state="$state_dir/state.json"
```

The shell may be zsh. Quote every expansion and use arrays. Never write `set -- $var`.

## Arguments

| Argument | Do |
|---|---|
| none, `start` | Preflight, the start sequence, then the loop |
| `tick` | One tick. No preflight. This is what the timer calls. |
| `retro` | The daily retro. Writes `retro/<date>.md` and proposals. |
| `week` | The weekly report. Every proposal, for per-item decisions. |
| `handover` | The handover block. Changes nothing. |
| `stop` | Leave the loop, write the handover, archive the state file |
| `approve <id>` | Operator only. Apply a class B proposal with `duty.sh apply ... --operator-approved`. |
| `reject <id>` | Operator only. Mark a proposal rejected with the operator's reason. |
| `revert <id>` | Operator only. Undo an applied class A proposal and mark it reverted. |
| `park <item>` / `unpark <item>` | Operator only. `duty.sh item <state> <item> park operator "<reason>"`. |

**Operator-only means the operator typed that command in the current message.** Never run these on
your own initiative, including inside a tick. Never approve a proposal you wrote. Drafting a change
and deciding to adopt it are two separate acts.

## Preflight

Ask everything in **one** `AskUserQuestion` call, never one question at a time. Put the default
first in each question, so that each answer is a confirmation, not a retype.

Before you ask, check the state directory and any existing state:

```bash
"$duty" state-dir-check "$state_dir" || { echo "state dir is inside a repository, choose another"; }
[ -f "$state" ] && jq '{scope: .shift.scope_timestamp, items: (.items | length)}' "$state"
```

The questions:

1. **New shift or resume?** Offer resume first only when the state file exists and its scope
   timestamp belongs to the current shift. Name the stored timestamp and item count in the option.
   Resume reads the stored timestamp and never writes a new one.
2. **Targets.** One question for `duty.repo`, `duty.assignee_id`, and `duty.ready_state`. First
   option: "All as configured", with the values in the description.
3. **Awake or asleep?** This selects the unattended rules in playbook section 8.

Confirm the answers in one block, then start. Ask nothing more until a tick needs a decision.

## Start sequence

1. Read the playbook end to end.
2. For a new shift, run `"$duty" init "$state"`. For a resume, keep the stored scope timestamp.
3. Enumerate **every** open item assigned to `duty.assignee_id`, then every open item authored by
   it, filtered on the server, and union the two sets by id. Run this read once per filter:

   ```bash
   filter="assignee=$(config_get '.duty.assignee_id')"
   cap=""
   [ "$(tracker_kind "$repo")" = "glab" ] && cap=100
   limit=100
   while :; do
     items=$(tracker_list "$repo" state=open "$filter" limit="$limit")
     rc=$?
     n=$(printf '%s' "$items" | jq 'length')
     status=$("$duty" fetch-status "$rc" "$n" "$limit" "$cap")
     [ "$status" = "TRUNCATED" ] || break
     [ -n "$cap" ] && [ "$limit" -ge "$cap" ] && break
     limit=$((limit * 2))
   done
   echo "$status $n"
   ```

   The GitLab adapter sends `limit` as `--per-page`, and GitLab caps a page at 100 items. So a
   `glab` read that returns 100 items stays `TRUNCATED`. Report it as "at least 100", never as a
   complete count. On `UNKNOWN`, retry once, then report `UNKNOWN`. Never report zero.
4. Run one tick.
5. Report a baseline: each owned item against the done checks, the backlog count, and every open
   and parked escalation.
6. Start the timer at `duty.watcher_interval_minutes` (default 15):

   ```
   /loop <watcher_interval_minutes>m /duty tick
   ```

   The timer belongs to this session. If the session ends, the loop stops silently. The liveness
   gate is how you find out. For an overnight stretch, prefer `/schedule`, which survives the
   session.

## Tick

Follow playbook section 3. `duty.sh plan` prints the steps for this tick:

```bash
tick="$state_dir/ticks/$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$(dirname "$tick")"
"$duty" liveness "$state"
"$duty" plan "$state" > "$tick.plan"
```

Record each step in a tick log as you finish it, then check the log against the plan:

```bash
printf '%s\n' liveness >> "$tick.log"
# ... watcher pass ...
printf '%s\n' watcher >> "$tick.log"
"$duty" stamp "$state" watcher && printf '%s\n' stamp_watcher >> "$tick.log"
# ... review pass only when the plan lists review ...
"$duty" verify-tick "$tick.log" "$tick.plan"
```

If `verify-tick` prints `FAILED`, say so in the report and journal it.

**Watcher pass.** Read new and changed items through `tracker_list` and `tracker_view`. These two
functions return `number`, `title`, `url`, `labels`, `state`, and `updatedAt` only. They do not
return the creation time, comments, or review threads. Read those fields with a read-only call to
the CLI that `tracker_kind` names. Never write through that CLI. When a field cannot be read, set
its `*_known` flag to `false`. For a `custom` or `none` tracker, set every `*_known` flag to
`false`. Build one JSON array with these fields per item, then run the partition:

| Field | Meaning |
|---|---|
| `id` | tracker id, string or number |
| `created` | ISO-8601 creation time |
| `assignee_id` | assignee id or login, empty when unassigned |
| `assignee_known` | `true` only when the assignee was read |
| `last_comment_at`, `last_comment_author_id` | latest comment |
| `comments_known` | `true` only when the comments were read |
| `unresolved_waiting_on_me` | count of unresolved threads whose last note is not yours |
| `unresolved_known` | `true` only when the threads were read |

A missing `*_known` flag counts as not read. A timestamp that does not parse counts as not read
too. The condition that depends on it is `unknown`. On a `glab` read that stayed `TRUNCATED`, the
partition covers only the items read. Say so in the report.

```bash
"$duty" partition "$items_file" "$state" "$(config_get '.duty.assignee_id')"
```

Report each `unknown` condition as `UNKNOWN`. Never treat it as false.

**Review pass.** For each owned item, run the done checks in playbook section 6 and take the one
owner move for each failing check. After each push, rebase, or thread reply, record it:

```bash
"$duty" record-action "$state" "<item id>" push
```

**Escalations.** Escalate with `duty.sh item <state> <id> escalate loop "<reason>"`. Each report
lists `duty.sh nag` output, which holds open items only. Parked items appear in the handover and the
weekly report, never in a tick report. When the operator is away, also send a push notification
for a new escalation.

**Journal.** Append to `$state_dir/journal/<date>.md` when the tick did something or something went
wrong. Record boring successes briefly too. A retro that sees only failures proposes rules against
things that already work.

## Retro and weekly report

Follow playbook section 10. The retro reads the day's journal and action ledger and writes
proposals to `$state_dir/proposals.json`. Each proposal has `id`, `date`, `class`, `evidence`,
`section`, `old`, `new`, and `status`.

For each proposal:

```bash
"$duty" classify "$proposal_file" "$playbook"
```

- `A` with no reasons: apply it with `"$duty" apply "$proposal_file" "$playbook"` and mark it
  `applied`. `apply` prints `REVERT <path>`. Record that path. The revert proposal is class B, so
  `revert <id>` applies it with `--operator-approved`.
- `B`: mark it `proposed`, change nothing, and list the reasons. A reason that starts with `RAIL`
  goes in the rail group of the weekly report and names the protection it would weaken.

Never pass `--operator-approved` unless the operator typed `approve <id>` in the current message.

The weekly report has four groups: applied class A changes with revert paths, class B proposals
that wait for a decision, rail proposals, and recurring friction with no proposal yet. Each item is
decided on its own.

## Handover and stop

The handover block lists owned items against the done checks, items waiting on someone outside the
team, held work with the command or decision that releases it, and every open and parked
escalation from `duty.sh handover-items`.

On `stop`, write the handover, then run `"$duty" stop "$state"`. It archives the state file under
`archive/` and removes it, so the next shift starts with `init`. A session that ends without
`stop` keeps the state file, so the next session resumes the same shift.

---

*Part of [ApexYard](https://github.com/me2resh/apexyard) — multi-project SDLC framework for Claude Code · MIT.*
