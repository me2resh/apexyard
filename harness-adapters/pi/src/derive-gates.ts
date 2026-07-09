/**
 * derive-gates.ts — parses `.claude/settings.json`'s `PreToolUse` hook
 * wiring into a gate table, replacing the hand-maintained `DEFAULT_GATES`
 * array this adapter originally shipped with (#840 C5).
 *
 * WHY THIS EXISTS (the #730 convergence, completed)
 * ----------------------------------------------------
 * This adapter originally shipped a hand-written `DEFAULT_GATES:
 * GateDefinition[]` table (AgDR-0082) — a curated subset of
 * `.claude/settings.json`'s `PreToolUse` hooks, picked to cover spike
 * #804's named acceptance criteria, with an explicit "Known NOT-yet-bridged
 * gates" section in `README.md` listing seven blocking hooks left out on
 * purpose (deferred, not technically hard to add). Tariq's design review on
 * #730 (the Codex adapter) named the risk that pattern carries: a
 * hand-maintained table can silently drift from `.claude/settings.json` as
 * new gates are added — it only grows when someone remembers to edit it by
 * hand.
 *
 * The opencode adapter (`harness-adapters/opencode/src/derive-gates.ts`,
 * AgDR-0092) solved this for its own runtime by deriving the FULL gate
 * table from `.claude/settings.json` at plugin-load time instead —
 * AgDR-0092 explicitly named porting pi to the same pattern as the
 * intended follow-up. This module is that follow-up.
 *
 * SHARED CORE, PER-RUNTIME TRANSLATION
 * ---------------------------------------
 * The settings.json-parsing logic itself (regex extraction, glob-to-RegExp,
 * matcher-group -> `GateDefinition` collapsing) is 100% identical between
 * pi and opencode — factored into
 * `harness-adapters/_shared/derive-gates-core.ts`, keyed by RAW Claude
 * Code matcher tokens (not by either runtime's own tool vocabulary). This
 * module is the pi-specific translation layer on top of that shared core:
 * `CLAUDE_MATCHER_TO_PI_TOOL` maps each matcher token onto pi's own tool
 * ids, and `buildPiToolInput` reconstructs the Claude-Code-shaped stdin
 * payload from a real pi `ToolCallEvent`.
 *
 * PI'S TOOL VOCABULARY DIFFERS FROM OPENCODE'S
 * -------------------------------------------------
 * Per `gate-dispatcher.ts`'s own header comment (verified against pi's
 * real, installed `.d.ts`, not guessed): pi's `ToolCallEvent` union is
 * `"bash" | "edit" | "write" | "read" | "grep" | "find" | "ls" | custom`.
 * Two concrete differences from opencode this module has to account for:
 *
 *   - Pi has NO `glob` tool the way opencode does — its closest semantic
 *     analog for Claude Code's `Glob` matcher is `find`. This is a
 *     judgment call (not verified against a documented 1:1 mapping,
 *     because none exists), recorded here rather than left implicit.
 *   - Edit/write's target-path field is `path`, not `filePath` (opencode's
 *     field name) — already established by `gate-dispatcher.ts`'s
 *     original `editOrWritePathInput` before this refactor.
 *
 * NOT GUESSING READ/GREP/FIND/LS STDIN SHAPES
 * -------------------------------------------------
 * Deriving the FULL gate table (not a curated subset) means
 * `suggest-mcp-search.sh` — wired to `Read|Glob|Grep` in
 * `.claude/settings.json` — is now part of pi's derived table too, exactly
 * as it already is for opencode (#840 C2). This module does not attempt to
 * build pi stdin for `read`/`grep`/`find`/`ls` tool calls — mirroring
 * opencode's own "don't guess field names, fail loud instead" decision
 * (see `findUnsupportedGateWires` here and in the opencode adapter) rather
 * than inventing an unverified `ReadToolCallEvent`/`GrepToolCallEvent`/
 * `FindToolCallEvent` field mapping.
 */

import {
  deriveGatesFromSettings as deriveCoreGates,
  gateMatchesClaudeMatcher,
  type GateDefinition as CoreGateDefinition,
  type RawSettings,
} from "../../_shared/derive-gates-core.ts";

export type { RawSettings };

/**
 * One wiring row: "this hook fires for this pi tool, optionally only when
 * the Bash command matches this glob." Mirrors one `{matcher, hooks[].if}`
 * combination from `.claude/settings.json` (see the shared core's
 * `GateWire` for the pre-translation shape this is built from).
 */
export interface GateWire {
  /** pi tool id (e.g. "bash", "edit", "write", "read", "grep", "find") this wire applies to. */
  tool: string;
  /** Bash-command glob (from Claude Code's `if: "Bash(<glob>)"`), or null. */
  commandGlob: string | null;
}

/**
 * A single `.claude/hooks/*.sh` gate, reconstructed from one or more
 * `.claude/settings.json` `PreToolUse` entries that all point at the same
 * hook script.
 */
