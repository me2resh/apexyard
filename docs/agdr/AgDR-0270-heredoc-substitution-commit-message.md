---
id: AgDR-0270
timestamp: 2026-10-21T20:00:00Z
agent: platform-engineer
model: claude-opus-5-5
session: fix-1833-build
trigger: user-prompt
status: executed
category: security
---

<!-- When this template creates an artifact, use the controlled technical writing profile in .claude/rules/writing-standard.md. -->

# AgDR-0270: Accept a heredoc substitution commit message as a data sink

> In the context of the Bash dispatcher and the push and commit gates, facing a 16 KB commit message in `git commit -m "$(cat <<'EOF' ... EOF\n)"` that ran past the dispatcher time limit, I decided to add this shape to the `quoted` mode data sinks of AgDR-0262 and to let the gate visitor parse the command structure on the `quoted` mode text, to make the most common agent commit form fast, accepting that the gate structure parse now reads stripped text for a confirmed single data sink.

## Context

Ticket: me2resh/apexyard#1833. Parent record: [AgDR-0262](AgDR-0262-git-routing-quoted-heredoc-strip.md).

Agents usually commit with the message in a command substitution around a plain `cat` of a quoted heredoc. AgDR-0262 kept the raw command for this shape. Measurement on `dev` at `1200b6df`, with every hook active, a 16 KB body that names push and commit, and the macOS awk: the dispatcher ran for more than 120 s. The dispatcher time limit is 75 s, so the commit was blocked.

Two costs add up:

- The body names `git push`, so the dispatcher routes the push gates too.
- Each push and commit gate parses the raw command. `_git_chain_segments` reads one character at a time, and its cost grows with the square of the command length. One call takes about 8 s on 16 KB under UTF-8. Each gate calls it at least once, through `git_visit_invocations` and `git_prepare_invocation`.

Thus a stripper change alone does not help. AgDR-0262 already records this as a known limit for `git commit -F -`: the measured time for that shape on `dev` is 54 s.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| A. Add the substitution shape to the `quoted` mode sinks. Let `git_visit_invocations` and `git_prepare_invocation` parse the structure (alias check, cd chain, `-C`) on the `quoted` mode text. | Small change. Fixes the measured cause in each gate. Uses the allow-list and the single-sink rule that AgDR-0262 already reviewed. | The gate structure parse no longer reads the raw command for a confirmed sink. |
| B. Make `_git_chain_segments` and `git_alias_check` linear. | Faster for every shape. | Large change in a file that other open work changes. The alias check still reads every git word in the body (about 0.5 s for each gate on 16 KB), so the 7 commit gates are estimated to stay above 3 s. |
| C. Only add the shape to the sinks. | Smallest change. | Measured: the commit gates alone still take about 54 s. The acceptance criterion is not met. |

## Decision

Chosen: **A**, because it is the smallest change that brings the shape to 3 s or less above the always-on-hook floor, and it keeps every AgDR-0262 rule. The CEO accepted this reading of the 3 s criterion in the AC note on #1833. With every hook active, the 3 s criterion as written is not met, because an ordinary 60-byte commit already takes about 3 s.

1. A new sink in `_lib-strip-heredoc.sh` (`_shq_subst_sink`): `git commit ... -m "$(cat <<'X'` or `--message`, then the body, the terminator line, and exactly one `)"` line. All of these must be true:
   - The text after `"$(` splits into exactly three words: `cat`, the heredoc operator, and one quoted delimiter word whose value is the terminator (AgDR-0262 Decision 3).
   - The words before `"$(` split with the same word splitter. They start with `git commit` and end with `-m` or `--message`. They pass the git option refusals of AgDR-0262 Decision 4 (no `-c`, `-e`, `-C`, `-t`, `--edit`, `--editor`, `--template`), hold no operator and no `<`, and hold no `#` at the start of a word.
   - The command holds nothing else (AgDR-0262 Decision 5). The `)"` line must be exactly `)"` and come after the terminator. A second `)"` line, or text after `)"`, keeps the raw command.
2. The linear early return of AgDR-0262 Decision 5 does not count one `)"` line as a second visible line. `_shq_sinks_ok` then checks the line.
3. `_git_structure_text` in `_lib-git-global.sh` returns the `quoted` mode text. If the command has no `<<`, if the stripper cannot load, or if it fails, it returns the raw command. `git_visit_invocations` and `git_prepare_invocation` call it first.
4. The gate bodies still read the raw command for their own checks (message refs, message format, presence checks). Presence checks stay on the raw command (AgDR-0113).

## Consequences

- With the always-on hooks stubbed and real push and commit gates, the 16 KB substitution message finishes in about 1.1 to 1.6 s through the dispatcher. This is true under UTF-8 and `LC_ALL=C`, with the macOS awk and with mawk 1.3.4. The message routes only the commit gates.
- With every hook active (system awk), the 16 KB message takes about 3.4 to 4.1 s. The floor for a 60-byte message on the same tree is about 2.8 to 3.2 s. The always-on hooks set that floor, not the message body.
- A `git commit -F -` sink with a large body is fast in the gates too. This removes the AgDR-0262 known limit on gate cost for that shape. The commit-format hook still decides on that shape by itself.
- A substitution that runs anything other than a plain `cat` keeps the raw command: a shell, `cat ... | sh`, an unquoted delimiter, an unquoted substitution, `eval`, a command before `git commit`, and text after `)"`. The test pins 15 such twins.
- Residual (advisory): a shell that reads a `)` in the body as the end of the substitution reads the body differently. Bash 3.2 can do this. This is a two-shell reading. The CEO decision of 2026-10-21 (#1845) lists that class as advisory, because the shell-text gates are guardrails against honest mistakes.
- Residual: `gh ... --body "$(cat <<'X' ...)"` and other substitution receivers keep the raw command and the old cost.

## Artifacts

- `.claude/hooks/_lib-strip-heredoc.sh` (`_shq_subst_sink`, `_shq_sinks_ok`, the early return)
- `.claude/hooks/_lib-git-global.sh` (`_git_structure_text`, `git_visit_invocations`, `git_prepare_invocation`)
- `.claude/hooks/tests/test_git_heredoc_subst_1833.sh`
- `docs/agdr/AgDR-0262-git-routing-quoted-heredoc-strip.md` (note that points here)
