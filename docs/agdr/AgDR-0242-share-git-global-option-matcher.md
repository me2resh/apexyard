---
id: AgDR-0242
timestamp: 2026-10-16T13:00:57Z
agent: claude-code
model: claude-opus-5-5
session: 1db99c62-d1aa-4904-b503-9d08b57ba95e
trigger: user-prompt
status: executed
category: security
---

# Share the git global-option matcher

> In the context of me2resh/apexyard#1730 and #1731, facing gates that skip a git global option, I decided to share the dispatcher matcher and replay `-C`.
> The gates then check the named repository.
> Quoted text that names `git push` still matches.

## Context

- The dispatcher already routes `git -C` and `git -c`.
- That routing landed in #1527.
- Each gate still requires `commit` or `push` as the next word after `git`.
- A gate that matches and then reads the hook directory checks the wrong repository.
- AgDR-0113 forbids a presence check on stripped text.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| Copy the expression into each gate | The change stays local | The copies drift |
| Share the matcher and stop | One definition | The secret scan still reads the hook directory |
| Share the matcher and replay `-C` | One definition and the named repository | A relative `-C` after `cd` stays ambiguous |

## Decision

Chosen: share the matcher and replay `-C`, because #1730 and #1731 ask for that fix.
A presence-only change would scan the wrong index.
The matcher stays on the raw command.
`git stash push` does not match.
`git log --grep=push` does not match.

## Consequences

- An absolute `-C` selects the repository for the secret scan, the architecture check, the onboarding check, and a bare push.
- A relative `-C` resolves against the harness cwd.
- `verify-commit-refs.sh` uses the resolved `-C` target.
- The orbit simple-push allowlist still rejects a git option.
- A missing library in a gate uses the old adjacent-word check.
- A missing library in the dispatcher runs both gate groups.

## Architecture evolution

Before this change, `dispatch-bash.sh` recognized a git global option and the gates did not.
After this change, both sides read `_lib-git-global.sh`.
A gate that sees `git -C <dir> commit` reads `<dir>`.
A gate that sees `git -C <dir> push` reads `<dir>`.
The push-segment parser drops those options before it reads the ref.
Quoted text that names `git push` still routes the push gates.

## Artifacts

- `.claude/hooks/_lib-git-global.sh`
- me2resh/apexyard#1730
- me2resh/apexyard#1731

## Review round 2

Each gate checks every matching invocation in a separate subshell.
The gate keeps the full raw command and its existing `cd` policy.
Each `-C` resolves against the previous directory.
Relative `--git-dir` and `--work-tree` values resolve after the last `-C`.
Blocking gates reject substitutions, invalid syntax, and missing target directories.
The parser expands a leading `~` to the home directory.
Advisory gates skip targets that they cannot resolve.
The dispatcher runs both gate groups if the matcher function is absent.
Diff and log checks disable external diff commands, text conversion, and the filesystem monitor.
