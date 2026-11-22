# AgDR-0316: Compare drift with the recorded release and rescue overlay edits

> In the context of framework updates, I decided to reuse the release pin and rescue supported edits into overlays.

## Context

The update engine records the installed release in `.claude/framework-version`.
A drift check must compare local files with that release, even when newer upstream files exist.
Product repositories can contain copied framework files with unrelated local additions.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| Compare with the latest upstream branch | Simple comparison | Confuses local edits with upstream changes |
| Compare with the recorded release | Stable baseline | Requires the release tag locally |
| Move all copied files automatically | Fewer manual steps | Can move hooks or unrelated skills |

## Decision

Chosen: **the recorded release**, because the existing updater already maintains this baseline.
The pin contains one release tag, such as `v1.0.0`.
A missing pin counts as drift.
An invalid or unavailable pin causes an error.
An explicit `--base` remains available for diagnosis.
The checker performs no network fetch.

The report separates your change from upstream change.
Upstream change compares the pin with locally available `upstream/main`.
The report states when that reference is unavailable.
Explicit config file references also count as drift when their targets are absent.

Rescue defaults to a dry run.
With `--apply`, rescue copies skill, template, and handbook edits into their matching overlay paths.
Skill copies include supporting files because skill overlays replace complete directories.
In-place rescue then restores the framework file from the pin.
The portfolio path helper resolves configured skill and handbook directories.
Templates use `custom-templates/` beside the resolved portfolio registry.
Existing overlay files and destination links stop application before the first write.
Missing files, hooks, settings, and files without an overlay home require a person.

Import accepts a product repository's `.claude` directory.
A path present in the pinned framework is shared.
An absent path is repo-only and stays in the product repository.
A matching skill or agent name with a different description is a duplicate candidate.
A second agent with the same name or description is also a duplicate candidate.
An agent naming a canonical framework role is also a duplicate candidate.
Classification reads `name` and `description` from frontmatter.
Duplicate candidates require a person because metadata cannot establish semantic equivalence.
Shared edits use overlays, while import preserves the source repository.

The SessionStart dispatcher runs a warning-only check.
The command returns zero without drift, one with findings, and two for errors.
Application returns one when the initial report contained findings, including successfully rescued files.

## Consequences

- CI can enforce the same drift check that SessionStart recommends.
- Rescue never automatically moves hooks or settings.
- Changed descriptions can require manual review for otherwise related skills.
- Role detection uses exact metadata or canonical role names, without semantic inference.
- Partial application remains possible after an unexpected filesystem failure.
- The copied overlay preserves an edit before restoration begins.

## Artifacts

- `bin/update-files.sh`
- `bin/_lib-drift-rescue.sh`
- `.claude/hooks/check-framework-drift.sh`
- `.claude/hooks/tests/test_drift_rescue.sh`
- `docs/getting-started.md`
- Ticket: me2resh/apexyard#2128
