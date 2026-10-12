---
id: AgDR-0235
timestamp: 2026-10-12T14:10:00Z
agent: platform-engineer
model: grok-4.7
session: cursor-gh1538
trigger: user-prompt
status: executed
category: security
---

<!-- When this template creates an artifact, use the controlled technical writing profile in .claude/rules/writing-standard.md. -->

# AgDR-0235: Post agent reviews as a GitHub App

> Agent approvals posted with the operator `gh` login can count as that person's approval.
> An opt-in GitHub App posts the review as a different account.
> The app token is limited to one `gh pr review` command.
> Merge stays on the operator login.

## Context

`tracker_review_submit` posts Rex, Hakim, and Tariq reviews.
On a `gh` project the command is `gh pr review`.
That command uses the operator login.
GitHub refuses a self-approval from the pull request author.
GitHub accepts an approval from a different account.
A required approving review can therefore treat the operator's agent approval as the human approval.

The merge path is separate.
`/approve-merge` calls `tracker_pr_merge`.
That command must keep the operator login.

The private key is a long-lived secret.
The installation token is short-lived.
Neither value may be printed, exported, or written to disk.

## Options Considered

| Option | Pros | Cons |
| --- | --- | --- |
| Keep the operator login | No new secret. Current behavior stays. | An agent approval can satisfy branch protection as the operator. |
| GitHub App installation token for one review command | The app is a different account. The token is minted per review and discarded. | The operator must create an app, store a private key, and install the app. |
| Second GitHub user with a personal access token | Also a different account. | The token is long-lived and easy to grant too much access. |
| Post comments only | No approval is recorded as the operator. | A required approving review stays unsatisfied. |

## Decision

Chosen: **GitHub App installation token for one review command**, because the app account is distinct and the token need not outlive the review.

The config key is `review_identity` in `.claude/project-config.defaults.json`.
The default `kind` is `operator`.
`github_app` is opt-in.
The private key path must sit outside every git work tree and outside `.claude/`.
The library checks the logical path and the symlink target.
A refused path does not reach `openssl`.

The JWT uses RS256.
`iat` is 60 seconds in the past.
`exp` is 9 minutes ahead.
GitHub rejects an app JWT older than 10 minutes.
The library reads the key from the file path.
It does not print the key.

The library POSTs `/app/installations/<id>/access_tokens` on `https://api.github.com`.
It passes the JWT to `curl` on stdin.
It does not put the JWT in argv.
It sets `GH_TOKEN` only on the following `gh pr review` command.
That assignment is not an export.
`set -x` is disabled while the token is in a shell variable.

`fallback` value `comment` posts a comment with the operator login after a mint or post failure.
The comment does not approve.
Any other `fallback` value fails closed and posts nothing.

`tracker_pr_merge` and `/approve-merge` never mint or attach the app token.
GitLab and custom review adapters ignore `review_identity`.

## Consequences

- Operator mode is unchanged when `kind` is `operator` or the `review_identity` config key is absent.
- An App review must never satisfy a required human review.
- Keep agents on the `comment` verdict.
- Require a CODEOWNERS or team review that excludes the App. A bot `APPROVED` review must not satisfy the branch rule.
- The local `/approve-merge` gate still applies.
- Merging requires `contents: write`. The app has only `contents: read`. This library does not use the token to merge.
- Fail closed leaves the pull request without a new review. The command exits non-zero.
- Comment fallback does not satisfy a required approving review.
- GitHub Enterprise Server is not covered. The token URL is `https://api.github.com`.
- One `installation_id` covers one user or one organization.
- The installation token is not cached. Each review mints a new one. GitHub expires it after one hour.

## Architecture evolution

### Before

`tracker_review_submit` always used the operator `gh` login for GitHub reviews.
An agent `APPROVED` review was an approval by that login.
`tracker_pr_merge` used the same login, which is correct for a human merge.

### After

`review_identity.kind` defaults to `operator`.
`github_app` mints an installation token and applies it to one `gh pr review` command.
The private key must live outside git and outside `.claude/`.
Mint or post failure either fails closed or posts an operator comment when `fallback` is `comment`.
Merge and `/approve-merge` still use the operator login.
The hooks container still owns the forge call. No new container is added.

## Artifacts

- Issue: me2resh/apexyard#1538
- Config: `.claude/project-config.defaults.json` key `review_identity`
- Library: `.claude/hooks/_lib-tracker.sh` `tracker_review_submit` gh adapter
- How-to: `docs/how-to/reviewer-github-app.md`
- Tests: `.claude/hooks/tests/test_reviewer_github_app.sh`
