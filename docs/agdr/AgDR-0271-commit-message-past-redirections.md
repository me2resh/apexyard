---
id: AgDR-0271
timestamp: 2026-10-21T21:00:00Z
agent: platform-engineer
model: claude-opus-5-5
session: fix-1842-build
trigger: user-prompt
status: executed
category: security
---

<!-- When this template creates an artifact, use the controlled technical writing profile in .claude/rules/writing-standard.md. -->

# AgDR-0271: Read the commit message past a redirection

> In the context of the commit-format gate, facing a redirection before the git verb that hid the commit and a redirection among the arguments that blocked every commit, I decided to read the commit words past each redirection with the redirection reader of `_lib-git-global.sh` and to fail closed when a target or a stdin message cannot be read, to judge each commit on its real message, accepting a small new parser walk in the gate.

## Context

Ticket: me2resh/apexyard#1842. Related: #1772 and AgDR-0264 (the dispatcher routes a verb after a redirection), #1831 and AgDR-0265 (the push gates read the destination past a redirection), #1810 and AgDR-0263 (the same gate, stacked base).

`validate-commit-format.sh` split the command into tokens with its own tokenizer. Each `<`, `>` and `&` became one token. This gave two faults:

- A redirection between `git` and the verb hid the verb. The token after `git` was the descriptor digit or the operator, so the gate found no commit and allowed it. A bad message passed.
- A redirection anywhere else counted as a compound command. The gate blocked every such commit, also one with a valid message, for example `git commit -m "fix: x" 2>&1`.

The shared units from #1835 already read a redirection as the shell does: `_git_take_redir` and `_git_take_raw_word`.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| A. Walk the command with `_git_take_redir` and `_git_take_raw_word`. Drop each redirection and its target. Decode each remaining word with the gate's tokenizer. | One redirection grammar for the dispatcher and the gates. The rest of the gate does not change. | A new walk of about 40 lines in the gate. |
| B. Teach the gate's tokenizer the redirection operators. | No new dependency on the library. | A second copy of the operator grammar that can drift from the dispatcher. |
| C. Skip redirection tokens only between `git` and the verb. | Smallest change. | Every commit with `2>&1` still blocks. The paired allow case of the ticket is not met. |

## Decision

Chosen: **A**, because it reads the words where the shell reads them and it reuses the grammar that routes the command.

1. `_fmt_read_words` walks the command. At each point it first tries `_git_take_redir`. A redirection and its target are not words.
2. Each `;`, `&`, `|`, `(` or `)` that is not part of a redirection becomes one token. Each line break outside quotes becomes `;`. This keeps the old compound check: a pipe, a chain, a background job or a second line still blocks.
3. A line break inside a redirection target also becomes `;`. Thus a target cannot hide a command on the next line.
4. Each other word goes through the gate's tokenizer, which removes the quotes as before.
5. The walk fails closed. The gate blocks when a target is not one closed word (for example a process substitution) or when a word cannot be read.
6. `-F -` (or `--file=-`) with an input redirection blocks. The message then comes from the redirection, and the gate does not read it.
7. A short option group is read as git reads it: `-am <msg>`, `-sm <msg>`, `-m<msg>` and `-F<file>`. Before this change, such a commit with a redirection blocked as a compound command. Without this step, the redirection fix would let a bad message in that form pass.
8. The library is optional, as before. Without it, the old tokens stay, and every redirection still blocks as a compound command.

## Consequences

- A commit with a redirection before the git word, before the verb or among the arguments is judged on its real message.
- An ordinary redirected commit with a valid message, such as `git commit -q -m "fix: x" >/dev/null 2>&1`, now passes. Before, it blocked.
- A short option group with a bad message now blocks also with no redirection, for example `git commit -am "bad"`. Before, the gate did not read it.
- `git commit -F - <file` and a here-string with `-F -` block with a new message. Before, they blocked as compound commands.
- A subshell `( ... )` around one commit is now read, and so is a commit after `;` with a redirection before the verb. Before, the gate did not find the commit in these forms and allowed them. Now a bad message in a subshell blocks, and the chain blocks as a compound command, as a chain with no redirection did before.
- Out of scope, the same as before this change: an interactive commit, a `-F` file that does not exist, and options that reuse a message (`-C`, `-c`).

## Artifacts

- Ticket: me2resh/apexyard#1842
- Tests: `.claude/hooks/tests/test_commit_format_redirect_1842.sh`
