/**
 * apexyard gate dispatcher — opencode plugin enforcing apexyard's mechanical
 * governance gates by shelling out to the EXISTING, UNMODIFIED bash hooks
 * under `.claude/hooks/`. Zero logic duplication: every gate's approval
 * decision stays 100% in bash; this file is a thin transport adapter
 * between opencode's `execute.before` tool hook and each hook's
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
 * `Plugin` is imported (type-only) from the real, installed
 * `@opencode/plugin` package, verified against its shipped
 * `dist/promise/plugin.d.ts` rather than documentation alone. This is the
 * same discipline the pi adapter used against
 * `@earendil-works/pi-coding-agent`. Three facts this verification
 * confirmed:
 *
 *   - V2 plugins are a default-exported DEFINITION OBJECT, `{ id, setup }`,
 *     not the V1 `async (input) => hooks` factory. `setup(ctx)` runs at
 *     plugin load and registers each hook on the domain that owns it. This
 *     adapter uses `ctx.tool.hook("execute.before", cb)` for what V1 called
 *     `"tool.execute.before"`.
 *   - The command tool's V2 id is `"shell"`. V1 called it `"bash"`. The
 *     `edit` and `write` tools take their file argument as `path`; V1 used
 *     `filePath`. `derive-gates.ts` accepts both vocabularies. See
 *     `CLAUDE_MATCHER_TO_OPENCODE_TOOLS`'s header comment for why carrying
 *     both is safer than version-probing.
 *   - The hook event is a single mutable object, `{ tool, input, ... }`.
 *     `input` is the tool's own argument object, untyped (`unknown`) in
 *     opencode's own `ToolHooks` interface. This dispatcher reads it
 *     defensively through `derive-gates.ts`'s `buildToolInput`, the same
 *     "return undefined rather than invoke with a garbage payload" contract
 *     the pi adapter uses.
 *
 * Blocking is still done by THROWING inside the hook. opencode has no
 * `{block: true}` return contract the way pi does, and V2's own migration
 * guide shows a throw as the way to deny a tool call.
 */

import { existsSync, readFileSync } from "node:fs";
import { execFileSync } from "node:child_process";
import * as path from "node:path";

import type { Plugin } from "@opencode/plugin";

