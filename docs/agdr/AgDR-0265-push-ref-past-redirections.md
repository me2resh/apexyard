---
id: AgDR-0265
timestamp: 2026-10-21T12:00:00Z
agent: platform-engineer
model: claude-opus-5-5
session: fix-1831-build
trigger: user-prompt
status: executed
category: security
---

<!-- When this template creates an artifact, use the controlled technical writing profile in .claude/rules/writing-standard.md. -->

# AgDR-0265: Read the push destination past a redirection

> In the context of the shared push-ref extractor that the branch-name gate and the main-push gate use, facing a redirection before the git verb or among the push arguments that hid the destination ref, I decided to read the push words with one redirection-aware word walk in `_lib-git-global.sh` and to fail closed when an invocation that holds a redirection cannot be read, to judge each push on its real destination, accepting that some unusual redirected pushes now block.

## Context

Ticket: me2resh/apexyard#1831. Related: #1772 and AgDR-0264 (the dispatcher routes a verb after a redirection).

`validate-branch-name.sh` and `block-main-push.sh` read the destination ref through `_lib-extract-push-ref.sh`. That code removed the text from the first blank-led redirection or pipe to the end of the command. It then took the first push segment, which ends at the first `|`, `;` or `&`. The result had two gaps:

- A redirection before the verb, or among the arguments, removed the ref. The gates got an empty ref and used local HEAD.
- A redirection that holds `&` or `|` (`2>&1`, `>|`, `&>`) ended the segment early, also among the arguments.

After #1772, the dispatcher sends these commands to the gates. The gates then allowed them. This affects the main-push gate too.

The shared units from #1835 already read a redirection as the shell does: `_git_redir_fd`, `_git_redir_op`, `_git_take_raw_word` and `_git_redir_take_word`.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| A. One word walk (`git_push_ref_words`) that reuses the shared redirection units. The extractor reads each push invocation from the verb to the end of its line, and the walk finds the end of the command. | One grammar for the dispatcher and the gates. The ref is read where the shell reads it. | The extractor changes in three functions. The walk must split each line at blanks to stay linear. |
| B. Change the old cut so that it starts after the verb. | Small change. | A redirection among the arguments still hides the ref. The segment pattern still ends at the `&` in `2>&1`. |
| C. Block every push that holds a redirection. | Simple and closed. | A common push with `2>&1` and a pipe blocks. |

## Decision

Chosen: **A**, because it reads the destination where the shell reads it and it fails closed where it cannot.

1. `git_push_ref_words` in `_lib-git-global.sh` strips the git word and the global options with `_git_scan_globals push`. It then prints each push word. It skips each redirection and its target. It stops at the `;`, `&`, `|` or `)` that ends the command.
2. The walk returns 2 in four cases:
   - A redirection target is not one closed word.
   - An operator has two readings (#1772 R2-2).
   - A word is not closed on its line, and the invocation holds a redirection.
   - The text after the verb holds a unit separator byte (0x1F). The walk uses that byte to split the line into pieces, so it cannot read such text (review finding B1 on PR #1841). Bash splits words only at a space, a tab and a newline, and the walk reads one line. Thus no other control byte can break the split.
3. A word that is not closed on its line, in an invocation with no redirection, ends the walk. The walk then prints the rest of the current piece and each later piece, up to a separator. This is the split at blanks that the gates used before. Prose in a commit message or a PR body often holds an open quote or backquote after a push word. A block for these would be a new false block, and these shapes are not part of this ticket.
4. The extractor returns 3 when the walk returns 2. Both gates block with one shared message (`push_ref_unresolved_message`).
5. Tag evidence, delete flags and the refspec are read from the same words. One function replaces the three copies of the token loop.
6. Each line is split into pieces at blanks, as in `_git_redir_hides_verb`. A plain piece is one word. Thus the walk is linear for words separated by blanks.

## Consequences

- A push with a redirection before the verb or among the arguments is judged on its real destination in both gates.
- An unreadable redirected push blocks with "Cannot read the push destination".
- A redirection before the push in another command no longer hides the ref. For example, `cmd > f; git push origin x` now reads `x`.
- A delete flag in one push no longer clears the ref of another push in the same command.
- The delete check now removes the quotes from each word and examines each word of the push. Thus a short delete flag directly after the verb, and a quoted delete flag, now count as a delete. The unquoted forms of these shapes were already allowed on `dev`, so this adds no new capability. Two older gaps stay: the gates do not examine a delete of a protected branch, and a delete flag as an option value clears the ref of a real push.
- New false block: prose that names a push and then holds a redirection operator and an open quote on the same line now blocks. An example is a one-line commit message given with `-m`. The block message tells the operator to write the message to a file or to use a separate Bash call.
- Accepted residual: many words that hold a quoted blank make the walk quadratic, as AgDR-0264 Decision 8 records for the dispatcher. The dispatcher time limit then blocks (fail closed).
- Out of scope: a line continuation and a variable verb (#1837). A push in a chain after the first push is still read only by the main-push scan, not by the branch-name gate. A refspec after the first refspec is not read. A ref word with a quote inside it is not decoded. These are the same on `dev`.

## Artifacts

- Ticket: me2resh/apexyard#1831
- Tests: `.claude/hooks/tests/test_push_ref_redirect_1831.sh`
