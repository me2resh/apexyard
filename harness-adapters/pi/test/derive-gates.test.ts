/**
 * derive-gates.test.ts — proves the pi-specific translation layer over the
 * shared `derive-gates-core.ts` parser behaves correctly (#840 C5). Mirrors
 * `harness-adapters/opencode/test/derive-gates.test.ts`'s structure and
 * coverage, adapted to pi's own tool vocabulary (no `glob` tool — `Glob`
 * maps to `find`; the target-path field is `path`, not `filePath`).
 *
 * RUN
 * ---
 *   node --test harness-adapters/pi/test/derive-gates.test.ts
 *
 * (Node >=22, no build step — native TS type-stripping.)
 */

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

import {
  claudeToolNameFor,
  deriveGatesFromSettings,
  findUnsupportedGateWires,
  gateMatchesToolCall,
  type GateDefinition,
  type RawSettings,
} from "../src/derive-gates.ts";

// ---------------------------------------------------------------------
// deriveGatesFromSettings — pi tool-vocabulary translation over the
// shared core
// ---------------------------------------------------------------------

function fixtureSettings(): RawSettings {
  return {
    hooks: {
      PreToolUse: [
        {
          matcher: "Edit|Write|MultiEdit",
          hooks: [{ type: "command", command: "bash -c '.../.claude/hooks/require-active-ticket.sh'" }],
        },
        {
          matcher: "Bash",
          hooks: [
            { type: "command", command: "bash -c '.../.claude/hooks/require-active-ticket.sh'" },
            { type: "command", command: "bash -c '.../.claude/hooks/block-unreviewed-merge.sh'", if: "Bash(gh pr merge *)" },
            { type: "command", command: "bash -c '.../.claude/hooks/block-unreviewed-merge.sh'", if: "Bash(gh api *)" },
            { type: "command", command: "bash -c '.../.claude/hooks/check-secrets.sh'", if: "Bash(git commit *)" },
          ],
        },
        {
          matcher: "Read|Glob|Grep",
          hooks: [{ type: "command", command: "bash -c '.../.claude/hooks/suggest-mcp-search.sh'" }],
        },
      ],
    },
  };
}

test("deriveGatesFromSettings collapses multiple wiring rows for the same hook into one GateDefinition", () => {
  const gates = deriveGatesFromSettings(fixtureSettings());
  const mergeGate = gates.find((g) => g.name === "block-unreviewed-merge");
  assert.ok(mergeGate);
  assert.equal(mergeGate!.hookRelativePath, ".claude/hooks/block-unreviewed-merge.sh");
  assert.equal(mergeGate!.wires.length, 2);
  assert.ok(mergeGate!.wires.every((w) => w.tool === "bash"));
});

test("deriveGatesFromSettings translates MultiEdit onto edit (pi has no separate multi-edit tool)", () => {
  const gates = deriveGatesFromSettings(fixtureSettings());
  const ticketGate = gates.find((g) => g.name === "require-active-ticket")!;
  const tools = ticketGate.wires.map((w) => w.tool).sort();
  // Edit AND MultiEdit both collapse onto "edit" — so "edit" should appear
  // (once, since the Map-collapse+push logic per matcher token still
  // pushes one wire per raw token; MultiEdit and Edit are two separate
  // Claude matcher tokens that both map to the pi tool "edit").
  assert.deepEqual(tools, ["bash", "edit", "edit", "write"]);
});

test("deriveGatesFromSettings translates Glob onto pi's find tool (no glob tool exists in pi)", () => {
  const gates = deriveGatesFromSettings(fixtureSettings());
  const mcpGate = gates.find((g) => g.name === "suggest-mcp-search")!;
  const tools = mcpGate.wires.map((w) => w.tool).sort();
  assert.deepEqual(tools, ["find", "grep", "read"]);
});

test("deriveGatesFromSettings marks a hook unconditional for a tool when its row has no `if`", () => {
  const gates = deriveGatesFromSettings(fixtureSettings());
  const ticketGate = gates.find((g) => g.name === "require-active-ticket")!;
  assert.ok(ticketGate.wires.every((w) => w.commandGlob === null));
});

test("deriveGatesFromSettings returns an empty table for settings with no PreToolUse hooks", () => {
  assert.deepEqual(deriveGatesFromSettings({}), []);
  assert.deepEqual(deriveGatesFromSettings({ hooks: {} }), []);
});

// ---------------------------------------------------------------------
// gateMatchesToolCall
// ---------------------------------------------------------------------

test("gateMatchesToolCall: a gate with an unconditional wire for this tool always matches", () => {
  const gates = deriveGatesFromSettings(fixtureSettings());
  const ticketGate = gates.find((g) => g.name === "require-active-ticket")!;
  assert.ok(gateMatchesToolCall(ticketGate, "bash", "literally anything"));
  assert.ok(gateMatchesToolCall(ticketGate, "edit", undefined));
});

