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

The first command is shipped framework code. It comes from `.claude/skills/threat-model/SKILL.md:128`.

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

Each fallback preserves the caller's current behaviour.

The fourth guard came from review, not from the author's own adversarial pass. Bash ignores quotes inside a comment and this scanner did not. Two apostrophes inside comments, straddling a real redirect, left the scan balanced and masked that redirect. The balance check could not see it. That is recorded below rather than described as solved in general.

The caller also checks for an empty mask before it reads the result. The command travels through the environment, and Linux caps one environment string at 128 KiB. A larger command makes `execve` fail, the helper returns nothing, and an unguarded caller reads that as "the command changed".

`require-active-ticket.sh` calls the helper only after the gate has decided to block. The hook adds one line to the message when the reported target came from inside quotes. No return code depends on the helper.

## Consequences

The block still happens. Option C does not fix the false positive. It makes the failure readable, and it names the issue so the operator can act.

Three consumers keep their current behaviour: `require-active-ticket.sh`, `require-migration-ticket.sh`, and `warn-review-marker-write.sh`. None of them changes how it decides.

`test_mask_quoted.sh` pins the governance choice. Three cases assert that `bash_command_appears_to_write` still reports a write for quoted-metacharacter commands. Those cases fail if someone wires masking into the presence check. The failure is the signal to re-read AgDR-0113 first.

The real fix stays open. It needs a decision about whether the presence question may read filtered text, and under which guards. That question is posted on #1356.

`_lib-mask-quoted.sh` is written as a shared helper. Other hooks can adopt it for additive questions without a rewrite.

## Residue and scope

AgDR-0113 closes with two binding rules for a security AgDR. Cite the test or write the claim as residue. State the scope at which each claim holds. This section applies both rules.

**Scope of the safety claim.** The four guards cover four known divergences between this scanner and bash. They are not a proof that none remains. A shape that makes the scanner treat a real operator as quoted, and that no guard catches, would hide that character from a caller. The consequence is bounded by the design, not by the parser: the helper feeds one additive consumer, so a hidden character produces a wrong message, never a skipped gate.

| Claim | Scope at which it holds | Pinned by |
|---|---|---|
| No verdict depends on the helper | Whole change. Verified by reading every call site. | `test_mask_quoted.sh` presence-pin, 3 cases |
| The detector is untouched | Whole change | `git diff origin/dev...HEAD` returns empty for that file |
| A real write is never hidden | The 12 shapes tested, not the general case | `test_mask_quoted.sh` sections 3b and 3c |
| Quoted targets still resolve | Single and double quotes, and a masked character inside a target name | `test_mask_quoted.sh` section 2 |
| awk portability | mawk, nawk, and busybox awk. **gawk is untested.** | Cross-run during review, no gawk available |

**Open residue, named rather than claimed away:**

1. **`$'...'` ANSI-C quoting.** Bash processes backslash escapes inside it and this scanner does not. Every variant tried during review left quotes unbalanced and hit guard 1. It is probed, not proven safe. No test pins it, because no failing case was constructed.
2. **The comment divergence was found by a reviewer**, not by the author's adversarial pass, after that pass had already asserted the general property. Treat the guard list as a living list, in the same sense as `_lib-detect-bash-write.sh`'s own matcher table.
3. **The 128 KiB threshold is Linux-specific.** macOS was not tested. The caller guard does not depend on the exact limit, only on an empty result.
4. **`shellcheck` and `markdownlint` did not run** on the authoring machine. Neither tool is installed. CI is the only verification for both.

## Artifacts

- `.claude/hooks/_lib-mask-quoted.sh`
- `.claude/hooks/require-active-ticket.sh` — `_ratc_quoted_origin_hint`
- `.claude/hooks/tests/test_mask_quoted.sh`
- `.claude/hooks/tests/test_require_active_ticket_bash.sh`
- me2resh/apexyard#1356
- [AgDR-0113](AgDR-0113-heredoc-stripper-additive-only.md)
