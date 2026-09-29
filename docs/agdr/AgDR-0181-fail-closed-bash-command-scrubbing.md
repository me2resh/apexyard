---
id: AgDR-0181
timestamp: 2026-09-29T08:30:00Z
agent: cursor-agent (implementation), orchestrator: claude-opus-5-5
model: see agent
session: PR #1466
trigger: security-review-of-PR-1466
status: executed
category: security
---

<!-- Uses the controlled technical writing profile in .claude/rules/writing-standard.md. -->

# Narrow Bash command scrubbing to a data-only allowlist

> In the context of PR #1466, facing bypasses where scrubbed text drove routing and gate matchers, and later where a deny list still scrubbed programs that run quoted text as code, I decided to keep the scrubbed view only for the write detector and the auto-code-review trigger, restore raw command matching everywhere else, and scrub only when every command word is on a data-only allowlist, to close those bypasses while keeping ordinary quoted false-positive fixes.

## Context

PR #1466 added `_lib-command-scrub.sh`. It blanks quoted text and heredoc bodies. Two security reviews found that the same scrubbed string then drove dispatcher routing and several PreToolUse matchers. A merge, issue create, or PR create hidden in quotes or in a nested shell never reached the real gate.

A later review found that a deny list of shells and interpreters is incomplete. Programs such as `git -c`, `git rebase --exec`, GNU `sed` `e`, `watch`, `make`, `ed`, `ssh`, `npx`, and many others still scrubbed quoted writes and slipped the ticket gate.

AgDR-0113 already forbids feeding a subtractive pre-filter into a presence question for git push and commit gates. AgDR-0171 kept quote masking diagnostic-only for the same reason. PR #1466 widened scrubbing past that boundary.

## Options considered

| Option | Result |
|---|---|
| Keep scrubbed routing and matchers | Leaves the reviewed bypasses open. |
| Delete the scrubber and restore raw matching everywhere | Closes bypasses. Restores ordinary quoted false blocks such as `git log --format='%h > %s'`. |
| Narrow scrubbing to two consumers and deny nested execution on the raw command | Closes some bypasses. A deny list still misses tools that run quoted text. |
| Narrow scrubbing to two consumers and allow scrubbing only for data-only command words | Closes the bypasses. Keeps the false-positive filter only where every command word is known not to execute its arguments. |

## Decision

Choose the allowlist option.

### Scope

Only these two consumers may read the scrubbed view:

1. `_lib-detect-bash-write.sh`, for the redirect presence and target questions used by the ticket gate and the migration gate.
2. `auto-code-review.sh`, for its PostToolUse `gh pr create` trigger.

`dispatch-bash.sh` routes on the raw `COMMAND`. So do `is_merge_command` and the PreToolUse matchers that PR #1466 had switched to scrubbed text: `block-ambient-tracker-repo.sh`, `require-skill-for-issue-create.sh`, `validate-issue-structure.sh`, `validate-pr-create.sh`, `require-agdr-for-arch-pr.sh`, `suggest-ticket-template.sh`, and `nudge-control-adversarial-test.sh`.

### Allowlist

Scrub only when every command word in the raw command is on the data-only allowlist. Otherwise return the raw command unchanged. When unsure, return raw.

A command word is the first word of each simple command. That includes the start of the string and the word after `;`, `&&`, `||`, `|`, `&`, `(`, `{`, a newline, `then`, `do`, `else`, `elif`, `!`, or `time`. Command words after a heredoc opener on the same line are checked like any others. A leading variable assignment returns raw, because it can name a program that `git` or `gh` runs, such as `GIT_PAGER` or `EDITOR`. Quotes, backslashes, and a leading path are removed before the compare, so `'cat'`, `\cat`, and `/bin/cat` all compare as `cat`.

Heredoc bodies are not command words. A quoted heredoc body is data. An unquoted heredoc body that holds `$(` or a backtick forces raw.

