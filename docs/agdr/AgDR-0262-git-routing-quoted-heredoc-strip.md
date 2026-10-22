---
id: AgDR-0262
timestamp: 2026-10-21T03:00:00Z
agent: platform-engineer
model: claude-opus-5-5
session: fix-1780-build
trigger: user-prompt
status: executed
category: security
---

<!-- When this template creates an artifact, use the controlled technical writing profile in .claude/rules/writing-standard.md. -->

# AgDR-0262: Strip a quoted heredoc body before push and commit routing

> In the context of the Bash dispatcher that routes commands to the push and commit gates, facing quoted heredoc prose that names those verbs and makes the gates time out, I decided to strip a confirmed quoted heredoc body before push and commit routing only when the whole command is one allow-listed data sink and the start line splits into words that show one heredoc operator and one quoted delimiter word, to keep a data body off the gate path, accepting that every other shape keeps the raw command and can still be slow or blocked.

## Context

Ticket: me2resh/apexyard#1780. Investigation: #1777.

The dispatcher scanned the raw command for a push or a commit. Prose in a quoted heredoc body that named `git push` or `git commit` therefore started the push and commit gates. The gate visitor rescans the whole command for each textual match. Its cost grew faster than the body size. A 16 KB body of such prose ran past the dispatcher time limit, and the timeout blocked a harmless command.

AgDR-0113 forbids a subtractive filter that decides whether a gate fires, because an over-strip fails open. A quoted heredoc body is data only when a known data sink receives it and the command holds nothing else.

History of this record:

