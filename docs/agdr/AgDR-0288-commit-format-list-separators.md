---
id: AgDR-0288
timestamp: 2026-11-06T12:00:00Z
agent: platform-engineer
model: claude-opus-5-5
session: fix-1958-rework
trigger: user-prompt
status: executed
category: security
---

<!-- When this template creates an artifact, use the controlled technical writing profile in .claude/rules/writing-standard.md. -->

# AgDR-0288: Accept list separators around one readable commit

> In the context of the commit-format hook, facing false blocks on ordinary command chains, I decided to accept `;`, `&&` and `||` around one commit whose message the hook can read as git reads it, to achieve fewer false blocks with the same message check, accepting that a relative `-F` path in a list still blocks.

## Context

AgDR-0271 item 2 says that a pipe, a chain, a background job or a second line still blocks.
Case C5 in #1958 shows false blocks for ordinary chains.
A list joins commands with `;`, `&&` or `||`.
A relative message path can resolve differently after `cd` or `git -C`.
An earlier command can rewrite a message file before git reads it.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| A: Keep all chains blocked | No change to a trust-chain hook | Ordinary chains such as commit-then-log stay blocked |
| B: Accept list separators around one commit with a literal `-m` message, or an absolute `-F` path when the commit runs first | Removes the false blocks; the hook reads the same message as git | A relative `-F` path in a list still blocks |
| C: Accept any readable `-F` path | Fewest blocks | After `cd`, `-C` or an earlier `cp`, the hook can check a different file from the one git commits |

## Decision

Choose B because it removes the false positive and keeps the hook reading the same message that git commits.
The hook requires aligned raw and decoded token arrays in list mode.
The hook blocks file messages when a list separator precedes the commit's `git` word.
Non-list behavior stays unchanged.

## Consequences

- A relative `-F` path in a list still blocks.
- A pipe, a background job, a redirection, `-F -` and two commits still block.
- A same-user file swap by another process is out of scope, per AgDR-0267.

## Artifacts

- PR: #1979
- Ticket: #1958
