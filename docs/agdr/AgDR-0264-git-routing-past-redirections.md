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
   - A quote or a substitution in a target can stay open at the end of its line. The shell then reads the target on to the next line. In that case a push or commit word on any later line of the command also counts. The scan reads one line at a time, so it cannot see the verb after the target. Thus it fails closed.
6. The no-jq path cannot read the command. It blocks a raw payload with a redirection before a push or commit word. It also blocks a redirection target that starts with a quote or an expansion and is followed by a push or commit word.
7. The Bash tool can run commands in zsh. Thus the grammar also accepts the zsh operators: `>!`, `>>!`, `>>|`, `&>!`, `&>|`, `&>>!`, `&>>|`, `>&!`, `>&|`, `>>&`, `>>&!` and `>>&|`. A named descriptor (`{name}>`, `{name}<`) can come before an operator, as a digit can. The dispatcher, the gate scanner and the no-jq path use the same operator units.
   - Some forms have two readings. In bash, `git >! f push` writes to a file named `!` and runs `git f`. In zsh, it writes to `f` and runs `git push`. The dispatcher grammar accepts both readings, so the command routes.
   - The gate scanner cannot know which shell runs the command. The two readings can give different options or a different verb. Thus, when an operator that ends in `!` (`>!`, `>>!`, `&>!`, `&>>!`, `>&!`, `>>&!`, with or without a digit or a `{name}` prefix) is followed by a blank, the gate scanner fails and the gate blocks. A glued form (`>!file`) has one reading in each shell, and the scanner skips it as before.
   - The fail-closed scan treats `&>` and its zsh forms as operators. They are not a command separator, so the walk does not stop at them.
8. The fail-closed scan is linear in the length of the command for words separated by blanks. A command can hold many git words on one line, for example in a commit message. A scan that starts again from each git word and reads the full rest of the line for each word step takes minutes, and the dispatcher time limit then blocks the command. The scan therefore does these things:
   - It stops before the lines that come after the last push or commit word.
   - It splits each line into pieces at each space and tab. A word step reads one piece. A word that is still open at the end of its piece is read again from the rest of the line.
   - It records each point where a walk reads a word. A walk that comes to a recorded point stops, because the rest of that walk is the same as before.
   - It reads a run of plain characters with one regex match, not one character at a time.
   - It removes quotes from the rest of the line only once for each new point, and with one `tr` call.
   - The scan is quadratic for two adversarial shapes:
     - a long run of text with no blank, so that the line is one piece;
     - many redirection targets that each hold a quoted blank, so that each target is still open at the end of its piece and is read again from the rest of the line.
   - A third adversarial shape is also super-linear: many git words, each followed by a nested-substitution opener. The security review measured 1.3 s at 100 repeats, 7.7 s at 200 repeats and 53 s at 400 repeats (about 3.6 KB).
   - Realistic text stays near base speed. The code review measured a PR body in a `--body` heredoc, 37 KB of review prose on one line, and a commit `-F` heredoc.
   - On the adversarial shapes, the dispatcher entry has `timeout` 75 and `onFailure: block`. On Claude Code 2.1.295 and later, a timeout therefore blocks the call (fail closed). Older clients ignore `onFailure`, as `docs/hooks-fail-closed.md` states.
   - Residual accepted by the CEO on 2026-10-20, as the decision owner. This record does not make the scan linear for these shapes.

## Consequences

- A push or commit with a redirection before the verb reaches the push or commit gates.
- A target that the grammar cannot read blocks with a message that names the redirection.
- A redirection with no push or commit word after it is not changed. For example, `git log > "a b.txt"` does not route the push or commit gates.
- A target that is open at the end of its line, with a push or commit word on a later line, blocks.
- A zsh operator before a push or commit verb routes to the gates. An operator that ends in `!` and is followed by a blank blocks at the gate, because bash and zsh read it in different ways. Thus `git >! f push origin feature/x` now blocks. The glued form `git >!f push origin feature/x` is allowed.
- The test `test_git_redirect_1772.sh` times the dispatcher with stub gates on the head tree and on the base tree. On one macOS host with the system awk, the five test shapes took 0.20 s to 0.35 s on the head and 0.19 s to 0.26 s on the base. The largest difference is the shape with 200 git words that each have a redirection: 0.35 s on the head and 0.19 s on the base. The code review measured 0.45 s and 0.20 s for that shape on another run.
- The scan residual in Decision 8 is accepted by the CEO on 2026-10-20. On the adversarial shapes, a command that the base allows can block at the dispatcher time limit on the head.
- False-block cost of Decision 5. A quoted heredoc can hold a git word in inline code, with an odd number of backquotes after it on that line, and a push or commit word on a later line. The scan reads the backquote as an open substitution that goes on to the next line, so the command now blocks. The code review wrote each of 296 framework docs to a file through a quoted heredoc. 5 of them are allowed on `dev` and blocked on the head. The heredoc stripping for #1780 is expected to remove most of this cost, because the scan then does not see the heredoc body.
- The gate bodies use their own ref and message parsers. Those parsers do not skip a redirection. A routed command can still pass a gate check that reads the ref or the message. That limit is the same as on the base, where the gates did not run at all. #1831 tracks this known gap in the gate parsers.
- A global-option value that is open at the end of its line (for example `git -C "a` with the rest on the next line) is not in scope here. The base has the same limit.
- The git-native `pre-push` hook still guards protected branches.

## Artifacts

- `.claude/hooks/_lib-git-global.sh`
- `.claude/hooks/dispatch-bash.sh` (no-jq pattern only)
- `.claude/hooks/tests/test_git_redirect_1772.sh`
