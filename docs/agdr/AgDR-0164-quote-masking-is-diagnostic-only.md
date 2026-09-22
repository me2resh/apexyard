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

Each fallback preserves the caller's current behaviour.

`require-active-ticket.sh` calls the helper only after the gate has decided to block. The hook adds one line to the message when the reported target came from inside quotes. No return code depends on the helper.

## Consequences

The block still happens. Option C does not fix the false positive. It makes the failure readable, and it names the issue so the operator can act.

Three consumers keep their current behaviour: `require-active-ticket.sh`, `require-migration-ticket.sh`, and `warn-review-marker-write.sh`. None of them changes how it decides.

`test_mask_quoted.sh` pins the governance choice. Three cases assert that `bash_command_appears_to_write` still reports a write for quoted-metacharacter commands. Those cases fail if someone wires masking into the presence check. The failure is the signal to re-read AgDR-0113 first.

The real fix stays open. It needs a decision about whether the presence question may read filtered text, and under which guards. That question is posted on #1356.

`_lib-mask-quoted.sh` is written as a shared helper. Other hooks can adopt it for additive questions without a rewrite.

## Artifacts

- `.claude/hooks/_lib-mask-quoted.sh`
- `.claude/hooks/require-active-ticket.sh` — `_ratc_quoted_origin_hint`
- `.claude/hooks/tests/test_mask_quoted.sh`
- `.claude/hooks/tests/test_require_active_ticket_bash.sh`
- me2resh/apexyard#1356
- [AgDR-0113](AgDR-0113-heredoc-stripper-additive-only.md)
