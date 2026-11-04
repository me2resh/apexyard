/**
 * gate-dispatcher.test.ts — unit tests for the plugin's tool.execute.before
 * handler, exercising the stdin-construction -> exec -> exit-code-mapping
 * path with the subprocess exec MOCKED (per #821's explicit "mock the
 * exec" test requirement). These run fully offline/hermetic — no real
 * bash hook is spawned here.
 *
 * A companion smoke script (`test/smoke-block-unreviewed-merge.sh`) proves
 * the REAL, unmodified `block-unreviewed-merge.sh` blocks through this
 * same dispatcher code, with a real subprocess exec, in a fixture ops
 * root — that's the "proven against a real hook" half; this file is the
 * "proven by construction against the documented contract" half. Same
 * split the pi adapter's test suite uses between its synthetic cases and
 * its LIVE cases.
 */

import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import {
  apexyardGateDispatcher,
  buildToolExecuteBeforeHandler,
  createV1Hooks,
  registerGateDispatcher,
  runGateHook,
  execGateHookReal,
  deriveGatesFromOpsRoot,
  type ExecGateHook,
  type GateDispatcherContext,
  type ToolExecuteBeforeEvent,
} from "../src/gate-dispatcher.ts";
import type { GateDefinition } from "../src/derive-gates.ts";

const OPS_ROOT = "/fixture/ops-root"; // never touched — existsSync short-circuits before any real exec in the "hook not found" cases; mocked exec never inspects the filesystem either

function mockExec(responses: Record<string, { status: number | null; stderr: string }>): { exec: ExecGateHook; calls: Array<{ hookPath: string; stdinPayload: string; cwd: string }> } {
  const calls: Array<{ hookPath: string; stdinPayload: string; cwd: string }> = [];
  const exec: ExecGateHook = (hookPath, stdinPayload, cwd) => {
    calls.push({ hookPath, stdinPayload, cwd });
    return responses[hookPath] ?? { status: 0, stderr: "" };
  };
  return { exec, calls };
}

// runGateHook checks existsSync(hookPath) BEFORE calling execGateHook, so
// these tests point hookRelativePath at a real, harmless file (this test
// file itself) purely so existsSync passes — the mock intercepts the actual
// "execution" and the real file's content is never read or run.
const THIS_FILE_AS_HOOK = "test/gate-dispatcher.test.ts";

function gate(name: string, hookRelativePath = THIS_FILE_AS_HOOK): GateDefinition {
  return {
    name,
    hookRelativePath,
    wires: [{ tool: "shell", commandGlob: null }],
  };
}

/**
 * Minimal stand-in for opencode's V2 `Context`: captures the callback
 * registered via `ctx.tool.hook("execute.before", …)` so a test can drive it
 * directly, exactly as opencode's own dispatcher would.
 */
function fakeContext(directory: string): {
  ctx: GateDispatcherContext;
  handler: () => (event: ToolExecuteBeforeEvent) => Promise<void>;
  hookNames: string[];
} {
  const hookNames: string[] = [];
  let registered: ((event: ToolExecuteBeforeEvent) => Promise<void> | void) | undefined;
  const ctx: GateDispatcherContext = {
    location: { directory },
    tool: {
      hook: async (name, callback) => {
        hookNames.push(name);
        registered = callback;
        return { dispose: async () => {} };
      },
    },
  };
  return {
    ctx,
    hookNames,
    handler: () => {
      if (!registered) throw new Error("no execute.before hook was registered");
      return async (event) => {
        await registered!(event);
      };
    },
  };
}

// ---------------------------------------------------------------------
// runGateHook — exit-code -> block/allow mapping, with a mocked exec
// ---------------------------------------------------------------------

test("runGateHook: exit code 2 maps to a block, with the hook's stderr as the reason", () => {
  const path = join(process.cwd(), THIS_FILE_AS_HOOK);
  const { exec } = mockExec({ [path]: { status: 2, stderr: "BLOCKED: no Rex approval\n" } });
  const result = runGateHook(process.cwd(), gate("block-unreviewed-merge"), { command: "gh pr merge 1" }, "Bash", exec);
  assert.equal(result?.block, true);
  assert.match(result?.reason ?? "", /BLOCKED: no Rex approval/);
});

