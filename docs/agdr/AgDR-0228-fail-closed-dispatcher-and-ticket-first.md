---
id: AgDR-0228
timestamp: 2026-10-11T10:40:00Z
agent: platform-engineer
model: claude-opus-5-5
session: 01KGvb2ba4gyT3TN8L2uMLTn
trigger: user-prompt
status: executed
category: security
---

# Fail-closed dispatcher and ticket-first gates with measured timeouts

> In the context of the Bash dispatcher and the ticket-first gate (#1623), facing a crashed or hung gate that lets the tool call through, I decided to set `onFailure` to `block` and a measured `timeout` on the two settings entries and to route ticket-first through the dispatcher's fail-closed path, to achieve a gate that cannot fail open, accepting that a slow tracker on a merge can block the call until the operator retries.

## Context

`.claude/settings.json` set no `onFailure` on any hook.
Claude Code treats a hook that crashes or times out as a non-blocking error.
So a hung or crashed gate let the tool call through.

Inside `dispatch-bash.sh`, `run_hook` turned every exit other than 2 into a `WARN`.
A crashed ticket-first gate failed open there.
The four merge gates already failed closed through `run_merge_gate_hook` (AgDR-0169).
Later work adds more gates, so the failure mode must be fixed first.

`claude --debug-file` records the duration of each hook run.
The profile is in `docs/perf/hook-fail-closed-profile-2026-10.md`.
Claude Code 2.1.295 added `onFailure`.
A test on 2026-10-11 shows 2.1.294 ignores the field with no warning.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| Set `onFailure` only on the settings entries | One change | The dispatcher still warns on a ticket-first crash, so the gate fails open inside the dispatcher |
| Fail closed in the dispatcher only | Works on every Claude Code version | A hung gate runs to the default 10 minute timeout and then fails open |
| Both, with timeouts from a profile (chosen) | Covers crash and hang | Needs a profile; needs 2.1.295 for the hang case |
| Set `onFailure` on every hook | Uniform | Blocks on a crash in advisory hooks; out of scope for #1623 |
| Dispatcher timer with `timeout` or a background kill | Catches a sub-gate hang inside the dispatcher | `timeout` is not on stock macOS; extra process code in the trust chain |

## Decision

Chosen: **both layers, with measured timeouts**.

- The `dispatch-bash.sh` entry sets `timeout` 20 and `onFailure` `block`.
  The slowest route p95 is 2748 ms, so 5 x p95 is 13.7 seconds.
- The `require-active-ticket.sh` entry sets `timeout` 10 and `onFailure` `block`.
  5 x p95 (207 ms) is under the 10 second floor.
- `dispatch-bash.sh` runs `require-active-ticket.sh` through
  `run_fail_closed_hook`, the function that the merge gates share.
- `block-reviewer-ci-wait.sh` stays fail open, through `run_cost_guard_hook`.
  It is a cost guard (#1625), and a crash in it loses no safety property.
- The escape hatch is the launch flag `claude --settings '{"disableAllHooks": true}'`.
  No environment variable is added, because a variable is a way for an agent
  to turn off the gates.

## Consequences

- A crashed or timed-out ticket-first or dispatcher hook blocks the tool call on Claude Code 2.1.295 and later.
- On an older client the settings fields have no effect. The dispatcher still blocks a crashed ticket-first or merge gate, because that code is in the shell script.
- A merge that waits more than 20 seconds for the tracker is blocked. The operator retries.
- The dispatcher has no timer for a sub-gate. The entry timeout covers a hang.
- CI pins Claude Code 2.1.296, validates the marketplace with `--strict`, and tests the escape hatch.

## Artifacts

- `docs/hooks-fail-closed.md`
- `docs/perf/hook-fail-closed-profile-2026-10.md`
- Parent records: AgDR-0157, AgDR-0169
