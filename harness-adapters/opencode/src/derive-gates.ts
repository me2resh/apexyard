/**
 * derive-gates.ts — parses `.claude/settings.json`'s `PreToolUse` hook
 * wiring into a gate table, instead of hand-maintaining a parallel
 * `DEFAULT_GATES` array.
 *
 * WHY THIS EXISTS (the #730 convergence)
 * ----------------------------------------
 * The pi adapter (`harness-adapters/pi/src/gate-dispatcher.ts`) originally
 * shipped a hand-written `DEFAULT_GATES: GateDefinition[]` table — a
 * curated subset of `.claude/settings.json`'s `PreToolUse` hooks, picked to
 * cover spike #804's named acceptance criteria. Tariq's design review on
 * #730 (the Codex adapter) named the risk that pattern carries forward: a
 * hand-maintained table can silently drift from `.claude/settings.json` as
 * new gates are added — the table only grows when someone remembers to
 * edit it by hand.
 *
 * The Codex adapter (`bin/sync-codex-adapter.sh`, AgDR-0088) already solved
 * this the right way for its target format: it reads `.claude/settings.json`
 * directly with `jq` and generates `.codex/hooks.json` from it, so Codex's
 * gate wiring can never drift from the canonical config by construction.
 * This module applies the same principle to opencode, adapted to opencode's
 * shape: opencode plugins are plain TypeScript with no required build step,
 * so there is no need for a static generation step that writes a file to
 * disk (Codex needed one because its target format, TOML/JSON consumed by a
 * non-Node runtime, isn't something a plugin can read live) — this module
 * parses `.claude/settings.json` at plugin init time instead, every time the
 * plugin loads. Same convergence goal (one canonical source, zero copies),
 * a simpler mechanism for a target that can read JSON at runtime.
 *
 * Per #821's ask ("if the pi adapter has a DEFAULT_GATES table, do better
 * here and note it as the pattern pi should converge to"): this module
 * derives the FULL set of `PreToolUse` hooks wired for `Bash` / `Edit` /
 * `Write` / `MultiEdit` / `Read` / `Glob` / `Grep` matchers — not a curated
 * subset. Advisory-only hooks (ones that never exit 2, e.g.
 * `detect-role-trigger.sh`, `suggest-mcp-search.sh`) are harmless to
 * include: they run, they never throw, they cost one subprocess spawn per
 * matching tool call. Gate correctness does not depend on us knowing in
 * advance which hooks are blocking and which are advisory — the dispatcher
 * finds out from each hook's own exit code, at the moment it runs it. A
 * future hook added to `.claude/settings.json` is picked up automatically,
 * with zero changes to this adapter.
 *
 * #840 C5 — SHARED CORE WITH THE PI ADAPTER
 * --------------------------------------------
 * `.claude/settings.json` parsing (the regex extraction, the glob-to-RegExp
 * conversion, the matcher-group -> `GateDefinition` collapsing) is now
 * factored into `harness-adapters/_shared/derive-gates-core.ts` — pi has
 * since converged to the same settings.json-derived pattern this module
 * pioneered (AgDR-0092), and that parsing logic was 100% identical between
 * the two runtimes; only the Claude-matcher -> runtime-tool-id translation
 * and `buildToolInput` genuinely differ (opencode has a `glob` tool and
 * uses `filePath`; pi has no `glob` tool — its closest analog is `find` —
 * and uses `path`). This module is now a thin translation layer over that
 * shared core: `deriveGatesFromSettings` below calls the core's parser,
 * then maps each core wire's raw Claude matcher token onto opencode's own
 * tool vocabulary via `CLAUDE_MATCHER_TO_OPENCODE_TOOL`. See
 * `derive-gates-core.ts`'s header comment for the full rationale, and
 * `harness-adapters/pi/src/derive-gates.ts` for the sibling translation
 * layer.
 *
 * WHAT THIS DOES NOT DO
 * -----------------------
 * It does not touch `.claude/settings.json` or any `.claude/hooks/*.sh`
 * file — this module only reads and interprets the existing wiring. Gate
 * *decisions* stay 100% in bash; this file's only job is figuring out
 * *which* hook to run for a given opencode tool call, from the same
 * config Claude Code itself reads.
 */

import {
  deriveGatesFromSettings as deriveCoreGates,
  extractCommandGlob,
  extractHookRelativePath,
  gateMatchesClaudeMatcher,
  globToRegExp,
  type GateDefinition as CoreGateDefinition,
  type RawHookEntry,
  type RawMatcherGroup,
  type RawSettings,
} from "../../_shared/derive-gates-core.ts";