test("runGateHook: exit code 0 maps to allow (undefined result)", () => {
  const path = join(process.cwd(), THIS_FILE_AS_HOOK);
  const { exec } = mockExec({ [path]: { status: 0, stderr: "" } });
  const result = runGateHook(process.cwd(), gate("noop-allow"), { command: "anything" }, "Bash", exec);
  assert.equal(result, undefined);
});

test("runGateHook: a numeric non-2 exit code (e.g. 1, an unrelated bash-level error) maps to allow, not block", () => {
  const path = join(process.cwd(), THIS_FILE_AS_HOOK);
  const { exec } = mockExec({ [path]: { status: 1, stderr: "some unrelated warning" } });
  const result = runGateHook(process.cwd(), gate("exit-one"), { command: "anything" }, "Bash", exec);
  assert.equal(result, undefined, "only exit code 2 blocks, matching Claude Code's own PreToolUse semantics");
});

test("runGateHook: NO numeric exit status (spawn failure / ENOBUFS / signal kill) fails CLOSED, not open", () => {
  const path = join(process.cwd(), THIS_FILE_AS_HOOK);
  const { exec } = mockExec({ [path]: { status: null, stderr: "" } });
  const result = runGateHook(process.cwd(), gate("execution-layer-failure"), { command: "anything" }, "Bash", exec);
  assert.equal(result?.block, true, "an execution-layer failure must fail CLOSED, not silently allow");
  assert.match(result?.reason ?? "", /could not be evaluated/);
});

// ---------------------------------------------------------------------
// Bounded timeout (#840 C1) — exercised against the REAL execGateHookReal
// (not the mock above), since the timeout is a property of the real
// subprocess spawn, not something a mocked exec function can represent.
// ---------------------------------------------------------------------

test("execGateHookReal: a hook that exceeds the bounded timeout is killed and reports timedOut", () => {
  const opsRoot = mkdtempSync(join(tmpdir(), "apexyard-opencode-gate-test-"));
  // Sleeps far longer than the tiny timeout below — simulates a hung hook.
  writeFileSync(join(opsRoot, "hangs.sh"), "#!/bin/bash\nsleep 5\nexit 0\n", { mode: 0o755 });
  const hookPath = join(opsRoot, "hangs.sh");

  const started = Date.now();
  const result = execGateHookReal(hookPath, JSON.stringify({ tool_name: "Bash", tool_input: {} }), opsRoot, 1024 * 1024, 100);
  const elapsedMs = Date.now() - started;

  assert.equal(result.status, null, "a killed subprocess never produces a numeric exit status");
  assert.equal(result.timedOut, true);
  assert.ok(elapsedMs < 4000, `expected the kill to happen well before the hook's own 5s sleep completes, took ${elapsedMs}ms`);
});

test("FAILS CLOSED: runGateHook maps a real timeout to a block, naming the hook and the timeout (#840 C1)", () => {
  const opsRoot = mkdtempSync(join(tmpdir(), "apexyard-opencode-gate-test-"));
  writeFileSync(join(opsRoot, "hangs.sh"), "#!/bin/bash\nsleep 5\nexit 0\n", { mode: 0o755 });
  const hangGate: GateDefinition = { name: "hangs", hookRelativePath: "hangs.sh", wires: [{ tool: "shell", commandGlob: null }] };

  const result = runGateHook(opsRoot, hangGate, { command: "anything" }, "Bash", execGateHookReal, 1024 * 1024, 100);

  assert.equal(result?.block, true, "a hung hook must fail CLOSED, not open");
  assert.match(result?.reason ?? "", /timed out/);
  assert.match(result?.reason ?? "", /hangs/);
});

test("runGateHook: a hook whose file doesn't exist in this ops root is a silent no-op (never calls exec)", () => {
  const { exec, calls } = mockExec({});
  const result = runGateHook(OPS_ROOT, gate("missing-hook", ".claude/hooks/does-not-exist.sh"), { command: "anything" }, "Bash", exec);
  assert.equal(result, undefined);
  assert.equal(calls.length, 0, "exec must never be invoked for a hook path that doesn't exist");
});

