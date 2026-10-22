---
id: AgDR-0263
timestamp: 2026-10-21T18:00:00Z
agent: platform-engineer
model: claude-opus-5-5
session: fix-1810-build-r5
trigger: user-prompt
status: executed
category: security
---

<!-- When this template creates an artifact, use the controlled technical writing profile in .claude/rules/writing-standard.md. -->

# AgDR-0263: Treat a quoted heredoc that writes a file as data in the commit-format check

> In the context of the commit-format check, facing false blocks on a Bash command that only writes a file from a quoted heredoc whose prose names a commit in Markdown backticks, I decided to remove the body of such a heredoc from the command before the check reads it, to stop the false block for review agents, accepting a small, local exception to the AgDR-0113 rule that stripped text must not decide whether a gate applies.

## Context

Ticket: me2resh/apexyard#1810. Related: AgDR-0113 (the heredoc stripper is additive only) and AgDR-0262 (the dispatcher strips a quoted heredoc before routing, for a single-command data sink).

A review agent writes its review body to a file with `cat > file <<'EOF'`. The body is Markdown. It often names a commit in inline code. The commit-format check scanned the raw command. It found the commit text in the body and then blocked on the backticks, or on the operators of the file write.

AgDR-0262 removes this body before routing, but only when the whole command is one data sink and the target passes an allow-list. A compound command (for example, a directory create and then the write) and a target in a home-directory dot folder do not qualify. For these, the dispatcher runs the commit gates, and the commit-format check blocks. The real case hit this: the review agent writes its body into a folder under a home-directory dot folder.

The commit-format check also runs the shared invocation visitor once for each commit mention in the prose. A long body with many mentions made the check slow.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| A. In the commit-format hook, remove the body of a quoted heredoc that only feeds `cat` or `tee` to a file. Do this before the visitor and the checks read the command. | One file changes. The other checks stay as they are. The visitor no longer sees prose mentions. | A second, narrow strip rule beside the AgDR-0262 rule. |
| B. Read only the stripped text for the backtick scan. | Very small. | Prose with an apostrophe or a file-write operator still blocks at a later check. The visitor still runs once for each mention. |
| C. Widen the AgDR-0262 routing strip to compound commands and to all targets. | One strip rule. | It changes routing for every push and commit gate. AgDR-0262 narrowed this rule on purpose after five review rounds. |

## Decision

Chosen: **A**, because it fixes the false block for the real command shapes and changes only the commit-format check.

1. `_fmt_strip_file_heredocs` in `validate-commit-format.sh` removes the body and the delimiter line of a quoted heredoc when all of these are true:
   - The start line ends in `cat > F <<'X'`, `cat <<'X' > F` (also `>>`) or `tee [-a] F <<'X'`. The delimiter has single or double quotes, so the shell does not expand the body.
   - That command starts the line, or follows `&&`, `||` or `;`.
   - The text before it on the line holds no other `<<`.
   - The line before the start line does not end in a backslash.
   - A later line is the delimiter. For `<<-`, leading tabs are removed first.
2. The helper keeps the raw command (no strip) when any of these is true:
   - Another line outside a stripped body holds `<<` and is not a qualifying start line. This covers a heredoc that a shell reads, an unquoted heredoc and a here-string.
   - A line after a stripped body names the file of that heredoc, because a later command can run the file.
   - The heredoc is not terminated.
3. When the helper strips a body, the hook puts the stripped text into its copy of the hook input. The visitor and all checks then read that text. If jq fails, the hook keeps the raw input.
4. The helper does not use the AgDR-0262 target allow-list. That allow-list protects routing for all push and commit gates. This strip changes only the view of the commit-format check, and a file write is not a commit for any target.
5. A real commit in the same command stays visible. The existing compound and newline checks then block it, as on `dev`.

## Consequences

- A file write from a quoted heredoc with prose that names a commit, in Markdown backticks, is not blocked by the commit-format check. This includes a compound write and a write into a home-directory dot folder.
- A command substitution in `-m` still blocks. A message file given with `-F` or `--file` is still read and checked.
- A heredoc fed to a shell, an unquoted heredoc, an unterminated heredoc, and a written file that a later command names keep the raw command. These block as on `dev`.
- The check is faster on a long body: the visitor no longer runs once for each prose mention.
- Exception to AgDR-0113: the stripped text decides whether the commit-format check applies. The exception is local to this hook and to bodies that only `cat` or `tee` copies to a file.
- Out of scope: other commit gates still run the shared visitor on the raw command. A directory change before the file write can make that visitor block with a target message. A redirection before the git verb is #1842.

## Artifacts

- Ticket: me2resh/apexyard#1810
- Hook: `.claude/hooks/validate-commit-format.sh`
- Tests: `.claude/hooks/tests/test_commit_format_file_heredoc_1810.sh`
