---
name: preflight
description: Check the local ApexYard environment before setup or when hooks fail.
allowed-tools: Bash, Read
---

Writing: read docs/skills/shared/writing-rule.md before you write a durable artifact.

# /preflight

Run the shared read-only check from the ops fork root:

```bash
bash .claude/skills/preflight/preflight.sh
```

Read the complete output even when the exit code is nonzero. Summarize the
FAIL rows first, then WARN rows. Include the single fix printed for each
problem. Explain INFO rows when they help the user. Do not run any fix or
change files, configuration, hooks, or git state.

Exit codes: 0 = no WARN or FAIL, 1 = at least one WARN, 2 = at least one FAIL.
Checks that need jq report INFO with a skipped reason when jq is unavailable.
The report has no JSON mode. Dispatcher timing uses a trivial `:` payload,
with one-second resolution and the tracked timeout as a limit. A run at 80%
of the timeout reports WARN. This probe does not predict long-command timing.

If Claude Code hooks block this command, tell the user to run
`bash bin/apexyard doctor` in Git Bash or another Bash terminal outside Claude
Code. Both entry points run this same script. `/doctor` is a Claude Code
built-in command and does not run this check.
