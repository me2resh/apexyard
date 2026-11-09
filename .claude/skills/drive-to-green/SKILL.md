---
name: drive-to-green
description: Drive one PR through CI, review, fixes, and delta review. Stop before human approval.
disable-model-invocation: false
argument-hint: "<pr-number> [repo] [--dry-run <state-file>]"
allowed-tools: Bash, Read, Grep, Glob, Agent
---

# /drive-to-green

Drive one PR to the existing approval boundary.
Read [the procedure](../../../docs/skills/drive-to-green.md) before execution.

1. Resolve the PR, linked ticket, current head, and existing review evidence.
2. Read `.review.drive_to_green.max_rounds` with `config_get_or`. Default to `2`.
3. For `--dry-run`, call `bash <skill-dir>/dry-run.sh --dry-run <state-file> <cap>` and stop.
4. Wait for CI through the existing `/code-review` Monitor flow.
5. After a base refresh, use `rex_approval_carries_over` before another reviewer spawn.
6. Run `/code-review` for an independent review of the current head.
7. Give required fixes to a role-appropriate build agent. Require tests and the new head SHA.
8. Request a delta review through `/code-review`. Repeat within the round cap.
9. Report the remaining blocker or the pending human approval.

Never write, copy, move, or refresh an approval marker.
Never merge. Never invoke `/approve-merge`.
Only the independent reviewer can write its own review approval marker.
Stop on a hook, permission, or sandbox block. Report its exact message.
