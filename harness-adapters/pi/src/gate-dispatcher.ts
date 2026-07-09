/**
 * apexyard-gate-dispatcher — pi extension enforcing apexyard's mechanical
 * governance gates by shelling out to the EXISTING, UNMODIFIED bash hooks
 * under `.claude/hooks/`. Zero logic duplication: every gate's approval
 * decision stays 100% in bash; this file is a thin transport adapter
 * between pi's `tool_call` event and each hook's stdin/exit-code contract.
 *
 * PROMOTED FROM SPIKE #804 (VIABLE) — see
 * docs/spike-reports/GH-804-pi-gate-extension/apexyard-merge-gate.ts and
 * docs/spike-reports/pi-gate-extension.md for the proof. This file
 * generalizes that single-hook prototype into a DISPATCHER that wires N
 * gates from one config table, per the spike's own "named gaps" section
 * (item 4: "multiple gates = multiple registrations (or one dispatcher)").
 *
 * See docs/agdr/AgDR-0082-pi-gate-dispatcher-adapter.md for the original
 * dispatcher design decision (and its "Update (GH-840)" section for what
 * changed below) and docs/harnesses/pi.md for install + usage docs.
 *
 * #840 C5 — SETTINGS.JSON-DERIVED GATE TABLE, NOT HAND-MAINTAINED
 * ---------------------------------------------------------------------
 * This dispatcher originally shipped with a hand-written `DEFAULT_GATES`
 * table (a curated subset of `.claude/settings.json`'s hooks). It now
 * derives the FULL gate table from `.claude/settings.json` via
 * `./derive-gates.ts`, converging to the same pattern the opencode adapter
 * established (AgDR-0092) — see `derive-gates.ts`'s header comment for the
 * shared-core design and the pi-specific tool-vocabulary translation
 * (`Glob` → pi's `find`; no stdin builder for `read`/`grep`/`find`/`ls`,
 * mirroring opencode's #840 C2 "fail loud, don't guess" decision).
 *
 * One structural difference from the opencode adapter, kept unchanged from
 * before this refactor: pi resolves the ops root — and, as of this
 * refactor, derives the gate table — PER `tool_call` EVENT, not once at
 * registration. Pi hands the dispatcher a fresh `ctx.cwd` on every event
 * (AgDR-0082's original design rationale); opencode's plugin function is
 * called once per session with no fresher cwd offered afterward
 * (AgDR-0092). Re-deriving per call means a live edit to
 * `.claude/settings.json` mid-session is picked up on the very next tool
 * call — genuinely more correct than a cache would be — at the cost of one
 * extra JSON parse per call, negligible next to the subprocess spawn(s)
 * that follow. The "unsupported gate wire" warning (mirroring opencode's
 * #840 C2) is deliberately DEDUPED per (opsRoot, gate, tool) rather than
 * re-emitted every call, so a `suggest-mcp-search.sh`-shaped read/find/grep
 * gate doesn't print a warning before every single read in a session — see
 * `warnUnsupportedGateWiresOnce` below.
 *
 * REAL PI TYPES, NOT SPIKE GUESSES
 * ---------------------------------
 * The spike's throwaway prototype hand-rolled a structural ExtensionAPI
 * shim (it didn't want a hard npm dependency for a throwaway file). This
 * shipped adapter imports the REAL types from
 * `@earendil-works/pi-coding-agent`, and two spike assumptions turned out
 * to need correcting once checked against the real `.d.ts`:
 *
 *   - The block-decision type is `ToolCallEventResult` ({block, reason}),
 *     not `ToolCallResult` (the spike's own invented name for the same
 *     shape).
 *   - `event.input` is NOT a generic `Record<string, unknown>` — pi's
 *     `ToolCallEvent` is a discriminated union (`BashToolCallEvent`,
 *     `EditToolCallEvent`, `WriteToolCallEvent`, `ReadToolCallEvent`,
 *     `GrepToolCallEvent`, `FindToolCallEvent`, `LsToolCallEvent`,
 *     `CustomToolCallEvent`) keyed by `toolName`. There is no
 *     `multi_edit` tool in pi — pi's `edit` tool already accepts multiple
 *     `{oldText, newText}` pairs in one call via its `edits` array — and
 *     the edit/write tools key their target path as `path`, not
 *     `file_path` (which is exactly the CLAUDE-CODE tool_input field name
 *     `require-active-ticket.sh` primarily checks, falling back to
 *     `.tool_input.path` — see that hook's line 40 — so this maps
 *     directly with no gap).
 */

import { execFileSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import * as path from "node:path";

import type { ExtensionAPI, ToolCallEvent, ToolCallEventResult } from "@earendil-works/pi-coding-agent";

import {
  claudeToolNameFor,
  deriveGatesFromSettings,
  findUnsupportedGateWires,
  gateMatchesToolCall,
  type GateDefinition,
  type RawSettings,
} from "./derive-gates.ts";
import { resolveOpsRootForPi } from "./resolve-ops-root.ts";

export type { GateDefinition, GateWire, RawSettings } from "./derive-gates.ts";

/**
 * Reconstructs the Claude-Code-shaped `tool_input` object each hook's own
 * `jq` parsing expects, from a real pi `ToolCallEvent`. Generic across
 * every gate (replacing the old per-gate `buildToolInput` field the
 * hand-maintained `DEFAULT_GATES` table used) — mirrors the opencode
 * adapter's own `buildToolInput` shape (`derive-gates.ts` there).
 *
 * Only `bash`/`edit`/`write` are supported; `read`/`grep`/`find`/`ls`
 * return `undefined` deliberately — see `derive-gates.ts`'s header comment
 * ("NOT GUESSING READ/GREP/FIND/LS STDIN SHAPES") for why this doesn't
 * attempt to guess those event shapes' field names.
 */
export function buildPiToolInput(event: ToolCallEvent): Record<string, unknown> | undefined {
  switch (event.toolName) {
    case "bash": {
      const command = event.input.command;
      if (typeof command !== "string" || command.length === 0) return undefined;
      return { command };
    }
    case "edit":
    case "write": {
      const targetPath = event.input.path;
      if (typeof targetPath !== "string" || targetPath.length === 0) return undefined;
      return { path: targetPath };
    }
    default:
      return undefined;
  }
}

export interface DispatcherOptions {
  /** Override the derived gate table (mainly for tests — production always derives from settings.json, per call). */
  gates?: GateDefinition[];
  /** Override ops-root resolution (defaults to resolveOpsRootForPi). */
  resolveOpsRoot?: (startCwd: string) => string | undefined;
  /** Path to settings.json relative to the ops root. Defaults to ".claude/settings.json". */
  settingsRelativePath?: string;
  /** Override tool_input reconstruction (mainly for tests). Defaults to buildPiToolInput. */
  buildToolInput?: (event: ToolCallEvent) => Record<string, unknown> | undefined;
}

/**
 * Ceiling for the hook subprocess's stdout+stderr buffers. Normal gate
 * hook output (a block reason, a jq error) is a few KB at most; 10 MB is
 * generous headroom so no legitimate hook run ever trips this, while
 * still bounding memory if something goes very wrong.
 */
const MAX_HOOK_OUTPUT_BYTES = 10 * 1024 * 1024;

/**
 * Ceiling for a single gate hook's wall-clock execution (#840 C1). Every
 * gate hook so far is a fast, local check (jq parse, a `gh` API call with
 * its own short timeout, a file stat) — 30s is generous headroom for a
 * legitimate hook while still bounding a hung subprocess (a network call
 * that never returns, an infinite loop introduced by a bad edit to a hook
 * script) from blocking every subsequent tool call in the session
 * indefinitely. `execFileSync`'s own `timeout` option kills the child with
 * `killSignal` on expiry, which surfaces here as "no numeric exit status"
 * (see the FAIL CLOSED branch below) — a timed-out hook is therefore
 * already, by construction, on the same fail-closed path as a spawn
 * failure or an ENOBUFS overflow; no separate branch was needed, only the
 * option itself.
 */
const HOOK_EXEC_TIMEOUT_MS = 30_000;

/**
 * Runs a single gate hook with the reconstructed Claude-Code-shaped stdin
 * payload, mapping its exit code to a pi ToolCallEventResult per the
 * proven-in-spike contract: exit 2 = block, everything else = allow.
 *
 * FAIL CLOSED, NOT OPEN (security — Rex finding on #817).
 * ---------------------------------------------------------
 * `execFileSync` throwing does not always mean "the hook exited nonzero".
 * It can also mean the hook never produced a numeric exit status at all —
 * `ENOBUFS` when a hook emits more than `maxBuffer`, a spawn failure
 * (missing `bash`, permission denied), a signal kill, or any other
 * execution-layer error. The earlier version of this function treated
 * every one of those cases the same as "exit 0" (allow), which is a
 * fail-OPEN on a security gate: a hook that couldn't even run its check
 * silently permitted the tool call it was supposed to be gating.
 *
 * The corrected semantics:
 *   - exit code 2                  → BLOCK (the hook's own verdict)
 *   - exit code 0 (or any other
 *     *numeric* non-2 exit code)   → ALLOW (matches Claude Code's own
 *                                     PreToolUse semantics: only exit 2
 *                                     is a hard stop)
 *   - NO numeric exit status at
 *     all (spawn failure, ENOBUFS,
 *     signal kill, TIMEOUT, etc.)  → BLOCK, fail closed, with a reason
 *                                     naming the hook and the underlying
 *                                     error, so the operator can see
 *                                     WHY a gate refused to evaluate
 *                                     rather than silently letting the
 *                                     tool call through.
 *
 * BOUNDED TIMEOUT, SAME FAIL-CLOSED PATH (#840 C1).
 * ---------------------------------------------------------
 * `execFileSync` is given a `timeout` (default `HOOK_EXEC_TIMEOUT_MS`,
 * 30s). A hook that exceeds it is killed by Node before it ever produces a
 * numeric exit status, so it lands in the same "NO numeric exit status"
 * branch above as a spawn failure or ENOBUFS — a hung hook fails closed,
 * not open, and never blocks the dispatcher indefinitely.
 */
export function runGateHook(
  opsRoot: string,
  gate: GateDefinition,
  toolInput: Record<string, unknown>,
  claudeToolName: string,
  maxBufferBytes: number = MAX_HOOK_OUTPUT_BYTES,
  timeoutMs: number = HOOK_EXEC_TIMEOUT_MS,
): ToolCallEventResult | undefined {
  const hookPath = path.join(opsRoot, gate.hookRelativePath);
  if (!existsSync(hookPath)) return undefined; // gate not present in this fork — no-op, not a failure

  const stdinPayload = JSON.stringify({ tool_name: claudeToolName, tool_input: toolInput });

  try {
    execFileSync("bash", [hookPath], {
      input: stdinPayload,
      cwd: opsRoot,
      encoding: "utf-8",
      stdio: ["pipe", "pipe", "pipe"],
      maxBuffer: maxBufferBytes,
      timeout: timeoutMs,
      killSignal: "SIGKILL",
    });
    // No throw => exit code 0 => allow.
    return undefined;
  } catch (err) {
    const execErr = err as { status?: number | null; stderr?: Buffer | string; message?: string; signal?: string | null; code?: string };
    const stderr = execErr.stderr ? execErr.stderr.toString() : String(execErr.message ?? err);

    if (execErr.status === 2) {
      return {
        block: true,
        reason: stderr.trim() || `Blocked by apexyard governance gate (${gate.name})`,
      };
    }
    if (typeof execErr.status === "number") {
      // A numeric, non-2 exit code (e.g. 1 from an unrelated bash-level
      // error inside the hook script itself). Claude Code's own
      // PreToolUse contract only treats exit 2 as blocking; mirror that
      // here rather than fail closed on every nonzero exit, which would
      // make an unrelated warning inside a hook block unrelated tool
      // calls.
      return undefined;
    }
    // No numeric exit status at all — execution-layer failure (spawn
    // error, ENOBUFS from output exceeding maxBuffer, killed by signal,
    // or a timeout kill). Fail CLOSED: a gate that could not run its check
    // must deny, not permit. Node's own `code` distinguishes a timeout
    // kill ("ETIMEDOUT") from a maxBuffer overflow ("ENOBUFS") even though
    // both share the same `killSignal` — `.signal` alone can't tell them
    // apart since both paths kill the child the same way.
    const timedOut = execErr.code === "ETIMEDOUT";
    const reasonPrefix = timedOut
      ? `apexyard governance gate "${gate.name}" timed out after ${timeoutMs}ms (${hookPath}) — failing closed.`
      : `apexyard governance gate "${gate.name}" could not be evaluated (${hookPath}) — failing closed.`;
    return {
      block: true,
      reason: `${reasonPrefix} Underlying error: ${stderr.trim() || "unknown execution failure"}`,
    };
  }
}

/**
 * Reads and parses `.claude/settings.json` from a resolved ops root. On
 * any failure (missing file, unparsable JSON) returns an empty gate table
 * rather than throwing — a broken settings.json should not brick every
 * tool call in the session; it should just mean no gates are enforced.
 * Matches the opencode adapter's identical `deriveGatesFromOpsRoot`
 * contract, including its #840 C3 fix: a PARSE failure warns to stderr
 * (deduped — see `warnOnce` below); a MISSING file stays silent (the
 * expected "nothing to enforce here" case, not a broken-config case).
 */
export function deriveGatesFromOpsRoot(opsRoot: string, settingsRelativePath: string): GateDefinition[] {
  const settingsPath = path.join(opsRoot, settingsRelativePath);
  if (!existsSync(settingsPath)) return [];
  try {
    const raw = JSON.parse(readFileSync(settingsPath, "utf-8")) as RawSettings;
    return deriveGatesFromSettings(raw);
  } catch (err) {
    warnOnce(
      `parse-failure:${settingsPath}`,
      `apexyard-gate-dispatcher: WARNING — failed to parse ${settingsPath}; NO gates are enforced this session. ` +
        `Underlying error: ${err instanceof Error ? err.message : String(err)}\n`,
    );
    return [];
  }
}

/**
 * Process-lifetime dedup set for warnings this dispatcher emits more than
 * once given pi's per-call resolution (see this file's header comment).
 * Keyed by an arbitrary caller-chosen string, not by message content, so
 * callers control the granularity (e.g. one entry per settings path, one
 * per (gate, tool) pair) independent of exact wording.
 */
const warnedKeys = new Set<string>();

function warnOnce(key: string, message: string): void {
  if (warnedKeys.has(key)) return;
  warnedKeys.add(key);
  process.stderr.write(message);
}

/**
 * Warns once per (opsRoot, gate, tool) about any derived gate wired to a
 * pi tool this dispatcher has no stdin builder for (#840 C2, ported here
 * as part of C5 — deriving the FULL table surfaces `suggest-mcp-search.sh`'s
 * `Read|Glob|Grep` wiring, which pi's `read`/`find`/`grep` tools have no
 * verified stdin shape for). Deduped so a hot Read/Glob/Grep-heavy session
 * doesn't print the same warning before every matching tool call.
 */
function warnUnsupportedGateWiresOnce(opsRoot: string, gates: GateDefinition[]): void {
  for (const unsupported of findUnsupportedGateWires(gates)) {
    warnOnce(
      `unsupported:${opsRoot}:${unsupported.gateName}:${unsupported.tool}`,
      `apexyard-gate-dispatcher: WARNING — gate "${unsupported.gateName}" is wired to pi tool "${unsupported.tool}", ` +
        `which this adapter has no stdin builder for (buildPiToolInput only supports bash/edit/write). This gate is SILENTLY SKIPPED ` +
        `for "${unsupported.tool}" tool calls — it never runs, so it can never block one. See derive-gates.ts for details.\n`,
    );
  }
}

/**
 * Registers the dispatcher's `tool_call` handler on a pi ExtensionAPI
 * instance. This is the function pi loads (default export, below) — kept
 * separate from the default export so tests can call it directly with a
 * mock `pi` object without going through pi's own module loader.
 */
export function registerGateDispatcher(pi: ExtensionAPI, options: DispatcherOptions = {}): void {
  const resolve = options.resolveOpsRoot ?? ((startCwd: string) => resolveOpsRootForPi({ startCwd }));
  const buildToolInput = options.buildToolInput ?? buildPiToolInput;
  const settingsRelativePath = options.settingsRelativePath ?? ".claude/settings.json";

  pi.on("tool_call", async (event, ctx) => {
    const toolName = event.toolName;
    const startCwd = ctx.cwd ?? process.cwd();
    const opsRoot = resolve(startCwd);
    if (!opsRoot) return undefined; // no apexyard fork found on this machine/session — nothing to enforce

    const gates = options.gates ?? deriveGatesFromOpsRoot(opsRoot, settingsRelativePath);
    if (!options.gates) warnUnsupportedGateWiresOnce(opsRoot, gates);

    // Run every gate wired to this tool. First hook to return a block wins
    // — mirrors Claude Code's own PreToolUse semantics, where any matching
    // hook exiting 2 halts the tool call regardless of what the other
    // matched hooks would have said.
    for (const gate of gates) {
      const command = event.toolName === "bash" ? event.input.command : undefined;
      if (!gateMatchesToolCall(gate, toolName, typeof command === "string" ? command : undefined)) continue;
      const toolInput = buildToolInput(event);
      if (!toolInput) continue;
      const claudeToolName = claudeToolNameFor(toolName);
      const result = runGateHook(opsRoot, gate, toolInput, claudeToolName);
      if (result?.block) return result;
    }
    return undefined;
  });
}

/** Default export — what `pi install` / `pi --extension` loads. */
export default function apexyardGateDispatcher(pi: ExtensionAPI): void {
  registerGateDispatcher(pi);
}
