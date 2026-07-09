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
 * #840 C5 UPDATE: this dispatcher no longer hand-maintains a `DEFAULT_GATES`
 * table — it derives the full gate table from `.claude/settings.json` (see
 * `derive-gates.ts` and `test/derive-gates.test.ts`). Most cases below now
 * either pass an explicit `gates` override (unchanged mechanism, new
 * `wires`-shaped `GateDefinition`) to test `runGateHook`/dispatch logic in
 * isolation, or exercise the NEW real-derivation path against a fixture
 * ops root that carries its own `.claude/settings.json`.
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

import { registerGateDispatcher, runGateHook, deriveGatesFromOpsRoot, type GateDefinition } from "../src/gate-dispatcher.ts";

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
 *
 * Carries NO `.claude/settings.json` by default — the derivation path
 * (`deriveGatesFromOpsRoot`) treats a missing settings.json as "nothing to
 * enforce" and returns an empty gate table, so tests that don't pass an
 * explicit `gates` override naturally see zero gates fire here. Tests that
 * need to exercise real derivation call `writeSettingsJson` afterward.
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

/** Writes a `.claude/settings.json` fixture wiring `hookFileName` unconditionally to the Bash matcher. */
function writeBashHookSettings(opsRoot: string, hookFileName: string): void {
  writeFileSync(
    join(opsRoot, ".claude", "settings.json"),
    JSON.stringify({
      hooks: { PreToolUse: [{ matcher: "Bash", hooks: [{ type: "command", command: `bash -c "exec .claude/hooks/${hookFileName}"` }] }] },
    }),
  );
}

