---
id: AgDR-0215
timestamp: 2026-10-04T11:40:00Z
agent: cursor
model: composer
session: chore-1543-pi-1x
trigger: user-prompt
status: executed
category: security
---

# Move the pi adapter to pi-coding-agent 1.x

> In the context of the pi harness adapter, facing a high-severity `brace-expansion` audit finding that shrinkwrap blocked, I decided to depend on `@earendil-works/pi-coding-agent` `^1.0.1` to clear the alert without a fragile override, accepting a major-version floor for the adapter.

## Context

`npm audit` reported high-severity `brace-expansion` 5.0.9 under `@earendil-works/pi-coding-agent` through `minimatch` 10.2.6. The advisories are GHSA-q2hr-2g5m-vwhr, GHSA-qhr7-859c-m2p7, and GHSA-6j4f-fj2g-mc7p. Version 5.0.12 fixes them.

Every release from 0.86.0 through 1.0.0 ships `npm-shrinkwrap.json` that pins `brace-expansion` 5.0.9. npm ignores `overrides` for shrinkwrapped dependencies. No later 0.x patch removes that shrinkwrap. Checked with `npm view` and `npm pack --dry-run` for 0.87.1, 0.99.2, and 1.0.0.

pi-coding-agent 1.0.1 removes the shrinkwrap and pins `brace-expansion` 5.0.12 as a direct dependency. 1.0.2 is also publishable and installable under `^1.0.1`.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| Stay on 0.x and force an override | Avoids a major bump | Shrinkwrap ignores overrides. The alert stays |
| Move to a later 0.x that drops shrinkwrap | Smaller semver step | No such 0.x release exists |
| Move to `^1.0.1` | Shrinkwrap is gone. Audit clears. Direct pin is 5.0.12 | Adopter floor becomes 1.x |

## Decision

Chosen: **Move to `^1.0.1`**, because only 1.0.1 and later remove the shrinkwrap that blocked a safe `brace-expansion` resolve.

Do not add a `brace-expansion` override. 1.0.1 already resolves 5.0.12 or later. Keep `undici` at 8.10.2 or later from the package itself. No extra undici override is required when the lockfile already meets that floor.

Checked the installed 1.0 `.d.ts` files and changelog for `tool_call` and extension registration. The adapter still uses type-only imports of `ExtensionAPI`, `ToolCallEvent`, and `ToolCallEventResult`. The event fields this adapter reads (`type`, `toolCallId`, `toolName`, `input.command` / `input.path`, `ctx.cwd`) remain valid. No source adaptation was required for gate dispatch.

## Consequences

- `harness-adapters/pi` depends on `@earendil-works/pi-coding-agent` `^1.0.1`.
- `npm audit --omit=dev` in that directory reports no high or critical findings.
- `npm ls brace-expansion` resolves only 5.0.12 or later.
- `npm ls undici` resolves only 8.10.2 or later.
- A dispatcher test builds a pi 1.0 `BashToolCallEvent` with `parentToolCallId` and asserts a blocking gate result.
- Adopters who stay on pi 0.x must upgrade the coding-agent package to use this adapter release.

## Artifacts

- me2resh/apexyard#1543
