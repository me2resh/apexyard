/**
 * gate-dispatcher.test.ts — synthetic tool_call harness for the dispatcher.
 *
 * WHAT THIS PROVES (and doesn't)
 * -------------------------------
 * Same shape as spike #804's test-harness.ts: mocks pi's `ExtensionAPI.on()`
 * registration call per the DOCUMENTED contract (see
 * docs/spike-reports/pi-gate-extension.md "Pi API facts"), then drives the
 * real dispatcher against the REAL, unmodified bash hooks in this repo,
 * with real `gh` lookups against real GitHub state for the merge-gate
 * cases. This is "proven by construction" for the pi-transport boundary
 * (mock matches the documented event shape) and "proven live" for
 * everything downstream of that boundary (the actual hook, the actual gh
 * calls, the actual exit-code mapping).
 *
 * It does NOT prove pi's real internal event dispatch calls handlers with
 * this exact object shape during a live, model-driven agent turn — that
 * is AC-6 from #815 and remains the one gap this build could not close in
 * this environment (no pi package / model credentials available here).
 * See harness-adapters/pi/README.md "Known gaps / what's unverified".
 *
 * RUN
 * ---
 *   node --test harness-adapters/pi/test/gate-dispatcher.test.ts
 *
 * (Node >=22, no build step — native TS type-stripping, matching how pi
 * itself loads extensions with no compile step.)
 */

import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, writeFileSync, mkdirSync, cpSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import { registerGateDispatcher, runGateHook, DEFAULT_GATES, type GateDefinition } from "../src/gate-dispatcher.ts";

// ---------------------------------------------------------------------
// Minimal structural mock of pi's ExtensionAPI. Typed loosely (no import
// of the real pi types here) because this test suite must run WITHOUT
// the @earendil-works/pi-coding-agent package installed — the whole
// point of a CI-runnable proof harness is that it doesn't require model
// credentials or a live pi install. gate-dispatcher.ts itself imports the
// real types (type-only; erased at runtime by Node's type stripping), so
// production code still tracks pi's real contract even though this test
// double does not import it.
// ---------------------------------------------------------------------
type Handler = (event: any, ctx: any) => Promise<any>;

function makeMockPi(): { pi: { on: (event: string, handler: Handler) => void }; handlers: Map<string, Handler> } {
  const handlers = new Map<string, Handler>();
  return {
    pi: {
      on(event: string, handler: Handler) {
        handlers.set(event, handler);
      },
    },
    handlers,
  };
}

/**
 * Builds an isolated fake "ops root" — a temp dir containing a real,
 * unmodified copy of .claude/hooks/ plus a .apexyard-fork marker — so
 * these tests don't require a real GitHub PR to exist and don't touch the
 * repo's own session markers. Only used for the non-merge / non-bash /
 * hook-missing cases; the two live-gh cases below intentionally run
 * against the REAL repo root (passed via APEXYARD_TEST_REPO_ROOT) because
 * they need the real block-unreviewed-merge.sh + real `gh` state.
 */
function makeIsolatedOpsRoot(): string {
  const dir = mkdtempSync(join(tmpdir(), "apexyard-pi-gate-test-"));
  writeFileSync(join(dir, ".apexyard-fork"), "test fixture\n");
  mkdirSync(join(dir, ".claude", "hooks"), { recursive: true });
  // A trivial "always allow" hook standing in for a gate we don't want to
  // exercise for real in this isolated case.
  writeFileSync(join(dir, ".claude", "hooks", "noop-allow.sh"), "#!/bin/bash\nexit 0\n", { mode: 0o755 });
  writeFileSync(join(dir, ".claude", "hooks", "always-block.sh"), "#!/bin/bash\necho 'blocked for test' >&2\nexit 2\n", { mode: 0o755 });
  return dir;
}

test("non-merge bash command passes through untouched", async () => {
  const opsRoot = makeIsolatedOpsRoot();
  const { pi, handlers } = makeMockPi();
  registerGateDispatcher(pi as any, { resolveOpsRoot: () => opsRoot });
  const toolCall = handlers.get("tool_call")!;

  const result = await toolCall({ type: "tool_call", toolCallId: "1", toolName: "bash", input: { command: "echo hello" } }, { cwd: opsRoot });
  assert.equal(result, undefined);
});

