/**
 * derive-gates.test.ts — proves the settings.json-derived gate table
 * behaves correctly, without needing the real @opencode-ai/plugin package
 * or a real .claude/settings.json on disk (fixture JSON only — hermetic).
 *
 * A second block at the bottom parses THIS repo's own real
 * .claude/settings.json, so a drift between the parser's assumptions and
 * the framework's actual wiring shape is caught here, not just against a
 * hand-written fixture.
 */

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

import {
  buildToolInput,
  claudeToolNameFor,
  deriveGatesFromSettings,
  extractCommandGlob,
  extractHookRelativePath,
  findUnsupportedGateWires,
  gateMatchesToolCall,
  globToRegExp,
  type GateDefinition,
  type RawSettings,
} from "../src/derive-gates.ts";

// ---------------------------------------------------------------------
// extractHookRelativePath / extractCommandGlob — the two regex extractors
// ---------------------------------------------------------------------

test("extractHookRelativePath finds the .claude/hooks/*.sh path inside the ops-root-pin wrapper command", () => {
  const command =
    "bash -c 'r=\"\";if [ -n \"${CLAUDE_CODE_SESSION_ID:-}\" ];then p=...;fi; INPUT=$(cat); echo \"$INPUT\" | bash \"$r/.claude/hooks/block-unreviewed-merge.sh\"'";
  assert.equal(extractHookRelativePath(command), ".claude/hooks/block-unreviewed-merge.sh");
});

test("extractHookRelativePath returns undefined for a command with no .claude/hooks/*.sh reference", () => {
  assert.equal(extractHookRelativePath("echo hello"), undefined);
  assert.equal(extractHookRelativePath(undefined), undefined);
});

test("extractCommandGlob extracts the glob from a Bash(<glob>) if predicate", () => {
  assert.equal(extractCommandGlob("Bash(gh pr merge *)"), "gh pr merge *");
  assert.equal(extractCommandGlob("Bash(git commit *)"), "git commit *");
});

test("extractCommandGlob returns undefined for a non-Bash(...) or missing predicate", () => {
  assert.equal(extractCommandGlob(undefined), undefined);
  assert.equal(extractCommandGlob("Edit(*.ts)"), undefined); // this framework never emits this shape today, but the parser shouldn't crash on it
});

// ---------------------------------------------------------------------
// globToRegExp
// ---------------------------------------------------------------------

test("globToRegExp matches a Claude Code Bash(...) glob against a real command string", () => {
  const re = globToRegExp("gh pr merge *");
  assert.ok(re.test("gh pr merge 123 --squash"));
  assert.ok(!re.test("gh pr view 123"));
});

test("globToRegExp anchors — a glob must match the whole command, not a substring", () => {
  const re = globToRegExp("git commit *");
  assert.ok(!re.test("echo 'not git commit at all but contains git commit inside'"));
});

// ---------------------------------------------------------------------
// deriveGatesFromSettings — the core parser
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
            {
              type: "command",
              command: "bash -c '.../.claude/hooks/block-unreviewed-merge.sh'",
              if: "Bash(gh pr merge *)",
            },
            {
              type: "command",
              command: "bash -c '.../.claude/hooks/block-unreviewed-merge.sh'",
              if: "Bash(gh api *)",
            },
            {
              type: "command",
              command: "bash -c '.../.claude/hooks/check-secrets.sh'",
              if: "Bash(git commit *)",
            },
          ],
        },
      ],
    },
  };
}

test("deriveGatesFromSettings collapses multiple wiring rows for the same hook into one GateDefinition", () => {
  const gates = deriveGatesFromSettings(fixtureSettings());
  const mergeGate = gates.find((g) => g.name === "block-unreviewed-merge");
  assert.ok(mergeGate, "block-unreviewed-merge gate must be derived");
  assert.equal(mergeGate!.hookRelativePath, ".claude/hooks/block-unreviewed-merge.sh");
  // Two `if` rows for the same tool -> two wires, not deduped into one.
  const bashWires = mergeGate!.wires.filter((w) => w.tool === "bash");
  assert.equal(bashWires.length, 2);
  assert.deepEqual(
    bashWires.map((w) => w.commandGlob).sort(),
    ["gh api *", "gh pr merge *"],
  );
});

test("deriveGatesFromSettings marks a hook unconditional for a tool when any row for that tool has no `if`", () => {
  const gates = deriveGatesFromSettings(fixtureSettings());
  const ticketGate = gates.find((g) => g.name === "require-active-ticket");
  assert.ok(ticketGate);
  // Wired under both Edit|Write|MultiEdit (no if) and Bash (no if) -> every
  // wire for every one of those tools is unconditional.
  assert.ok(ticketGate!.wires.some((w) => w.tool === "edit" && w.commandGlob === null));
  assert.ok(ticketGate!.wires.some((w) => w.tool === "write" && w.commandGlob === null));
  assert.ok(ticketGate!.wires.some((w) => w.tool === "bash" && w.commandGlob === null));
});

