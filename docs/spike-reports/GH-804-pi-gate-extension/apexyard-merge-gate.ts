/**
 * apexyard-merge-gate — pi extension prototype for spike #804.
 *
 * THROWAWAY SPIKE ARTIFACT. This is a proof-of-pattern, not a shipped
 * feature. See docs/spike-reports/pi-gate-extension.md for the findings
 * this file exists to support, and me2resh/apexyard#804 for the ticket.
 *
 * WHAT THIS PROVES
 * -----------------
 * A pi extension can enforce an apexyard governance gate — here,
 * block-unreviewed-merge.sh, the two-marker (Rex + CEO) merge gate — by
 * shelling out to the EXISTING bash hook, unmodified, rather than
 * re-implementing its logic in TypeScript. Zero logic duplication: the
 * bash script stays the single source of truth for "is this merge
 * allowed", and this file is a thin transport adapter between pi's
 * `tool_call` event and the hook's stdin/exit-code contract.
 *
 * THE CONTRACT BEING BRIDGED
 * --------------------------
 * Claude Code's PreToolUse hooks (what block-unreviewed-merge.sh was
 * written for) receive JSON on stdin shaped like:
 *   { "tool_input": { "command": "<the bash command>" } }
 * and signal their verdict via exit code:
 *   0 = allow, 2 = block (with a human-readable reason on stderr).
 *
 * pi's `tool_call` event (see docs/spike-reports/pi-gate-extension.md
 * § "Pi API facts" for citations) hands an extension:
 *   event.toolName   — "bash" for shell commands
 *   event.input      — { command: string } for the bash tool
 * and expects a return value of:
 *   { block: true, reason: string }   to block
 *   undefined                        to allow
 *
 * This file's entire job is translating one contract into the other.
 * No merge-approval logic lives here — that logic is 100% in the bash
 * hook, read unchanged from .claude/hooks/.
 *
 * DESIGN NOTE — no pre-filter (deliberate)
 * ----------------------------------------
 * A production port might add a cheap regex pre-filter ("does this
 * command look like `gh pr merge` / `gh api .../pulls/.../merge`?")
 * before paying the subprocess cost of invoking bash for every single
 * bash tool call pi runs. This prototype deliberately OMITS that
 * optimization: block-unreviewed-merge.sh already self-filters (it
 * exits 0 immediately for non-merge commands — see is_merge_command()
 * in _lib-extract-pr.sh), so invoking it unconditionally keeps 100% of
 * the decision logic in bash and 0% in this file. The cost is one extra
 * subprocess spawn per bash tool call; named as a gap/optimization
 * opportunity in the findings doc, not implemented here.
 */

import { execFileSync } from "node:child_process";
import * as path from "node:path";

// Minimal structural shape of pi's ExtensionAPI — just enough of the
// real @earendil-works/pi-coding-agent types to typecheck this
// prototype standalone (the spike doesn't want a hard npm dependency
// for a throwaway file). See pi's own `ExtensionAPI` / `ToolCallEvent`
// types for the authoritative shape.
export interface ToolCallEvent {
  type: "tool_call";
  toolName: string;
  toolCallId: string;
  input: Record<string, unknown>;
}

export interface ExtensionContext {
  cwd?: string;
  hasUI?: boolean;
  [key: string]: unknown;
}

export interface ToolCallResult {
  block?: boolean;
  reason?: string;
}

export interface ExtensionAPI {
  on(
    event: "tool_call",
    handler: (event: ToolCallEvent, ctx: ExtensionContext) => Promise<ToolCallResult | undefined> | ToolCallResult | undefined,
  ): void;
}

/** Name of the bash hook this prototype wires up. Swap or add more —
 * see the findings doc's "generalizing to N gates" section for how this
 * would extend to block-merge-on-red-ci.sh, require-design-review-for-ui.sh,
 * require-architecture-review.sh, etc.
 */
const HOOK_RELATIVE_PATH = ".claude/hooks/block-unreviewed-merge.sh";

export default function apexyardMergeGate(pi: ExtensionAPI) {
  pi.on("tool_call", async (event, ctx) => {
    // Only the bash tool carries a shell command string the hook can parse.
    if (event.toolName !== "bash") return undefined;

    const command = event.input?.command;
    if (typeof command !== "string" || command.length === 0) return undefined;

    // Resolve the repo root the same way a Claude Code session would —
    // ctx.cwd is the project directory pi is running in. APEXYARD_REPO_ROOT
    // is a spike-only override so the test harness can point this at an
    // isolated worktree without needing a live pi session.
    const repoRoot = process.env.APEXYARD_REPO_ROOT || ctx.cwd || process.cwd();
    const hookPath = path.join(repoRoot, HOOK_RELATIVE_PATH);

    // Reconstruct EXACTLY the stdin shape the bash hook already parses via
    // `jq -r '.tool_input.command // empty'`. This is the entire adapter —
    // one JSON.stringify call, no merge-detection or approval logic here.
    const stdinPayload = JSON.stringify({ tool_input: { command } });

    let stderr = "";
    let exitCode = 0;
    try {
      execFileSync("bash", [hookPath], {
        input: stdinPayload,
        cwd: repoRoot,
        encoding: "utf-8",
        // stdout is the hook's WARN/BLOCKED prose; not surfaced to the LLM
        // here, only stderr is (which is where the hook actually writes).
        stdio: ["pipe", "pipe", "pipe"],
      });
    } catch (err) {
      const execErr = err as { status?: number; stderr?: Buffer | string; message?: string };
      exitCode = typeof execErr.status === "number" ? execErr.status : 1;
      stderr = execErr.stderr ? execErr.stderr.toString() : String(execErr.message ?? err);
    }

    // The hook's ENTIRE verdict contract: exit 2 = block. Everything else
    // (0 = allow, or any other nonzero from an unexpected bash-level error)
    // is treated as non-blocking here — matching Claude Code's own
    // PreToolUse semantics, where only exit 2 is a hard stop and other
    // nonzero exits are just logged. See CLAUDE.md's hooks documentation.
    if (exitCode === 2) {
      return {
        block: true,
        reason: stderr.trim() || "Blocked by apexyard governance gate (block-unreviewed-merge.sh)",
      };
    }

    return undefined;
  });
}