test("runGateHook: reconstructs the exact Claude-Code-shaped stdin payload", () => {
  const path = join(process.cwd(), THIS_FILE_AS_HOOK);
  const { exec, calls } = mockExec({ [path]: { status: 0, stderr: "" } });
  runGateHook(process.cwd(), gate("stdin-shape-check"), { command: "gh pr merge 7 --squash" }, "Bash", exec);
  assert.equal(calls.length, 1);
  assert.deepEqual(JSON.parse(calls[0]!.stdinPayload), {
    tool_name: "Bash",
    tool_input: { command: "gh pr merge 7 --squash" },
  });
});

// ---------------------------------------------------------------------
// buildToolExecuteBeforeHandler — the plugin's actual V2 event handler, with
// a mocked exec, driven end-to-end through the real `{ tool, input }` event
// shape opencode's `execute.before` hook delivers.
// ---------------------------------------------------------------------

test("execute.before: a blocked shell call THROWS with the hook's reason (opencode has no {block:true} return contract)", async () => {
  const path = join(process.cwd(), THIS_FILE_AS_HOOK);
  const { exec } = mockExec({ [path]: { status: 2, stderr: "BLOCKED: fabricated for test\n" } });
  const handler = buildToolExecuteBeforeHandler(process.cwd(), [gate("block-unreviewed-merge")], exec);

  await assert.rejects(
    () => handler({ tool: "shell", input: { command: "gh pr merge 1 --squash" } }),
    /BLOCKED: fabricated for test/,
  );
});

test("execute.before: an allowed shell call resolves without throwing", async () => {
  const path = join(process.cwd(), THIS_FILE_AS_HOOK);
  const { exec } = mockExec({ [path]: { status: 0, stderr: "" } });
  const handler = buildToolExecuteBeforeHandler(process.cwd(), [gate("noop-allow")], exec);

  await assert.doesNotReject(() => handler({ tool: "shell", input: { command: "echo hello" } }));
});

test("execute.before: a non-shell tool call with no matching gate is a silent pass-through", async () => {
  const { exec, calls } = mockExec({});
  const handler = buildToolExecuteBeforeHandler(process.cwd(), [gate("block-unreviewed-merge")], exec); // only wired to "shell"

  await assert.doesNotReject(() => handler({ tool: "read", input: { path: "/repo/README.md" } }));
  assert.equal(calls.length, 0);
});

test("execute.before: no ops root resolved => silent no-op (fails toward not-enforcing, never toward false-blocking)", async () => {
  const { exec, calls } = mockExec({});
  const handler = buildToolExecuteBeforeHandler(undefined, [gate("block-unreviewed-merge")], exec);

  await assert.doesNotReject(() => handler({ tool: "shell", input: { command: "gh pr merge 1 --squash" } }));
  assert.equal(calls.length, 0);
});

test("execute.before: the first matching gate that blocks wins — later gates are not evaluated", async () => {
  const hookA = join(process.cwd(), THIS_FILE_AS_HOOK);
  const { exec, calls } = mockExec({ [hookA]: { status: 2, stderr: "first gate blocks\n" } });
  const gates = [gate("gate-a", THIS_FILE_AS_HOOK), gate("gate-b", THIS_FILE_AS_HOOK)];
  const handler = buildToolExecuteBeforeHandler(process.cwd(), gates, exec);

  await assert.rejects(() => handler({ tool: "shell", input: { command: "anything" } }), /first gate blocks/);
  assert.equal(calls.length, 1, "the second gate must not run once the first one already blocked");
});

// ---------------------------------------------------------------------
// registerGateDispatcher — the plugin-init entry point, with a
// resolveOpsRoot override (no real filesystem walk-up needed for this
// unit test) and an explicit gates override (bypassing settings.json
// parsing, which derive-gates.test.ts already covers on its own).
// ---------------------------------------------------------------------

