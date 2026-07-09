/**
 * apexyard-gate-dispatcher — opencode plugin enforcing apexyard's mechanical
 * governance gates by shelling out to the EXISTING, UNMODIFIED bash hooks
 * under `.claude/hooks/`. Zero logic duplication: every gate's approval
 * decision stays 100% in bash; this file is a thin transport adapter
 * between opencode's `tool.execute.before` event and each hook's
 * stdin/exit-code contract.
 *
 * PROMOTED FROM SPIKE #816 (VIABLE). The spike proved the PATTERN fully
 * live: a real, model-driven opencode turn attempting `gh pr merge` was
 * blocked by the unmodified `block-unreviewed-merge.sh`, with a negative
 * control — corrupting the plugin — proving the block came from the
 * plugin, not opencode itself. IMPORTANT HEDGE (#840 C4, matching
 * AgDR-0092's own "Consequences" section): that live run was against the
 * spike's throwaway single-gate prototype plugin, NOT this shipped,
 * settings.json-derived dispatcher. This file is proven-by-construction
 * against opencode's documented/typed contract (real types, a real
 * subprocess exec, a real hook, and `test/smoke-block-unreviewed-merge.sh`'s
 * fixture-ops-root proof) — the one hop still resting on the spike's
 * earlier live run, not a fresh one against this code, is "does opencode's
 * own internal event dispatch call this handler the documented way during
 * a live, model-driven agent turn." See
 * docs/agdr/AgDR-0092-opencode-gate-adapter.md for the full decision and
 * its honest breakdown, and docs/opencode-adapter.md for install + usage.
 *
 * SAME PATTERN AS THE PI ADAPTER, ONE UPGRADE
 * ----------------------------------------------
 * This mirrors `harness-adapters/pi/src/gate-dispatcher.ts` in every load-
 * bearing way: one dispatcher extension, one event registration, hooks run
 * as real subprocesses with the Claude-Code-shaped stdin JSON they already
 * parse, exit code 2 maps to a block. The one structural difference is the
 * gate table itself: rather than a hand-maintained `DEFAULT_GATES` array,
 * `src/derive-gates.ts` parses `.claude/settings.json` directly — see that
 * file's header comment for the full rationale (the #730 convergence Tariq
 * asked for). The pi adapter is NOT modified by this change; it should
 * converge to the same derive-from-settings.json pattern in a follow-up,
 * not as part of this PR.
 *
 * REAL OPENCODE TYPES, NOT GUESSES
 * -----------------------------------
 * `Plugin`, `PluginInput`, `Hooks` are imported (type-only) from the real,
 * installed `@opencode-ai/plugin` package (verified against its shipped
 * `dist/index.d.ts`, not documentation alone — same discipline the pi
 * adapter used against `@earendil-works/pi-coding-agent`). Two facts this
 * verification confirmed, matching the ticket's stated ACs:
 *
 *   - `input.tool === "bash"` and `output.args.command` for the bash tool
 *     (opencode's bash tool is internally implemented in `shell.ts`, but
 *     its registered tool id — the value `tool.execute.before`'s `input.tool`
 *     carries — is literally `"bash"`, kept for plugin backwards
 *     compatibility per opencode's own source comment).
 *   - Blocking is done by THROWING inside the `"tool.execute.before"`
 *     handler — opencode has no `{block: true}` return contract the way pi
 *     does. `output.args` is untyped (`any`) in opencode's own `Hooks`
 *     interface, so this dispatcher reads `output.args.command` /
 *     `output.args.filePath` defensively (see `derive-gates.ts`'s
 *     `buildToolInput`), the same "return undefined rather than invoke with
 *     a garbage payload" contract the pi adapter uses.
 */

import { existsSync, readFileSync } from "node:fs";
import { execFileSync } from "node:child_process";
import * as path from "node:path";

import type { Hooks, Plugin } from "@opencode-ai/plugin";

