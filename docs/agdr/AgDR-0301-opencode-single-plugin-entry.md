# AgDR-0301: opencode adapter keeps its code outside the discovery directory

> Supersedes the install-layout part of AgDR-0299 and of AgDR-0092. The adapter code now lives in `.opencode/apexyard/`, and `.opencode/plugins/apexyard.ts` stays the single discovered entry.

## Context

opencode 2.x discovers two shapes under a local plugin directory: a top-level file (`plugins/<name>.ts`) and a directory entry (`plugins/<dir>/index.ts`).
[#2072](https://github.com/me2resh/apexyard/issues/2072) recorded the consequence on 2.3.0.
The installer wrote both shapes, so opencode loaded the adapter twice:

```
INFO loading plugin id=.../.opencode/plugins/apexyard      entrypoint=.../plugins/apexyard/index.ts
INFO loading plugin id=.../.opencode/plugins/apexyard.ts   entrypoint=.../plugins/apexyard.ts
```

Each instance registered its own `execute.before` hook set.
Every matching gate therefore ran twice per tool call, and the adapter prepended the session-id prefix twice.

[AgDR-0299](AgDR-0299-opencode-top-level-shim.md) added the top-level shim because it measured the discovery glob as top-level files only, in opencode 1.17.16, 1.18.35 and 1.19.5.
That measurement predates 2.x.
Dropping the shim would fix 2.x and break 1.x, because 1.x never loads `plugins/<dir>/index.ts`.

## Options Considered

| Option | Pros | Cons |
| --- | --- | --- |
| Keep both shapes | Nothing changes. | opencode 2.x keeps loading two instances. Each gate runs twice. |
| Drop the shim | One entry on 2.x. | opencode 1.x loads nothing. Regresses every 1.3.4 to 1.19.x install. |
| Rename `plugins/<dir>/index.ts` to another filename | One entry on 2.x, if discovery is index-only. | Unverified assumption. If 2.x scans every file in the directory, the helpers load as plugins and the #844 crash returns. |
| Move the code directory beside the discovery directory | One entry on 1.x and 2.x by construction. The helpers sit outside every discovery glob. The shim keeps the closed export surface. | One more path for the installer, the drift check and the smoke test to know. |

## Decision

Chosen: **move the code directory beside the discovery directory.**

The installer writes the code to `<parent-of-discovery>/<name>/`, which defaults to `.opencode/apexyard/`.
It writes `<discovery>/<name>.ts` as the only discovered file, with the content `export { default } from "../<name>/index.ts";`.
opencode 1.x loads that shim, because its glob matches top-level files only.
opencode 2.x loads the same shim, and it finds no `<discovery>/<name>/index.ts` to load a second time.
The helper modules live outside every discovery glob, so the #844 crash class cannot return.

The installer removes a pre-#2072 `<discovery>/<name>/` directory after a successful install.
The drift check in `bin/manage-portfolio-adapters.sh` reports that directory as drift, so an adopter who only pulls `/update` sees it and re-runs the installer.
`harness-adapters/opencode/test/smoke-install-layout.sh` asserts one discovered file, no in-tree code directory, and the upgrade path.

## Consequences

- A running opencode session must restart after re-running the installer, because the plugin set is read at startup.
- `--target-dir` keeps its meaning (the discovery directory). `--name` now names a directory beside that directory.
- The installer refuses three inputs that would put the code back inside a scanned directory or delete an operator's files: a `--target-dir` not named `plugins`, a `--name` equal to that directory's own name, and a code directory that already exists without an adapter entry.
- AgDR-0299's shim decision stands. Its "top-level files only" measurement no longer describes 2.x.
