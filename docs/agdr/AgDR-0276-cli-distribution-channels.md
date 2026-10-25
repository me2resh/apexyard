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

Chosen: **release assets plus install.sh, formula file and npm launcher**. The release workflow runs only on a `v*.*.*` tag push. It builds the archive and checksum, then creates the release. The installer refuses on a checksum mismatch.

## Consequences

- The owner pushes a tag to release. No other trigger exists.
- The formula and npm package stay as files in the repo until the owner publishes them.
- A checksum mismatch stops the install.

## Artifacts

- `.github/workflows/release-cli.yml`, `install.sh`, `packaging/`