test("deriveGatesFromSettings derives every hook, not a curated subset — check-secrets.sh (not in pi's DEFAULT_GATES omission list logic) is present", () => {
  const gates = deriveGatesFromSettings(fixtureSettings());
  assert.ok(gates.some((g) => g.name === "check-secrets"));
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
// buildToolInput / claudeToolNameFor — the stdin-construction unit tests
// ---------------------------------------------------------------------

test("buildToolInput reconstructs {command} for the bash tool from output.args.command", () => {
  assert.deepEqual(buildToolInput("bash", { args: { command: "gh pr merge 1" } }), { command: "gh pr merge 1" });
});

test("buildToolInput reconstructs {file_path} for edit/write from output.args.filePath", () => {
  assert.deepEqual(buildToolInput("edit", { args: { filePath: "/repo/src/foo.ts" } }), { file_path: "/repo/src/foo.ts" });
  assert.deepEqual(buildToolInput("write", { args: { filePath: "/repo/src/bar.ts" } }), { file_path: "/repo/src/bar.ts" });
});

// ---------------------------------------------------------------------
// findUnsupportedGateWires (#840 C2) — the "fail loud, don't guess" guard
// for gates wired to read/glob/grep, which buildToolInput has no stdin
// builder for.
// ---------------------------------------------------------------------

test("findUnsupportedGateWires: a gate wired only to bash/edit/write reports nothing", () => {
  const gates: GateDefinition[] = [
    { name: "require-active-ticket", hookRelativePath: ".claude/hooks/require-active-ticket.sh", wires: [{ tool: "bash", commandGlob: null }, { tool: "edit", commandGlob: null }] },
  ];
  assert.deepEqual(findUnsupportedGateWires(gates), []);
});

test("findUnsupportedGateWires: a gate wired to read/glob/grep is reported, once per tool", () => {
  const gates: GateDefinition[] = [
    {
      name: "suggest-mcp-search",
      hookRelativePath: ".claude/hooks/suggest-mcp-search.sh",
      wires: [
        { tool: "bash", commandGlob: "grep *" },
        { tool: "read", commandGlob: null },
        { tool: "glob", commandGlob: null },
        { tool: "grep", commandGlob: null },
      ],
    },
  ];
  const found = findUnsupportedGateWires(gates);
  assert.deepEqual(
    found.map((f) => f.tool).sort(),
    ["glob", "grep", "read"],
  );
  assert.ok(found.every((f) => f.gateName === "suggest-mcp-search"));
});

test("findUnsupportedGateWires, run against this repo's real .claude/settings.json, flags suggest-mcp-search.sh's Read/Glob/Grep wiring", () => {
  const here = dirname(fileURLToPath(import.meta.url));
  const settingsPath = join(here, "..", "..", "..", ".claude", "settings.json");
  const raw = JSON.parse(readFileSync(settingsPath, "utf-8")) as RawSettings;
  const gates = deriveGatesFromSettings(raw);
  const found = findUnsupportedGateWires(gates);
  assert.ok(
    found.some((f) => f.gateName === "suggest-mcp-search" && f.tool === "read"),
    "the real settings.json wires suggest-mcp-search.sh to Read|Glob|Grep — this must surface as an unsupported wire, not silently vanish",
  );
});

test("buildToolInput returns undefined when the expected field is missing or the wrong type", () => {
  assert.equal(buildToolInput("bash", { args: {} }), undefined);
  assert.equal(buildToolInput("bash", { args: { command: 123 } }), undefined);
  assert.equal(buildToolInput("edit", { args: {} }), undefined);
  assert.equal(buildToolInput("bash", undefined), undefined);
});

test("buildToolInput returns undefined for a tool this dispatcher doesn't reconstruct input for (e.g. read/grep/glob)", () => {
  assert.equal(buildToolInput("read", { args: { filePath: "/repo/README.md" } }), undefined);
});

test("claudeToolNameFor maps opencode tool ids back to the Claude Code tool_name hooks expect", () => {
  assert.equal(claudeToolNameFor("bash"), "Bash");
  assert.equal(claudeToolNameFor("edit"), "Edit");
  assert.equal(claudeToolNameFor("write"), "Write");
  assert.equal(claudeToolNameFor("read"), "Read");
});

// ---------------------------------------------------------------------
// Drift check against THIS repo's real .claude/settings.json — proves the
// parser's assumptions hold against the framework's actual wiring, not
// just a hand-written fixture.
// ---------------------------------------------------------------------

test("deriveGatesFromSettings, run against this repo's real .claude/settings.json, finds the named merge-gate hooks", () => {
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

  // The convergence this module exists for: NOT a curated subset. Hooks pi's
  // DEFAULT_GATES explicitly defers (see pi/README.md "Known NOT-yet-bridged
  // gates") must show up here automatically, with zero adapter changes.
  for (const deferredByPi of ["validate-branch-name", "validate-commit-format", "validate-pr-create", "require-skill-for-issue-create"]) {
    assert.ok(names.includes(deferredByPi), `"${deferredByPi}" must be derived even though pi's hand-maintained table defers it`);
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
