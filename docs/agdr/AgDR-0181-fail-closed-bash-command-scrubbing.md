---
id: AgDR-0181
timestamp: 2026-09-29T07:00:00Z
agent: codex (implementation), orchestrator (review and commit)
model: claude-opus-5-5
session: session_01KGvb2ba4gyT3TN8L2uMLTn
trigger: user-prompt
status: executed
category: security
---

<!-- Uses the controlled technical writing profile in .claude/rules/writing-standard.md. -->

# Fail-closed Bash command scrubbing for hook gates

> In the context of the Bash PreToolUse and PostToolUse hooks, facing false blocks and false triggers from text inside quotes and heredoc bodies, I decided to route every command matcher through one shared scanner that returns the raw command on any uncertain parse, to achieve correct results for ordinary quoted data, accepting that unsupported syntax still gets today's conservative raw-text verdict.

## Context

The Bash hooks match the raw tool command. A redirect in a quoted argument or
heredoc body can block a read-only command. Tracker and PR-create text in the
same data can start unrelated gates and a PostToolUse review. The quote masker
in AgDR-0171 was limited to diagnostics because a parser error could hide a
real write. AgDR-0113 recorded the same concern for heredoc stripping.

The ticket gate also judged only the targets it could extract. An exempt
redirect could therefore hide a write by an interpreter or an in-place editor
whose target was unknown.

## Options considered

| Option | Result |
|---|---|
| Keep raw matching | Preserves existing conservative blocks and leaves the reported false blocks and review triggers. |
| Add local quote and heredoc exceptions to each hook | Repeats parsing rules and allows the gates to disagree. |
| Use a shared conservative scanner | Gives the hooks one account of shell syntax; any uncertain parse must return the raw command. |

## Decision

Use a shared scanner with two views. The syntax view blanks quoted data and
heredoc bodies for command matching. The operator view keeps quoted target
names while masking their metacharacters. Both views use the same quote,
command-substitution, comment, and heredoc state. An incomplete quote or
heredoc, unsupported expansion, missing `awk`, or scanner failure returns the
raw command. Existing gates then retain their prior conservative verdict.

The write detector asks its presence question of the scrubbed views. Quoted
source passed to an actual `sed` or inline interpreter remains a separate
write signal, because that program executes its source. The ticket gate also
checks for any write family whose target could not be extracted, regardless
of other extracted or exempt targets. Adjacent redirects are separate targets.

This supersedes AgDR-0171's decision to keep the write presence question on
raw text. The older quote masker remains a diagnostic helper. It does not
become the gate filter.

## Consequences and limits

The parser is deliberately incomplete. Uncertain input uses raw matching and
may retain a false block. Shell text passed to `eval` or another nested shell
can execute after expansion; the hooks still cannot prove the effects of
arbitrary programs. A `bash -c` merge wrapper retains its existing merge-gate
routing. Tests pin ordinary quoted data, four heredoc spellings, malformed
input, real redirects and tracker commands, and mixed extractable and
unextractable writes.

## Artifacts

- Issues: #1459, #1356, #1416
- Library: `.claude/hooks/_lib-command-scrub.sh`
- Tests: `.claude/hooks/tests/test_command_scrub_regressions.sh`
