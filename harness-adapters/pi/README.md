# apexyard pi Gate Adapter

Enforces apexyard's mechanical governance gates inside [pi](https://pi.dev) (Earendil's agent CLI) by shelling out to the **existing, unmodified** bash hooks under `.claude/hooks/` — zero logic duplication. The bash hooks stay the single source of truth for every gate's approval decision; this package is a thin transport adapter between pi's `tool_call` event and each hook's stdin/exit-code contract.

Promoted from spike [me2resh/apexyard#804](https://github.com/me2resh/apexyard/issues/804) (verdict: VIABLE). See `docs/agdr/AgDR-0082-pi-gate-dispatcher-adapter.md` for the design decision and `docs/spike-reports/pi-gate-extension.md` for the spike's own findings.

## What this enforces

The dispatcher (`src/gate-dispatcher.ts`) wires the following gates by default. **This is a curated subset, not the full list** `.claude/settings.json` wires for Claude Code's `PreToolUse` hooks — every gate below was checked against its own `jq` stdin parsing (all use the identical `.tool_input.command` shape `block-unreviewed-merge.sh` uses) and included because it's a blocking (exit-2) governance gate covering #815's named acceptance criteria (merge gate, red-CI, design/architecture review, ticket-first, secrets) plus leak protection:

| Gate | Hook | pi tool(s) checked |
|------|------|---------------------|
| Unreviewed merge (Rex + CEO markers) | `block-unreviewed-merge.sh` | `bash` |
| Red CI block | `block-merge-on-red-ci.sh` | `bash` |
| Design review required for UI PRs | `require-design-review-for-ui.sh` | `bash` |
| Architecture review required for design-artifact PRs | `require-architecture-review.sh` | `bash` |
| Secrets scanning | `check-secrets.sh` | `bash` |
| `git add -A` / `git add .` block | `block-git-add-all.sh` | `bash` |
| Direct push to `main` block | `block-main-push.sh` | `bash` |
| Leak protection (private project refs on public repos) | `block-private-refs-in-public-repos.sh` | `bash` |
| Ticket-first (an active ticket required before edits) | `require-active-ticket.sh` | `edit`, `write`, `bash` |
| Migration-ticket-first | `require-migration-ticket.sh` | `edit`, `write` |

### Known NOT-yet-bridged gates

`.claude/settings.json` also wires these blocking Bash-matcher `PreToolUse` hooks, which are **not** in `DEFAULT_GATES` yet. Each one uses the exact same `.tool_input.command` stdin shape as everything above, so bridging them is a table-row addition, not new adapter logic — they were deferred to keep this first pass scoped to #815's named acceptance criteria, not left out because of a technical blocker:

| Hook | Fires on | Why deferred |
|------|----------|--------------|
| `validate-branch-name.sh` | `git branch` / `git checkout -b` | Same shape as everything bridged; out of #815's named scope |
| `validate-commit-format.sh` | `git commit` | Same shape; out of #815's named scope |
| `verify-commit-refs.sh` | `git commit` | Same shape; out of #815's named scope |
| `validate-pr-create.sh` | `gh pr create` | Same shape; out of #815's named scope |
| `require-agdr-for-arch-pr.sh` | `gh pr create` | Same shape; out of #815's named scope |
| `require-skill-for-issue-create.sh` | `gh issue create` / equivalent | Same shape; out of #815's named scope |
| `block-onboarding-in-git.sh` | `git add` of `onboarding.yaml` | Same shape; out of #815's named scope |

If you rely on any of these under pi today, add them to your own `gates` array (see "Customizing the gate table" below) — they'll work with `bashCommandInput` unchanged.

Extend or trim `DEFAULT_GATES` by passing a custom `gates` array to `registerGateDispatcher()` — see "Customizing the gate table" below.

## Install

```bash
cd harness-adapters/pi
npm install       # pulls in @earendil-works/pi-coding-agent (real pi types + runtime)
```

Then load the extension in a pi session pointed at your apexyard ops fork:

```bash
pi --extension harness-adapters/pi/src/gate-dispatcher.ts
```

Or install it as a project-local extension pi auto-discovers (`.pi/extensions/*.ts` in the project pi is running in):

```bash
mkdir -p .pi/extensions
cp harness-adapters/pi/src/gate-dispatcher.ts .pi/extensions/apexyard-gate-dispatcher.ts
cp harness-adapters/pi/src/resolve-ops-root.ts .pi/extensions/resolve-ops-root.ts
```

(pi loads extensions via `jiti` with no compile step — plain `.ts`, no build pipeline, matching the bash hooks' own "just a script" simplicity.)

## How ops-root resolution works

Every gate hook needs to find the apexyard ops fork (where `.claude/session/reviews/*.approved` markers live) regardless of pi's current working directory. Claude Code resolves this via `_lib-ops-root.sh`, which layers a SessionStart-written pin on top of a directory walk-up. pi has no session-pin equivalent, so this adapter:

1. **Honors an explicit `APEXYARD_OPS_ROOT` environment variable** if set and valid (recommended when running pi from a directory that isn't the ops fork's own working tree — e.g. a project workspace clone).
2. **Falls back to a walk-up** from `ctx.cwd`, looking for the same anchor apexyard's bash hooks recognise: a `.apexyard-fork` marker file, or the legacy `onboarding.yaml` + `apexyard.projects.yaml` pair.

If neither resolves, the dispatcher is a silent no-op for that tool call — it fails toward **not enforcing**, never toward **false-blocking** a legitimate tool call it can't evaluate.

See `src/resolve-ops-root.ts` and AgDR-0082 for the full rationale, including the one safety property Claude Code's session pin provides that this adapter does NOT (protection against a pi session accidentally resolving to an unrelated ops-fork-shaped directory tree, e.g. a throwaway clone).

## Customizing the gate table

```ts
import { registerGateDispatcher, DEFAULT_GATES, type GateDefinition } from "./src/gate-dispatcher.ts";

const myGates: GateDefinition[] = [
  ...DEFAULT_GATES,
  {
    name: "my-custom-gate",
    hookRelativePath: ".claude/hooks/my-custom-gate.sh",
    toolNames: ["bash"],
    buildToolInput: (event) => (event.toolName === "bash" ? { command: event.input.command } : undefined),
  },
];

export default function myExtension(pi) {
  registerGateDispatcher(pi, { gates: myGates });
}
```

## Testing

```bash
# hermetic — isolated fixture ops roots, no gh calls, no real pi package needed
node --test test/gate-dispatcher.test.ts

# + LIVE cases against this repo's real block-unreviewed-merge.sh and real gh state
APEXYARD_TEST_REPO_ROOT="$(pwd)/.." ALLOW_TEST_PR=<pr-with-real-rex+ceo-markers> node --test test/gate-dispatcher.test.ts
```

`npm run typecheck` runs `tsc --noEmit` against the real `@earendil-works/pi-coding-agent` types — this is what verifies the adapter's field-name assumptions (e.g. `event.input.path` for edit/write, `event.input.command` for bash) against pi's actual, installed `.d.ts` rather than against documentation alone.

## Known gaps / what's unverified

This build (me2resh/apexyard#815) closed most of the gaps the spike flagged, but one remains — and it's the one that matters most for a production merge gate:

- **Verified against pi's real, installed `.d.ts`**: the exact shape of `ToolCallEvent`, `ToolCallEventResult`, `ExtensionAPI`, and the edit/write tools' `path` field name (not `file_path`) — this is now typechecked (`npm run typecheck`), not guessed.
- **Verified live, against the real bash hook + real GitHub state**: the full stdin-reconstruction → hook-exec → exit-code-mapping path, using a synthetic `tool_call` event that mocks only pi's `ExtensionAPI.on()` registration call (see `test/gate-dispatcher.test.ts`'s "LIVE" cases, run against real PR #767's real Rex+CEO markers and a real nonexistent-PR block).
- **NOT verified** (and could not be verified in the environment this was built in — no pi model credentials available): that a real, model-driven pi agent turn actually invokes `tool_call` handlers with events matching this contract when the model itself calls the `bash`/`edit`/`write` tools. This is a transport-fidelity assumption inherited from spike #804's own "proven by construction, not proven live" finding for the same reason — it needs a live model API key this environment doesn't have. Once available, the correct test is: run a real pi session with this extension loaded, prompt a model turn that attempts an ungated `gh pr merge`, and confirm the tool call is refused with the hook's block reason surfaced to the model.
- **The pi-flavored ops-root override (`APEXYARD_OPS_ROOT`) has no equivalent to Claude Code's session-pin protection** against resolving to an unrelated ops-fork-shaped directory tree (see "How ops-root resolution works" above and AgDR-0082).
- **`check-secrets.sh` scans `git diff --cached` relative to `cwd: opsRoot`, with no additional cd-resolution.** If a pi session is launched from inside a nested or otherwise different git repo than the intended one, the secrets scan runs against the *ops fork's* staged diff, not the repo the operator actually meant to scan. This mirrors an equivalent limitation Claude Code already has (the hook resolves the same way there), so it's not a regression introduced by this adapter — noted here for completeness, no code change made.
- **Gate execution failures fail CLOSED, not open** (fixed in this build after a Rex finding on PR #817): if a hook can't produce a numeric exit status at all — a spawn failure, output exceeding the 10 MB `maxBuffer` ceiling, a signal kill — the dispatcher now BLOCKS with a reason naming the hook and the underlying error, rather than silently allowing the tool call through. Only a genuine hook exit code of 0 (or a numeric non-2 exit code) allows the call; exit code 2 blocks with the hook's own reason. See `src/gate-dispatcher.ts`'s `runGateHook` doc comment for the full semantics and `test/gate-dispatcher.test.ts`'s "FAILS CLOSED" test.

## Glossary

| Term | Definition |
|------|------------|
| pi | pi.dev — Earendil's minimal, unopinionated agent CLI with a TypeScript extension system |
| adapter-over-bash | A thin per-harness extension that invokes apexyard's existing bash gate hooks rather than reimplementing the gate logic natively |
| `tool_call` event | pi's pre-execution lifecycle event; extensions registered via `pi.on("tool_call", handler)` can block or allow a tool invocation before it runs |
| ops root | The apexyard fork's root directory, where `.claude/session/reviews/*.approved` markers and `.claude/hooks/*.sh` live |
| dispatcher | A single extension that checks a tool call against a table of gate definitions, rather than one extension per gate |
| proven live | Observed directly against the real running system (real bash hook, real `gh` calls) |
| proven by construction | Demonstrated via a mock built to match the documented/typed contract, not observed inside a live pi agent turn |