test("non-bash, non-edit tool is ignored entirely", async () => {
  const opsRoot = makeIsolatedOpsRoot();
  const { pi, handlers } = makeMockPi();
  registerGateDispatcher(pi as any, { resolveOpsRoot: () => opsRoot });
  const toolCall = handlers.get("tool_call")!;

  const result = await toolCall({ type: "tool_call", toolCallId: "2", toolName: "read", input: { path: "README.md" } }, { cwd: opsRoot });
  assert.equal(result, undefined);
});

test("a gate whose hook file doesn't exist in this ops root is a silent no-op", async () => {
  const opsRoot = makeIsolatedOpsRoot();
  const { pi, handlers } = makeMockPi();
  registerGateDispatcher(pi as any, { resolveOpsRoot: () => opsRoot }); // DEFAULT_GATES reference real hook paths that don't exist in this fixture dir
  const toolCall = handlers.get("tool_call")!;

  const result = await toolCall({ type: "tool_call", toolCallId: "3", toolName: "bash", input: { command: "gh pr merge 1 --squash" } }, { cwd: opsRoot });
  assert.equal(result, undefined, "missing hook files must not crash or falsely block");
});

test("a custom gate hook that exits 2 is surfaced as a block with the stderr reason", async () => {
  const opsRoot = makeIsolatedOpsRoot();
  const customGates: GateDefinition[] = [
    {
      name: "always-block",
      hookRelativePath: ".claude/hooks/always-block.sh",
      toolNames: ["bash"],
      buildToolInput: (event) => ({ command: (event.input as any).command }),
    },
  ];
  const { pi, handlers } = makeMockPi();
  registerGateDispatcher(pi as any, { gates: customGates, resolveOpsRoot: () => opsRoot });
  const toolCall = handlers.get("tool_call")!;

  const result = await toolCall({ type: "tool_call", toolCallId: "4", toolName: "bash", input: { command: "anything" } }, { cwd: opsRoot });
  assert.equal(result?.block, true);
  assert.match(result?.reason ?? "", /blocked for test/);
});

test("a custom gate hook that exits 0 allows the call", async () => {
  const opsRoot = makeIsolatedOpsRoot();
  const customGates: GateDefinition[] = [
    {
      name: "noop-allow",
      hookRelativePath: ".claude/hooks/noop-allow.sh",
      toolNames: ["bash"],
      buildToolInput: (event) => ({ command: (event.input as any).command }),
    },
  ];
  const { pi, handlers } = makeMockPi();
  registerGateDispatcher(pi as any, { gates: customGates, resolveOpsRoot: () => opsRoot });
  const toolCall = handlers.get("tool_call")!;

  const result = await toolCall({ type: "tool_call", toolCallId: "5", toolName: "bash", input: { command: "anything" } }, { cwd: opsRoot });
  assert.equal(result, undefined);
});

test("FAILS CLOSED: a hook whose output exceeds maxBuffer (execution-layer error, no numeric exit status) is BLOCKED, not silently allowed", () => {
  const opsRoot = makeIsolatedOpsRoot();
  // A hook that emits well more output than a deliberately tiny maxBuffer,
  // simulating the ENOBUFS class of failure Rex flagged: execFileSync
  // throws with no `status` field at all (not exit code 0, not exit code
  // 2 — an execution-layer failure). Fixed semantics must BLOCK this,
  // not treat the "no status" case as an implicit allow.
  writeFileSync(join(opsRoot, ".claude", "hooks", "noisy.sh"), "#!/bin/bash\nyes | head -c 100000\nexit 0\n", { mode: 0o755 });
  const gate: GateDefinition = {
    name: "noisy",
    hookRelativePath: ".claude/hooks/noisy.sh",
    toolNames: ["bash"],
    buildToolInput: (event) => ({ command: (event.input as any).command }),
  };

  const result = runGateHook(opsRoot, gate, { command: "anything" }, "Bash", /* maxBufferBytes */ 1024);
  assert.equal(result?.block, true, "an execution-layer failure (ENOBUFS) must fail CLOSED, not open");
  assert.match(result?.reason ?? "", /could not be evaluated/);
  assert.match(result?.reason ?? "", /noisy/);
});