test("registerGateDispatcher registers an execute.before hook on ctx.tool, wired to the resolved ops root + gate table", async () => {
  // resolveOpsRoot is overridden to point at this package's own cwd (a real
  // directory) so existsSync(hookPath) — checked before the mocked exec is
  // ever called — passes for THIS_FILE_AS_HOOK, same trick every other test
  // in this file uses.
  const path = join(process.cwd(), THIS_FILE_AS_HOOK);
  const { exec } = mockExec({ [path]: { status: 2, stderr: "blocked via registerGateDispatcher\n" } });
  const { ctx, handler, hookNames } = fakeContext("/wherever/opencode/was/launched/from");

  await registerGateDispatcher(ctx, {
    resolveOpsRoot: () => process.cwd(),
    gates: [gate("via-register", THIS_FILE_AS_HOOK)],
    execGateHook: exec,
  });

  assert.deepEqual(hookNames, ["execute.before"]);
  await assert.rejects(() => handler()({ tool: "shell", input: { command: "gh pr merge 1" } }), /blocked via registerGateDispatcher/);
});

test("registerGateDispatcher: when resolveOpsRoot returns undefined, the hook is registered but is a permanent no-op", async () => {
  const { exec, calls } = mockExec({});
  const { ctx, handler } = fakeContext("/nowhere");

  await registerGateDispatcher(ctx, { resolveOpsRoot: () => undefined, gates: [gate("unreachable")], execGateHook: exec });

  await assert.doesNotReject(() => handler()({ tool: "shell", input: { command: "gh pr merge 1" } }));
  assert.equal(calls.length, 0);
});

test("registerGateDispatcher resolves the ops root from ctx.location.directory", async () => {
  const seen: string[] = [];
  const { ctx } = fakeContext("/the/session/directory");

  await registerGateDispatcher(ctx, {
    resolveOpsRoot: (c) => {
      seen.push(c.directory);
      return undefined;
    },
    gates: [],
  });

  assert.deepEqual(seen, ["/the/session/directory"]);
});

// ---------------------------------------------------------------------
// findUnsupportedGateWires wiring into registerGateDispatcher (#840 C2) —
// a gate matched to read/glob/grep must warn loudly at init, not vanish.
// ---------------------------------------------------------------------

/** Captures everything written to process.stderr while `fn` runs, restoring the real stream afterward even if `fn` throws. */
function captureStderr(fn: () => void): string {
  const originalWrite = process.stderr.write.bind(process.stderr);
  const written: string[] = [];
  process.stderr.write = ((chunk: string) => {
    written.push(String(chunk));
    return true;
  }) as typeof process.stderr.write;
  try {
    fn();
  } finally {
    process.stderr.write = originalWrite;
  }
  return written.join("");
}

test("registerGateDispatcher warns to stderr when a gate is wired to a tool with no stdin builder (read/glob/grep)", async () => {
  const { exec } = mockExec({});
  const unsupportedGate: GateDefinition = {
    name: "example-advisory",
    hookRelativePath: THIS_FILE_AS_HOOK,
    wires: [{ tool: "read", commandGlob: null }],
  };
  const { ctx } = fakeContext("/wherever");

  let combined = "";
  const originalWrite = process.stderr.write.bind(process.stderr);
  const written: string[] = [];
  process.stderr.write = ((chunk: string) => {
    written.push(String(chunk));
    return true;
  }) as typeof process.stderr.write;
  try {
    await registerGateDispatcher(ctx, { resolveOpsRoot: () => process.cwd(), gates: [unsupportedGate], execGateHook: exec });
  } finally {
    process.stderr.write = originalWrite;
    combined = written.join("");
  }

  assert.match(combined, /WARNING/);
  assert.match(combined, /example-advisory/);
  assert.match(combined, /"read"/);
});

test("registerGateDispatcher does NOT warn when every gate is wired only to shell/bash/edit/write", async () => {
  const { exec } = mockExec({});
  const supportedGate: GateDefinition = {
    name: "require-active-ticket",
    hookRelativePath: THIS_FILE_AS_HOOK,
    wires: [
      { tool: "shell", commandGlob: null },
      { tool: "bash", commandGlob: null },
      { tool: "edit", commandGlob: null },
    ],
  };
  const { ctx } = fakeContext("/wherever");

  let combined = "";
  const originalWrite = process.stderr.write.bind(process.stderr);
  const written: string[] = [];
  process.stderr.write = ((chunk: string) => {
    written.push(String(chunk));
    return true;
  }) as typeof process.stderr.write;
  try {
    await registerGateDispatcher(ctx, { resolveOpsRoot: () => process.cwd(), gates: [supportedGate], execGateHook: exec });
  } finally {
    process.stderr.write = originalWrite;
    combined = written.join("");
  }

  assert.equal(combined, "");
});

