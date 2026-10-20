---
id: AgDR-0264
timestamp: 2026-10-20T14:00:00Z
agent: platform-engineer
model: claude-opus-5-5
session: fix-1772-build
trigger: user-prompt
status: executed
category: security
---

<!-- When this template creates an artifact, use the controlled technical writing profile in .claude/rules/writing-standard.md. -->

# AgDR-0264: Route a git verb after a redirection

> In the context of the shared git matcher that routes Bash commands to the push and commit gates, facing a redirection between `git` and the verb that hid the verb, I decided to skip each redirection with its full shell-word target in the shared grammar and to fail closed on a target that the grammar cannot read, to keep those commands on the gate path, accepting that some unusual targets now block instead of being allowed.

## Context

Ticket: me2resh/apexyard#1772. Umbrella: #1805.

The shared grammar in `_lib-git-global.sh` accepted only global options between the git command word and the verb. The shell accepts a redirection in that position too. A redirection there, or a redirection glued to `git`, made `command_has_git_subcommand` return false. The dispatcher then did not run the push gates or the commit gates.

A redirection target is one shell word. That word can hold quoted parts, escaped characters and substitutions. A space inside a quoted part does not end the word. A grammar that stops at the first space can still hide the verb.

The CEO split PR #1829 on 2026-10-20. This record covers the redirection routing only. AgDR-0262 stays with the heredoc stripping work for #1780.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| A. Skip a redirection and its full shell-word target in the shared grammar. Fail closed on a target that the grammar cannot read. | One grammar for the dispatcher, the gates and the no-jq path. The verb is found where the shell finds it. | The grammar is longer. Some targets that the shell can read cause a block. |
| B. Route both gate groups for any command that holds `git` and a `<` or `>` character. | Simple. | Every `git log > file` runs every push and commit gate. That gives false blocks and slow calls. |
| C. Skip only a redirection with a plain target that has no quotes or spaces. | Small change. | A quoted target with a space or a substitution target still hides the verb. |

## Decision

Chosen: **A**, because it finds the verb where the shell finds it and fails closed where it cannot.

1. The shared grammar treats a redirection before the verb as a non-verb unit. The grammar also accepts a redirection glued to `git`. The longest operators come first, because ERE alternation takes the first match.
2. A redirection must have a target. Thus `git > push` writes to a file named `push` and is not a push.
3. The target is one full shell word. The word can hold plain characters, escaped characters, quoted parts with spaces, ANSI-C quoted parts, and one level of `$(...)` or backquote substitution.
4. `_git_scan_globals` skips a redirection in the same way. Thus the gates read the same verb and options as the dispatcher.
5. A target can be a word that the grammar cannot match, such as a nested substitution or a `${...}` expansion with a space. A target can also be not closed. When a push or commit word follows such a target, `git_uncertain_protected_shape` returns true. The dispatcher then runs both gate groups, and the visitor blocks.
6. The no-jq path cannot read the command. It blocks a raw payload with a redirection before a push or commit word. It also blocks a redirection target that starts with a quote or an expansion and is followed by a push or commit word.

## Consequences

- A push or commit with a redirection before the verb reaches the push or commit gates.
- A target that the grammar cannot read blocks with a message that names the redirection.
- A redirection with no push or commit word after it is not changed. For example, `git log > "a b.txt"` does not route the push or commit gates.
- The gate bodies use their own ref and message parsers. Those parsers do not skip a redirection. A routed command can still pass a gate check that reads the ref or the message. That limit is the same as on the base, where the gates did not run at all.
- The git-native `pre-push` hook still guards protected branches.

## Artifacts

- `.claude/hooks/_lib-git-global.sh`
- `.claude/hooks/dispatch-bash.sh` (no-jq pattern only)
- `.claude/hooks/tests/test_git_redirect_1772.sh`
