---
id: AgDR-0245
timestamp: 2026-10-17T00:00:00Z
agent: codex
model: gpt-6
session: n/a
trigger: user-prompt
status: executed
category: security
---

# Allow the First Push to an Empty Remote

> In the context of setup, I decided to permit a simple first push after an empty remote probe, accepting a remote-state race.

## Context

Issue #1739 covers setup Step 2b. Setup creates a sibling repository and pushes its first commit to main.
The operator approved an exception for remotes without branches.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| Block every protected push | Requires no remote query | Blocks initial setup |
| Probe remote branches | Permits initial setup | Adds latency and a remote-state race |

## Decision

Chosen: **Probe remote branches**, as the operator requested.
Resolve the remote in the target repository. Use the explicit remote, the branch remote, or origin, in that order.
Allow only a successful probe with no heads. Reject force, mirror, bulk, and delete options.
Keep ambiguous commands blocked. Keep later protected pushes blocked.

Disable terminal prompts and remove askpass environment variables. Override core.askPass with an empty value.
Keep credential helpers so stored credentials remain available. Apply SSH BatchMode when GIT_SSH_COMMAND has no value.
Limit the probe to ten seconds. Use timeout or gtimeout when available. Otherwise terminate the probe with a watchdog.

## Probe safety

The PreToolUse hook runs before the operator approves the command.
The probe copies only directory selection from `cd` and `-C`.
It does not copy other Git global options. Commands with `--git-dir` or `--work-tree` remain blocked.
The probe resolves named remote URLs before it connects. It rejects URLs with `::` or an initial `-`.
It rejects push options that select a program or transmit push options.
It never passes `--upload-pack` to `ls-remote`. It puts the URL after `--`.
A fixed protocol policy permits only HTTPS, SSH, Git, and file protocols. The probe sets `GIT_PROTOCOL_FROM_USER=0`.
Target repository configuration is local trusted state. This includes configured `core.sshCommand` values and credential helpers.
Command text cannot change that trusted configuration for the probe.
The additive ref scan checks every possible destination after the remote. Quoted values cannot hide a later protected destination.

## Consequences

- The hook can permit the first commit and push chain during setup.
- Probe errors leave the existing block in effect.
- Another writer can create a branch after the probe. The probe does not reserve remote state.
- Git-native hooks retain their existing rules.

## Artifacts

- `.claude/hooks/block-main-push.sh`
- `.claude/hooks/_lib-git-global.sh`
- `.claude/hooks/tests/test_push_cd_target.sh`
- `.claude/rules/git-conventions.md`
