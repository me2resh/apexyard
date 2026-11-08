# Secrets and the agent

This page describes controls that reduce secret exposure to the agent.
These controls do not prevent every secret read.
Agent context means the input and tool output that the agent can read.

## What the controls exclude from agent context, and how

### Secrets hook: available on dev

The [secrets hook](../.claude/hooks/check-secrets.sh) scans staged changes before a commit.
It blocks assignments that match its secret pattern.
For each match, it reports the file, line number, and rule name.
It does not print the matched source or secret value.
It reports at most five matches.
It does not scan every secret format or redact other tool output.

### Deny rules, wrapper, and Cockpit: pending merges

The following controls apply **when the step 2 PR and the Cockpit PR have merged**.
They are not all available on dev today.
See [Permission rules and hooks](hooks-fail-closed.md#permission-rules-and-hooks) for the current settings and these limits.

| Control | Intended effect after merge | File reference |
| --- | --- | --- |
| Env-file deny rules | Deny direct reads of `.env` and `.env.*` files. The two Read rules already exist on dev. | `.claude/settings.json` |
| Command deny rules | Deny matching command text for `gh auth token`, `printenv`, and bare `env`. | `.claude/settings.json` |
| Reviewer key deny rules | Deny direct reads of the reviewer key folder, `~/.config/apexyard`. | `.claude/settings.json` |
| Connection config deny rules | Deny direct reads of `.mcp.json`. This file can contain credentials. | `.claude/settings.json` |
| GitHub identity wrapper | Keep token retrieval inside the wrapper process instead of returning the token as agent tool output. | `bin/apexyard-gh-as` |
| Cockpit run environment | Pass only allowlisted environment variables to an agent run. | The Cockpit PR's run-environment implementation. Its file path is unavailable in this checkout. |
| Cockpit Keychain items | Limit new or rewritten credential items to app-only access. | The Cockpit PR's Keychain implementation. Its file path is unavailable in this checkout. |

The wrapper does not remove a token from the process that needs it.
The Cockpit controls do not apply to other launch paths.
The pending wrapper and self-test files are absent from this checkout.

## What the controls do NOT exclude

Command deny rules match command text.
Another command can still read a file.
A determined caller can reach a token that a `gh` process holds.
An allowlisted environment does not prevent other file reads.
Older Cockpit Keychain items keep their old access list until the Cockpit rewrites them.
The rules do not cover `~/.claude.json`.
On Linux and WSL2, the sandbox can ignore glob paths.
Do not assume that a glob rule blocks every shell read on those systems.
No control here removes secrets from existing logs or conversation history.

## How to check

Run this command when the step 2 PR and the Cockpit PR have merged:

```bash
bash bin/secrets-selftest.sh
```

The self-test is not available on dev in this checkout.
This checkout cannot establish its exact output lines.
Use the following meanings to assess its checks after merge.

| Check subject | Meaning and limit |
| --- | --- |
| Settings or deny rules | A configuration check confirms rule text. It does not prove that another command cannot read the same file. |
| Wrapper | A wrapper check tests its stated token-handling path. It does not prove that process credentials are unreachable. |
| Sandbox | A read check establishes behavior only for that path and sandbox. Glob handling can differ on Linux and WSL2. |
| Cockpit environment or Keychain | A framework-only check cannot establish Cockpit behavior. Existing items can retain old access lists. |
| Failure or skipped check | A failure needs investigation. A skipped check gives no evidence of protection. |

Do not paste credential values into a report.
Record the check name and result only.
The self-test does not certify that all secrets remain outside agent context.

See [reviewer key storage](how-to/reviewer-github-app.md#agent-access-and-key-storage) before you configure a reviewer identity.