- Draft PR #1829 held two fixes: the redirection routing for #1772 and the heredoc stripping for #1780. The CEO split it on 2026-10-20. PR #1835 merged the redirection part, and [AgDR-0264](AgDR-0264-git-routing-past-redirections.md) owns that part. This record keeps only the #1780 decisions.
- 2026-10-20 (CEO decision): strip only for an allow-list of data sinks, not for a deny-list of runners. A deny-list missed other shells, interpreters and split runner words.
- 2026-10-20 (CEO decision, after 5 review rounds on #1829): strip only when the whole command is one data sink. Other text in the same command could reach or hide around a stripped body.
- 2026-10-20 (security review B4 on #1829): the quoted-mode check split the text before and after the heredoc marker, but not the marker itself. A marker quote that had no pair, a marker quote that closed a string opened before the marker, or an operator inside a quoted argument passed the check. Bash did not see a heredoc there, so the lines that the stripper removed ran as commands. This record adds Decision 3 to close that class.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| A. Strip a confirmed quoted body at dispatch, only for one allow-listed data sink, with a full word split of the start line. | Removes the measured cause for the common shape. A positive check: an unknown receiver keeps the raw command. | Other shapes keep the raw command and the old cost. |
| B. Only raise the time limit. | Simple. | Prose still starts the gates and can still block falsely. |
| C. Make the gate visitor and the chain segmenter linear in `_lib-git-global.sh`. | Faster for every shape. | Large change in a file that two other open PRs change. Prose still starts the gates. |

## Decision

Chosen: **A**, because it removes the measured cause and fails closed on any doubt.

1. `dispatch-bash.sh` calls `strip_heredoc_bodies "$COMMAND" quoted` on the raw command. Then it joins line continuations on the result. The stripper must see each backslash-newline, because bash removes it before it reads operators.
2. The alias check, `git_uncertain_protected_shape` and push and commit routing read the stripped text. The merge-shape scan reads the raw command. If the stripper cannot load or returns non-zero, the dispatcher runs both gate groups (fail closed).
3. In `quoted` mode, the stripper splits the whole start line, the heredoc marker included, with one word splitter. It keeps the stripped text only when all of these are true:
   - The line has exactly one heredoc operator (`<<` or `<<-`) outside quotes.
   - The next word is one quoted word with a matching quote at each end. Its value is the terminator that the forward scan found.
   - No word holds a `<` character inside quotes.
   - The line without the operator and the delimiter word is one allow-listed data sink.
   For any other shape the stripper returns the raw command.
4. The data sinks and the target rules are the sets below. `_shq_single_sink`, `_shq_cli_ok` and `_shq_target` in `_lib-strip-heredoc.sh` are the authority, and their comments repeat these sets.
   - Sinks:
     - `cat > file` and `cat >> file`. The heredoc can come before or after the redirection.
     - `cat <<'X' | tee [-a|--append] file`, with the heredoc right after `cat`.
     - `tee [-a|--append] file`, with exactly one file.
     - `git commit` and `git notes add|append`, with standard input as the message: `-F -`, `-F=-`, `--file -` or `--file=-`.
     - `gh pr|issue|release create|comment|edit`, with standard input as the body: `--body-file -`, `--body-file=-`, `-F -` or `-F=-`.
   - Option refusals for git and gh. No operator word can come after the subcommand.
     - git: no single-dash word that holds the letter `c`, `e`, `C` or `t` (`-c`, `-e`, `-C`, `-t`), and no `--edit`, `--editor` or `--template`, alone or with `=value`.
     - gh: no single-dash word that holds the letter `e` or `w` (`-e`, `-w`), and no `--editor` or `--web`, alone or with `=value`.
   - File target rules:
     - The target is a plain relative or absolute path of the characters `A-Z a-z 0-9 . _ + % @ , = / -`. It does not start with `-` and does not end with `/`.
     - The target is not in `/dev`, `/proc` or `/sys`.
     - No path part is `..`, `.git` (or starts with `.git`), `.husky`, `hooks`, `.hooks` or `githooks`, in any case.
     - The file is not a symbolic link, and its directory resolves.
     - `$HOME` is set. The resolved path is not a home-directory dot file and not inside a home-directory dot directory. This includes `$HOME/.config`.
     - The resolved path is not inside `$XDG_CONFIG_HOME`, when that variable is set.
     - The resolved path is not inside the git dir of its repository.
     - The resolved path is not inside the `core.hooksPath` of its repository or of the current repository. A hooks path that is set but does not resolve is a refusal.
5. The command must hold nothing else: no other visible line, no separator, no continuation, no subshell, group, substitution or expansion, and no second heredoc or here-string. The start line must not have an earlier heredoc operator on its logical line. In `quoted` mode the stripper returns the raw command at the second visible line that holds text, so its scan is linear in the number of lines (#1844 review, S1).
6. AgDR-0113 still holds. The stripper is additive-only for every other caller. A body that a shell runs is a command, not data.
7. This change does not edit `_lib-git-global.sh`. The gates read the raw command from their input, as before.

## Consequences

- A 16 KB quoted heredoc of prose that names push and commit verbs, written to a file by one data sink, does not start the push or commit gates. The test pins it at 3 s or less with the always-on hooks stubbed, under UTF-8 and under `LC_ALL=C`. On the full hook tree the test requires 20 s or less, well inside the 75 s dispatcher limit.
- A real push after `cd` and a quoted heredoc in the same command still reaches every push gate.
- Unquoted heredocs and here-strings still route on the raw command.
- A marker with an unpaired quote, a mismatched quote pair, a partly quoted delimiter, or an operator inside a quoted argument keeps the raw command. The push or commit gates then see the lines after it.
- Known limit: any shape other than one data sink keeps the raw command. For example, a sink after `cd`, a commit message passed in a substitution, and a body file that a later command reads all keep the old cost. With a large body that names the verbs, the gates can still be slow, and a dispatcher timeout blocks (fail closed).
- Known limit: a `git commit -F -` sink still routes the commit gates, because the stripped text holds the commit. The gates read the raw command, so a large message body that names the verbs keeps the old gate cost, and a gate parser can still block on prose in the message. The visitor speed-up in issue #1780 scope items 2 and 3 is not part of this change.
- Update (#1833): [AgDR-0270](AgDR-0270-heredoc-substitution-commit-message.md) adds `git commit -m "$(cat <<'X' ... X\n)"` as a sink. It also lets the gate visitor parse the structure on the `quoted` mode text. That record changes the two known limits above for the substitution message and for the gate cost of a `git commit -F -` sink.
- Residual: a later Bash call can use a file or a message that a sink wrote. That is the same class as a file that the Write tool writes.

## Artifacts

- `.claude/hooks/_lib-strip-heredoc.sh` (`quoted` mode)
- `.claude/hooks/dispatch-bash.sh`
- `.claude/hooks/tests/test_git_heredoc_routing_1780.sh`
- `.claude/hooks/tests/test_dispatch_bash.sh` and `.claude/hooks/tests/test_git_global_options.sh` (copy the stripper into their dispatcher sandboxes)
- `docs/agdr/AgDR-0113-heredoc-stripper-additive-only.md` (note that points here)
