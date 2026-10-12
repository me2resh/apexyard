# Fail-closed gates and the escape hatch

This page describes how the Bash dispatcher and the ticket-first gate fail,
what Claude Code version you need, and how an operator turns hooks off.
It covers me2resh/apexyard#1623.

## Terms

- A gate is a hook that decides whether a tool call may run.
- Fail closed means a gate that crashes or times out blocks the tool call.
- Fail open means a hook that crashes or times out lets the tool call run.
- `onFailure` is a Claude Code hook field. The value `block` makes a failed
  or timed-out hook block the tool call.
- The dispatcher is `.claude/hooks/dispatch-bash.sh`. It runs the Bash hooks.
- Ticket-first is `.claude/hooks/require-active-ticket.sh`.
  It blocks a code edit when no ticket is active.

## What fails closed

| Gate | Where it runs | On a crash or timeout |
|------|---------------|-----------------------|
| `dispatch-bash.sh` | Bash matcher in `.claude/settings.json` | Claude Code blocks the call (`onFailure` is `block`) |
| `require-active-ticket.sh` | Edit, Write, MultiEdit matcher in `.claude/settings.json` | Claude Code blocks the call (`onFailure` is `block`) |
| `require-active-ticket.sh` | Inside the dispatcher, for each Bash call | The dispatcher prints `BLOCKED` and exits 2 |
| The four merge gates | Inside the dispatcher, for merge commands | The dispatcher prints `BLOCKED` and exits 2 |
| `block-forged-menu-approval.sh` | Edit, Write, MultiEdit matcher in `.claude/settings.json` | Claude Code blocks the call (`onFailure` is `block`) |
| `block-forged-menu-approval.sh` | Inside the dispatcher, for each Bash call | The dispatcher prints `BLOCKED` and exits 2 |

The dispatcher has one path for fail-closed gates, `run_fail_closed_hook`.
The merge gates (`run_merge_gate_hook`), ticket-first, and the menu-record guard use it.
Any exit code other than 0 or 2 blocks. That includes exit 1, exit 127, and a
kill signal.
A Bash syntax error in a gate already exits 2, so it blocks too.

The dispatcher sets no timer of its own.
A gate that hangs is ended by the `timeout` on the dispatcher entry.
`onFailure` set to `block` then blocks the call.
Timeout values come from a recorded profile.
See `docs/perf/hook-fail-closed-profile-2026-10.md`.

| Entry | Timeout | Basis |
|-------|---------|-------|
| `dispatch-bash.sh` | 20 seconds | 5 x the slowest route p95 (2748 ms) is 13.7 seconds |
| `require-active-ticket.sh` | 10 seconds | 5 x p95 (207 ms) is under the 10 second floor |

### The fail-open exception