import {
  buildToolInput,
  claudeToolNameFor,
  deriveGatesFromSettings,
  findUnsupportedGateWires,
  gateMatchesToolCall,
  type GateDefinition,
  type RawSettings,
} from "./derive-gates.ts";
import { resolveOpsRootForOpencode } from "./resolve-ops-root.ts";

export interface GateHookResult {
  block: boolean;
  reason?: string;
}

/** Injection point for tests — swap the real subprocess exec for a mock (per #821's "mock the exec" test requirement). */
export type ExecGateHook = (
  hookPath: string,
  stdinPayload: string,
  cwd: string,
  maxBufferBytes: number,
  timeoutMs: number,
) => { status: number | null; stderr: string; timedOut?: boolean };

/**
 * Ceiling for the hook subprocess's stdout+stderr buffers — identical
 * rationale and value to the pi adapter's `MAX_HOOK_OUTPUT_BYTES`: normal
 * gate hook output is a few KB at most; 10 MB is generous headroom.
 */
export const MAX_HOOK_OUTPUT_BYTES = 10 * 1024 * 1024;

/**
 * Ceiling for a single gate hook's wall-clock execution (#840 C1) — same
 * value and rationale as the pi adapter's `HOOK_EXEC_TIMEOUT_MS`: every
 * gate hook today is a fast local check, so 30s is generous headroom for a
 * legitimate run while still bounding a hung subprocess from blocking every
 * subsequent tool call in the session indefinitely.
 */
export const HOOK_EXEC_TIMEOUT_MS = 30_000;

/** Real subprocess exec — the production `ExecGateHook` implementation. */
export const execGateHookReal: ExecGateHook = (hookPath, stdinPayload, cwd, maxBufferBytes, timeoutMs) => {
  try {
    execFileSync("bash", [hookPath], {
      input: stdinPayload,
      cwd,
      encoding: "utf-8",
      stdio: ["pipe", "pipe", "pipe"],
      maxBuffer: maxBufferBytes,
      timeout: timeoutMs,
      killSignal: "SIGKILL",
    });
    return { status: 0, stderr: "" };
  } catch (err) {
    const execErr = err as { status?: number | null; stderr?: Buffer | string; message?: string; code?: string };
    return {
      status: typeof execErr.status === "number" ? execErr.status : null,
      stderr: execErr.stderr ? execErr.stderr.toString() : String(execErr.message ?? err),
      // Node's `code` distinguishes a timeout kill ("ETIMEDOUT") from a
      // maxBuffer overflow ("ENOBUFS") even though both share the same
      // killSignal — `.signal` alone can't tell them apart, since both
      // paths kill the child the same way.
      timedOut: execErr.code === "ETIMEDOUT",
    };
  }
};

/**
 * Runs a single gate hook with the reconstructed Claude-Code-shaped stdin
 * payload, mapping its exit code to a block/allow decision per the
 * proven-in-spike contract: exit 2 = block, everything else = allow —
 * EXCEPT an execution-layer failure (no numeric exit status at all: spawn
 * error, ENOBUFS from output exceeding `maxBufferBytes`, signal kill),
 * which fails CLOSED, not open, mirroring the pi adapter's fix for the
 * same Rex finding (PR #817): a hook that could not even run its check
 * must deny, not silently permit the tool call it was supposed to be
 * gating.
 *
 *   - exit code 2                       → BLOCK (the hook's own verdict)
 *   - exit code 0 (or any other
 *     *numeric* non-2 exit code)        → ALLOW (matches Claude Code's own
 *                                          PreToolUse semantics: only exit 2
 *                                          is a hard stop)
 *   - NO numeric exit status at all     → BLOCK, fail closed, naming the
 *                                          hook and the underlying error
 *
 * BOUNDED TIMEOUT, SAME FAIL-CLOSED PATH (#840 C1). `execGateHook` is given
 * `timeoutMs` (default `HOOK_EXEC_TIMEOUT_MS`, 30s). A hook that exceeds it
 * is killed before it produces a numeric exit status, so it lands in the
 * same "NO numeric exit status" branch below as a spawn failure or ENOBUFS
 * — a hung hook fails closed, not open, and never blocks the dispatcher
 * indefinitely.
 */
