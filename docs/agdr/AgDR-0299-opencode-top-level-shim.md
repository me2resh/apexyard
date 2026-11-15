# AgDR-0299: opencode adapter loads through a top-level shim

> opencode loads only top-level plugin files, so the installer writes a top-level shim beside the adapter subfolder. This supersedes part of AgDR-0092.

## Context

This record supersedes the install-layout part of [AgDR-0092](AgDR-0092-opencode-gate-adapter.md) for [#2059](https://github.com/me2resh/apexyard/issues/2059).
AgDR-0092 made `.opencode/plugins/apexyard/index.ts` the only discovered entry.
opencode's local plugin glob is `{plugin,plugins}/*.{ts,js}`.
It matches top-level files only. The glob is the same in opencode 1.17.16, 1.18.35 and 1.19.5.
So opencode never loaded the subfolder entry, and no gate ran in opencode since 9 Jul 2026.
A real Conformance turn showed it: `git add -A` staged files.

## Options Considered

| Option | Pros | Cons |
| --- | --- | --- |
| Put every adapter file at top level | Loads. | Brings back the #844 crash: opencode treats each exported function of a loaded file as a plugin. |
| Top-level shim that re-exports the subfolder | Loads. The shim exports only the default plugin. The code stays in the subfolder. | One more file to keep correct. |
| List the plugin in `opencode.json` | Loads. | Edits adopter config. |

## Decision

Chosen: **a top-level shim**.
The installer writes `.opencode/plugins/apexyard.ts` with `export { default } from "./apexyard/index.ts";`.
The `apexyard/` subfolder stays and holds all code.
The installer writes the shim last, through a temp file and a rename, and refuses a symlink on the install path.
The smoke test expects exactly this one top-level file.
The portfolio drift check reports a missing or wrong shim as drift.
`/update` ships the installer only. An adopter re-runs the installer in each project.
