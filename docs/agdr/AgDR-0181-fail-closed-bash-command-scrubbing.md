---
id: AgDR-0181
timestamp: 2026-09-29T08:30:00Z
agent: composer (implementation)
model: composer
session: local-worktree-codex-1459
trigger: security-review-of-PR-1466
status: executed
category: security
---

<!-- Uses the controlled technical writing profile in .claude/rules/writing-standard.md. -->

# Narrow Bash command scrubbing to a false-positive filter

> In the context of PR #1466, facing bypasses where scrubbed text drove routing and gate matchers, I decided to keep the scrubbed view only for the write detector and the auto-code-review trigger, restore raw command matching everywhere else, and deny scrubbing when the raw command names an interpreter or unmodelled syntax, to close those bypasses while keeping ordinary quoted false-positive fixes.

## Context

PR #1466 added `_lib-command-scrub.sh`. It blanks quoted text and heredoc bodies. Two security reviews found that the same scrubbed string then drove dispatcher routing and several PreToolUse matchers. A merge, issue create, or PR create hidden in quotes or in a nested shell never reached the real gate.

The scanner also treated real code as data for here-strings, arithmetic shifts, a `#` after `)`, a `case` pattern inside `"$(...)"`, and `$(...)` inside an unquoted heredoc. Its fallback only caught plain `eval` and `bash|sh|zsh -c`.

AgDR-0113 already forbids feeding a subtractive pre-filter into a presence question for git push and commit gates. AgDR-0171 kept quote masking diagnostic-only for the same reason. PR #1466 widened scrubbing past that boundary.

## Options considered

| Option | Result |
|---|---|
| Keep scrubbed routing and matchers | Leaves the reviewed bypasses open. |
| Delete the scrubber and restore raw matching everywhere | Closes bypasses. Restores ordinary quoted false blocks such as `git log --format='%h > %s'`. |
| Narrow scrubbing to two consumers and deny nested execution on the raw command | Closes the bypasses. Keeps the false-positive filter where it is safe. |

## Decision

Choose the narrow option.

### Scope

Only these two consumers may read the scrubbed view:

1. `_lib-detect-bash-write.sh`, for the redirect presence and target questions used by the ticket gate and the migration gate.
2. `auto-code-review.sh`, for its PostToolUse `gh pr create` trigger.

`dispatch-bash.sh` routes on the raw `COMMAND`. So do `is_merge_command` and the PreToolUse matchers that PR #1466 had switched to scrubbed text: `block-ambient-tracker-repo.sh`, `require-skill-for-issue-create.sh`, `validate-issue-structure.sh`, `validate-pr-create.sh`, `require-agdr-for-arch-pr.sh`, `suggest-ticket-template.sh`, and `nudge-control-adversarial-test.sh`.

Both public scrubber functions return the raw command unchanged when the raw command, after quotes, backslashes, and a leading path are removed, contains any of:

- a shell or interpreter command word from the deny list in `_lib-command-scrub.sh`
- `find` with `-exec` or `-execdir`
- `<<<`, `((`, `$(`, a backtick, `<(`, or `>(`
- a pipe into any of those command words

When unsure, return raw.

The ticket gate keeps the #1416 rule. An unextractable write still blocks even when another target is extractable or exempt.

### Residue

These shapes still false-block, because matchers read raw text again:

- tracker or PR-create words inside quotes or heredoc bodies, for every matcher except `auto-code-review.sh`
- interpreter programs such as `awk '$1 > 0'`, because `awk` is on the deny list and the write detector then sees raw text

When the deny gate returns raw for `python3` / `node` / `ruby` heredoc writes beside a sed `w` decoy, target extraction matches upstream/`dev`: the visible heredoc body fires `_bdw_detects_other_write`, so the decoy target is held back and the list is empty. The ticket gate still blocks via the unextractable-write rule. That is not the scrub-era `/tmp/x` result from 39c5b95, where blanking the heredoc body hid the other write from the hold-back check.

The scanner still does not model full shell grammar. Nested execution through deny-listed words is handled by returning raw, not by proving the nested effects. See AgDR-0113 for the additive-versus-subtractive rule this narrowing restores for routing and command matchers.

## Consequences

Ordinary quoted false positives that do not trip the deny gate still scrub for the write detector. Examples include `git log --format='%h > %s'`, `grep -nE 'a|>|b' file`, `echo '  >> TEXT'`, and a quoted heredoc that only mentions `>` while writing a scratch file.

Must-block tests pin the reviewed bypass shapes against the ticket gate and dispatcher routing. Fail-before proofs run the same cases against the 39c5b95 hook tree.

This record replaces the earlier AgDR-0181 claim that every command matcher should read the shared scrubbed view.

## Artifacts

- Issues: #1459, #1416, #1356
- Library: `.claude/hooks/_lib-command-scrub.sh`
- Write detector: `.claude/hooks/_lib-detect-bash-write.sh`
- Tests: `.claude/hooks/tests/test_command_scrub_regressions.sh`, `.claude/hooks/tests/test_command_scrub_must_block.sh`
- Related: [AgDR-0113](AgDR-0113-heredoc-stripper-additive-only.md), [AgDR-0171](AgDR-0171-quote-masking-is-diagnostic-only.md)