test("non-merge bash command passes through untouched (no settings.json in this fixture ops root => nothing derived)", async () => {
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

test("a hook wired in settings.json but whose file doesn't exist in this ops root is a silent no-op", async () => {
  const opsRoot = makeIsolatedOpsRoot();
  writeBashHookSettings(opsRoot, "block-unreviewed-merge.sh"); // wired, but this fixture ops root never copied that file
  const { pi, handlers } = makeMockPi();
  registerGateDispatcher(pi as any, { resolveOpsRoot: () => opsRoot });
  const toolCall = handlers.get("tool_call")!;

  const result = await toolCall({ type: "tool_call", toolCallId: "3", toolName: "bash", input: { command: "gh pr merge 1 --squash" } }, { cwd: opsRoot });
  assert.equal(result, undefined, "missing hook files must not crash or falsely block");
});

test("a custom gate hook that exits 2 is surfaced as a block with the stderr reason", async () => {
  const opsRoot = makeIsolatedOpsRoot();
  const customGates: GateDefinition[] = [
    { name: "always-block", hookRelativePath: ".claude/hooks/always-block.sh", wires: [{ tool: "bash", commandGlob: null }] },
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
    { name: "noop-allow", hookRelativePath: ".claude/hooks/noop-allow.sh", wires: [{ tool: "bash", commandGlob: null }] },
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
  const gate: GateDefinition = { name: "noisy", hookRelativePath: ".claude/hooks/noisy.sh", wires: [{ tool: "bash", commandGlob: null }] };

  const result = runGateHook(opsRoot, gate, { command: "anything" }, "Bash", /* maxBufferBytes */ 1024);
  assert.equal(result?.block, true, "an execution-layer failure (ENOBUFS) must fail CLOSED, not open");
  assert.match(result?.reason ?? "", /could not be evaluated/);
  assert.match(result?.reason ?? "", /noisy/);
});

test("FAILS CLOSED: a hook that exceeds the bounded timeout is BLOCKED, not left hanging or silently allowed (#840 C1)", () => {
  const opsRoot = makeIsolatedOpsRoot();
  // Sleeps far longer than the tiny timeout override below — simulates a
  // hung hook (network call that never returns, an accidental infinite
  // loop). execFileSync's own `timeout` option must kill it before it can
  // produce a numeric exit status, landing this on the fail-closed path.
  writeFileSync(join(opsRoot, ".claude", "hooks", "hangs.sh"), "#!/bin/bash\nsleep 5\nexit 0\n", { mode: 0o755 });
  const gate: GateDefinition = { name: "hangs", hookRelativePath: ".claude/hooks/hangs.sh", wires: [{ tool: "bash", commandGlob: null }] };

  const started = Date.now();
  const result = runGateHook(opsRoot, gate, { command: "anything" }, "Bash", /* maxBufferBytes */ undefined, /* timeoutMs */ 100);
  const elapsedMs = Date.now() - started;

  assert.equal(result?.block, true, "a hung hook must fail CLOSED, not open");
  assert.match(result?.reason ?? "", /timed out/);
  assert.match(result?.reason ?? "", /hangs/);
  assert.ok(elapsedMs < 4000, `expected the dispatcher to return well before the hook's own 5s sleep completes, took ${elapsedMs}ms`);
});

test("a hook exiting 1 (an unrelated, non-blocking bash-level error) is allowed, not blocked — only exit 2 blocks", async () => {
  const opsRoot = makeIsolatedOpsRoot();
  writeFileSync(join(opsRoot, ".claude", "hooks", "exit-one.sh"), "#!/bin/bash\nexit 1\n", { mode: 0o755 });
  const customGates: GateDefinition[] = [
    { name: "exit-one", hookRelativePath: ".claude/hooks/exit-one.sh", wires: [{ tool: "bash", commandGlob: null }] },
  ];
  const { pi, handlers } = makeMockPi();
  registerGateDispatcher(pi as any, { gates: customGates, resolveOpsRoot: () => opsRoot });
  const toolCall = handlers.get("tool_call")!;

  const result = await toolCall({ type: "tool_call", toolCallId: "9", toolName: "bash", input: { command: "anything" } }, { cwd: opsRoot });
  assert.equal(result, undefined, "exit code 1 is not exit code 2 — must not block, matching Claude Code's own PreToolUse semantics");
});

test("no ops root resolved => dispatcher is a silent no-op (fails toward not-enforcing, never toward false-blocking)", async () => {
  const { pi, handlers } = makeMockPi();
  registerGateDispatcher(pi as any, { resolveOpsRoot: () => undefined });
  const toolCall = handlers.get("tool_call")!;

  const result = await toolCall({ type: "tool_call", toolCallId: "6", toolName: "bash", input: { command: "gh pr merge 1 --squash" } }, { cwd: "/nonexistent" });
  assert.equal(result, undefined);
});

// ---------------------------------------------------------------------
// #840 C5 — real settings.json-derived dispatch, end to end, against an
// isolated fixture ops root (no real repo state needed). Proves the NEW
// derive-per-call path — not just derive-gates.ts's own unit tests — wires
// correctly into registerGateDispatcher's dispatch loop.
// ---------------------------------------------------------------------

test("registerGateDispatcher, with NO explicit gates, derives from a real settings.json in the ops root and blocks through it end-to-end", async () => {
  const opsRoot = makeIsolatedOpsRoot();
  writeFileSync(join(opsRoot, ".claude", "hooks", "always-block.sh"), "#!/bin/bash\necho 'blocked via real derivation' >&2\nexit 2\n", { mode: 0o755 });
  writeBashHookSettings(opsRoot, "always-block.sh");

  const { pi, handlers } = makeMockPi();
  registerGateDispatcher(pi as any, { resolveOpsRoot: () => opsRoot }); // no `gates:` override — must derive
  const toolCall = handlers.get("tool_call")!;

  const result = await toolCall({ type: "tool_call", toolCallId: "10", toolName: "bash", input: { command: "anything" } }, { cwd: opsRoot });
  assert.equal(result?.block, true);
  assert.match(result?.reason ?? "", /blocked via real derivation/);
});

test("registerGateDispatcher re-derives per call — a settings.json edited mid-session is picked up on the next tool call", async () => {
  const opsRoot = makeIsolatedOpsRoot();
  const { pi, handlers } = makeMockPi();
  registerGateDispatcher(pi as any, { resolveOpsRoot: () => opsRoot }); // no settings.json yet — first call sees nothing
  const toolCall = handlers.get("tool_call")!;

  const before = await toolCall({ type: "tool_call", toolCallId: "11a", toolName: "bash", input: { command: "anything" } }, { cwd: opsRoot });
  assert.equal(before, undefined, "no settings.json yet => nothing derived, nothing enforced");

  // Now wire a gate mid-"session" (this is exactly what a live settings.json edit looks like).
  writeBashHookSettings(opsRoot, "always-block.sh");
  const after = await toolCall({ type: "tool_call", toolCallId: "11b", toolName: "bash", input: { command: "anything" } }, { cwd: opsRoot });
  assert.equal(after?.block, true, "the newly-wired gate must be picked up on the very next call — no cache to invalidate");
});

// ---------------------------------------------------------------------
// deriveGatesFromOpsRoot's parse-failure warning (#840 C3, ported here as
// part of C5's consistency with the opencode adapter's identical fix).
// ---------------------------------------------------------------------

/** Captures everything written to process.stderr while `fn` runs, restoring the real stream afterward even if `fn` throws. */
async function captureStderr(fn: () => void | Promise<void>): Promise<string> {
  const originalWrite = process.stderr.write.bind(process.stderr);
  const written: string[] = [];
  process.stderr.write = ((chunk: string) => {
    written.push(String(chunk));
    return true;
  }) as typeof process.stderr.write;
  try {
    await fn();
  } finally {
    process.stderr.write = originalWrite;
  }
  return written.join("");
}

test("deriveGatesFromOpsRoot: a malformed settings.json warns to stderr and returns an empty gate table", async () => {
  const opsRoot = makeIsolatedOpsRoot();
  writeFileSync(join(opsRoot, ".claude", "settings.json"), "{ not valid json");

  let gates: GateDefinition[] = [];
  const combined = await captureStderr(() => {
    gates = deriveGatesFromOpsRoot(opsRoot, ".claude/settings.json");
  });

  assert.deepEqual(gates, [], "a broken settings.json must fail toward not-enforcing, not throw");
  assert.match(combined, /WARNING/);
  assert.match(combined, /settings\.json/);
});

test("deriveGatesFromOpsRoot: a missing settings.json is silent (the expected \"nothing to enforce\" case, not a broken-config case)", async () => {
  const opsRoot = makeIsolatedOpsRoot(); // never gets a settings.json written

  let gates: GateDefinition[] = [];
  const combined = await captureStderr(() => {
    gates = deriveGatesFromOpsRoot(opsRoot, ".claude/settings.json");
  });

  assert.deepEqual(gates, []);
  assert.equal(combined, "", "a missing file is not a parse failure — warning here would be noise for every non-apexyard session");
});

test("registerGateDispatcher warns to stderr, once, when a derived gate is wired to a tool with no pi stdin builder (read/find/grep)", async () => {
  const opsRoot = makeIsolatedOpsRoot();
  writeFileSync(
    join(opsRoot, ".claude", "settings.json"),
    JSON.stringify({
      hooks: {
        PreToolUse: [{ matcher: "Read|Glob|Grep", hooks: [{ type: "command", command: 'bash -c "exec .claude/hooks/suggest-mcp-search.sh"' }] }],
      },
    }),
  );
  writeFileSync(join(opsRoot, ".claude", "hooks", "suggest-mcp-search.sh"), "#!/bin/bash\nexit 0\n", { mode: 0o755 });

  const { pi, handlers } = makeMockPi();
  registerGateDispatcher(pi as any, { resolveOpsRoot: () => opsRoot });
  const toolCall = handlers.get("tool_call")!;

  const combined = await captureStderr(async () => {
    // Two calls — the warning must appear only once (deduped), not twice.
    await toolCall({ type: "tool_call", toolCallId: "12a", toolName: "read", input: { path: "README.md" } }, { cwd: opsRoot });
    await toolCall({ type: "tool_call", toolCallId: "12b", toolName: "read", input: { path: "README.md" } }, { cwd: opsRoot });
  });

  const warningLines = combined.split("\n").filter((l) => l.includes("suggest-mcp-search") && l.includes("read"));
  assert.equal(warningLines.length, 1, `expected exactly one deduped warning line, got:\n${combined}`);
});

// ---------------------------------------------------------------------
// LIVE cases against the real repo's real block-unreviewed-merge.sh and
// real `gh` state — same two cases the spike #804 harness proved. These
// only run when APEXYARD_TEST_REPO_ROOT points at a real apexyard ops
// root (the checkout these tests live in), keeping the default `node
// --test` run fully offline/hermetic via the fixtures above. Under #840
// C5, "no gates override" now derives the FULL real gate table from the
// real repo's real settings.json (previously the curated DEFAULT_GATES) —
// block-unreviewed-merge.sh is still derived and still fires the same way.
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

void execFileSync;
void cpSync;
