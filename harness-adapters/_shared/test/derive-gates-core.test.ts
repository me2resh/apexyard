/**
 * derive-gates-core.test.ts — proves the harness-agnostic settings.json
 * parser behaves correctly on its own, independent of either runtime's
 * tool-id translation layer (opencode's and pi's own `derive-gates.ts`
 * test suites separately prove their translation is correct on top of
 * this). Run: `node --test harness-adapters/_shared/test/derive-gates-core.test.ts`.
 */

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

import {
  deriveGatesFromSettings,
  extractCommandGlob,
  extractHookRelativePath,
  gateMatchesClaudeMatcher,
  globToRegExp,
  type RawSettings,
} from "../derive-gates-core.ts";

// ---------------------------------------------------------------------
// extractHookRelativePath / extractCommandGlob
// ---------------------------------------------------------------------

test("extractHookRelativePath finds the .claude/hooks/*.sh path inside the ops-root-pin wrapper command", () => {
  const command =
    "bash -c 'r=\"\";if [ -n \"${CLAUDE_CODE_SESSION_ID:-}\" ];then p=...;fi; INPUT=$(cat); echo \"$INPUT\" | bash \"$r/.claude/hooks/block-unreviewed-merge.sh\"'";
  assert.equal(extractHookRelativePath(command), ".claude/hooks/block-unreviewed-merge.sh");
});

test("extractHookRelativePath returns undefined for a command with no .claude/hooks/*.sh reference", () => {
  assert.equal(extractHookRelativePath("echo hello"), undefined);
});

test("extractCommandGlob extracts the glob from a Bash(<glob>) if predicate", () => {
  assert.equal(extractCommandGlob("Bash(gh pr merge *)"), "gh pr merge *");
});

test("extractCommandGlob returns undefined for a non-Bash(...) or missing predicate", () => {
  assert.equal(extractCommandGlob(undefined), undefined);
  assert.equal(extractCommandGlob("Edit(*)"), undefined);
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

// Regression test for #899: globToRegExp must carry the `s` (dotall) flag so
// `.*` crosses embedded newlines. Without it, a multi-line command string
// (the conventional-commit norm — a subject line plus a body) fails to
// match its own `Bash(<prefix> *)` glob, and the consuming gate is silently
// skipped (fail-open) instead of firing. Both assertions below FAIL if the
// `s` flag is removed from globToRegExp's `new RegExp(...)` call.
test("globToRegExp — the derived RegExp carries the dotall (s) flag, so it matches across embedded newlines (#899)", () => {
  const re = globToRegExp("git commit *");
  assert.ok(re.flags.includes("s"), "globToRegExp's RegExp must carry the `s` (dotall) flag");
});

test("globToRegExp matches a multi-line `git commit -m` command (conventional-commit subject + body) — #899", () => {
  const re = globToRegExp("git commit *");
  // Real embedded newlines (template literal), not escaped "\n" text — this
  // is what a shell actually hands the hook for `git commit -m $'subject\n\nbody'`.
  const multiLineCommit = `git commit -m $'feat: add widget

- detail one
- detail two

Closes #1'`;
  assert.ok(re.test(multiLineCommit), "a multi-line git commit command must match its own Bash(git commit *) glob");
});

test("globToRegExp matches a multi-line `gh issue create --body` command — #899", () => {
  const re = globToRegExp("gh issue create *");
  const multiLineIssueCreate = `gh issue create --title "Bug: X" --body "Given a user
When they do Y
Then Z happens

Repro steps here."`;
  assert.ok(
    re.test(multiLineIssueCreate),
    "a multi-line gh issue create --body command must match its own Bash(gh issue create *) glob",
  );
});

// ---------------------------------------------------------------------
// deriveGatesFromSettings — keyed by raw Claude matcher token, not by any
// runtime's tool id.
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
  assert.ok(mergeGate!.wires.every((w) => w.claudeMatcher === "Bash"));
});

