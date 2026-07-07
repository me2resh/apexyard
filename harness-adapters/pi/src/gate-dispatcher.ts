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
 * See docs/agdr/AgDR-0082-pi-gate-dispatcher-adapter.md for the dispatcher
 * design decision and docs/harnesses/pi.md for install + usage docs.
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
import { existsSync } from "node:fs";
import * as path from "node:path";

import type { ExtensionAPI, ToolCallEvent, ToolCallEventResult } from "@earendil-works/pi-coding-agent";

import { resolveOpsRootForPi } from "./resolve-ops-root.ts";

/**
 * One row = one apexyard PreToolUse gate hook this dispatcher enforces.
 *
 * `toolNames` lists the real pi tool names (per
 * `@earendil-works/pi-coding-agent`'s `ToolCallEvent` union: "bash",
 * "read", "edit", "write", "grep", "find", "ls", or a custom string)
 * whose `tool_call` events this gate should be checked against.
 *
 * `buildToolInput` reconstructs the exact `tool_input` shape each hook's
 * `jq` parsing expects (see `.claude/hooks/_lib-extract-pr.sh` and each
 * hook's own `INPUT | jq -r '.tool_input....'` line) from pi's event
 * fields. Returning `undefined` means "this event doesn't carry the field
 * this hook needs" — the dispatcher then skips invoking that hook for that
 * event rather than invoking it with a garbage payload.
 */
export interface GateDefinition {
  /** Human-readable name, used in block reasons and logs. */
  name: string;
  /** Relative path to the hook script under the ops root. */
  hookRelativePath: string;
  /** Real pi tool names this gate should be checked against. */
  toolNames: string[];
  /**
   * Claude-Code tool_name string the hook's own `jq -r '.tool_name'`
   * lookup expects (only a few hooks read this field; most only read
   * `.tool_input.*` and ignore `.tool_name`). Defaults per toolName are
   * applied by `defaultClaudeToolName` below when omitted.
   */
  claudeToolName?: (piToolName: string) => string;
  /** Build the `tool_input` object from a pi ToolCallEvent. */
  buildToolInput: (event: ToolCallEvent) => Record<string, unknown> | undefined;
}

function defaultClaudeToolName(piToolName: string): string {
  switch (piToolName) {
    case "bash":
      return "Bash";
    case "edit":
      return "Edit";
    case "write":
      return "Write";
    default:
      return piToolName;
  }
}

/** Reconstructs `{command: <string>}` for pi's "bash" tool. */
function bashCommandInput(event: ToolCallEvent): Record<string, unknown> | undefined {
  if (event.toolName !== "bash") return undefined;
  const command = event.input.command;
  if (typeof command !== "string" || command.length === 0) return undefined;
  return { command };
}

/**
 * Reconstructs `{path: <string>}` for pi's "edit" / "write" tools — pi
 * names the target field `path` on both `EditToolInput` and
 * `WriteToolInput` (confirmed against the real `.d.ts`, not guessed).
 * `require-active-ticket.sh` and `require-migration-ticket.sh` already
 * fall back to `.tool_input.path` when `.tool_input.file_path` is absent
 * (see `_lib-extract-pr.sh` / the hooks' own jq lines), so this maps onto
 * the EXISTING fallback rather than requiring a hook change.
 */
function editOrWritePathInput(event: ToolCallEvent): Record<string, unknown> | undefined {
  if (event.toolName !== "edit" && event.toolName !== "write") return undefined;
  const targetPath = event.input.path;
  if (typeof targetPath !== "string" || targetPath.length === 0) return undefined;
  return { path: targetPath };
}

/**
 * The gate table. Every row here corresponds 1:1 to a `PreToolUse` hook
 * that is ALSO wired in `.claude/settings.json` for Claude Code — this is
 * the "one config, two harnesses" shape the spike report recommended, not
 * a hand-copied re-derivation. Extend this array to cover additional
 * gates; do not write a new dispatcher-shaped file per hook.
 *
 * THIS IS A CURATED SUBSET, NOT THE FULL LIST. `.claude/settings.json`
 * wires more Bash-matcher PreToolUse hooks than are bridged here. Every
 * hook below was checked against its own `jq -r '.tool_input.command'`
 * parsing (all of them read the identical stdin shape as
 * `block-unreviewed-merge.sh`, so no new adapter logic was needed) and
 * included because it's a real, blocking (exit-2) governance gate. Known
 * NOT-yet-bridged blocking Bash gates, and why:
 *
 *   - `validate-branch-name.sh`, `validate-commit-format.sh`,
 *     `verify-commit-refs.sh` — fire on `git branch` / `git commit`
 *     commands. Same bash-command shape as everything below and would be
 *     trivial to add; left out of this pass to keep the initial bridge
 *     scoped to the gates #815's acceptance criteria named explicitly
 *     (merge gate, red-CI, design/architecture review, ticket-first,
 *     secrets). Follow-up work, not a technical blocker.
 *   - `validate-pr-create.sh`, `require-agdr-for-arch-pr.sh`,
 *     `require-skill-for-issue-create.sh` — fire on `gh pr create` /
 *     `gh issue create` commands. Same reasoning: trivially the same
 *     shape, deferred rather than out of scope.
 *   - `block-onboarding-in-git.sh` — fires on `git add` of
 *     `onboarding.yaml`; same shape, deferred for the same reason.
 *
 * `block-private-refs-in-public-repos.sh` (leak protection) IS bridged
 * below, ahead of the others in this deferred list, because it's
 * security-relevant in exactly the way this dispatcher exists to close:
 * without it, a pi session could leak a registered private project's
 * name/repo/workspace path into a public framework issue with nothing
 * underneath to stop it.
 */