// ---------------------------------------------------------------------
// deriveGatesFromOpsRoot's parse-failure warning (#840 C3) — the catch
// block's fail-open ("no gates enforced") must be loudly visible, not
// silent, matching the function's own header-comment claim.
// ---------------------------------------------------------------------

test("deriveGatesFromOpsRoot: a malformed settings.json warns to stderr and returns an empty gate table", () => {
  const opsRoot = mkdtempSync(join(tmpdir(), "apexyard-opencode-gate-test-"));
  writeFileSync(join(opsRoot, "settings.json"), "{ not valid json", "utf-8");

  let gates: GateDefinition[] = [];
  const combined = captureStderr(() => {
    gates = deriveGatesFromOpsRoot(opsRoot, "settings.json");
  });

  assert.deepEqual(gates, [], "a broken settings.json must fail toward not-enforcing, not throw");
  assert.match(combined, /WARNING/);
  assert.match(combined, /settings\.json/);
});

test("deriveGatesFromOpsRoot: a missing settings.json is silent (the expected \"nothing to enforce\" case, not a broken-config case)", () => {
  const opsRoot = mkdtempSync(join(tmpdir(), "apexyard-opencode-gate-test-"));

  let gates: GateDefinition[] = [];
  const combined = captureStderr(() => {
    gates = deriveGatesFromOpsRoot(opsRoot, "settings.json");
  });

  assert.deepEqual(gates, []);
  assert.equal(combined, "", "a missing file is not a parse failure — warning here would be noise for every non-apexyard session");
});

// ---------------------------------------------------------------------
// V2 `patch` tool (Rex F3 / Hakim F1 on #1959) — opencode 2.x ships a
// patch tool that edits files under the `edit` permission. Before this
// wire existed a `patch` call matched NO gate at all.
// ---------------------------------------------------------------------

/** A fixture ops root whose only hook is the framework's patch dispatcher. */
function patchFixtureOpsRoot(): string {
  const opsRoot = mkdtempSync(join(tmpdir(), "apexyard-opencode-patch-test-"));
  mkdirSync(join(opsRoot, ".claude/hooks"), { recursive: true });
  writeFileSync(join(opsRoot, "settings.json"), JSON.stringify({ hooks: { PreToolUse: [] } }), "utf-8");
  writeFileSync(join(opsRoot, ".claude/hooks/dispatch-apply-patch.sh"), "#!/bin/bash\nexit 0\n", { mode: 0o755 });
  return opsRoot;
}

test("deriveGatesFromOpsRoot wires opencode's patch tool to the framework's patch dispatcher", () => {
  const opsRoot = patchFixtureOpsRoot();
  const gates = deriveGatesFromOpsRoot(opsRoot, "settings.json");
  const patchGate = gates.find((g) => g.hookRelativePath === ".claude/hooks/dispatch-apply-patch.sh");
  assert.ok(patchGate, "a `patch` call must not be gate-less");
  assert.deepEqual(patchGate!.wires.map((w) => w.tool).sort(), ["apply_patch", "patch"]);
});

test("deriveGatesFromOpsRoot adds no patch wire when the ops fork has no patch dispatcher", () => {
  const opsRoot = mkdtempSync(join(tmpdir(), "apexyard-opencode-patch-absent-"));
  mkdirSync(join(opsRoot, ".claude/hooks"), { recursive: true });
  writeFileSync(join(opsRoot, "settings.json"), JSON.stringify({ hooks: { PreToolUse: [] } }), "utf-8");
  const gates = deriveGatesFromOpsRoot(opsRoot, "settings.json");
  assert.equal(gates.some((g) => g.hookRelativePath === ".claude/hooks/dispatch-apply-patch.sh"), false);
});

