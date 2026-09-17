# Collapse SessionStart hook fan-out

## Status

Accepted

## Context

The framework registered 18 SessionStart commands.

- Each command repeated the session-pin and ops-root discovery wrapper.
- The repeated wrapper added process and shell-start cost to every session.
- A harness that launched the group together was more likely to exhaust file descriptors.

## Decision

Register one SessionStart command that resolves the ops root once.

- The command invokes `.claude/hooks/dispatch-session-start.sh`.
- The dispatcher passes the original SessionStart payload to the existing hooks.
- The dispatcher runs the pin hook first.
- The dispatcher runs the remaining advisory and housekeeping hooks concurrently.
- The dispatcher reports stdout and stderr on their original streams.
- Hook scripts remain the policy source.
- The dispatcher continues after a nonzero result.
- One unavailable check cannot suppress cleanup, routing, or reindexing.

## Consequences

The dispatcher is now the SessionStart wiring source. Adding, removing, or
reordering a SessionStart hook requires updating its ordered list and the
dispatcher regression test. Hook decisions remain in the existing scripts.

The following hooks are advisory and stay silent when their condition is not present:

- onboarding
- upstream drift
- jq availability
- git-hook installation
- portfolio configuration
- MCP tooling
- search configuration
- split-portfolio primer
- unqualified review-marker detection

The following hooks are housekeeping hooks:

- marker cleanup
- custom-skill linking
- agent-routing application
- search reindexing

They produce no output unless their own work requires it.

The settings fan-out falls from 18 commands to one. The PR records
SessionStart timing against the issue baseline and verifies that Claude Code,
Cursor IDE, pi, Codex, and opencode retain their existing startup wiring. On
the development checkout, five direct dispatcher runs completed in 2.46,
2.51, 2.43, 2.46, and 2.45 seconds. This is below the issue's 2.87 second
sequential baseline while retaining the existing hook set.

## Options considered

| Option | Result |
| --- | --- |
| One dispatcher over the existing hooks | Accepted. It removes repeated root discovery while preserving hook ownership and order. |
| Remove or merge the individual hooks | Rejected. It would combine unrelated policy and increase regression risk. |
| Keep the 18 wrappers and rely on harness parallelism | Rejected. It leaves repeated process startup and file-descriptor pressure in place. |

## References

- Issue #1318
- AgDR-0157
