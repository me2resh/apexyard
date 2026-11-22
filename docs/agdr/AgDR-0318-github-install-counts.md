# GitHub install counts

> For release measurement, I chose GitHub counters and a dedicated stats branch to retain history, accepting that downloads cannot identify installations.

## Context

Ticket [#2120](https://github.com/me2resh/apexyard/issues/2120) requires measurement without adding code to users' machines.
The Homebrew formula downloads `apexyard-<tag>.tar.gz` from a GitHub Release.
The existing CLI release workflow already attaches that filename.
The formula installs `bin` and `.claude` from the extracted archive root.

## Options Considered

| Option | Benefit | Cost |
|--------|---------|------|
| Dedicated stats branch | Retains one append-only JSON lines file | Requires repository contents write permission |
| Workflow artifacts | Requires no data branch | Retention expires and reports require multiple downloads |

## Decision

Chosen: **`stats/install-counts`**, because one persistent file keeps reporting simple and avoids data commits on `main` and `dev`.
The workflow creates an orphan branch on its first successful collection.
Each run appends one JSON line to `install-counts.jsonl`.
Scheduled runs execute weekly on Ubuntu with a five-minute timeout.
Manual runs append additional observations.
A concurrency group serializes writes, and normal pushes reject conflicting updates.

The release workflow builds the formula archive with `git archive` from the release tag.
One root directory contains the tagged files, including `bin` and `.claude`.
The build stamps the CLI version and `VERSION` file before compression, preserving the existing installation contract.
Packaging uses the resulting archive checksum.
Uploads preserve existing assets because replacing an asset resets its download counter.

The collector uses the default `GITHUB_TOKEN` for this repository's releases.
It reads all release pages and selects the exact formula asset for each published release.
Missing assets remain `null`, rather than becoming zero downloads.
The collector uses `TAP_TRAFFIC_TOKEN` only for the tap traffic request.
The owner must configure that optional secret with push access to `me2resh/homebrew-tap`.
An absent secret produces a notice and records `null` traffic.
A failed API request fails collection before any snapshot is stored.

## Consequences

- Release download counts are cumulative observations, including downloads from other distribution channels.
- GitHub's clone API supplies a rolling 14-day window with weekly buckets when requested with `per=week`.
- Snapshots retain the complete traffic response, including aggregate count, unique cloners, and weekly buckets.
- The report uses the latest observation for each week, avoiding duplicate counts from overlapping API windows.
- Unique cloners apply to each API bucket and cannot be summed into an all-time unique count.
- Delayed or disabled schedules can leave gaps after GitHub's traffic window expires.
- Asset IDs identify counter replacement, and missing historical assets remain visible.
- No new measurement code executes on users' machines.

## Operation and verification

Retrieve the history and print the report:

```bash
git fetch origin stats/install-counts
git show origin/stats/install-counts:install-counts.jsonl > /tmp/install-counts.jsonl
bash bin/install-counts-report.sh /tmp/install-counts.jsonl
```

Offline tests use saved API-shaped fixtures with fixed example counters.
These fixtures are not measurements from the live repositories.
GitHub was unreachable during implementation, so live API behavior remains unverified.

## Artifacts

- `.github/workflows/release-cli.yml`
- `.github/workflows/install-counts.yml`
- `.claude/skills/release/SKILL.md`
- `bin/install-counts-collect.sh`
- `bin/install-counts-report.sh`
- `.claude/hooks/tests/test_install_counts.sh`

## Glossary

| Term | Definition |
|------|------------|
| Asset | A file attached to a GitHub Release |
| Snapshot | One JSON line containing counters observed during one workflow run |
| Orphan branch | A Git branch whose first commit has no parent |
