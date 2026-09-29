---
id: AgDR-0192
timestamp: 2026-09-29T16:23:38Z
agent: codex
model: gpt-6
session: issue-1459
trigger: user-prompt
status: executed
category: security
---

# Allow allowlisted command scrubbing in the tracker gate

> In the context of issue #1459, facing false tracker blocks from quoted data, I chose allowlisted scrubbing for the tracker gate. The scanner keeps raw fallback for unclassified commands.

## Context

The tracker gate reads raw Bash command text. It treats tracker words in quoted arguments and heredoc bodies as commands.

AgDR-0181 limits command scrubbing to a data-only allowlist. It keeps dispatcher routing and merge gates on raw text.

The syntax view also blanks a quoted command word. The tracker gate must still see an executable quoted `gh` word.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| Keep raw matching | Keeps the existing security boundary. | Blocks tracker words in data. |
| Scrub every command | Removes the false blocks. | Hides commands run by shells and other programs. |
| Scrub only allowlisted commands and keep quoted tracker words raw | Removes the reported false blocks. Keeps executable tracker words visible. | Unsupported syntax still uses raw text. |

## Decision

Chosen: **Scrub only allowlisted commands and keep quoted tracker words raw**, because the shared scanner already enforces this boundary.

The tracker gate scans the scrubber's syntax view for both tracker presence and repository flags. The scanner returns raw for unallowlisted commands and syntax it cannot classify.

The allowlist returns raw when a tracker command word or subcommand contains shell quotes or escapes. The tracker gate recognizes those word forms in that raw fallback.

This decision extends AgDR-0181 Scope to the tracker gate. Dispatcher routing, merge gates, and other PreToolUse matchers continue to read raw commands.

## Consequences

- Quoted tracker text and heredoc bodies stop triggering the tracker gate when every command word is data-only.
- Real unqualified tracker commands still block, including nested shell execution and quoted tracker words.
- Unallowlisted commands, malformed syntax, and executable substitutions can still false-block because the scanner returns raw.
- AgDR-0181 Residue no longer applies to the tracker gate for allowlisted quoted arguments and heredoc bodies.

## Artifacts

- Issue: #1459
- Related decision: [AgDR-0181](AgDR-0181-fail-closed-bash-command-scrubbing.md)
- Hook: `.claude/hooks/block-ambient-tracker-repo.sh`
- Scanner: `.claude/hooks/_lib-command-scrub.sh`
- Tests: `.claude/hooks/tests/test_block_ambient_tracker_repo.sh`, `.claude/hooks/tests/test_command_scrub_regressions.sh`