export function runGateHook(
  opsRoot: string,
  gate: GateDefinition,
  toolInput: Record<string, unknown>,
  claudeToolName: string,
  execGateHook: ExecGateHook = execGateHookReal,
  maxBufferBytes: number = MAX_HOOK_OUTPUT_BYTES,
  timeoutMs: number = HOOK_EXEC_TIMEOUT_MS,
): GateHookResult | undefined {
  const hookPath = path.join(opsRoot, gate.hookRelativePath);
  if (!existsSync(hookPath)) return undefined; // gate not present in this fork — no-op, not a failure

  const stdinPayload = JSON.stringify({ tool_name: claudeToolName, tool_input: toolInput });
  const { status, stderr, timedOut } = execGateHook(hookPath, stdinPayload, opsRoot, maxBufferBytes, timeoutMs);

  if (status === 2) {
    return { block: true, reason: stderr.trim() || `Blocked by apexyard governance gate (${gate.name})` };
  }
  if (typeof status === "number") {
    return undefined; // exit 0, or an unrelated non-2 numeric exit — allow, matching Claude Code's own contract
  }
  const reasonPrefix = timedOut
    ? `apexyard governance gate "${gate.name}" timed out after ${timeoutMs}ms (${hookPath}) — failing closed.`
    : `apexyard governance gate "${gate.name}" could not be evaluated (${hookPath}) — failing closed.`;
  return {
    block: true,
    reason: `${reasonPrefix} Underlying error: ${stderr.trim() || "unknown execution failure"}`,
  };
}

export interface DispatcherOptions {
  /** Override the derived gate table (mainly for tests — production always derives from settings.json). */
  gates?: GateDefinition[];
  /** Override ops-root resolution (mainly for tests). Defaults to resolveOpsRootForOpencode against PluginInput.directory. */
  resolveOpsRoot?: (ctx: { directory: string; worktree: string }) => string | undefined;
  /** Path to settings.json relative to the ops root. Defaults to ".claude/settings.json". */
  settingsRelativePath?: string;
  /** Injection point for tests — see ExecGateHook. Defaults to a real `bash <hook>` subprocess spawn. */
  execGateHook?: ExecGateHook;
}

/**
 * Builds the `"tool.execute.before"` handler for a resolved ops root +
 * gate table. Split out from `apexyardGateDispatcher` (the plugin's default
 * export) so tests can drive it directly without importing the real
 * `@opencode-ai/plugin` runtime — mirrors the pi adapter's
 * `registerGateDispatcher` / default-export split.
 */
export function buildToolExecuteBeforeHook(
  opsRoot: string | undefined,
  gates: GateDefinition[],
  execGateHook: ExecGateHook = execGateHookReal,
): NonNullable<Hooks["tool.execute.before"]> {
  return async (input, output) => {
    if (!opsRoot) return; // no apexyard fork found on this machine/session — nothing to enforce, fail toward not-blocking
    const toolId = input.tool;
    const command = (output.args as Record<string, unknown> | undefined)?.command;

    // Run every gate wired to this tool. First hook to block wins — mirrors
    // Claude Code's own PreToolUse semantics, where any matching hook
    // exiting 2 halts the tool call regardless of what other matched hooks
    // would have said.
    for (const gate of gates) {
      if (!gateMatchesToolCall(gate, toolId, typeof command === "string" ? command : undefined)) continue;
      const toolInput = buildToolInput(toolId, output);
      if (!toolInput) continue;
      const claudeToolName = claudeToolNameFor(toolId);
      const result = runGateHook(opsRoot, gate, toolInput, claudeToolName, execGateHook);
      if (result?.block) {
        // opencode has no `{block: true}` return contract — throwing inside
        // "tool.execute.before" is the documented way to deny a tool call.
        throw new Error(result.reason ?? `Blocked by apexyard governance gate (${gate.name})`);
      }
    }
  };
}

