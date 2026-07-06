# pi Gate Extension over Bash Hooks — Spike Report

> **Spike ticket**: [me2resh/apexyard#804](https://github.com/me2resh/apexyard/issues/804)
> **Hypothesis**: a thin pi (pi.dev) TypeScript extension can enforce an apexyard governance gate by firing on pi's tool-call event and shelling out to the existing bash gate hook — zero logic duplication, one bash source of truth, thin per-harness adapter.
> **Verdict: VIABLE** (see caveats below — nothing exercised in this spike was proven-live end-to-end inside a running pi *agent turn*, because that requires model credentials this sandbox doesn't have; everything short of that final hop was proven live against the real pi binary and the real, unmodified bash hook).

## Date + scope

- **Run date**: 2026-07-06, single session, well inside the 1–2 day budget.
- **Environment**: macOS sandbox, Node v26.4.0 (native `.ts` execution via type-stripping), `@earendil-works/pi-coding-agent@0.80.3` installed locally via npm, `gh` CLI authenticated against `me2resh/apexyard`.
- **Representative gate hook used**: `.claude/hooks/block-unreviewed-merge.sh` (the two-marker Rex+CEO merge gate), read unmodified from this repo.

## Method

1. Read pi's real extension docs and source (cited below) to establish the exact event contract before writing any code.
2. Read `block-unreviewed-merge.sh` + `_lib-extract-pr.sh` to establish the bash hook's exact input/output contract.
3. Wrote a minimal prototype extension (`GH-804-pi-gate-extension/apexyard-merge-gate.ts`) that translates one contract into the other, with zero merge-approval logic of its own.
4. Wrote an isolated proof harness (`GH-804-pi-gate-extension/test-harness.ts`) that mocks pi's `ExtensionAPI.on()` registration per the documented contract and drives the extension against the **real, unmodified hook** with **real `gh` lookups against real GitHub state**.
5. Installed the real `pi` CLI (`npm install @earendil-works/pi-coding-agent`) and attempted to load the prototype extension under it, to see how far a live run gets without model credentials.

## Pi API facts (with citations)

Primary sources — all from the canonical `earendil-works/pi` repo and `pi.dev`:

- Extension docs: [`packages/coding-agent/docs/extensions.md`](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/extensions.md) (mirrored at [pi.dev/docs/latest/extensions](https://pi.dev/docs/latest/extensions))
- Example extension: [`packages/coding-agent/examples/extensions/permission-gate.ts`](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/examples/extensions/permission-gate.ts)
- Type definitions: [`packages/coding-agent/src/core/extensions/types.ts`](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/src/core/extensions/types.ts)
- SDK docs: [`packages/coding-agent/docs/sdk.md`](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/sdk.md)
- npm package: [`@earendil-works/pi-coding-agent`](https://www.npmjs.com/package/@earendil-works/pi-coding-agent) (v0.80.3 at spike time)

| Fact | What the docs/source say | Decides |
|------|---------------------------|---------|
| **A pre-execution event exists** | The per-tool lifecycle is `tool_execution_start → tool_call (can block) → tool_execution_update → tool_result (can modify) → tool_execution_end`. `tool_call` fires **before** the tool actually runs. | Kill criterion (d) does NOT trip — pi has a pre-tool event, and it fires for the `bash` tool same as any other. |
| **An extension can BLOCK** | Returning `{ block: true, reason: string }` from a `tool_call` handler prevents execution; returning `undefined` allows it. The shipped example (`permission-gate.ts`) does exactly this for dangerous bash patterns (`rm -rf`, `sudo`, `chmod 777`). Only the first handler returning `block: true` wins. | Kill criterion (b) does NOT trip. |
| **The command string is exposed** | `event.toolName === "bash"` and `event.input.command` is the literal shell command string, mutable in place for argument-patching (not used here — we only read it). | Kill criterion (a) does NOT trip — this is exactly `.tool_input.command`, the field `block-unreviewed-merge.sh` already parses via `jq -r '.tool_input.command // empty'`. |
| **No sandboxing; arbitrary subprocess spawn is supported** | Docs state extensions "run with your full system permissions and can execute arbitrary code" and ship a `pi.exec()` helper (`await pi.exec("git", ["status"], {...})` → `{stdout, stderr, code, killed}`) alongside plain Node `child_process` access. | Kill criterion (c) does NOT trip — shelling out to a bash script and reading its exit code back is exactly what `pi.exec()` (or plain `execFileSync`) is for. |
| **Loading model** | Extensions are plain TypeScript, no compile step (loaded via `jiti`), auto-discovered from `.pi/extensions/*.ts` (project-local) or `~/.pi/agent/extensions/` (global), or loaded ad hoc via `pi --extension <path>` / `pi -e <path>`. | Confirms packaging is trivial — a single `.ts` file, no build pipeline, matching the bash hooks' own "just a script" simplicity. |

None of the four kill criteria in the spike ticket trip. The adapter pattern has a real event to hang off, a real command string to reconstruct the hook's stdin from, a real block mechanism, and no restriction on shelling out.

## The bash hook's contract (read from source, unchanged)

`block-unreviewed-merge.sh` (and its sibling merge-gate hooks) expect:

- **Input**: JSON on stdin, `{"tool_input": {"command": "<the bash command>"}}` — the same shape Claude Code's own `PreToolUse` hooks receive.
- **Output**: exit code `2` = block (with a human-readable reason on stderr), exit code `0` = allow.
- **Side effects during the check**: it shells out to `gh pr view` (real GitHub API calls) and reads local marker files at `<ops_root>/.claude/session/reviews/<repo>__<pr>-{rex,ceo}.approved`.

This is the entire surface the extension has to bridge. See `docs/spike-reports/GH-804-pi-gate-extension/apexyard-merge-gate.ts` for the ~15 lines that actually do it (`JSON.stringify({ tool_input: { command } })` in, exit-code check out) — everything else in that file is comments and type scaffolding.

## What was proven LIVE vs proven BY CONSTRUCTION

| Claim | Live or by-construction? | Evidence |
|-------|---------------------------|----------|
| The bash hook correctly BLOCKS an ungated merge | **LIVE** | `echo '{"tool_input":{"command":"gh pr merge 999999 --repo me2resh/apexyard --squash"}}' \| bash .claude/hooks/block-unreviewed-merge.sh` → real `gh pr view` lookup, exit 2, `BLOCKED: PR #999999 has no recorded code-reviewer (Rex) approval.` |
| The bash hook correctly ALLOWS an already-approved merge | **LIVE** | Same invocation against real PR #767 (merged, with pre-existing valid Rex+CEO markers matching its real HEAD SHA in this machine's ops root) → exit 0, no output. |
| The extension correctly translates a `tool_call` event into the hook's stdin and maps exit 2 → `{block:true}` / exit 0 → `undefined` | **LIVE**, against the real hook | `test-harness.ts` (mocking only pi's `ExtensionAPI.on()` registration call, per the documented contract) drove all 4 cases through the *real* hook: non-merge command → allow, non-bash tool → allow, PR #999999 → **BLOCK**, PR #767 → **ALLOW**. All 4 passed. |
| The extension file loads without error under the **real, installed pi binary** | **LIVE** | `pi --extension ./apexyard-merge-gate.ts --api-key dummy --provider anthropic --model claude-sonnet-4-5 --print "say hi"` proceeded all the way to a live (auth-failed) Anthropic API call — i.e., past extension loading. Negative control: deliberately corrupting the file's syntax produced a distinct `Error: Failed to load extension ... ParseError: Missing semicolon.` — confirming pi does genuinely parse the file, and the clean run's silence on that front means it parsed fine. |
| The `tool_call` handler actually **fires and blocks pi's own bash tool** during a real, model-driven agent turn | **NOT proven live** — proven by construction only | This sandbox has no `ANTHROPIC_API_KEY` / other provider credentials (`env \| grep -i api_key` came back empty), and pi requires a live model call to drive an agent turn that would call the bash tool. The mock harness's `ExtensionAPI` shape is written to match the documented/observed contract exactly (`event.toolName`, `event.input`, `{block, reason}` return), so the gap between "mocked call" and "pi's real internal dispatch" is a transport-fidelity assumption, not a logic gap — but it IS an assumption, not an observation. |

## Verdict: VIABLE

All four kill criteria are cleared by direct evidence:

1. ✅ pi's extension API exposes the command string (`event.input.command`) — confirmed in docs and by loading the real extension under the real binary.
2. ✅ A pi extension CAN block a tool call (`{ block: true, reason }`) — confirmed in docs, matches the shipped `permission-gate.ts` example pattern exactly.
3. ✅ Shelling out to bash and propagating exit-2/stderr into a block decision works cleanly — proven live in isolation against the real, unmodified hook (all 4 harness cases passed).
4. ✅ pi has a pre-tool event (`tool_call`, fires before `tool_execution_update`/execution) covering the `bash` tool, which is what carries the `gh pr merge` command shape.

The remaining gap — a full model-driven agent turn actually invoking the bash tool with a merge command inside a live `pi` session — is a **credentials gap in this sandbox**, not a pattern gap. Nothing in the four kill criteria depends on that final hop; it would only additionally confirm pi's internal event dispatch matches its own documentation, which is a much smaller residual risk than the four criteria the ticket asked to resolve.

## Named gaps (what the bash hooks assume that pi doesn't hand over for free)

- **Ops-root / marker-path resolution.** `block-unreviewed-merge.sh` resolves `MARKER_HOME` via `_lib-ops-root.sh`, which has Claude-Code-specific assumptions baked in (workspace/`<project>` nesting, the ops fork being the git worktree's ancestor). In this spike it happened to resolve correctly through a pi-driven cwd (`ctx.cwd`) because the worktree layout matched what `_lib-ops-root.sh` expects — but a pi user with a different project layout (no `workspace/<project>/` nesting, no ops-fork concept) may get a different, possibly wrong, marker path. **Not a kill criterion**, but a real port-cost item: `_lib-ops-root.sh` needs to either learn a pi-flavored resolution rule, or the extension needs to pass an explicit override (as this prototype does via `APEXYARD_REPO_ROOT`, which is a spike-only escape hatch, not a real solution).
- **`gh` CLI auth context.** The hook shells out to `gh pr view` / `gh pr checks` etc. A pi extension inherits the parent process's environment (confirmed — no sandboxing), so this works for the common case (same machine, same `gh auth login`), but multi-account or CI-driven pi setups would need the same auth-context care Claude Code's hooks already require.
- **No pre-filter, by design (see the extension file's own doc comment).** This prototype invokes the hook for **every single bash tool call**, not just merge-shaped ones, trusting the hook's own `is_merge_command()` self-filter. That's correct for zero-duplication but adds one subprocess spawn of latency per bash call. A production port might add a cheap regex pre-filter as a latency optimization — that would NOT duplicate the approval *decision* logic (still 100% in bash), only the "is this worth checking" gate, so it stays consistent with the zero-duplication goal if done carefully.
- **Multiple gates = multiple registrations (or one dispatcher).** This spike wires exactly one hook (`block-unreviewed-merge.sh`) as `.claude/skills/spike/SKILL.md` and the ticket's "representative gate hook" framing both allow. Porting the rest of apexyard's merge gates (`block-merge-on-red-ci.sh`, `require-design-review-for-ui.sh`, `require-architecture-review.sh`, `check-secrets.sh`, `require-active-ticket.sh`, etc.) means either N separate `pi.on("tool_call", ...)` registrations (one per hook) or a small dispatcher extension that loops over the same hook list `.claude/settings.json` already wires for Claude Code, in the same order. The latter is the more faithful "one config, two harnesses" shape and should be the real feature's design, not N independent copies of this prototype's boilerplate.
- **`--offline` doesn't skip the live model call.** Noted in passing during testing: pi's `--offline` flag disables *startup* network operations, not the actual provider chat request — a real agent turn still needs live model access regardless. Not an apexyard-specific gap, just a fact that shaped how far this spike could get without credentials.
- **No isolated extension-testing harness in pi itself.** pi's SDK docs don't document a way to fire a single `tool_call` event without a live model turn or interactive session — this spike's `test-harness.ts` (a hand-rolled `ExtensionAPI` mock) is the workaround, and it's the same workaround a real feature port would need for its own test suite, since there's no first-party alternative documented.

## Disposition recommendation: PROMOTE

Recommend `/spike-close --promote` to file the real "multi-harness adapter (pi extensions over bash gates)" feature. Rough shape for that follow-up, based on what this spike learned:

1. **A generalized dispatcher extension**, not one file per hook — reads the same hook list `.claude/settings.json` wires for Claude Code's `PreToolUse` matchers, and replays it against pi's `tool_call` event for the `bash` tool.
2. **A pi-aware `_lib-ops-root.sh` resolution path** (or an explicit config file a pi user sets once) so marker-path resolution doesn't depend on Claude-Code-specific worktree/workspace assumptions.
3. **Packaging as an installable pi package** (`pi install` / `.pi/extensions/`) shipped from this same apexyard repo, so `docs/harnesses/pi.md`'s "not yet" row for mechanical gate enforcement becomes a "yes, via `pi install <this>`" row.
4. **A real live end-to-end test** — the one gap this spike couldn't close (needs model credentials) — should be the first acceptance criterion of the follow-up feature ticket, run with real provider credentials in whatever CI/dev environment has them.

If a maintainer disagrees and wants to discard instead, the named alternative (per the ticket's kill-criteria framing) would be a **native TypeScript reimplementation of each gate's logic** inside the pi extension — rejected here because it would create two sources of truth (bash + TS) for every governance rule, the exact problem the adapter pattern exists to avoid, and this spike found no evidence forcing that fallback.

## Glossary

| Term | Definition |
|------|------------|
| pi | pi.dev — Earendil's minimal, unopinionated agent CLI with a TypeScript extension system (tools/commands/events) |
| adapter-over-bash | A thin per-harness extension that invokes apexyard's existing bash gate hooks rather than reimplementing the gate logic in the harness's native language |
| `tool_call` event | pi's pre-execution lifecycle event; extensions registered on it via `pi.on("tool_call", handler)` can block or allow a tool invocation before it runs |
| proven live | Observed directly against the real running system (real `pi` binary, real `gh` API calls) in this spike |
| proven by construction | Demonstrated via a hand-written mock built to match the documented contract, not observed inside the real running system end-to-end |
| governance gate | An apexyard mechanical enforcement hook (merge gate, ticket-first, secrets, commit-format) |
