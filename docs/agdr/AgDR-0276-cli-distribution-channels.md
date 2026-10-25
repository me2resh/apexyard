---
id: AgDR-0276
timestamp: 2026-10-25T12:00:00Z
agent: platform-engineer
model: claude-sonnet-5-5
session: n/a
trigger: user-prompt
status: executed
category: architecture
---

# CLI distribution channels and tag-only release workflow

> In the context of the one-command install (#1885), facing the need for pinned and checksummed CLI downloads, I decided to ship a plain install script, a Homebrew formula file, an npm launcher package and a tag-triggered release workflow, accepting that the owner publishes each channel by hand.

## Context

Install was star, fork and clone. We want one command and real download counts. Every channel must use a tagged release and a checksum. Nothing may be published by the build itself.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| Release assets plus install.sh, formula file, npm launcher | Pinned, checksummed, no sudo, download counts | Three channels to publish by hand |
| Single npm package only | One channel | Needs Node, no checksum step we control |
| Fork-and-clone only | No work | No private repo, no install count |

## Decision

Chosen: **release assets plus install.sh, formula file and npm launcher**. The release workflow is reusable (`workflow_call`, with a `tag` input) and has a `workflow_dispatch` trigger for a manual re-run. It builds the archive and checksum, then attaches them to the release. The installer refuses on a checksum mismatch.

Trigger: `auto-tag-on-release-pr-merge.yml` calls the workflow in a `cli-assets` job, after it creates the tag and the GitHub Release. A tag push made with `GITHUB_TOKEN` starts no other workflow (AgDR-0076), so a tag-push trigger never ran for framework releases. We reject a personal access token. A tag trigger would also share the `v*.*.*` name space with framework releases. The workflow has top-level `contents: read`. Only its job and the calling job have `contents: write`.

Version form: the archive and release use the tag form (`v1.2.3`). The CLI version stamp drops the `v`, as `bin/apexyard` and the Homebrew file do.

## Consequences

- A framework release builds and attaches the CLI assets with no owner step. The owner can re-run the workflow with `workflow_dispatch`.
- Follow-up (not filed): the checksum comes from the same host as the archive. It gives integrity, not authenticity. A later signature, for example a Sigstore attestation, can close the gap.
- The formula and npm package stay as files in the repo until the owner publishes them.
- A checksum mismatch stops the install.

## Artifacts

- `.github/workflows/release-cli.yml`, `install.sh`, `packaging/`
