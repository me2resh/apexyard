# AgDR-0282: Declare tickets through a vetted helper

## Context

Issue #1928 reports that Claude Code denies pending-file writes under `.claude/` during headless runs.
The Bash state-writer rule also rejects harness-only writers.

## Options Considered

| Option | Benefit | Cost |
|--------|---------|------|
| Retain Write calls | No new exception | Headless runs cannot declare tickets |
| Allow general shell state writes | Simple caller | Weakens the state boundary |
| Allow one exact helper command | Validates tracker data and paths | Adds a narrow command grammar |

## Decision

Use `bin/apexyard-start-ticket owner/repo#number` as the sole agent-callable state writer.
The protected-target hook checks the complete raw command before granting this exception.
The dispatcher still runs all other gates.
The helper accepts no caller-supplied title, URL, branch, or output path.
It fetches issue fields through the tracker library and uses the shared ticket writer.
It refuses symlinked session paths, existing pending files, closed issues, and foreign-session takeovers.

## Consequences

Headless runs require no Write call under `.claude/`.
Interactive sessions retain the Write fallback.
Wrappers, alternate paths, substitutions, pipes, redirections, and additional arguments receive no exception.
Filesystem checks remain cooperative checks, not protection against concurrent malicious filesystem replacement.
Tracker failures stop declaration.
The helper requires a validated current working tree and does not redirect to another clone.

## Artifacts

- Issue: me2resh/apexyard#1928
- Helper: `bin/apexyard-start-ticket`
- Matcher: `.claude/hooks/_lib-start-ticket-command.sh`