export const DEFAULT_GATES: GateDefinition[] = [
  {
    name: "block-unreviewed-merge",
    hookRelativePath: ".claude/hooks/block-unreviewed-merge.sh",
    toolNames: ["bash"],
    buildToolInput: bashCommandInput,
  },
  {
    name: "block-merge-on-red-ci",
    hookRelativePath: ".claude/hooks/block-merge-on-red-ci.sh",
    toolNames: ["bash"],
    buildToolInput: bashCommandInput,
  },
  {
    name: "require-design-review-for-ui",
    hookRelativePath: ".claude/hooks/require-design-review-for-ui.sh",
    toolNames: ["bash"],
    buildToolInput: bashCommandInput,
  },
  {
    name: "require-architecture-review",
    hookRelativePath: ".claude/hooks/require-architecture-review.sh",
    toolNames: ["bash"],
    buildToolInput: bashCommandInput,
  },
  {
    name: "check-secrets",
    hookRelativePath: ".claude/hooks/check-secrets.sh",
    toolNames: ["bash"],
    buildToolInput: bashCommandInput,
  },
  {
    name: "block-git-add-all",
    hookRelativePath: ".claude/hooks/block-git-add-all.sh",
    toolNames: ["bash"],
    buildToolInput: bashCommandInput,
  },
  {
    name: "block-main-push",
    hookRelativePath: ".claude/hooks/block-main-push.sh",
    toolNames: ["bash"],
    buildToolInput: bashCommandInput,
  },
  {
    name: "block-private-refs-in-public-repos",
    hookRelativePath: ".claude/hooks/block-private-refs-in-public-repos.sh",
    toolNames: ["bash"],
    buildToolInput: bashCommandInput,
  },
  {
    name: "require-active-ticket",
    hookRelativePath: ".claude/hooks/require-active-ticket.sh",
    // This hook also fires on Bash when the command writes a file via
    // redirection/tee/sed -i, which `_lib-detect-bash-write.sh` detects
    // bash-side; that detection works unchanged once the command string
    // is forwarded, so "bash" is included alongside "edit"/"write".
    toolNames: ["edit", "write", "bash"],
    buildToolInput: (event) => bashCommandInput(event) ?? editOrWritePathInput(event),
  },
  {
    name: "require-migration-ticket",
    hookRelativePath: ".claude/hooks/require-migration-ticket.sh",
    toolNames: ["edit", "write"],
    buildToolInput: editOrWritePathInput,
  },
];

export interface DispatcherOptions {
  /** Override the gate table (defaults to DEFAULT_GATES). */
  gates?: GateDefinition[];
  /** Override ops-root resolution (defaults to resolveOpsRootForPi). */
  resolveOpsRoot?: (startCwd: string) => string | undefined;
}

/**
 * Ceiling for the hook subprocess's stdout+stderr buffers. Normal gate
 * hook output (a block reason, a jq error) is a few KB at most; 10 MB is
 * generous headroom so no legitimate hook run ever trips this, while
 * still bounding memory if something goes very wrong.
 */
const MAX_HOOK_OUTPUT_BYTES = 10 * 1024 * 1024;

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
 *     signal kill, etc.)           → BLOCK, fail closed, with a reason
 *                                     naming the hook and the underlying
 *                                     error, so the operator can see
 *                                     WHY a gate refused to evaluate
 *                                     rather than silently letting the
 *                                     tool call through.
 */
export function runGateHook(
  opsRoot: string,
  gate: GateDefinition,
  toolInput: Record<string, unknown>,
  claudeToolName: string,
  maxBufferBytes: number = MAX_HOOK_OUTPUT_BYTES,
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
    });
    // No throw => exit code 0 => allow.
    return undefined;
  } catch (err) {
    const execErr = err as { status?: number | null; stderr?: Buffer | string; message?: string };
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
    // etc.). Fail CLOSED: a gate that could not run its check must deny,
    // not permit.
    return {
      block: true,
      reason: `apexyard governance gate "${gate.name}" could not be evaluated (${hookPath}) — failing closed. Underlying error: ${stderr.trim() || "unknown execution failure"}`,
    };
  }
}

/**
 * Registers the dispatcher's `tool_call` handler on a pi ExtensionAPI
 * instance. This is the function pi loads (default export, below) — kept
 * separate from the default export so tests can call it directly with a
 * mock `pi` object without going through pi's own module loader.
 */
export function registerGateDispatcher(pi: ExtensionAPI, options: DispatcherOptions = {}): void {
  const gates = options.gates ?? DEFAULT_GATES;
  const resolve = options.resolveOpsRoot ?? ((startCwd: string) => resolveOpsRootForPi({ startCwd }));

  pi.on("tool_call", async (event, ctx) => {
    const toolName = event.toolName;
    const startCwd = ctx.cwd ?? process.cwd();
    const opsRoot = resolve(startCwd);
    if (!opsRoot) return undefined; // no apexyard fork found on this machine/session — nothing to enforce

    // Run every gate whose toolNames list includes this event's tool.
    // First hook to return a block wins — mirrors Claude Code's own
    // PreToolUse semantics, where any matching hook exiting 2 halts the
    // tool call regardless of what the other matched hooks would have
    // said.
    for (const gate of gates) {
      if (!gate.toolNames.includes(toolName)) continue;
      const toolInput = gate.buildToolInput(event);
      if (!toolInput) continue;
      const claudeToolName = (gate.claudeToolName ?? defaultClaudeToolName)(toolName);
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