export type { RawHookEntry, RawMatcherGroup, RawSettings };
export { extractCommandGlob, extractHookRelativePath, globToRegExp };

export interface ToolCallInput {
  tool: string;
  sessionID: string;
  callID: string;
}

export interface ToolCallOutput {
  args: Record<string, unknown> | undefined;
}

/**
 * One wiring row: "this hook fires for this opencode tool, optionally only
 * when the Bash command matches this glob." Mirrors one
 * `{matcher, hooks[].if}` combination from `.claude/settings.json`.
 *
 * `commandGlob: null` means the hook fires unconditionally for this tool —
 * either because the matcher itself carried no `if` predicate (true for
 * every non-Bash matcher in this framework's wiring today, and for some
 * Bash rows too, e.g. `require-active-ticket.sh`, which does its own
 * command-shape detection *inside* the hook rather than via the `if`
 * predicate), or the row's `if` value didn't parse as a `Bash(<glob>)`
 * predicate.
 */
export interface GateWire {
  /** opencode tool id (e.g. "bash", "edit", "write") this wire applies to. */
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
 * Claude Code matcher token -> opencode built-in tool id. Confirmed against
 * opencode's real, installed tool registry (`packages/opencode/src/tool/`):
 * the bash tool's registered id is literally `"bash"` (kept for backwards
 * compatibility even though the source file implementing it is
 * `shell.ts`), and `edit`/`write`/`read`/`grep`/`glob` match their Claude
 * Code matcher names 1:1. `MultiEdit` has no opencode equivalent — opencode's
 * `edit` tool already accepts the same "one file, N find/replace pairs"
 * shape MultiEdit covers, so MultiEdit collapses onto `edit` (the same
 * choice the pi adapter made for the same reason).
 */
const CLAUDE_MATCHER_TO_OPENCODE_TOOL: Record<string, string> = {
  Bash: "bash",
  Edit: "edit",
  MultiEdit: "edit",
  Write: "write",
  Read: "read",
  Glob: "glob",
  Grep: "grep",
};

/** Reverse of the above — the `tool_name` field the bash hooks' own `.tool_name` jq lookups expect. */
const OPENCODE_TOOL_TO_CLAUDE_NAME: Record<string, string> = {
  bash: "Bash",
  edit: "Edit",
  write: "Write",
  read: "Read",
  glob: "Glob",
  grep: "Grep",
};

export function claudeToolNameFor(opencodeTool: string): string {
  return OPENCODE_TOOL_TO_CLAUDE_NAME[opencodeTool] ?? opencodeTool;
}

/**
 * Derives the full gate table from a parsed `.claude/settings.json`, by
 * calling the shared, harness-agnostic core parser
 * (`derive-gates-core.ts`) and translating each wire's raw Claude matcher
 * token into an opencode tool id via `CLAUDE_MATCHER_TO_OPENCODE_TOOL`. A
 * wire whose matcher has no opencode translation (no such token exists in
 * this framework's own wiring today; a future adopter-added Claude-only
 * matcher would be the only way to hit this) is dropped — and a gate left
 * with zero translatable wires is dropped entirely — matching this
 * module's pre-#840-C5 behavior exactly (see `derive-gates-core.test.ts`
 * / this file's own tests for the parity proof).
 */
export function deriveGatesFromSettings(settings: RawSettings): GateDefinition[] {
  const coreGates = deriveCoreGates(settings);
  const translated: GateDefinition[] = [];

  for (const coreGate of coreGates) {
    const wires: GateWire[] = [];
    for (const wire of coreGate.wires) {
      const tool = CLAUDE_MATCHER_TO_OPENCODE_TOOL[wire.claudeMatcher];
      if (!tool) continue; // matcher this adapter has no opencode tool for (e.g. a future Claude-only matcher)
      wires.push({ tool, commandGlob: wire.commandGlob });
    }
    if (wires.length === 0) continue; // every wire for this gate was for an untranslatable matcher
    translated.push({ name: coreGate.name, hookRelativePath: coreGate.hookRelativePath, wires });
  }

  return translated;
}

/**
 * True if `gate` should fire for a tool call on `toolId` with the given
 * (optional — only bash calls carry one) `command` string. A gate with an
 * unconditional wire (`commandGlob === null`) for this tool always fires;
 * otherwise it fires if `command` matches ANY of the gate's globs for this
 * tool (mirrors Claude Code's own PreToolUse semantics: multiple `if`
 * predicates on the same hook are alternatives, not conjunctions).
 *
 * Delegates to the shared core's `gateMatchesClaudeMatcher` by adapting
 * this module's opencode-tool-keyed `GateDefinition` into the core's
 * claudeMatcher-keyed shape inline — a small adapter shim rather than a
 * second copy of the matching logic.
 */