/**
 * Reads and parses `.claude/settings.json` from the resolved ops root. On
 * any failure (missing file, unparsable JSON) returns an empty gate table
 * rather than throwing — a broken settings.json should not brick every
 * tool call in the session; it should just mean no gates are enforced,
 * loudly visible as "governance isn't wired" rather than a plugin crash.
 *
 * #840 C3: that "loudly visible" claim used to be aspirational — the catch
 * block was a bare `catch { return []; }` with no output at all, so a
 * malformed `.claude/settings.json` produced total, silent, fail-open
 * governance with nothing anywhere hinting why (Rex + Hakim both flagged
 * this on #839). The warning below is what makes the comment's claim true:
 * a parse failure is now a visible stderr line naming the settings path
 * and the underlying error, not a quiet `[]`.
 *
 * A missing settings.json (no file at all — the far more common case, e.g.
 * an ops root that predates this framework version, or a session launched
 * outside any apexyard fork) stays silent-`[]` on purpose: that's the
 * expected "nothing to enforce here" case, not a broken-config case, and
 * warning on it would just be noise for every non-apexyard opencode
 * session using this plugin.
 */
export function deriveGatesFromOpsRoot(opsRoot: string, settingsRelativePath: string): GateDefinition[] {
  const settingsPath = path.join(opsRoot, settingsRelativePath);
  if (!existsSync(settingsPath)) return [];
  try {
    const raw = JSON.parse(readFileSync(settingsPath, "utf-8")) as RawSettings;
    return deriveGatesFromSettings(raw);
  } catch (err) {
    process.stderr.write(
      `apexyard-gate-dispatcher: WARNING — failed to parse ${settingsPath}; NO gates are enforced this session. ` +
        `Underlying error: ${err instanceof Error ? err.message : String(err)}\n`,
    );
    return [];
  }
}

/**
 * Builds the full `Hooks` object for a given opencode `PluginInput`. This
 * is what both the default export and a custom extension entry point call.
 * Ops-root resolution and gate derivation both happen ONCE here, at plugin
 * init — not per tool call — because opencode's plugin lifecycle hands
 * `directory`/`worktree` once and doesn't offer a fresher cwd on
 * subsequent events (see `resolve-ops-root.ts`'s header comment for why
 * this differs from the pi adapter's per-call resolution).
 */
export function registerGateDispatcher(pluginInput: { directory: string; worktree: string }, options: DispatcherOptions = {}): Hooks {
  const resolve = options.resolveOpsRoot ?? ((ctx) => resolveOpsRootForOpencode({ startCwd: ctx.directory }));
  const opsRoot = resolve({ directory: pluginInput.directory, worktree: pluginInput.worktree });

  const gates =
    options.gates ?? (opsRoot ? deriveGatesFromOpsRoot(opsRoot, options.settingsRelativePath ?? ".claude/settings.json") : []);

  // #840 C2: warn loudly, once at init, about any gate wired to a tool this
  // adapter has no stdin builder for (today: read/glob/grep — see
  // findUnsupportedGateWires's header comment for why this doesn't attempt
  // to guess field names instead). A future blocking gate on those tools
  // would otherwise be silently skipped on every matching call with no
  // signal anywhere that it never actually ran.
  for (const unsupported of findUnsupportedGateWires(gates)) {
    process.stderr.write(
      `apexyard-gate-dispatcher: WARNING — gate "${unsupported.gateName}" is wired to opencode tool "${unsupported.tool}", ` +
        `which this adapter has no stdin builder for (buildToolInput only supports bash/edit/write). This gate is SILENTLY SKIPPED ` +
        `for "${unsupported.tool}" tool calls — it never runs, so it can never block one. See derive-gates.ts's findUnsupportedGateWires for details.\n`,
    );
  }

  return {
    "tool.execute.before": buildToolExecuteBeforeHook(opsRoot, gates, options.execGateHook),
  };
}

/** Default export — what opencode's `.opencode/plugin/*.ts` auto-discovery (or an explicit `plugin` config entry) loads. */
const apexyardGateDispatcher: Plugin = async (input) => registerGateDispatcher(input);

export default apexyardGateDispatcher;
export { apexyardGateDispatcher };