test("gateMatchesToolCall: a gate with only conditional wires matches ONLY a command satisfying one of the globs", () => {
  const gates = deriveGatesFromSettings(fixtureSettings());
  const mergeGate = gates.find((g) => g.name === "block-unreviewed-merge")!;
  assert.ok(gateMatchesToolCall(mergeGate, "bash", "gh pr merge 42 --squash"));
  assert.ok(gateMatchesToolCall(mergeGate, "bash", "gh api repos/x/y/pulls/1/merge -X PUT"));
  assert.ok(!gateMatchesToolCall(mergeGate, "bash", "gh pr view 42"));
});

test("gateMatchesToolCall: a gate never matches a tool it isn't wired to at all", () => {
  const gates = deriveGatesFromSettings(fixtureSettings());
  const mergeGate = gates.find((g) => g.name === "block-unreviewed-merge")!;
  assert.ok(!gateMatchesToolCall(mergeGate, "read", undefined));
});

// ---------------------------------------------------------------------
// claudeToolNameFor
// ---------------------------------------------------------------------

test("claudeToolNameFor maps pi tool ids back to the Claude Code tool_name hooks expect, including Glob for find", () => {
  assert.equal(claudeToolNameFor("bash"), "Bash");
  assert.equal(claudeToolNameFor("edit"), "Edit");
  assert.equal(claudeToolNameFor("write"), "Write");
  assert.equal(claudeToolNameFor("read"), "Read");
  assert.equal(claudeToolNameFor("grep"), "Grep");
  assert.equal(claudeToolNameFor("find"), "Glob");
});

// ---------------------------------------------------------------------
// findUnsupportedGateWires (#840 C2, ported here as part of C5)
// ---------------------------------------------------------------------

test("findUnsupportedGateWires: a gate wired only to bash/edit/write reports nothing", () => {
  const gates: GateDefinition[] = [
    { name: "require-active-ticket", hookRelativePath: ".claude/hooks/require-active-ticket.sh", wires: [{ tool: "bash", commandGlob: null }, { tool: "edit", commandGlob: null }] },
  ];
  assert.deepEqual(findUnsupportedGateWires(gates), []);
});

test("findUnsupportedGateWires flags suggest-mcp-search.sh's read/find/grep wiring — this adapter has no pi stdin builder for those tools", () => {
  const gates = deriveGatesFromSettings(fixtureSettings());
  const found = findUnsupportedGateWires(gates);
  assert.deepEqual(
    found.map((f) => f.tool).sort(),
    ["find", "grep", "read"],
  );
  assert.ok(found.every((f) => f.gateName === "suggest-mcp-search"));
});

// ---------------------------------------------------------------------
// Drift check against THIS repo's real .claude/settings.json
// ---------------------------------------------------------------------

test("deriveGatesFromSettings, run against this repo's real .claude/settings.json, finds the named merge-gate hooks AND the hooks pi's old DEFAULT_GATES deferred", () => {
  const here = dirname(fileURLToPath(import.meta.url));
  const settingsPath = join(here, "..", "..", "..", ".claude", "settings.json");
  const raw = JSON.parse(readFileSync(settingsPath, "utf-8")) as RawSettings;
  const gates = deriveGatesFromSettings(raw);
  const names = gates.map((g) => g.name);

  for (const expected of [
    "block-unreviewed-merge",
    "block-merge-on-red-ci",
    "require-design-review-for-ui",
    "require-architecture-review",
    "check-secrets",
    "require-active-ticket",
    "require-migration-ticket",
    "block-private-refs-in-public-repos",
  ]) {
    assert.ok(names.includes(expected), `expected "${expected}" to be derived from the real settings.json`);
  }

  // The convergence this refactor exists for: NOT a curated subset anymore.
  // Every hook the old DEFAULT_GATES/README.md "Known NOT-yet-bridged
  // gates" table explicitly deferred must show up here automatically, with
  // zero adapter changes.
  for (const previouslyDeferred of [
    "validate-branch-name",
    "validate-commit-format",
    "verify-commit-refs",
    "validate-pr-create",
    "require-agdr-for-arch-pr",
    "require-skill-for-issue-create",
    "block-onboarding-in-git",
  ]) {
    assert.ok(names.includes(previouslyDeferred), `"${previouslyDeferred}" must be derived even though the old DEFAULT_GATES deferred it`);
  }
});

test("deriveGatesFromSettings, run against this repo's real .claude/settings.json, wires block-unreviewed-merge to every multi-tracker merge-shape glob", () => {
  const here = dirname(fileURLToPath(import.meta.url));
  const settingsPath = join(here, "..", "..", "..", ".claude", "settings.json");
  const raw = JSON.parse(readFileSync(settingsPath, "utf-8")) as RawSettings;
  const gates = deriveGatesFromSettings(raw);
  const mergeGate = gates.find((g) => g.name === "block-unreviewed-merge")!;
  const globs = mergeGate.wires.filter((w) => w.tool === "bash").map((w) => w.commandGlob);
  for (const expected of ["gh pr merge *", "gh api *", "glab mr merge *", "glab api *", "tracker_pr_merge *"]) {
    assert.ok(globs.includes(expected), `expected glob "${expected}" to be wired for block-unreviewed-merge`);
  }
});