import {
  buildToolInput,
  claudeToolNameFor,
  deriveGatesFromDispatcher,
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
  sessionId?: string,
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

/**
 * Env for gate hooks and skill shells. Drop an inherited
 * `CLAUDE_CODE_SESSION_ID` so the adapter id decides the marker path
 * (AgDR-0250 precedence; #1783). Claude Code itself still sets that
 * variable — this strip is adapter-only.
 */
export function adapterSessionEnv(sessionId?: string): NodeJS.ProcessEnv {
  const env: NodeJS.ProcessEnv = { ...process.env };
  delete env.CLAUDE_CODE_SESSION_ID;
  const id = sessionId ?? process.env.APEXYARD_SESSION_ID;
  if (id !== undefined) env.APEXYARD_SESSION_ID = id;
  else delete env.APEXYARD_SESSION_ID;
  return env;
}

/** Real subprocess exec — the production `ExecGateHook` implementation. */
export const execGateHookReal: ExecGateHook = (hookPath, stdinPayload, cwd, maxBufferBytes, timeoutMs, sessionId) => {
  try {
    execFileSync("bash", [hookPath], {
      env: adapterSessionEnv(sessionId),
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
  callCwd: string = opsRoot,
): GateHookResult | undefined {
  const hookPath = path.join(opsRoot, gate.hookRelativePath);
  if (!existsSync(hookPath)) return undefined; // gate not present in this fork — no-op, not a failure

  // The top-level `cwd` is what Claude Code and Codex send, and what the bash
  // hooks read first (`dispatch-apply-patch.sh` and
  // `block-protected-target-writes.sh` both prefer `.cwd`). It must be the
  // directory the HOST resolves relative tool paths against, not the ops root:
  // a relative patch/edit target under `workspace/<project>` belongs to that
  // project, which may be a different tree from the ops fork above it.
  const stdinPayload = JSON.stringify({ tool_name: claudeToolName, tool_input: toolInput, cwd: callCwd });
  const { status, stderr, timedOut } = execGateHook(hookPath, stdinPayload, callCwd, maxBufferBytes, timeoutMs);

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
  /** Override ops-root resolution (mainly for tests). Defaults to resolveOpsRootForOpencode against ctx.location.directory. */
  resolveOpsRoot?: (ctx: { directory: string }) => string | undefined;
  /** Path to settings.json relative to the ops root. Defaults to ".claude/settings.json". */
  settingsRelativePath?: string;
  /** Injection point for tests — see ExecGateHook. Defaults to a real `bash <hook>` subprocess spawn. */
  execGateHook?: ExecGateHook;
}

/**
 * The slice of opencode's V2 plugin `Context` this dispatcher uses.
 * Narrowing to this structural shape keeps the unit tests free of a full
 * `@opencode/plugin` `Context`, which is a whole server client. The real
 * `Context` opencode hands `setup` still satisfies it.
 */
export interface GateDispatcherContext {
  readonly location: { readonly directory: string };
  readonly tool: {
    hook(
      name: "execute.before",
      callback: (event: ToolExecuteBeforeEvent) => Promise<void> | void,
    ): Promise<unknown>;
    /** Optional: the host's registered tools, used only for the init-time wiring warnings. */
    list?: () => Promise<ReadonlyArray<{ readonly id: string }>>;
  };
}

/**
 * The V2 `execute.before` event fields this dispatcher reads. Declared
 * structurally rather than imported so the handler can be unit-tested with a
 * small object. The real event also carries `sessionID`, `agent`,
 * `messageID`, and `id`.
 */
export interface ToolExecuteBeforeEvent {
  readonly tool: string;
  readonly sessionID?: string;
  /** The tool's own argument object. Mutable: opencode applies edits made here. */
  readonly input?: unknown;
}

/** V1's two-argument `tool.execute.before` handler shape. */
export type V1ToolExecuteBeforeHandler = (
  input: { tool: string; sessionID?: string },
  output: { args?: Record<string, unknown> },
) => Promise<void>;

/** What V1's `async (input) => hooks` factory returns. */
export interface V1Hooks {
  "tool.execute.before": V1ToolExecuteBeforeHandler;
}

/** V1's plugin input — the subset the dispatcher reads. */
export interface V1PluginInput {
  readonly directory: string;
  readonly worktree?: string;
}

/** One tool call, normalised from either plugin generation's event shape. */
interface NormalisedToolCall {
  readonly tool: string;
  readonly sessionId?: string;
  /** The tool's own argument object, same reference the host will execute. */
  readonly args: Record<string, unknown>;
  /**
   * Directory the host resolves relative tool paths against — V2's
   * `ctx.location.directory`, V1's `input.directory`. Sent as the payload's
   * top-level `cwd` and used as the hook subprocess's working directory.
   */
  readonly cwd?: string;
  /** Plugin generation the call arrived on; V1's edit/write use `filePath` only. */
  readonly generation: "v1" | "v2";
}

/** The opencode tool ids whose `command` argument is a shell command line. */
function isCommandTool(toolId: string): boolean {
  return toolId === "shell" || toolId === "bash";
}

/**
 * Strips a host namespace from a tool id (`acme.edit` -> `edit`). The wiring
 * warning has always normalised this way; the dispatcher now uses the same
 * normalisation, so a namespaced id cannot be reported as routed while every
 * gate misses it.
 */
function normaliseToolId(toolId: string): string {
  const tail = toolId.split(".").pop();
  return tail === undefined || tail === "" ? toolId : tail;
}

/**
 * The directory a hook should run in. The session directory is correct only
 * when it sits inside the ops root: the bash checks locate the ops root by
 * walking up from `$PWD`, so running them from an unrelated directory (the
 * `APEXYARD_OPS_ROOT` override case) makes them exit without enforcing. Fall
 * back to the ops root there — the pre-port behaviour, which cannot fail open.
 */
function resolveHookCwd(opsRoot: string | undefined, directory: string): string {
  if (!opsRoot) return directory;
  const relative = path.relative(opsRoot, directory);
  const inside = relative === "" || (!relative.startsWith("..") && !path.isAbsolute(relative));
  return inside ? directory : opsRoot;
}

/** Single-quotes a value for safe interpolation into a POSIX shell command. */
function shellQuote(value: string): string {
  return "'" + value.replaceAll("'", "'\\''") + "'";
}

/**
 * The single gate cascade both plugin generations share. Returns normally when
 * the call is allowed, throws when a gate blocks it.
 *
 * It also applies the #1783 session-id prefix to command-tool calls. The
 * prefix is written onto the SAME argument object the host will execute, so it
 * reaches the shell for both `(input, output)` and `{ tool, input }` callers.
 * The `unset CLAUDE_CODE_SESSION_ID` line is always emitted, even when no
 * native id is known: otherwise an inherited Claude Code id wins the
 * marker-path resolver, which is exactly the bug #1783 removed. The
 * `export APEXYARD_SESSION_ID=` line is emitted only when an id is known.
 */
async function evaluateToolCall(
  opsRoot: string | undefined,
  gates: GateDefinition[],
  call: NormalisedToolCall,
  execGateHook: ExecGateHook,
): Promise<void> {
  if (!opsRoot) return; // no apexyard fork found on this machine/session — nothing to enforce, fail toward not-blocking
  const { tool: toolId, sessionId, args, cwd, generation } = call;
  const command = args.command;
  const effectiveCwd = cwd ?? opsRoot;
  // opencode can host concurrent sessions. Carry the native id per call.
  const sessionExec: ExecGateHook = (hook, payload, hookCwd, maxBuffer, timeout) =>
    execGateHook(hook, payload, hookCwd, maxBuffer, timeout, sessionId);

  // Run every gate wired to this tool. First hook to block wins — mirrors
  // Claude Code's own PreToolUse semantics, where any matching hook
  // exiting 2 halts the tool call regardless of what other matched hooks
  // would have said.
  for (const gate of gates) {
    if (!gateMatchesToolCall(gate, toolId, typeof command === "string" ? command : undefined)) continue;
    const toolInput = buildToolInput(toolId, { args }, generation);
    if (!toolInput) {
      // An edit or patch call with no target skips every path check silently.
      // If a host renamed the argument, that is a governance hole, not an
      // empty tool call. Block and name the problem rather than allow it.
      if (toolId === "patch" || toolId === "apply_patch") {
        throw new Error(
          `Blocked by apexyard governance gate (${gate.name}): the ${toolId} tool call carried no patch envelope, ` +
            "so its target paths could not be checked.",
        );
      }
      if (toolId === "edit" || toolId === "write") {
        const argument = generation === "v1" ? "filePath" : "path";
        throw new Error(
          `Blocked by apexyard governance gate (${gate.name}): the ${toolId} tool call carried no ${argument}, ` +
            "so its target path could not be checked.",
        );
      }
      continue;
    }
    const claudeToolName = claudeToolNameFor(toolId);
    const result = runGateHook(
      opsRoot,
      gate,
      toolInput,
      claudeToolName,
      sessionExec,
      undefined,
      undefined,
      effectiveCwd,
    );
    if (result?.block) {
      // opencode has no `{block: true}` return contract — throwing inside
      // the execute.before hook is the documented way to deny a tool call.
      throw new Error(result.reason ?? `Blocked by apexyard governance gate (${gate.name})`);
    }
  }

  if (isCommandTool(toolId) && typeof command === "string") {
    const prefix = ["unset CLAUDE_CODE_SESSION_ID"];
    if (sessionId !== undefined) prefix.push(`export APEXYARD_SESSION_ID=${shellQuote(sessionId)}`);
    args.command = `${prefix.join("\n")}\n${command}`;
  }
}

/**
 * Builds the V2 `execute.before` handler for a resolved ops root + gate table.
 * Split out from the default export so tests can drive it directly without
 * importing the real `@opencode/plugin` runtime.
 *
 * V1's two-argument `(input, output)` shape is gone in V2. The hook receives
 * ONE mutable event whose `input` is the tool's own argument object. The
 * cascade itself is shared with `buildToolExecuteBeforeHook` below.
 */
export function buildToolExecuteBeforeHandler(
  opsRoot: string | undefined,
  gates: GateDefinition[],
  execGateHook: ExecGateHook = execGateHookReal,
  cwd?: string,
): (event: ToolExecuteBeforeEvent) => Promise<void> {
  return async (event) => {
    // `input` is `unknown` in the host's type, so narrow it before the cast.
    // A non-object falls back to an empty argument set, as before.
    const rawInput = event.input;
    const args = typeof rawInput === "object" && rawInput !== null ? (rawInput as Record<string, unknown>) : {};
    await evaluateToolCall(
      opsRoot,
      gates,
      {
        tool: normaliseToolId(event.tool),
        sessionId: event.sessionID,
        args,
        cwd,
        generation: "v2",
      },
      execGateHook,
    );
  };
}

/**
 * Builds the V1 `tool.execute.before` handler. Kept because the default
 * export still serves opencode 1.x through its `server()` member: the V1
 * loader calls that instead of `setup()`, and this is what it must return.
 */
export function buildToolExecuteBeforeHook(
  opsRoot: string | undefined,
  gates: GateDefinition[],
  execGateHook: ExecGateHook = execGateHookReal,
  cwd?: string,
): V1ToolExecuteBeforeHandler {
  return async (input, output) => {
    await evaluateToolCall(
      opsRoot,
      gates,
      {
        tool: normaliseToolId(input.tool),
        sessionId: input.sessionID,
        args: output.args ?? {},
        cwd,
        generation: "v1",
      },
      execGateHook,
    );
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
    const dispatcherPath = path.join(opsRoot, ".claude/hooks/dispatch-bash.sh");
    const dispatcher = existsSync(dispatcherPath) ? deriveGatesFromDispatcher(readFileSync(dispatcherPath, "utf-8")) : [];
    const settingsGates = deriveGatesFromSettings(raw).filter((gate) => gate.hookRelativePath !== ".claude/hooks/dispatch-bash.sh");
    const derived = [...settingsGates, ...dispatcher];
    return [...derived, ...patchRoutingGates(opsRoot, derived)];
  } catch (err) {
    process.stderr.write(
      `apexyard gate dispatcher: WARNING — failed to parse ${settingsPath}; NO gates are enforced this session. ` +
        `Underlying error: ${err instanceof Error ? err.message : String(err)}\n`,
    );
    return [];
  }
}

/**
 * Routes opencode's patch-shaped tool through the framework's existing bash
 * patch dispatcher.
 *
 * WHY THIS IS NOT DERIVED FROM settings.json
 * --------------------------------------------
 * `.claude/settings.json` cannot express it. Claude Code and Codex reach
 * `apply_patch` through the wildcard `*` matcher, which runs
 * `dispatch-bash.sh --shell-alias-only`; that flag is what routes
 * `.tool_name == "apply_patch"` onward to `dispatch-apply-patch.sh`. This
 * adapter runs hooks with no arguments, so it cannot reproduce the flag. It
 * calls `dispatch-apply-patch.sh` directly instead, which is the script that
 * actually re-runs every Edit/Write check once per target path.
 *
 * WHY IT MATTERS
 * ----------------
 * V2 ships a `patch` tool that adds, updates, moves, and deletes files under
 * the `edit` permission. Without this wire a `patch` call matched no gate at
 * all: `require-active-ticket`, `block-protected-target-writes`,
 * `require-migration-ticket` and the reviewer-marker guards were all skipped,
 * with no diagnostic. That is the exact silent fail-open this adapter exists
 * to prevent.
 *
 * If the framework's patch dispatcher is absent (an older ops fork), no wire
 * is added. `findUnsupportedGateWires` cannot see a tool with no wire, so
 * callers get the loud init-time warning from `warnOnWiringGaps` instead.
 */
function patchRoutingGates(opsRoot: string, existing: GateDefinition[]): GateDefinition[] {
  const patchDispatcher = path.join(opsRoot, ".claude/hooks/dispatch-apply-patch.sh");
  if (!existsSync(patchDispatcher)) return [];
  // A fork may already wire this hook in settings.json. Only skip when it is
  // wired for the patch tools themselves: an edit-only wiring of the same
  // script would otherwise drop the `patch` wire entirely.
  const patchWired = existing.some(
    (gate) =>
      gate.hookRelativePath === ".claude/hooks/dispatch-apply-patch.sh" &&
      gate.wires.some((wire) => wire.tool === "patch" || wire.tool === "apply_patch"),
  );
  if (patchWired) return [];
  return [
    {
      name: "apply-patch",
      hookRelativePath: ".claude/hooks/dispatch-apply-patch.sh",
      wires: [
        { tool: "patch", commandGlob: null },
        { tool: "apply_patch", commandGlob: null },
      ],
    },
  ];
}

/**
 * Resolves the ops root, derives the gate table, and registers the dispatcher
 * on opencode's V2 `ctx.tool` domain. This is what the default export's
 * `setup` calls.
 *
 * Ops-root resolution and gate derivation both happen ONCE here, at plugin
 * init, not per tool call. opencode's plugin lifecycle hands the plugin its
 * location (`ctx.location.directory`) once at load. V2's `ctx.location`
 * describes the location where this plugin instance loaded, not every
 * session it may later observe, so a per-call re-resolution would be
 * guesswork rather than freshness. See `resolve-ops-root.ts`'s header
 * comment for how this differs from the pi adapter.
 */
export async function registerGateDispatcher(ctx: GateDispatcherContext, options: DispatcherOptions = {}): Promise<void> {
  const resolve = options.resolveOpsRoot ?? ((c) => resolveOpsRootForOpencode({ startCwd: c.directory }));
  const opsRoot = resolve({ directory: ctx.location.directory });

  const gates =
    options.gates ?? (opsRoot ? deriveGatesFromOpsRoot(opsRoot, options.settingsRelativePath ?? ".claude/settings.json") : []);

  // Register the hook FIRST. The wiring warnings below are advisory, and a
  // host that throws while enumerating tools must never leave the session
  // with a registered nothing.
  await ctx.tool.hook(
    "execute.before",
    buildToolExecuteBeforeHandler(
      opsRoot,
      gates,
      options.execGateHook,
      resolveHookCwd(opsRoot, ctx.location.directory),
    ),
  );
  warnOnWiringGaps(ctx, gates);
}

/**
 * The V2 tool ids that write files. If one of these is registered by the host
 * and no gate wire matches it, the call would run ungoverned with nothing
 * reported anywhere.
 */
const EDIT_CLASS_TOOL_IDS = new Set(["edit", "write", "multiedit", "notebookedit", "patch", "apply_patch"]);

/**
 * Warns once at init about two distinct wiring gaps (#840 C2, plus the hole
 * behind the V2 `patch` finding on #1959).
 *
 * The first is a wire this adapter cannot build stdin for. The second is a
 * file-writing tool the HOST registers but the gate table never mentions. The
 * second cannot be found by walking the table, which is why it needs the
 * host's own tool list. Without it, a future rename of `edit`/`patch` would
 * reproduce a silent fail-open with no diagnostic.
 */
function warnOnWiringGaps(ctx: GateDispatcherContext, gates: GateDefinition[]): void {
  // #840 C2: a gate wired to a tool this adapter has no stdin builder for
  // (today: read/glob/grep). A future blocking gate on those tools would
  // otherwise be silently skipped on every matching call.
  const unsupported = findUnsupportedGateWires(gates);
  for (const gap of unsupported) {
    process.stderr.write(
      `apexyard gate dispatcher: WARNING — gate "${gap.gateName}" is wired to opencode tool "${gap.tool}", ` +
        `which this adapter has no stdin builder for (buildToolInput supports shell/bash/edit/write/patch). This gate is SILENTLY SKIPPED ` +
        `for "${gap.tool}" tool calls — it never runs, so it can never block one. See derive-gates.ts's findUnsupportedGateWires for details.\n`,
    );
  }

  // A file-writing host tool with no wire cannot be found by walking the gate
  // table, so ask the host which tools it registers.
  const list = ctx.tool.list;
  if (typeof list !== "function") return;
  try {
    void list
      .call(ctx.tool)
      .then((tools) => {
        const routed = new Set(gates.flatMap((gate) => gate.wires.map((wire) => wire.tool)));
        for (const tool of tools) {
          const id = normaliseToolId(tool.id);
          if (!EDIT_CLASS_TOOL_IDS.has(id) || routed.has(id)) continue;
          process.stderr.write(
            `apexyard gate dispatcher: WARNING — opencode registers the file-writing tool "${id}", but no gate is wired to it. ` +
              `Every gate wired to edit/write is SILENTLY SKIPPED for "${id}" calls. See derive-gates.ts's patch/apply_patch mapping and ` +
              `gate-dispatcher.ts's patchRoutingGates.\n`,
          );
        }
      })
      .catch(() => {
        // A host that cannot enumerate tools is not a governance failure; the
        // rest of setup must not depend on it.
      });
  } catch {
    // Same reasoning for a synchronous throw out of the host's list().
  }
}

/**
 * Resolves the ops root + gate table for one V1 plugin instance. V1 calls the
 * plugin factory once per session, so this mirrors `registerGateDispatcher`.
 */
export function createV1Hooks(input: V1PluginInput, options: DispatcherOptions = {}): V1Hooks {
  const resolve = options.resolveOpsRoot ?? ((c) => resolveOpsRootForOpencode({ startCwd: c.directory }));
  const opsRoot = resolve({ directory: input.directory });
  const gates =
    options.gates ?? (opsRoot ? deriveGatesFromOpsRoot(opsRoot, options.settingsRelativePath ?? ".claude/settings.json") : []);
  for (const gap of findUnsupportedGateWires(gates)) {
    process.stderr.write(
      `apexyard gate dispatcher: WARNING — gate "${gap.gateName}" is wired to opencode tool "${gap.tool}", ` +
        `which this adapter has no stdin builder for. This gate is SILENTLY SKIPPED for "${gap.tool}" tool calls.\n`,
    );
  }
  return {
    "tool.execute.before": buildToolExecuteBeforeHook(
      opsRoot,
      gates,
      options.execGateHook,
      resolveHookCwd(opsRoot, input.directory),
    ),
  };
}

/**
 * V2 plugin definition plus the V1 `server()` member.
 *
 * opencode 2.x validates the default export against `{ id, setup }` (or
 * `{ id, effect }`) and ignores extra members. opencode 1.3.4+ accepts an
 * object entrypoint and calls `server()` (1.3.3 and earlier require a
 * factory function and fail with "fn3 is not a function"). One file therefore
 * serves both generations, which is the vendor's own documented migration
 * shape.
 *
 * The object is written literally rather than as
 * `{ ...Plugin.define({ id, setup }), server }` on purpose: `Plugin.define`
 * is an identity function, and importing `@opencode/plugin` at runtime would
 * make the file unloadable on opencode 1.x, where that package does not
 * exist. `import type` is erased, so the V1 path stays dependency-free.
 */
type DualPlugin = Plugin.Plugin & { server: (input: V1PluginInput) => Promise<V1Hooks> };

const apexyardGateDispatcher: DualPlugin = {
  id: "apexyard.gates",
  setup: (ctx) => registerGateDispatcher(ctx),
  server: (input) => Promise.resolve(createV1Hooks(input)),
};

export default apexyardGateDispatcher;
export { apexyardGateDispatcher };
