/**
 * derive-gates.ts — parses `.claude/settings.json`'s `PreToolUse` hook
 * wiring into a gate table, instead of hand-maintaining a parallel
 * `DEFAULT_GATES` array.
 *
 * WHY THIS EXISTS (the #730 convergence)
 * ----------------------------------------
 * The pi adapter (`harness-adapters/pi/src/gate-dispatcher.ts`) ships a
 * hand-written `DEFAULT_GATES: GateDefinition[]` table — a curated subset of
 * `.claude/settings.json`'s `PreToolUse` hooks, picked to cover spike #804's
 * named acceptance criteria. Tariq's design review on #730 (the Codex
 * adapter) named the risk that pattern carries forward: a hand-maintained
 * table can silently drift from `.claude/settings.json` as new gates are
 * added — the table only grows when someone remembers to edit it by hand.
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
 * WHAT THIS DOES NOT DO
 * -----------------------
 * It does not touch `.claude/settings.json` or any `.claude/hooks/*.sh`
 * file — this module only reads and interprets the existing wiring. Gate
 * *decisions* stay 100% in bash; this file's only job is figuring out
 * *which* hook to run for a given opencode tool call, from the same
 * config Claude Code itself reads.
 */

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

/** Minimal shape of `.claude/settings.json` this module reads — a structural subset, not the full schema. */
export interface RawHookEntry {
  type?: string;
  command?: string;
  if?: string;
}
export interface RawMatcherGroup {
  matcher?: string;
  hooks?: RawHookEntry[];
}
export interface RawSettings {
  hooks?: {
    PreToolUse?: RawMatcherGroup[];
  };
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
 * Extracts the `.claude/hooks/<file>.sh` path from a settings.json hook
 * `command` string. The command is the ops-root-pin bash wrapper (see
 * `pin-ops-root.sh` / `_lib-ops-root.sh`) that ultimately execs
 * `"$r/.claude/hooks/<file>.sh"` — this is a regex extraction of that
 * trailing path, not a full shell parse, matching the extraction
 * discipline `_lib-extract-pr.sh` already uses elsewhere in this framework
 * ("regex-only extraction, sufficient for the shapes these commands
 * actually emit" — the shape here is generated by this repo's own
 * `settings.json`, not attacker-controlled input).
 */
export function extractHookRelativePath(command: string | undefined): string | undefined {
  if (!command) return undefined;
  const m = command.match(/\.claude\/hooks\/([\w.-]+\.sh)\b/);
  return m ? `.claude/hooks/${m[1]}` : undefined;
}

/** Extracts the glob from a Claude Code `if: "Bash(<glob>)"` predicate string, or undefined if it doesn't match that shape. */
export function extractCommandGlob(ifPredicate: string | undefined): string | undefined {
  if (!ifPredicate) return undefined;
  const m = ifPredicate.match(/^Bash\((.*)\)$/);
  return m ? m[1] : undefined;
}

function hookNameFromPath(hookRelativePath: string): string {
  const base = hookRelativePath.split("/").pop() ?? hookRelativePath;
  return base.replace(/\.sh$/, "");
}

/**
 * Derives the full gate table from a parsed `.claude/settings.json`. Every
 * `PreToolUse` entry whose command execs a `.claude/hooks/*.sh` script
 * becomes (or is folded into) a `GateDefinition` — grouped by hook path
 * because the same hook is commonly wired multiple times (once per
 * Bash-command-glob it cares about, e.g. `block-unreviewed-merge.sh` is
 * wired 5 times: `gh pr merge *`, `gh api *`, `glab mr merge *`,
 * `glab api *`, `tracker_pr_merge *` — the multi-tracker merge-shape
 * coverage from #47/#759).
 *
 * Entries whose `command` doesn't reference a `.claude/hooks/*.sh` file are
 * skipped — none exist in this framework's own wiring today, but a future
 * adopter's custom hook shape shouldn't crash gate derivation.
 */
export function deriveGatesFromSettings(settings: RawSettings): GateDefinition[] {
  const byHook = new Map<string, GateDefinition>();
  const preToolUse = settings.hooks?.PreToolUse ?? [];

  for (const group of preToolUse) {
    const claudeTools = (group.matcher ?? "")
      .split("|")
      .map((s) => s.trim())
      .filter(Boolean);
    const opencodeTools = claudeTools
      .map((t) => CLAUDE_MATCHER_TO_OPENCODE_TOOL[t])
      .filter((t): t is string => Boolean(t));
    if (opencodeTools.length === 0) continue; // matcher this adapter has no opencode tool for (e.g. a future Claude-only tool)

    for (const entry of group.hooks ?? []) {
      if (entry.type && entry.type !== "command") continue; // not a shell command hook
      const hookRelativePath = extractHookRelativePath(entry.command);
      if (!hookRelativePath) continue;

      let gate = byHook.get(hookRelativePath);
      if (!gate) {
        gate = { name: hookNameFromPath(hookRelativePath), hookRelativePath, wires: [] };
        byHook.set(hookRelativePath, gate);
      }

      // `if` predicates in this framework's wiring only ever gate the Bash
      // matcher (command-shape matching) — Edit/Write/Read/Glob/Grep rows
      // carry no `if` field. Applying the glob only to the "bash" tool and
      // treating every other tool as unconditional matches that reality
      // without needing to special-case matcher names here.
      const commandGlob = extractCommandGlob(entry.if) ?? null;
      for (const tool of opencodeTools) {
        gate.wires.push({ tool, commandGlob: tool === "bash" ? commandGlob : null });
      }
    }
  }

  return Array.from(byHook.values());
}

/** Converts a Claude Code `if: "Bash(<glob>)"` glob (shell-style `*` wildcard) into an anchored RegExp. */
export function globToRegExp(glob: string): RegExp {
  const escaped = glob.replace(/[.+^${}()|[\]\\]/g, "\\$&").replace(/\*/g, ".*");
  return new RegExp(`^${escaped}$`);
}

/**
 * True if `gate` should fire for a tool call on `toolId` with the given
 * (optional — only bash calls carry one) `command` string. A gate with an
 * unconditional wire (`commandGlob === null`) for this tool always fires;
 * otherwise it fires if `command` matches ANY of the gate's globs for this
 * tool (mirrors Claude Code's own PreToolUse semantics: multiple `if`
 * predicates on the same hook are alternatives, not conjunctions).
 */
export function gateMatchesToolCall(gate: GateDefinition, toolId: string, command: string | undefined): boolean {
  for (const wire of gate.wires) {
    if (wire.tool !== toolId) continue;
    if (wire.commandGlob === null) return true;
    if (typeof command === "string" && globToRegExp(wire.commandGlob).test(command)) return true;
  }
  return false;
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
