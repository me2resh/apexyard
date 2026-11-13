---
id: AgDR-0300
timestamp: 2026-11-12T23:30:00Z
agent: platform-engineer
model: claude-opus-5-5
session: n/a
trigger: user-prompt
status: executed
category: architecture
---

# Publish create-apexyard with a bundled, pinned CLI archive

> The npm package `create-apexyard` bundles the CLI release archive and pins its SHA-256, as the Homebrew formula does.
> The release workflow publishes it with provenance when the `NPM_TOKEN` secret exists.
> The cost is a larger package and one more release secret.

## Context

The site shows two install paths for [#2062](https://github.com/me2resh/apexyard/issues/2062).
The Homebrew path works: `brew install me2resh/tap/apexyard && apexyard init`.
The npx path fails because `create-apexyard` is not on npm.
The owner decided on 12 Nov 2026 to publish the package.

[AgDR-0276](AgDR-0276-cli-distribution-channels.md) added the launcher source in `packaging/npm/create-apexyard`.
That launcher had three gaps:

1. No workflow published it.
2. It downloaded the CLI archive and a checksum file from the same release host at run time.
   The Homebrew formula instead embeds the archive SHA-256 at stamp time.
3. With no terminal, the launcher passed control to `apexyard init`.
   The init on `dev` then used defaults and created a repository without a question.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| Keep the run-time download, publish as is | No code change | The checksum comes from the archive host. A run can fetch a version other than the package version (`APEXYARD_VERSION`). |
| Run-time download, check against a stamped SHA-256 | Small package. Same check as the formula. | Needs the network at run time. Two copies of the install logic (install.sh and the launcher). |
| Bundle the release archive, check against a stamped SHA-256 | No download of code. Same archive and same SHA-256 as the formula. npm records its own integrity hash and provenance. | The package grows to about 340 kB. |
| Bundle the extracted CLI files | No `tar` step | The files differ from the formula archive. No single SHA-256 ties the channels together. |

## Decision

Chosen: **bundle the release archive and check it against a stamped SHA-256**.

- `bin/stamp-packaging.sh` stamps `apexyard.tag` and `apexyard.sha256` into `package.json`.
  These are the same values that it stamps into the Homebrew formula.
- The stamp script copies the release archive into the package.
  It stops when the archive does not match the checksum file.
- The launcher hashes the bundled archive before it extracts a file.
  It stops on a mismatch, as `brew install` does.
  `tar` reads the hashed bytes from stdin, so it never reads the file again after the check.
- The launcher passes `--ref <tag>` to `apexyard init` when the caller gives no `--ref`.
  The framework clone then matches the package version, not `main`.
  When the tag is missing, `git clone` fails, and init removes the folder before it contacts GitHub.
- The launcher always uses the bundled CLI version.
  It no longer prefers an `apexyard` that is already on `PATH`, because that copy can be a different version.
- The launcher installs the CLI in `$APEXYARD_PREFIX/share/apexyard/<tag>` and links `$APEXYARD_PREFIX/bin/apexyard`, as `install.sh` does.
  It never replaces a regular file at the link path.
- `--help` extracts into a temp directory, prints the `apexyard init` usage, and deletes the temp directory.
- With no terminal, and without `--yes` or `--interactive`, the launcher names each missing flag (`--org`, `--name`) and exits 2.
  This is the same rule as `apexyard init` after [#2060](https://github.com/me2resh/apexyard/issues/2060).
  The launcher keeps its own copy of the rule so that the npm path is safe before and after that change merges.
- `package.json` has no `scripts`, no dependencies, `engines.node` `>=22` (the oldest Node line in LTS on the decision date), and `os` `darwin` and `linux` (the formula platforms).
- The package no longer contains `install.sh`. `bin/check-bundled-installer.sh` is deleted, because no second copy exists.

Publish:

- The `release` job in `release-cli.yml` packs the tarball once.
  It checks the pinned tag and SHA-256 in that tarball, runs its launcher help, and records the tarball SHA-256 as a job output.
- A new `npm-publish` job downloads the attached tarball.
  It stops unless the tarball SHA-256 equals the `release` job output, so it publishes the exact bytes that the run built and tested.
- The job runs only in `me2resh/apexyard` and only for a tag input that starts with `v`.
  The script also requires a release tag form (`vX.Y.Z` with an optional suffix) and a real tag ref.
- The job uses the protected GitHub environment `npm-publish`.
  `NPM_TOKEN` is an environment secret, so other workflows and branches cannot read it.
  The caller passes no secret.
- The token reaches npm through `NODE_AUTH_TOKEN` and an `.npmrc` that names the variable.
  The token value is never written to disk.
- With the repository variable `NPM_TRUSTED_PUBLISHING` set to `true`, the job can publish with npm trusted publishing (OIDC) and no token.
  npm accepts trusted publishing only for a package that already exists, so the first publish uses the token.
- The job publishes with `--provenance` through a pinned npm (`npm@11.6.2`), which supports OIDC.
  It has `id-token: write` and `contents: read` only.
  The calling `cli-assets` job grants `id-token: write`.
- The job skips with a notice when it has no token and no trusted publishing, for example in a fork.
  It skips when the version is already on npm, so a `workflow_dispatch` re-run is safe.
- A version with a hyphen goes to the `next` dist-tag.
  A version lower than the current `latest` goes to the `backport` dist-tag, so `latest` moves only forward.
- A new `create-apexyard.yml` workflow runs on pull requests that touch the package inputs.
  It packs the tarball once, runs the launcher help from it, and dry-runs the publish of the same tarball.

## Consequences

- `npx create-apexyard` works after the owner creates the `npm-publish` environment, adds `NPM_TOKEN` to it, and cuts a release.
- The npm path and the Homebrew path run the same CLI archive, checked against the same SHA-256.
- The npm path clones the framework at the package tag. The Homebrew path still clones `main` by default.
- The stamped SHA-256 travels in the same package as the archive.
  It detects corruption and a partial edit, not a replaced package.
  The npm registry integrity hash and the provenance statement cover a replaced package.
- A later run reuses an installed `share/apexyard/<tag>` folder without a new hash check, as `install.sh` does.
- The package does not run on Windows. WSL counts as Linux.
- Each framework release publishes one package version. The package version is the framework version.
- The SHA-256 still comes from the build that made the archive. A signature on the archive itself stays a follow-up from AgDR-0276.

## Artifacts

- `packaging/npm/create-apexyard/`, `bin/stamp-packaging.sh`
- `.github/workflows/release-cli.yml`, `.github/workflows/auto-tag-on-release-pr-merge.yml`, `.github/workflows/create-apexyard.yml`
- `.claude/hooks/tests/test_apexyard_dist.sh`
- Ticket: [#2062](https://github.com/me2resh/apexyard/issues/2062)
