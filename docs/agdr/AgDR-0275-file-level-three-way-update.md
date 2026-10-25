---
id: AgDR-0275
timestamp: 2026-10-25T06:30:00Z
agent: platform-engineer
model: claude-opus-5-5
session: n/a
trigger: user-prompt
status: executed
category: architecture
---

<!-- When this template creates an artifact, use the controlled technical writing profile in .claude/rules/writing-standard.md. -->

# File-level three-way update by ownership class

> In the context of updates to adopter ops repos, facing local edits that a history merge can lose or bury in conflicts, I decided to update each shipped file with its own three-way merge, with the last-synced release tag as the base, to achieve updates that keep every local edit or stop with nothing written, accepting a second update path next to the history merge.

## Context

`/update` merges the upstream history into the fork. That works only when the fork shares history with upstream. A repo made from a template (#1885) has no shared history. The history merge also has no idea of ownership: it can change an adopter file, and it treats a gate edit like any other conflict.

The ownership manifest (AgDR-0274) gives each path a class. The version anchor `.claude/framework-version` names the last-synced release.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| Keep only the history merge, then restore adopter paths | Small change | Needs shared history. A conflict leaves a half-merged tree. Gate edits are not shown before the merge. |
| History merge with `-s ours`, then write files by class | Keeps ancestry | Complex. Still needs shared history. |
| File-level three-way merge (`git merge-file`), base = anchor tag | No shared history needed. Each class gets its own rule. A full plan exists before any write. | A second update path. Renames upstream show as a delete and an add. |

## Decision

Chosen: **the file-level three-way merge in `bin/update-files.sh`**, because it is the only option that works for a template-made repo and can compute the full plan before it writes a file.

Rules:

- Base is the tag in `.claude/framework-version`, or `--base`. Target is `upstream/main`, or `--target`.
- The target ref's manifest gives the class. Only paths in the base or target tree are candidates.
- Adopter paths and unclassified paths are kept. A path behind a symlink is an overlay and is kept.
- Framework and shared paths: no local edit means the target blob is written. A local edit is re-applied with `git merge-file`. A failed merge is a conflict.
- Any conflict stops the update before the first write. The output shows the local edit, the upstream change and an overlay suggestion.
- A local edit to a security path is shown first and needs `--confirm-security` or a typed `yes`.
- Each re-applied or confirmed local edit is saved as a patch under `.claude/session/update-backup/`.
- `--plan` uses the same computation and writes nothing.

## Consequences

- `apexyard update` (#1885) and `/update` can call one engine for both forks and template-made repos.
- A fork that uses the engine does not get upstream commits in its history. The hook drift notice still works, because it compares blobs against a local `upstream/*` ref.
- An upstream rename shows as an `updated` delete and an `updated` add. A local edit to the old path then becomes a conflict, which stops the update. No edit is lost.
- Only regular files are supported. The engine refuses a tree with a symlink or a submodule entry.

## Artifacts

- me2resh/apexyard#1887 (step 2: update engine)
