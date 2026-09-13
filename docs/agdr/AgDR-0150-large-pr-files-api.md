---
id: AgDR-0150
timestamp: 2026-09-13T06:00:00Z
agent: Codex
model: GPT-6
session: GH-1261
trigger: user-prompt
status: executed
category: security
---

# Use the paginated pull-files API for large PR merge gates

> In the context of merge gates evaluating large pull requests, facing GitHub's 300-file diff limit, I decided to use the paginated pull-files API with an authoritative file-count check to preserve fail-closed review behavior.

## Context

The `gh pr diff --name-only` endpoint fails above 300 changed files. The pull-files API supports larger responses but returns at most 3,000 files. A gate must not scan a truncated result.

## Options Considered

| Option | Pros | Cons |
| --- | --- | --- |
| Use the pull-files API with `changed_files` validation | Handles large supported PRs and detects the API ceiling | Adds one metadata request and pagination |
| Keep the diff endpoint | Minimal code change | Blocks valid large PRs above 300 files |

## Decision

Chosen: **the pull-files API with an authoritative count**, because it removes the 300-file failure while blocking PRs above the 3,000-file API ceiling.

## Consequences

- Large PRs through `/update` can be evaluated when their total is within the supported limit.
- PRs above 3,000 files remain blocked until the framework supports a complete file-set source.

## Artifacts

- [Issue #1261](https://github.com/me2resh/apexyard/issues/1261)
