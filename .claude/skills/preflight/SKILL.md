---
name: preflight
description: Check the local ApexYard environment before setup or when hooks fail.
allowed-tools: Bash, Read
---

Writing: read docs/skills/shared/writing-rule.md before you write a durable artifact.

# /preflight

Run the shared environment check from the ops fork root:

```bash
bash .claude/skills/preflight/preflight.sh
```

Read the complete output even when the exit code is nonzero. Summarize the
FAIL rows first, then WARN rows. Include the single fix printed for each
problem. Explain INFO rows when they help the user. The report is read-only.
An install runs only after an explicit yes in an interactive terminal.
Do not run other suggested fixes or change configuration, hooks, or git state.

Interactive mode requires terminal stdin and stdout, an empty `CI`, and
`APEXYARD_NO_INSTALL` other than `1`. Non-interactive runs install nothing.
Homebrew installs jq and gh with ApexYard. Other paths use this check to offer installation.
Use `apexyard doctor --dependencies` before init to check tools without fork configuration.

Exit codes: 0 = no WARN or FAIL, 1 = at least one WARN, 2 = at least one FAIL.
Checks that need jq report INFO with a skipped reason when jq is unavailable.
The report has no JSON mode. Dispatcher timing uses a trivial `:` payload,
with one-second resolution and the tracked timeout as a limit. A run at 80%
of the timeout reports WARN. This probe does not predict long-command timing.

If Claude Code hooks block this command, tell the user to run
`bash bin/apexyard doctor` in Git Bash or another Bash terminal outside Claude
Code. Both entry points run this same script. `/doctor` is a Claude Code
built-in command and does not run this check.
