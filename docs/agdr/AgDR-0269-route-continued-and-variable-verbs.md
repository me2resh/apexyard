---
id: AgDR-0269
timestamp: 2026-10-21T18:00:00Z
agent: platform-engineer
model: claude-opus-5-5
session: fix-1837-build
trigger: user-prompt
status: executed
category: security
---

<!-- When this template creates an artifact, use the controlled technical writing profile in .claude/rules/writing-standard.md. -->

# AgDR-0269: Route a continued word and a variable verb after a redirection

> In the context of the Bash dispatcher that routes push and commit commands to their gates, facing a line continuation inside a word and a variable verb after a redirection that both routed nothing, I decided to also scan the text that bash runs and to let the uncertain-verb check skip a redirection, to route both classes to the gates, accepting one more awk pass for each command that holds a continuation.

## Context

Ticket: me2resh/apexyard#1837. Related: #1772, #1825, AgDR-0264 and AgDR-0253.

The dispatcher joins line continuations in broad-space mode before its verb scan. That mode puts a space where bash puts nothing. Thus a continuation inside a word splits the word. These words lost their route:

- the verb
- a `-C` value
- a redirection target before the verb
- the dashed program name from #1825 (code review of #1838)

The broad-space join also ignores escape parity. A line that ends in an escaped backslash is not a continuation in bash, but the join still joins it. The next line then loses its command position.

The G2/G3 uncertain-verb check in `git_uncertain_protected_shape` skips global options before an expansion in the verb position. It did not skip a redirection. Thus a variable verb after a redirection routed nothing.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| A. Keep the broad-space text. Also join the command in bash mode (`join_shell_continuations ... bash`) when it holds a backslash-newline pair after a character that is not a blank, and route when either text routes. Add the shared redirection unit to the uncertain-verb options. | Only adds routes. Uses existing linear code. A command with no continuation pays nothing. | One more awk pass and one more scan for a command with a continuation. |
| B. Change the dispatcher join to bash mode only. | One scan. | Loses routes that the broad join gives today, for example `git` and `push` on two lines with a continuation directly after `git`. |
| C. Make the gates fail closed on any continuation near a git word. | Gates block the class. | Blocks ordinary multi-line git commands that pass on `dev`. |

## Decision

Chosen: **A**, because it only adds routes and it reuses code that is already in the dispatcher and the library.

1. The dispatcher keeps the broad-space join. It also joins the command in bash mode when the stripped command holds a backslash-newline pair directly after a character that is not a blank. The bash mode removes each continuation outside single quotes and comments, with escape parity, as bash does. After a blank, both joins give the same words, so the usual line end (a blank and then a backslash) pays nothing.
2. The uncertain-verb check and the push and commit scans read both texts. A route from either text counts.
3. If the bash-mode join fails, the dispatcher runs both gate groups (fail closed).
4. The uncertain-verb options now accept the shared redirection unit (`_git_redir`), spaced or glued to the command word. This is the same unit that `_git_sub_opts` uses.

## Consequences

- A push or commit whose verb, `-C` value, redirection target or dashed program name is split by a continuation now routes to the gates.
- A variable verb after a redirection now routes to both gate groups. The gates block it, because they run the same uncertain-verb check on the raw command.
- The allow twins still route nothing. They are the same shapes with another verb, a continuation inside single quotes or a comment, and a bare variable verb with no arguments.
- Gap that stays open: the gate bodies read the raw command and do not join continuations. A routed push whose verb is split by a continuation reaches the gates, and the gates do not see the verb. `dev` has the same gap for a continuation between `git` and the verb. The gates block most forms of the dashed program name class, because a backslash after the dashed prefix fails closed there. A continuation inside the `git` part of that name is not blocked by the gates. The git-native pre-push and pre-commit hooks still apply (AgDR-0114).
- Gap that stays open: the `-C` value class can block in the git alias check before routing. The alias check reads the broad-space text, as on `dev`.
- Residual: a comment line that ends in a blank and a backslash. Bash ends the comment at the newline, but the broad join keeps the next line on the comment line. The position-aware checks (the dashed program name and the uncertain verb) can then miss a command on the next line. `dev` has the same miss.
- Cost: a command with a continuation after a character that is not a blank pays one awk pass and one more scan. Any other command pays only one glob test. Measured on `/bin/bash` 3.2.57 with stub gates: the existing timing cases stay within 0.1 s of `dev`. A 100 KB line with such a continuation costs about 0.8 s more, because the awk join builds each line one character at a time. `git_alias_check` already pays that join for every command that holds a git word.
- The `&>` form with a quoted target that holds a blank stays in the accepted quadratic class (AgDR-0264 Decision 8). A timing case now covers it.

## Artifacts

- Ticket: me2resh/apexyard#1837
- Tests: `.claude/hooks/tests/test_git_continuation_1837.sh`, `.claude/hooks/tests/test_git_redirect_1772.sh`