test("deriveGatesFromSettings keeps wires keyed by the RAW matcher token, one wire per token in a piped matcher group", () => {
  const gates = deriveGatesFromSettings(fixtureSettings());
  const ticketGate = gates.find((g) => g.name === "require-active-ticket")!;
  const matchers = ticketGate.wires.map((w) => w.claudeMatcher).sort();
  assert.deepEqual(matchers, ["Bash", "Edit", "MultiEdit", "Write"]);
});

test("deriveGatesFromSettings marks a hook unconditional for a matcher when its row has no `if`", () => {
  const gates = deriveGatesFromSettings(fixtureSettings());
  const ticketGate = gates.find((g) => g.name === "require-active-ticket")!;
  assert.ok(ticketGate.wires.every((w) => w.commandGlob === null));
});

test("deriveGatesFromSettings only applies commandGlob to the Bash matcher — non-Bash rows never carry an `if` in this framework's own wiring", () => {
  const gates = deriveGatesFromSettings(fixtureSettings());
  const mcpGate = gates.find((g) => g.name === "suggest-mcp-search")!;
  assert.ok(mcpGate.wires.every((w) => w.commandGlob === null));
  assert.deepEqual(
    mcpGate.wires.map((w) => w.claudeMatcher).sort(),
    ["Glob", "Grep", "Read"],
  );
});

test("deriveGatesFromSettings returns an empty table for settings with no PreToolUse hooks", () => {
  assert.deepEqual(deriveGatesFromSettings({}), []);
  assert.deepEqual(deriveGatesFromSettings({ hooks: {} }), []);
});

// ---------------------------------------------------------------------
// gateMatchesClaudeMatcher
// ---------------------------------------------------------------------

test("gateMatchesClaudeMatcher: a gate with an unconditional wire for this matcher always matches", () => {
  const gates = deriveGatesFromSettings(fixtureSettings());
  const ticketGate = gates.find((g) => g.name === "require-active-ticket")!;
  assert.ok(gateMatchesClaudeMatcher(ticketGate, "Bash", "literally anything"));
  assert.ok(gateMatchesClaudeMatcher(ticketGate, "Edit", undefined));
});

test("gateMatchesClaudeMatcher: a gate with only conditional wires matches ONLY a command satisfying one of the globs", () => {
  const gates = deriveGatesFromSettings(fixtureSettings());
  const mergeGate = gates.find((g) => g.name === "block-unreviewed-merge")!;
  assert.ok(gateMatchesClaudeMatcher(mergeGate, "Bash", "gh pr merge 42 --squash"));
  assert.ok(gateMatchesClaudeMatcher(mergeGate, "Bash", "gh api repos/x/y/pulls/1/merge -X PUT"));
  assert.ok(!gateMatchesClaudeMatcher(mergeGate, "Bash", "gh pr view 42"));
});

test("gateMatchesClaudeMatcher: a gate never matches a matcher it isn't wired to at all", () => {
  const gates = deriveGatesFromSettings(fixtureSettings());
  const mergeGate = gates.find((g) => g.name === "block-unreviewed-merge")!;
  assert.ok(!gateMatchesClaudeMatcher(mergeGate, "Read", undefined));
});

// ---------------------------------------------------------------------
// Drift check + cross-runtime parity: run against THIS repo's real
// .claude/settings.json, and prove the core produces the exact same gate
// set opencode's own (translated) derive-gates.ts does — the parity claim
// #840 C5's "reuse where the two runtimes allow" rests on.
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
    "suggest-mcp-search",
  ]) {
    assert.ok(names.includes(expected), `expected "${expected}" to be derived from the real settings.json`);
  }
});

test("deriveGatesFromSettings, run against this repo's real .claude/settings.json, produces the same gate names opencode's translated derive-gates.ts does", async () => {
  const here = dirname(fileURLToPath(import.meta.url));
  const settingsPath = join(here, "..", "..", "..", ".claude", "settings.json");
  const raw = JSON.parse(readFileSync(settingsPath, "utf-8")) as RawSettings;

  const coreGates = deriveGatesFromSettings(raw);
  const opencodeModule = await import("../../opencode/src/derive-gates.ts");
  const opencodeGates = opencodeModule.deriveGatesFromSettings(raw);

  assert.deepEqual(coreGates.map((g) => g.name).sort(), opencodeGates.map((g) => g.name).sort());
});
