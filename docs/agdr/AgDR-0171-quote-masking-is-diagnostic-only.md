# Quote masking is a diagnostic aid, never a gate pre-filter

> In the context of me2resh/apexyard#1356, the write detector reads a redirect character inside a quoted argument as a real file write. Facing a choice between making the presence check quote-aware and leaving it alone, I decided to add quote masking as an additive, diagnosis-only helper. The gate verdict does not change. AgDR-0113 forbids feeding quote-filtered text to a presence question, because a parser bug there fails open across every consumer at once. The presence check keeps reading raw command text, and a regression test pins that choice.

## Status

Accepted

## Context

`_lib-detect-bash-write.sh` matches a regular expression against raw command text. It runs no quoting step. Bash treats `>` inside single quotes as a literal character. The matcher treats it as a redirect operator.

Five read-only commands were confirmed against v5.6.3. Each one reports a write and names a target the command never writes.

```
command                                                 reported target
------------------------------------------------------  ---------------
awk '/^## D/ { c=1 } { if (c && NR > 1) exit }' dfd.md   1)
grep -nE 'redirect|>|quote' file.sh                      quote
echo '  >> ZERO MATCHES'                                 ZERO
git log --format='%h > %s'                               %s
jq '.[] | select(.n > 1)' data.json                      1)
```

The first command is a short form of an awk program that the framework itself ships. `/threat-model` Step 1b runs that program. The copy at `.claude/skills/threat-model/SKILL.md:119-123` on `dev` at `5be9ecb` also reports a write to `1)`.

`require-active-ticket.sh` decides in two steps. `bash_command_appears_to_write` answers whether a write exists. `bash_extract_write_targets` answers which target. The false positive sits in the first step. An empty result from the second step still blocks, so a change there alone does not help.

## Options Considered

| Option | Result |
|---|---|
| **A. Make the presence check quote-aware** | Fixes the false positive. Feeds filtered text to a gate's presence question, which AgDR-0113 forbids. Three hooks read that function, so one parser bug fails open across all three at once. |
| **B. Make only target extraction quote-aware** | Safe under AgDR-0113. Does not fix the report. `git log --format='%h > %s'` still blocks, and the message then names no target, which reads worse. |
| **C. Add masking for diagnosis only, and keep the verdict unchanged** | Safe under AgDR-0113. Does not stop the block. Explains it, and answers the "the failure is opaque" point from #1145. Gives the maintainer the primitive without deciding the gate question. |

## Decision

Option C.

`_lib-mask-quoted.sh` masks `>`, `<`, `|`, `&`, and `;` inside quoted spans. It substitutes one byte for one byte, so offsets and length stay exact. A quoted write target therefore still resolves. `echo x > "out.txt"` yields `out.txt`, and `echo x > "a>b.txt"` round-trips through `unmask_quoted_metachars`.

The helper returns the raw command whenever it cannot be confident:

- quotes are unbalanced when the scan ends
- the command holds a heredoc operator, whose body bash does not quote-process
- the command holds a backtick, which opens a fresh quoting context
- the command holds a `#` at a comment position, whose body bash does not quote-process
- the command holds a backslash-newline pair, which joins lines before bash tokenises them
- the command already holds a placeholder byte, which could not round-trip
- a `$'` sits outside quotes, where ANSI-C quoting lets a backslash escape the quote
- a double-quoted span holds `$(`, `${`, or `$[`, whose body bash parses by its own rules

A comment position is the start of the command, or a place after whitespace or after one of `; & | ( ) < >`.

Each fallback preserves the caller's current behaviour.

Reviews found the last five guards, not the author's own adversarial pass. Three code reviews and one security review each found a shape that hid a real redirect. The guards for `$` inside double quotes grew three times. So the final guard returns the raw command for any `$` followed by `(`, `{`, or `[`, instead of listing forms one at a time. The residue section below records this history rather than a general claim of safety.

The caller also checks for an empty mask before it reads the result. The command travels through the environment, and Linux caps one environment string at 128 KiB. A larger command makes `execve` fail, and the helper returns nothing. An unguarded caller would read that as "the command changed".

`require-active-ticket.sh` calls the helper only after the gate has decided to block. No return code depends on the helper. The hook then asks `bash_command_appears_to_write` about the masked command. The note prints only when the masked command no longer looks like a write. So a write outside quotes that the detector recognises always suppresses the note.

This is the same function the gate uses, asked of filtered text. AgDR-0113 allows that only for an additive question, and this question is additive. It chooses a message after the verdict is fixed. The gate's own call still reads the raw command. A comment at the masked call says so. A presence check also costs far less than a second target extraction. On a masked command of 800 quoted `grep` calls, one local run measured about 0.9 s for the presence check. A target extraction on the same text took about 10 s.

The note speaks about the quoted match only, not the whole command. If the quoted text is only data, it says the match is a false positive. If eval, sh -c, awk, or another program runs that text, it says the text may write a file. It also says the detector does not see every kind of write. Its only remedy is to declare a ticket. An earlier draft also said "reword the command". A security review showed that advice could steer an agent toward a detector gap when the write is real.

## Consequences

The block still happens. Option C does not fix the false positive. It makes the failure readable, and it names the issue so the operator can act.

The maintainer listed four read-only commands on #1356 that a fix must allow. All four still block under this change. The message now explains all four, including `grep -E '^>' f`, whose target the detector cannot extract. `test_require_active_ticket_bash.sh` pins all four as current behaviour.

A command that trips a guard gets no note. The full `/threat-model` Step 1b block is one example. It holds a backtick and a `#` comment, so two guards trip. The block message shows `Target: 1)` without a note. That is the safe direction: a missing note, never a false one.

