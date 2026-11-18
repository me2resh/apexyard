---
id: AgDR-0305
timestamp: 2026-11-16T00:00:00Z
agent: codex
model: GPT-6
trigger: user-prompt
status: executed
category: architecture
---

# Make review copies light and keep them in one folder

> In the context of reviewers that make a full clone for each scratch review, facing disk growth of about 20 GB with no way to find old copies, I decided to make a shallow, single-commit standalone clone under one folder with a small record in each copy, to keep the disk small and let a later sweep find every copy (me2resh/apexyard#2070, step 3).

## Context

Rex, Hakim and Tariq run tests in a scratch clone of the PR head. Each clone was a full copy in any temp path. Nothing listed them, and nothing recorded which PR or session made them. Step 4 of #2070 needs to find old copies.

A linked worktree is also small. But writes inside a linked worktree still need an active ticket. A standalone clone with an origin remote has the scratch-clone ticket exemption (AgDR-0188). The reviewer mutation lock blocks `git clone`, `git fetch` and `git checkout` while the marker exists, so the orchestrator makes the copy before it arms the marker.

## Options Considered

| Option | Pros | Cons |
|---|---|---|
| Linked worktree | Small, shares objects | No ticket exemption; ties the copy to one clone |
| Shallow standalone clone, one folder, record in `.git` | Small, keeps the exemption, no hook change, easy to list | One fetch per copy |
| Keep the full clone | No change | 20 GB growth, no record |

## Decision

Chosen: **shallow standalone clone**. `review-copy.sh create` runs `git init` and fetches `refs/pull/<N>/head` with `--depth 1`.
It then checks out the commit.
The repo input requires `owner/name`, with exactly one slash and nonempty components.
Each component accepts letters, digits, dots, dashes and underscores.
The folder is `<temp dir>/apexyard-review-copies/<owner>__<name>-pr<N>`.
Forks and upstream repositories use separate folders.

The JSON record `.git/apexyard-review-copy.json` contains these fields:

| Field | Type | Meaning |
|---|---|---|
| `repo` | String | Repository as `owner/name` |
| `pr` | Number | Pull request number |
| `head_sha` | String | Checked-out commit SHA |
| `session` | String | Session identifier, or `unknown` |
| `created_at` | String | UTC creation time in ISO 8601 format |
| `path` | String | Absolute copy path |

The record sits in the git directory, so the work tree stays clean.
`list` reports `repo` as `unknown` for old records without an owner.

Before create, list or remove, the script checks the root.
It creates a missing root with mode 0700.
The root must be a real directory owned by the current user, without group or world write permission.
A symlink root fails the check.
`remove` requires a real directory directly under the resolved root, with a record and a standalone git directory.

## Consequences

- No hook change. The mutation lock and every gate stay as they were.
- The copy is a standalone clone under a temp path, so the ticket exemption still applies.
- Step 4 can sweep with `review-copy.sh list` and `remove`.
- The orchestrator must run `create` before it arms the marker.

## Artifacts

- `.claude/skills/code-review/review-copy.sh`
- `.claude/hooks/tests/test_review_copy.sh`
- Issue #2070
