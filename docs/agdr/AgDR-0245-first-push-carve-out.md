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

# Allow the First Push to a Never-Fetched Remote

## Context

Issue #1739 covers /setup Step 2b. Setup creates a sibling repository.
The fork's protected-branch list still applies to that repository.
The carve-out permits its first push to a protected branch.

## Decision

Use local Git state. Do not probe the remote.
Allow the carve-out only for a configured remote name.
Resolve the remote in this order: explicit argument, branch.<cur>.pushRemote,
remote.pushDefault, branch.<cur>.remote, then origin.
Require `git for-each-ref --count=1 refs/remotes/<remote>/` to print nothing.
Read this state in the resolved target repository.

Reject force, mirror, delete, bulk, tag, and glob pushes.
Reject `+` and deletion refspecs.
Reject program selectors and push options.
Reject invocation config from `-c`, `--config-env`, or a `GIT_*=` prefix.
Reject commands containing `git remote` or `git config`.
These commands can change the destination before the push.
Reject a configured `remote.<name>.pushurl`.

Do not copy command config to a local read.
Do not run a remote helper or make a network request.

Without a fetch, the local repository cannot hold the remote's commits.
Git rejects a non-force push to a non-empty remote branch as non-fast-forward.
The guard relaxes only the never-fetched case.
The push exemption applies to one push invocation. Commit checks still run.

## Initial commit

Allow one commit invocation on a protected branch when HEAD is unborn.
An unborn HEAD names a branch but has no commit.
Require `git rev-parse -q --verify HEAD` to fail in the resolved target repository.
Require `git symbolic-ref -q HEAD` to name that branch.
Use local reads only.
Reject `-c`, `--config-env`, `GIT_*=` prefixes, and `--amend` for that invocation.
Use a separate flag for each commit invocation. Continue all other checks.

The hook reads state before the command executes.
Thus, `git commit && git commit` can pass both checks on an unborn protected branch.
The hook cannot know that the first commit will create history.
This is a known limit.

The dispatcher sends commits to this backstop. The branch-name gate checks pushes only.
The native `.githooks/pre-commit` hook retains its stricter protected-branch rule.
It cannot inspect the original invocation to enforce these exclusions.
Repositories with that native hook installed still block an initial protected-branch commit.

## Command target resolution

Resolve the target in this order: payload cwd, cd chain, each `-C`, then
`--git-dir` and `--work-tree`.
Follow a literal leading-segment `cd` before `&&`, `;`, or a newline.
Support `cd X || exit N` and `cd X || return N` before `;` or `&&`.
These tails retain X as the current directory.
Block unresolvable, missing, or non-leading directory commands.
Block unsupported `cd`, `pushd`, `popd`, and `builtin cd` forms.
Reject directory changes inside parentheses, braces, and conditional commands.
Report an unresolved cd target as a cd target.

Commit gates follow the cd chain too.
A commit after a cd to a missing directory blocks.
Case 10 in `test_verify_commit_refs_cwd.sh` records this behavior.

## Consequences

Local reads need no network access or prompt controls.
A tracking ref keeps the protected-push block in effect.
A URL or path destination cannot use the carve-out.
Git-native hooks retain their existing rules.

## Artifacts

- `.claude/hooks/block-main-push.sh`
- `.claude/hooks/_lib-git-global.sh`
- `.claude/hooks/tests/test_push_cd_target.sh`
- `.claude/rules/git-conventions.md`