export function gateMatchesToolCall(gate: GateDefinition, toolId: string, command: string | undefined): boolean {
  const coreShaped: CoreGateDefinition = {
    name: gate.name,
    hookRelativePath: gate.hookRelativePath,
    wires: gate.wires.map((w) => ({ claudeMatcher: w.tool, commandGlob: w.commandGlob })),
  };
  return gateMatchesClaudeMatcher(coreShaped, toolId, command);
}

/**
 * Builds the Claude-Code-shaped `tool_input` object each hook's own `jq`
 * parsing expects, from an opencode `tool.execute.before` event. Returns
 * `undefined` when the event doesn't carry the field a hook needs — the
 * dispatcher then skips invoking that hook for that event rather than
 * invoking it with a garbage payload (same "skip, don't guess" contract
 * the pi adapter uses).
 *
 * Field names are chosen to match Claude Code's OWN `tool_input` shape
 * directly (`command`, `file_path`) rather than opencode's native field
 * names (`command`, `filePath`) — this is simpler than the pi adapter's
 * approach (which relied on `require-active-ticket.sh`'s existing
 * `.tool_input.file_path // .tool_input.path` fallback because pi's own
 * field is named `path`); since this module constructs the JSON payload
 * itself rather than forwarding a native field name, it can just emit the
 * name the hooks already read as their primary key.
 */
export function buildToolInput(toolId: string, output: ToolCallOutput | undefined): Record<string, unknown> | undefined {
  const args = output?.args ?? {};
  switch (toolId) {
    case "bash": {
      const command = (args as Record<string, unknown>).command;
      if (typeof command !== "string" || command.length === 0) return undefined;
      return { command };
    }
    case "edit":
    case "write": {
      const filePath = (args as Record<string, unknown>).filePath;
      if (typeof filePath !== "string" || filePath.length === 0) return undefined;
      return { file_path: filePath };
    }
    default:
      return undefined;
  }
}

/**
 * The opencode tool ids `buildToolInput` above knows how to reconstruct
 * stdin for. Kept as a single source of truth so `findUnsupportedGateWires`
 * below can never drift from `buildToolInput`'s own `switch` cases.
 */
const SUPPORTED_TOOL_INPUT_TOOLS = new Set(["bash", "edit", "write"]);

/**
 * One `(gate name, tool)` pair this dispatcher cannot build stdin for —
 * see `findUnsupportedGateWires`'s header comment for why this exists.
 */
export interface UnsupportedGateWire {
  gateName: string;
  tool: string;
}

/**
 * Finds every derived gate wire whose tool this adapter has NO
 * `buildToolInput` support for (#840 C2).
 *
 * WHY THIS EXISTS
 * -----------------
 * `deriveGatesFromSettings` derives gates for every `PreToolUse` matcher
 * `.claude/settings.json` wires, including `Read|Glob|Grep` (today, exactly
 * one hook: `suggest-mcp-search.sh`, an advisory-only hook that never exits
 * 2 for those tool types — see its own header comment). `buildToolInput`,
 * by contrast, only reconstructs stdin for `bash`/`edit`/`write` — Hakim's
 * #839 finding (ported to this adapter as #840 C2) is that a FUTURE
 * blocking gate wired to `Read`/`Glob`/`Grep` would be silently skipped at
 * every matching tool call, with nothing surfaced anywhere.
 *
 * This adapter deliberately does NOT guess opencode's real `read`/`glob`/
 * `grep` tool argument field names to construct stdin for them — every
 * other field-name mapping in this adapter family (`command` for bash,
 * `filePath` for edit/write) was verified against opencode's real,
 * installed `.d.ts` / source per AgDR-0092's explicit "real types, not
 * guesses" discipline; guessing field names for three more tools here
 * would silently violate that same discipline and could hand a hook a
 * garbage payload it would misparse. The safer, honest alternative: fail
 * LOUD instead of silently skipping. Call this once at gate-table
 * construction time (dispatcher init, not per tool call — avoids per-call
 * log noise for advisory hooks that were never going to block anything)
 * and surface every finding to stderr so "a gate exists for this tool but
 * this adapter can't evaluate it" is visible, not silently swallowed.
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
