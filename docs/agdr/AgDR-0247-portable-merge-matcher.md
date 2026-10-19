# AgDR-0247: Keep the merge matcher portable and literal

> For the shared merge matcher, I chose a counted window and literal merge arguments, so old mawk can read a direct merge and the documented approve-merge call can pass the gate.

## Context

Three bugs block commands the gates must allow. They share one matcher.

- mawk 1.3.4 on Debian aborts on an ERE interval in the shell `-c` check. The fail-closed fallback then blocks every direct merge.
- `/approve-merge` step 6 passes `$PR_HOST_REPO` in the merge call. The gate reads that text before the shell expands it.
- A search pattern or a heredoc body that names a merge call is treated as a merge. The body may be quoted. An unquoted body with no dollar sign, backtick, or backslash is also data. That rule is older than this change.

The matcher fails closed. A new allow path needs a test that the matching real merge still blocks.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| Keep the interval | Short pattern | Old mawk aborts and blocks every direct merge |
| Count 200 characters in awk | Same bound on every awk | A few more lines |
| Accept `$PR_HOST_REPO` in the gate | The skill text can stay | A variable can name the wrong PR |
| Put the repo and the PR in the call as literals | The gate can read the target | The agent copies the checked values |
| Treat every quoted string as data | Fixes the search false positive | A `sh -c` script would skip the gate |
| Mask only grep patterns and inert heredocs | Read-only text is allowed | An executor in the same command stays raw |

## Decision

Chosen: **count the window, require literals, and mask only inert data**, because each allow path still leaves a real merge visible.

- Replace the interval with one pass over the command. A merge phrase may start at most 200 characters after the `-c` quote. The pass does not copy the unread tail. macOS awk makes that copy quadratic, and a slow gate does not block.
- `test_awk_ere_interval_lock.sh` is the evidence for #1757. No ERE interval remains in an awk program in any `_lib-*.sh` file. macOS Homebrew mawk 1.3.4-20260302 accepts intervals, so it cannot reproduce #1757.
- Scan awk program literals in every `.claude/hooks/_lib-*.sh` file. Do not flag a POSIX grep interval.
- In `/approve-merge` step 6, pass the repo and the PR as literals. Stop when the check script returns a different host repo.
- Blank a grep, egrep, or fgrep pattern unless a dangerous grep option is present.
- Blank an attached `--regexp=` or `-e=` pattern in that word. A bare `--regexp` or `-e` still blanks the next word.
- An unquoted `~[` inside a grep word keeps the raw command. AgDR-0204 requires that shape.
- Inside a double-quoted argument of an allowlisted command, treat `$name` and `${name}` as data. `$(`, backticks, and `${` with an operator still keep the raw text.
- The redirect guard applies to any word lead. A word lead is the first character of a target that is not a separator. When the reader fails on that lead, the raw command stays. A later quoted variable span is in that class. A target that starts with a double quote or a dollar sign stays in that class.
- Blank an inert heredoc body only when every command word is on the data list. `true` and `false` are on that list. An interpreter heredoc, a pipe to a shell, and a later executor stay visible. The rule already covered an unquoted body with no dollar sign, backtick, or backslash. This change does not widen that rule.
- Do not call `strip_heredoc_bodies` from the merge scrub. That helper must not decide whether a merge gate fires.

## Consequences

- A literal `gh pr merge` is checked on Debian and Ubuntu.
- The documented approve-merge call is not a variable target.
- A grep for a merge call, and an inert heredoc that only cats that text, are not merges.
- A variable merge, a `sh -c` or `bash -c` wrapper, and an argv `-c` wrapper still block.
- An uncertain command stays on the raw scan.
- A redirect target with a quoted variable after its first character stays visible.

## Architecture evolution

### Portable window and a narrower data view (#1761)

The opaque-wrapper check used an ERE interval. Old mawk rejects that interval. The fallback then marked every direct merge as opaque. A counted window keeps the same 200-character bound without an interval.

The data view now hides a grep pattern and an inert heredoc body when the command cannot run them. It does not hide a shell `-c` script, an interpreter heredoc, or a variable merge. The approve-merge skill places the checked repo and PR in the merge call as literals. The gate reads the command text before the shell expands it.

### Linear window and variable redirect targets (#1761)

The double-quoted `$name` rule hid a redirect such as `> "$HOME/.zshenv"`. The word reader stops on `$`. The startup-file check never saw the target. A target that cannot be read, and that starts with a double quote or a dollar sign, now keeps the raw command.

The counted window copied the unread tail once per `-c` match. On macOS awk that copy is quadratic. One pass now records merge-phrase starts. Each `-c` match tests a fixed 200-character window.

An unquoted `~[` inside a grep word keeps the raw command again. AgDR-0204 already required that check.

The data view already treated an unquoted heredoc body with no dollar sign, backtick, or backslash as data. This change does not widen heredoc handling. The merge scrub does not call `strip_heredoc_bodies`.

`test_awk_ere_interval_lock.sh` is the evidence that #1757 stays fixed. No ERE interval remains in an awk program in any `_lib-*.sh` file. macOS Homebrew mawk 1.3.4-20260302 accepts intervals, so it cannot reproduce #1757.

### Later variable span in a redirect target (#1761)

The redirect check set the raw flag only when the target started with a double quote or a dollar sign. A later `"$NAME"` span still stopped the word reader. The scrub then hid the merge. The check now sets the raw flag when the reader fails on any word lead. An ordinary file name with a quoted variable also stays raw. That fails closed.

### Mid-word redirect word and #1757 evidence (#1761)

The redirect guard applies to any word lead. Three tests pin a variable in the middle of the target. Those targets are `~/"$NOPE".zshenv`, `.git/hooks/pre"$NOPE"-push`, and a quoted heredoc on `~/"$NOPE".bashrc`.

`test_awk_ere_interval_lock.sh` is the evidence that #1757 stays fixed. No ERE interval remains in an awk program in any `_lib-*.sh` file. macOS Homebrew mawk 1.3.4-20260302 accepts intervals, so it cannot reproduce #1757. The tests workflow does not run Debian mawk 1.3.4 20200120.

## Artifacts

- Issues #1757, #1758, #1760, and #1761
- `.claude/hooks/_lib-extract-pr.sh`
- `.claude/skills/approve-merge/SKILL.md`
- `.claude/hooks/tests/test_awk_ere_interval_lock.sh`
- `.claude/hooks/tests/test_merge_matcher_1761.sh`
- `.claude/hooks/tests/test_merge_command_data.sh`