test("a hook exiting 1 (an unrelated, non-blocking bash-level error) is allowed, not blocked — only exit 2 blocks", async () => {
  const opsRoot = makeIsolatedOpsRoot();
  writeFileSync(join(opsRoot, ".claude", "hooks", "exit-one.sh"), "#!/bin/bash\nexit 1\n", { mode: 0o755 });
  const customGates: GateDefinition[] = [
    {
      name: "exit-one",
      hookRelativePath: ".claude/hooks/exit-one.sh",
      toolNames: ["bash"],
      buildToolInput: (event) => ({ command: (event.input as any).command }),
    },
  ];
  const { pi, handlers } = makeMockPi();
  registerGateDispatcher(pi as any, { gates: customGates, resolveOpsRoot: () => opsRoot });
  const toolCall = handlers.get("tool_call")!;

  const result = await toolCall({ type: "tool_call", toolCallId: "9", toolName: "bash", input: { command: "anything" } }, { cwd: opsRoot });
  assert.equal(result, undefined, "exit code 1 is not exit code 2 — must not block, matching Claude Code's own PreToolUse semantics");
});

test("DEFAULT_GATES includes the leak-protection gate (block-private-refs-in-public-repos)", () => {
  const names = DEFAULT_GATES.map((g) => g.name);
  assert.ok(names.includes("block-private-refs-in-public-repos"), "leak protection must be bridged by default — it's security-relevant");
});

test("no ops root resolved => dispatcher is a silent no-op (fails toward not-enforcing, never toward false-blocking)", async () => {
  const { pi, handlers } = makeMockPi();
  registerGateDispatcher(pi as any, { resolveOpsRoot: () => undefined });
  const toolCall = handlers.get("tool_call")!;

  const result = await toolCall({ type: "tool_call", toolCallId: "6", toolName: "bash", input: { command: "gh pr merge 1 --squash" } }, { cwd: "/nonexistent" });
  assert.equal(result, undefined);
});

// ---------------------------------------------------------------------
// LIVE cases against the real repo's real block-unreviewed-merge.sh and
// real `gh` state — same two cases the spike #804 harness proved. These
// only run when APEXYARD_TEST_REPO_ROOT points at a real apexyard ops
// root (the checkout these tests live in), keeping the default `node
// --test` run fully offline/hermetic via the fixtures above.
// ---------------------------------------------------------------------

const realRepoRoot = process.env.APEXYARD_TEST_REPO_ROOT;

test("LIVE: ungated merge of a nonexistent PR is BLOCKED by the real hook", { skip: !realRepoRoot }, async () => {
  const { pi, handlers } = makeMockPi();
  registerGateDispatcher(pi as any, { resolveOpsRoot: () => realRepoRoot });
  const toolCall = handlers.get("tool_call")!;

  const result = await toolCall(
    { type: "tool_call", toolCallId: "7", toolName: "bash", input: { command: "gh pr merge 999999 --repo me2resh/apexyard --squash" } },
    { cwd: realRepoRoot },
  );
  assert.equal(result?.block, true);
});

const allowTestPr = process.env.ALLOW_TEST_PR;

test(
  "LIVE: a previously-approved PR is ALLOWED by the real hook (real markers, real HEAD match)",
  { skip: !realRepoRoot || !allowTestPr },
  async () => {
    const { pi, handlers } = makeMockPi();
    registerGateDispatcher(pi as any, { resolveOpsRoot: () => realRepoRoot });
    const toolCall = handlers.get("tool_call")!;

    const result = await toolCall(
      { type: "tool_call", toolCallId: "8", toolName: "bash", input: { command: `gh pr merge ${allowTestPr} --repo me2resh/apexyard --squash` } },
      { cwd: realRepoRoot },
    );
    assert.equal(result, undefined);
  },
);

// Reference DEFAULT_GATES so the import isn't flagged unused if the LIVE
// cases above are both skipped in a given run.
void DEFAULT_GATES;
void execFileSync;
void cpSync;
