# Secrets and the agent

This page describes controls that reduce secret exposure to the agent.
These controls do not prevent every secret read.
Agent context means the input and tool output that the agent can read.

## What the controls exclude from agent context, and how

### Secrets hook

The [secrets hook](../.claude/hooks/check-secrets.sh) scans staged changes before a commit.
It blocks assignments that match its secret pattern.
For each match, it reports the file, line number, and rule name.
It does not print the matched source or secret value.
It reports at most five matches.
It does not scan every secret format or redact other tool output.

### Deny rules, wrapper, and Cockpit

The deny rules, wrapper, and self-test are available on dev.
The Cockpit controls are live in the premium Cockpit.
See [Permission rules and hooks](hooks-fail-closed.md#permission-rules-and-hooks) for the current settings and these limits.

| Control | Effect | File reference |
| --- | --- | --- |
| Env-file deny rules | Deny direct reads of `.env` and `.env.*` files. | `.claude/settings.json` |
| Command deny rules | Deny matching command text for `gh auth token`, `printenv`, and bare `env`. | `.claude/settings.json` |
| Private key deny rules | Deny direct reads of `.pem` files in `~/.config/apexyard` and files matching `*.private-key.pem`. | `Read(//**/.config/apexyard/*.pem)` and `Read(//**/*.private-key.pem)` in `.claude/settings.json` |
| Connection config deny rules | Deny direct reads of `.mcp.json`. This file can contain credentials. | `.claude/settings.json` |
| GitHub identity wrapper | Keep token retrieval inside the wrapper process instead of returning the token as agent tool output. | `bin/apexyard-gh-as` |
| Cockpit run environment | Pass only allowlisted environment variables to an agent run. | The premium Cockpit. Its implementation is outside this checkout. |
| Cockpit Keychain items | Trust only the Cockpit app for new credential items. Rewritten items receive the new access list. | The premium Cockpit. Its implementation is outside this checkout. |

The wrapper does not remove a token from the process that needs it.
The Cockpit controls do not apply to other launch paths.
The wrapper permits only `api`, `issue`, `label`, `pr`, `release`, `repo`, `run`, or `workflow` as its first command argument.
It refuses `auth`, `-t`, `--show-token`, `--jq`, and `-q` arguments.
It fixes the `gh` pager, browser, and editor.
It stops accidental token prints, but cannot stop a caller who wants the token.

## What the controls do NOT exclude

Command deny rules match command text.
Another command can still read a file.
A determined caller can reach a token that a `gh` process holds.
An allowlisted environment does not prevent other file reads.
Older Cockpit Keychain items keep their old access list until the Cockpit rewrites them.
A governed Cockpit run can still call `gh` with the operator's GitHub login, and that login can merge PRs.
The premium Cockpit tracks a fix for this gap.
Until that fix ships, do not assume that a Cockpit run cannot reach GitHub credentials.
The rules do not cover `~/.claude.json`.
On Linux and WSL2, the sandbox can ignore glob paths.
Do not assume that a glob rule blocks every shell read on those systems.
No control here removes secrets from existing logs or conversation history.

## How to check

Run this command:

```bash
bash bin/secrets-selftest.sh
```

The self-test prints `PASS` or `FAIL` before each check name below.
Any failed check causes exit 1.

| Exact check name | Meaning and limit |
| --- | --- |
| `deny Read(//**/.env)` | Confirms that the deny rule exists. It does not test all possible read commands. |
| `deny Read(//**/.env.*)` | Confirms that the deny rule exists. It does not test all possible read commands. |
| `deny Bash(gh auth token)` | Confirms that the deny rule exists. It does not test all possible read commands. |
| `deny Bash(gh auth token:*)` | Confirms that the deny rule exists. It does not test all possible read commands. |
| `deny Bash(printenv)` | Confirms that the deny rule exists. It does not test all possible read commands. |
| `deny Bash(printenv:*)` | Confirms that the deny rule exists. It does not test all possible read commands. |
| `deny Bash(env)` | Confirms that the deny rule exists. It does not test all possible read commands. |
| `deny Read(//**/*.private-key.pem)` | Confirms that the deny rule exists. It does not test all possible read commands. |
| `deny Read(//**/.config/apexyard/*.pem)` | Confirms that the deny rule exists. It does not test all possible read commands. |
| `deny Read(//**/.mcp.json)` | Confirms that the deny rule exists. It does not test all possible read commands. |
| `env arguments stay allowed` | Confirms that `Bash(env:*)` is absent. |
| `secret scan hides the value` | Tests that the scanner blocks a staged sample without printing value fragments. |
| `wrapper keeps its token private` | Tests token delivery and refused commands with a fake `gh`. Process credentials remain reachable. |

The script then prints this note:

```text
Cockpit run environment: checked in the premium Cockpit, not here.
```

This note is not a check result.
The self-test does not verify the Cockpit environment or Keychain access lists.

Do not paste credential values into a report.
Record the check name and result only.
The self-test does not certify that all secrets remain outside agent context.

See [reviewer key storage](how-to/reviewer-github-app.md#agent-access-and-key-storage) before you configure a reviewer identity.