The allowlist starts with tools that do not execute their arguments as code: `echo`, `printf`, `cat`, `grep`, `egrep`, `fgrep`, `rg`, `head`, `tail`, `wc`, `sort`, `uniq`, `cut`, `tr`, `diff`, `cmp`, `ls`, `stat`, `file`, `basename`, `dirname`, `realpath`, `jq`, `yq`, `true`, `false`, `test`, `[`, `cd`, `pwd`, `mkdir`, `touch`, `tee`, `cp`, `mv`, `rm`, `gh`, and `git`. It does not include `sed`, `awk`, `find`, `xargs`, `env`, `make`, `ssh`, any shell, or any interpreter.

`tee`, `cp`, `mv`, `rm`, `mkdir`, and `touch` may write files. That is fine. The allowlist only answers whether quoted text may be treated as data. The write detector still sees their targets.

`git` is allowed only with no `-c` before the subcommand, and only for `log`, `show`, `diff`, `status`, `commit`, `add`, `rev-parse`, `branch`, `ls-files`, and `blame`. `grep`, `fetch`, and `push` are not on the list, because options such as `--open-files-in-pager`, `--upload-pack`, and `--receive-pack` run a program. Any other subcommand, any alias, and any `-c` return raw.

`gh` is allowed for `pr view`, `pr diff`, `pr create`, `pr edit`, `pr comment`, `pr review`, `issue view`, `issue comment`, `issue create`, `issue edit`, and `api`. Any other subcommand or extension returns raw.

`$(`, backticks, `<(`, `>(`, and `<<<` return raw when they appear outside single quotes and outside quoted heredoc bodies. Inside single quotes and quoted heredoc bodies they are data. Inside double quotes and unquoted heredoc bodies they execute, so the scrubber returns raw.

The ticket gate keeps the #1416 rule. An unextractable write still blocks even when another target is extractable or exempt.

### Residue

These shapes still false-block:

- `awk` and `sed` programs that hold `>` or similar text in arguments, because those tools are outside the allowlist and the write detector then sees raw text
- interpreter programs such as `python3 -c` when the scrubber returns raw for the same reason
- tracker or PR-create words inside quotes or heredoc bodies, for every matcher except `auto-code-review.sh`
- unquoted heredoc bodies that hold `$(` or a backtick, because the scrubber returns raw and the body text stays visible

The detector does not see these writes on `dev` either:

- `git log --output`, `sort -o`, `yq -i`, and `git diff --output`

Any program outside the allowlist gets the raw view.

When the allowlist returns raw for `python3` / `node` / `ruby` heredoc writes beside a sed `w` decoy, target extraction matches upstream/`dev`. The visible heredoc body fires `_bdw_detects_other_write`, so the decoy target is held back and the list is empty. The ticket gate still blocks via the unextractable-write rule. That is not the scrub-era `/tmp/x` result from 39c5b95, where blanking the heredoc body hid the other write from the hold-back check.

The scanner still does not model full shell grammar. Nested execution through non-allowlisted words is handled by returning raw, not by proving the nested effects. See AgDR-0113 for the additive-versus-subtractive rule this narrowing restores for routing and command matchers.

## Consequences

Ordinary quoted false positives that stay on the allowlist still scrub for the write detector. Examples include `git log --format='%h > %s'`, `grep -nE 'a|>|b' file`, `echo '  >> TEXT'`, `printf '%s\n' 'a > b'`, a quoted heredoc that only mentions `>` while writing a scratch file, and `gh pr comment` with a markdown body-file heredoc.

Must-block tests pin the reviewed bypass shapes against the ticket gate and dispatcher routing. Fail-before proofs run older cases against the 39c5b95 hook tree and the new allowlist cases against d5e7ce4.

This record replaces the earlier AgDR-0181 claim that a deny list of shells and interpreters was enough.

## Artifacts

- Issues: #1459, #1416, #1356
- Library: `.claude/hooks/_lib-command-scrub.sh`
- Write detector: `.claude/hooks/_lib-detect-bash-write.sh`
- Tests: `.claude/hooks/tests/test_command_scrub_regressions.sh`, `.claude/hooks/tests/test_command_scrub_must_block.sh`
- Related: [AgDR-0113](AgDR-0113-heredoc-stripper-additive-only.md), [AgDR-0171](AgDR-0171-quote-masking-is-diagnostic-only.md)