test("a patch call runs the patch dispatcher as apply_patch, with the envelope as `command`", async () => {
  const opsRoot = patchFixtureOpsRoot();
  const hookPath = join(opsRoot, ".claude/hooks/dispatch-apply-patch.sh");
  const { exec, calls } = mockExec({ [hookPath]: { status: 0, stderr: "" } });
  const gates = deriveGatesFromOpsRoot(opsRoot, "settings.json");
  const handler = buildToolExecuteBeforeHandler(opsRoot, gates, exec);
  const envelope = "*** Begin Patch\n*** Update File: src/a.ts\n*** End Patch";

  await handler({ tool: "patch", sessionID: "s1", input: { patchText: envelope } });

  assert.equal(calls.length, 1, "the patch dispatcher must run for a patch call");
  assert.deepEqual(JSON.parse(calls[0]!.stdinPayload), {
    tool_name: "apply_patch",
    tool_input: { command: envelope },
  });
});

test("a blocked patch call throws, so the edit is denied", async () => {
  const opsRoot = patchFixtureOpsRoot();
  const hookPath = join(opsRoot, ".claude/hooks/dispatch-apply-patch.sh");
  const { exec } = mockExec({ [hookPath]: { status: 2, stderr: "BLOCKED: no active ticket\n" } });
  const gates = deriveGatesFromOpsRoot(opsRoot, "settings.json");
  const handler = buildToolExecuteBeforeHandler(opsRoot, gates, exec);

  await assert.rejects(
    () => handler({ tool: "patch", input: { patchText: "*** Begin Patch\n*** End Patch" } }),
    /no active ticket/,
  );
});

// ---------------------------------------------------------------------
// Dual V1 + V2 entrypoint (#1956 AC1/AC6) — one file serves both plugin
// generations: V2 calls setup(), V1 (1.18.29+) calls server().
// ---------------------------------------------------------------------

test("the default export is a V2 definition that also exposes the V1 server() member", async () => {
  assert.equal(apexyardGateDispatcher.id, "apexyard.gates");
  assert.equal(typeof apexyardGateDispatcher.setup, "function");
  assert.equal(typeof apexyardGateDispatcher.server, "function");

  const hooks = await apexyardGateDispatcher.server({ directory: "/nowhere" });
  assert.equal(typeof hooks["tool.execute.before"], "function");
});

test("the V1 server() hook blocks a matching call, sharing the same cascade as V2", async () => {
  const path = join(process.cwd(), THIS_FILE_AS_HOOK);
  const { exec } = mockExec({ [path]: { status: 2, stderr: "blocked through the v1 hook\n" } });

  const hooks = createV1Hooks(
    { directory: "/wherever" },
    {
      resolveOpsRoot: () => process.cwd(),
      // V1 emits the `bash` tool id, so the wire must name it.
      gates: [{ name: "via-v1", hookRelativePath: THIS_FILE_AS_HOOK, wires: [{ tool: "bash", commandGlob: null }] }],
      execGateHook: exec,
    },
  );

  await assert.rejects(
    () => hooks["tool.execute.before"]({ tool: "bash", sessionID: "s1" }, { args: { command: "gh pr merge 1" } }),
    /blocked through the v1 hook/,
  );
});

// ---------------------------------------------------------------------
// Session-id prefix (Hakim F4 on #1959) — the `unset` line must survive
// an event with no native session id, or an inherited Claude Code id wins
// the marker-path resolver again (#1783).
// ---------------------------------------------------------------------

test("execute.before always strips an inherited CLAUDE_CODE_SESSION_ID, even with no native id", async () => {
  const { exec } = mockExec({});
  const handler = buildToolExecuteBeforeHandler(process.cwd(), [], exec);
  const input: { command: string } = { command: "echo hi" };

  await handler({ tool: "shell", input });

  assert.equal(input.command, "unset CLAUDE_CODE_SESSION_ID\necho hi");
  assert.doesNotMatch(input.command, /APEXYARD_SESSION_ID/);
});

test("execute.before exports the native session id when the event carries one", async () => {
  const { exec } = mockExec({});
  const handler = buildToolExecuteBeforeHandler(process.cwd(), [], exec);
  const input: { command: string } = { command: "echo hi" };

  await handler({ tool: "shell", sessionID: "sub-agent-session", input });

  assert.equal(
    input.command,
    "unset CLAUDE_CODE_SESSION_ID\nexport APEXYARD_SESSION_ID='sub-agent-session'\necho hi",
  );
});