export interface GateDefinition {
  /** Human-readable name (the hook's basename, no extension), used in block reasons. */
  name: string;
  /** Path to the hook script, relative to the ops root — e.g. ".claude/hooks/block-unreviewed-merge.sh". */
  hookRelativePath: string;
  /** Every (tool, commandGlob) combination this gate is wired to. */
  wires: GateWire[];
}

/**
 * Claude Code matcher token -> pi tool id. `MultiEdit` collapses onto
 * `edit` (pi's `edit` tool already accepts multiple `{oldText, newText}`
 * pairs per call — no separate multi-edit tool exists, the same reasoning
 * the opencode adapter uses for the same collapse). `Glob` maps onto
 * `find` — pi's closest analog, a judgment call (see this file's header
 * comment); there is no pi tool named `glob`.
 */
const CLAUDE_MATCHER_TO_PI_TOOL: Record<string, string> = {
  Bash: "bash",
  Edit: "edit",
  MultiEdit: "edit",
  Write: "write",
  Read: "read",
  Glob: "find",
  Grep: "grep",
};

/** Reverse of the above — the `tool_name` field the bash hooks' own `.tool_name` jq lookups expect. */
const PI_TOOL_TO_CLAUDE_NAME: Record<string, string> = {
  bash: "Bash",
  edit: "Edit",
  write: "Write",
  read: "Read",
  find: "Glob",
  grep: "Grep",
};

export function claudeToolNameFor(piTool: string): string {
  return PI_TOOL_TO_CLAUDE_NAME[piTool] ?? piTool;
}

/**
 * Derives the full gate table from a parsed `.claude/settings.json`, by
 * calling the shared, harness-agnostic core parser and translating each
 * wire's raw Claude matcher token into a pi tool id via
 * `CLAUDE_MATCHER_TO_PI_TOOL`. A wire whose matcher has no pi translation
 * is dropped; a gate left with zero translatable wires is dropped
 * entirely (mirrors the opencode adapter's identical parity contract —
 * see `derive-gates-core.test.ts`'s cross-runtime parity test).
 */
export function deriveGatesFromSettings(settings: RawSettings): GateDefinition[] {
  const coreGates = deriveCoreGates(settings);
  const translated: GateDefinition[] = [];

  for (const coreGate of coreGates) {
    const wires: GateWire[] = [];
    for (const wire of coreGate.wires) {
      const tool = CLAUDE_MATCHER_TO_PI_TOOL[wire.claudeMatcher];
      if (!tool) continue; // matcher this adapter has no pi tool for
      wires.push({ tool, commandGlob: wire.commandGlob });
    }
    if (wires.length === 0) continue;
    translated.push({ name: coreGate.name, hookRelativePath: coreGate.hookRelativePath, wires });
  }

  return translated;
}

/**
 * True if `gate` should fire for a tool call on `toolName` with the given
 * (optional — only bash calls carry one) `command` string. Delegates to
 * the shared core's matcher, adapting this module's pi-tool-keyed
 * `GateDefinition` into the core's claudeMatcher-keyed shape inline.
 */
export function gateMatchesToolCall(gate: GateDefinition, toolName: string, command: string | undefined): boolean {
  const coreShaped: CoreGateDefinition = {
    name: gate.name,
    hookRelativePath: gate.hookRelativePath,
    wires: gate.wires.map((w) => ({ claudeMatcher: w.tool, commandGlob: w.commandGlob })),
  };
  return gateMatchesClaudeMatcher(coreShaped, toolName, command);
}

/**
 * The pi tool ids this module knows how to reconstruct Claude-Code-shaped
 * stdin for. `read`/`grep`/`find`/`ls` are deliberately absent — see this
 * file's header comment ("NOT GUESSING READ/GREP/FIND/LS STDIN SHAPES").
 */
const SUPPORTED_TOOL_INPUT_TOOLS = new Set(["bash", "edit", "write"]);

/** One `(gate name, tool)` pair this dispatcher cannot build stdin for. */
export interface UnsupportedGateWire {
  gateName: string;
  tool: string;
}

/**
 * Finds every derived gate wire whose tool this adapter has NO stdin
 * builder for (#840 C2's guard, ported here as part of C5 — deriving the
 * FULL table means `suggest-mcp-search.sh`'s `Read|Glob|Grep` wiring is
 * now part of pi's table too, and this adapter has no verified pi stdin
 * shape for those tool types). Call once at dispatcher registration, not
 * per tool call, to avoid per-call log noise for a hook that was never
 * going to block anything.
 */
export function findUnsupportedGateWires(gates: GateDefinition[]): UnsupportedGateWire[] {
  const found: UnsupportedGateWire[] = [];
  for (const gate of gates) {
    const unsupportedTools = new Set(gate.wires.map((w) => w.tool).filter((t) => !SUPPORTED_TOOL_INPUT_TOOLS.has(t)));
    for (const tool of unsupportedTools) {
      found.push({ gateName: gate.name, tool });
    }
  }
  return found;
}