`block-reviewer-ci-wait.sh` stays fail open.
It is a cost guard (me2resh/apexyard#1625). It stops a review agent from
polling CI. If it crashes, the reviewer pays for a CI poll. No safety
property is lost.
A crash in it must not block a whole review run.
So the dispatcher runs it with `run_cost_guard_hook`.
A crash prints `WARN` and the dispatcher continues.
The hook's own exit 2 still blocks.
`test_dispatch_bash.sh` tests both behaviors.

Do not move this hook to `run_fail_closed_hook`.

### What is not changed

- No other hook entry sets `onFailure`.
- The `exit 0` in the settings wrapper stays.
  It runs when no `.claude/hooks` directory exists.
  That is deliberate for directories that are not ApexYard forks.
  `onFailure` does not change a hook that exits 0.

## Minimum Claude Code version for `onFailure`

`onFailure` needs Claude Code 2.1.295 or later.

Test of 2026-10-11, with two npm-installed versions and a probe project.
The probe hook was a PreToolUse Bash hook with `onFailure` set to `block`.
It either ran `sleep 4` with `timeout` 1, or exited 1.

| Claude Code | Hook timeout | Hook exit 1 |
|-------------|--------------|-------------|
| 2.1.295 | Tool call blocked. Log: `command hook timed out; blocking (onFailure: "block")` | Tool call blocked. Log: `command hook failed; blocking (onFailure: "block")` |
| 2.1.294 | Tool call ran. Log: `timed out after 1000ms`, no block | Tool call ran |

An older client does not reject the field and prints no warning.
It ignores `onFailure`.
The hook then fails open, as it did before this change.
The `timeout` field is older, so an older client still ends a slow hook.
The tool call then runs.
A fork that uses Claude Code older than 2.1.295 gets no fail-closed
protection from the settings file.
The dispatcher still blocks a crashed ticket-first or merge gate on any version,
because that code is in the shell script.

## Review agent detection needs `agent_type`

The reviewer lock finds a review agent by the `agent_type` field in the hook
input (me2resh/apexyard#1649, AgDR-0145 amendment).
Claude Code sets this field on every tool call that a sub-agent makes.
A call from the main thread has no `agent_type` and no `agent_id`.

You need a Claude Code build that sends `agent_type` in hook input.
We verified this on Claude Code 2.1.296 (`claude --version`).
We did not test older builds, so we state no earliest version.

On a build that sends neither field, a review agent looks like the main thread.
The lock then does not block it.
The merge gates do not depend on this field and stay in force.
A hook cannot read the Claude Code version cheaply: the hook input has no
version field, and `CLAUDE_CODE_EXECPATH` can name the parent process.
So the framework gives no version warning at session start.

The `/code-review`, `/security-review` and `/design-review` skills spawn the
reviewer with its own agent type: `code-reviewer`, `security-reviewer` or
`solution-architect`. Do not spawn a review with `general-purpose`.

### Add your own review agent types

Set `review_markers.extra_review_agents` in `.claude/project-config.json` to an array of exact type names.
Do not use patterns.
The config can only add types.
You cannot remove built-in types.
A malformed or missing value leaves the built-in list unchanged.
The helper skips entries with disallowed characters.
The first character must be a letter or digit.
Other characters can be letters, digits, `.`, `_`, `:`, or `-`.
The fallback knows only built-in types when the library is missing.

```json
{
  "review_markers": {
    "extra_review_agents": ["acme-reviewer", "plugin:code-reviewer"]
  }
}
```

**Warning:** A name shared with a build agent locks that build agent during an active review.

## Operator escape hatch

If a gate blocks all work, for example after a bad hook edit, start Claude
Code with hooks off:

```bash
claude --settings '{"disableAllHooks": true}'
```

`disableAllHooks` turns off all hooks for the session.
Claude Code documents that the same setting also turns off a custom status
line and a custom `@` file suggestion command.
The flag applies to that launch only. Nothing is written to a settings file.

Rules for the escape hatch:

- Use it to repair the hooks, then restart without it.
- With hooks off, no ApexYard gate runs.
  That includes the merge gates and ticket-first.
  Do not merge or push in that session.
- There is no environment variable for it. A new variable would be a new way
  for an agent to turn off the gates. The launch flag needs the operator
  to start the session.
- Do not set `disableAllHooks` in a tracked settings file.

`bin/check-escape-hatch.sh` tests the hatch against the real CLI.
It starts Claude Code twice in the repository with a fake API key.
The first run must log a hook run, which proves hooks are on by default.
The second run uses the override and must log no hook run.
The `claude plugin validate` workflow runs it with the pinned version.

## Plugin marketplace validation

The workflow `.github/workflows/claude-plugin-validate.yml` installs a pinned
Claude Code version and runs:

```bash
claude plugin validate --strict .claude-plugin/marketplace.json
```

`--strict` treats a warning as an error.
A marketplace without a `description` fails this check.
The workflow also validates each plugin that the marketplace lists with a local path.
A plugin from a GitHub source is validated in its own repository.
To change the pinned version, edit `CLAUDE_CODE_VERSION` in the workflow.