Three consumers keep their current behaviour: `require-active-ticket.sh`, `require-migration-ticket.sh`, and `warn-review-marker-write.sh`. None of them changes how it decides.

`test_mask_quoted.sh` section 5 pins the governance choice in two ways. Three cases assert that `bash_command_appears_to_write` still reports a write for quoted-metacharacter commands. Those cases fail if someone makes that function itself quote-aware. They cannot see masking added at a gate's call site. So a static check also asserts that only the library and the note function call `mask_quoted_metachars`. Hook case A pins the exit code at that one call site. A failure in either pin is the signal to re-read AgDR-0113 first.

The real fix stays open. It needs a decision about whether the presence question may read filtered text, and under which guards. That question is posted on #1356. The security review adds evidence for that decision. A quote-aware presence check would allow `bash -c 'echo x > f'`, `eval`, and `awk '{ print > "f" }'`. The raw check blocks all three today.

`_lib-mask-quoted.sh` is written as a shared helper. Other hooks can adopt it for additive questions without a rewrite.

## Residue and scope

AgDR-0113 closes with two binding rules for a security AgDR. Cite the test or write the claim as residue. State the scope at which each claim holds. This section applies both rules.

**Scope of the safety claim.** The eight guards cover the known divergences between this scanner and bash. They are not a proof that none remains. If a shape makes the scanner treat a real operator as quoted, and no guard catches it, the scanner hides that character from a caller. The design bounds the consequence, not the parser. The helper feeds one additive consumer. So a hidden character produces a wrong message, never a skipped gate.

| Claim | Scope at which it holds | Pinned by |
|---|---|---|
| No verdict depends on the helper | Whole change. Verified by reading every call site. | The 14 `quoted_note_case` checks in `test_require_active_ticket_bash.sh` each assert exit 2. |
| The presence function reads raw text | `bash_command_appears_to_write` itself, 3 commands | `test_mask_quoted.sh` section 5, pin 1 |
| No gate calls the masker | Every `.claude/hooks/*.sh` file, and every line of `require-active-ticket.sh` outside the note function | `test_mask_quoted.sh` section 5, pin 2. Hook case A pins the exit code at the one allowed call site. |
| The detector is untouched | Whole change | Not pinned by a test. `git diff origin/dev...HEAD -- .claude/hooks/_lib-detect-bash-write.sh` prints nothing. |
| A real write is never hidden | The 23 adversarial shapes tested, not the general case | `test_mask_quoted.sh` sections 3b, 3c, 3c2, and 3c3 |
| A write outside quotes suppresses the note | Two commands with a quoted `>` before a redirect the detector recognises | Case C in `test_require_active_ticket_bash.sh` |
| Each guard is needed | Each of the eight guards | Removing any one guard makes at least one case in `test_mask_quoted.sh` fail. Checked by hand during review, not by a test. |
| An oversize command yields no note | A 140,018-byte command on Linux | Case F in `test_require_active_ticket_bash.sh` |
| Quoted targets still resolve | Single and double quotes, and a masked character inside a target name | `test_mask_quoted.sh` section 2 |
| awk portability | mawk and busybox awk. On the test machine `nawk` resolves to mawk. **gawk and BWK awk are untested.** | `test_mask_quoted.sh` passed 69 of 69 under each awk in a local run. |

**Open residue, named rather than claimed away:**

1. **Quoted text that runs as code.** `bash -c`, `eval`, `awk`, `trap`, `find -exec`, and similar programs run quoted text. No quote tracker can see that. The note states both readings for this reason. Case E pins the wording.
2. **Writes the detector does not recognise.** On this branch, `bash_command_appears_to_write` reports no write for `touch`, `ln -s`, `mkdir`, `truncate`, or a redirect written as `>&word`. When one of these sits beside a quoted `>`, the note still prints. The note says the detector does not see every kind of write, so its text stays true. The verdict still blocks. Without the quoted `>`, the detector allows such a command today.
3. **Reviewers found the last five guards**, not the author's adversarial pass. That pass had already asserted the general property each time. Treat the guard list as a living list, in the same sense as `_lib-detect-bash-write.sh`'s own matcher table.
4. **Bash 5.3 shapes were tested on bash 5.3.9 only.** Function substitution first appeared in bash 5.3. On older bash, the guard can only drop a note.
5. **The 128 KiB threshold is Linux-specific.** macOS was not tested. The caller guard does not depend on the exact limit, only on an empty result.
6. **Double-byte locales are untested.** In GBK, Big5, or Shift-JIS, byte `0x5C` can be the second byte of a character. awk may then read it as a backslash inside double quotes, and bash would not. This is inferred, not observed. Only the note could go wrong.
7. **The note adds time before exit 2.** One local run on Linux compared this branch with `dev`, five times per command:
   - `grep -E 'a>b' f`: about 90 ms on `dev`, about 130 ms here.
   - 800 quoted `grep 'a>b'` commands: about 6.8 s on `dev`, about 7.8 s here.
   - 800 real redirects: no clear difference, because the masked command still looks like a write.

   `.claude/settings.json` sets no hook timeout. The harness default timeout was not checked.
8. **`shellcheck` and `markdownlint` did not run** on the authoring machine. Neither tool is installed. CI is the only verification for both.

## Artifacts

- `.claude/hooks/_lib-mask-quoted.sh`
- `.claude/hooks/require-active-ticket.sh` — `_ratc_quoted_origin_hint`
- `.claude/hooks/tests/test_mask_quoted.sh`
- `.claude/hooks/tests/test_require_active_ticket_bash.sh`
- me2resh/apexyard#1356
- [AgDR-0113](AgDR-0113-heredoc-stripper-additive-only.md)
