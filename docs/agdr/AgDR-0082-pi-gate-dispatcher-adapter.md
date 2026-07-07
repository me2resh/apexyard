# pi Gate Dispatcher — a Single-Extension Adapter Over the Bash Hooks

> In the context of making apexyard's governance gates enforceable inside pi (pi.dev) as well as Claude Code, facing the choice between N per-hook pi extensions and a re-implementation of the gate logic in TypeScript, I decided to ship one dispatcher extension that reads a gate table and shells out to the existing, unmodified bash hooks to achieve zero logic duplication across harnesses, accepting the ongoing cost of keeping the gate table in sync with `.claude/settings.json`'s hook wiring and the residual, currently-unverified risk that pi's true internal `tool_call` tool-name enumeration might drift from what's documented in its shipped `.d.ts`.

## Context

Spike me2resh/apexyard#804 proved (VIABLE verdict) that a pi extension can enforce `block-unreviewed-merge.sh` by registering on pi's `tool_call` event, reconstructing the exact stdin JSON the bash hook already parses, and mapping the hook's exit code (2 = block, 0 = allow) to pi's `{block, reason}` return contract — with zero merge-approval logic duplicated into TypeScript. The spike's own "named gaps" section flagged three follow-up decisions the real feature needed to make:

1. How to wire **more than one** gate hook without N copy-pasted single-hook extension files.
2. How to resolve an **ops root** (the directory holding `.claude/session/reviews/*.approved` markers) under pi, given that `_lib-ops-root.sh`'s session-pin mechanism (`pin-ops-root.sh` + `CLAUDE_CODE_SESSION_ID`) is Claude-Code-specific and has no pi equivalent.
3. Whether to trust the spike's hand-rolled structural types or import pi's real ones now that this is shipped code, not a throwaway prototype.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| **N separate extension files, one per gate hook** | Each file is small and independently toggleable; matches the spike prototype's shape exactly | N near-identical boilerplate blocks (stdin JSON build, exec, exit-code mapping) that drift independently as pi's API evolves; adding a gate means copy-pasting a whole file instead of a table row |
| **Reimplement each gate's approval logic in TypeScript, native to pi** | No bash subprocess per tool call; could use pi-native APIs more idiomatically | Creates a second source of truth for every governance rule — exactly the problem the adapter-over-bash pattern exists to avoid. The spike ticket named this the fallback only if the pattern proved non-viable; it didn't. |
| **One dispatcher extension driven by a gate table (CHOSEN)** | One registration, one `tool_call` handler, N gates as data rows; adding a gate is a table entry, not a new file; the table is a direct visual analog of `.claude/settings.json`'s PreToolUse wiring — "one config, two harnesses" | The dispatcher itself is now the thing that must track pi's real tool-name surface accurately (see decision below); a bug in the shared dispatcher affects every gate at once, not just one |

## Decision

Chosen: **one dispatcher extension driven by a `GateDefinition[]` table** (`harness-adapters/pi/src/gate-dispatcher.ts`), because it is the shape the spike report itself recommended ("a small dispatcher extension that loops over the same hook list `.claude/settings.json` already wires for Claude Code, in the same order") and it keeps the zero-duplication property at the *gate* level (bash owns every approval decision) while collapsing the *per-gate* boilerplate to configuration.

Two supporting decisions, made while building the dispatcher:

- **Ops-root resolution**: a new, pi-only module (`harness-adapters/pi/src/resolve-ops-root.ts`) that reproduces `_lib-ops-root.sh`'s anchor-walk (the `.apexyard-fork` marker / legacy `onboarding.yaml`+`apexyard.projects.yaml` pair) faithfully in TypeScript, and substitutes an explicit `APEXYARD_OPS_ROOT` environment variable for Claude Code's session-pin mechanism (pi has no `CLAUDE_CODE_SESSION_ID` equivalent and no SessionStart hook to write a pin). This is a **deliberate divergence**: pi users get the anchor-walk safety (same as Claude Code) but not the pin-first protection that closed apexyard#381 (the `/tmp`-clone-resolves-wrong-tree bug). Consequence: a pi session launched from inside an unrelated ops-fork-shaped directory tree (e.g. a throwaway clone) could resolve markers to the wrong fork, same failure class #381 fixed for Claude Code. Mitigation available today: set `APEXYARD_OPS_ROOT` explicitly in any pi session that isn't launched from the real ops fork's working tree.
- **Real pi types, not spike shims**: `gate-dispatcher.ts` imports `ExtensionAPI`, `ToolCallEvent`, `ToolCallEventResult` directly from `@earendil-works/pi-coding-agent`, rather than the spike prototype's hand-rolled structural interface. Checking the real `.d.ts` (not just the spike's docs-based reasoning) surfaced two corrections: the result type is `ToolCallEventResult`, not `ToolCallResult` (an invented name that happened to typecheck against the shim), and pi's `ToolCallEvent` is a **discriminated union** by `toolName` (`bash` | `read` | `edit` | `write` | `grep` | `find` | `ls` | custom) — there is no `multi_edit` tool (pi's `edit` tool accepts multiple `{oldText, newText}` pairs per call), and the edit/write tools key their target as `path`, not `file_path`. That last fact turned out to need no hook change at all: `require-active-ticket.sh` and `require-migration-ticket.sh` already fall back to `.tool_input.path` when `.tool_input.file_path` is absent.

## Consequences

- Adding a new gate to both harnesses is now "add a row to `DEFAULT_GATES`", not "write a new file" — the dispatcher table and `.claude/settings.json`'s hook list should be kept in visual sync by whoever edits either.
- The `require-active-ticket` / `require-migration-ticket` mapping to pi's `edit` / `write` tool names is verified against pi's real, installed `.d.ts` (not guessed), which closes most of the residual risk the spike flagged — but the ONE thing that remains genuinely unverified is whether pi's *live internal dispatch* actually calls `tool_call` handlers with events matching this `.d.ts` during a real, model-driven agent turn (see the test suite's "LIVE" vs by-construction distinction, and AC-6 of me2resh/apexyard#815).
- The pi-flavored ops-root resolution is a new code path apexyard has to maintain in parallel with `_lib-ops-root.sh`; a future change to the bash version's anchor conditions must be mirrored here by hand (there is no shared source file across bash and TypeScript).
- Every gate hook still receives its input via a real subprocess spawn per matching tool call — the spike's own "no pre-filter, by design" note applies unchanged here; this trades a small latency cost for keeping 100% of the decision logic in one place.

## Artifacts

- `harness-adapters/pi/src/gate-dispatcher.ts` — the dispatcher extension
- `harness-adapters/pi/src/resolve-ops-root.ts` — pi-flavored ops-root resolution
- `harness-adapters/pi/test/gate-dispatcher.test.ts` — synthetic + live proof harness
- `harness-adapters/pi/README.md` — install + usage docs
- `docs/harnesses/pi.md` — updated harness-support matrix
- Spike: me2resh/apexyard#804 / PR #814 (`docs/spike-reports/GH-804-pi-gate-extension/`)
- Feature: me2resh/apexyard#815
