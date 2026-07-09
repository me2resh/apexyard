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
import { join } from "node:path";
import test from "node:test";

import {
  buildToolExecuteBeforeHook,
  registerGateDispatcher,
  runGateHook,
  type ExecGateHook,
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
    wires: [{ tool: "bash", commandGlob: null }],
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
// buildToolExecuteBeforeHook — the plugin's actual event handler, with a
// mocked exec, driven end-to-end through tool.execute.before's real
// input/output shape.
// ---------------------------------------------------------------------

test("tool.execute.before: a blocked bash call THROWS with the hook's reason (opencode has no {block:true} return contract)", async () => {
  const path = join(process.cwd(), THIS_FILE_AS_HOOK);
  const { exec } = mockExec({ [path]: { status: 2, stderr: "BLOCKED: fabricated for test\n" } });
  const handler = buildToolExecuteBeforeHook(process.cwd(), [gate("block-unreviewed-merge")], exec);

  await assert.rejects(
    () => handler({ tool: "bash", sessionID: "s1", callID: "c1" }, { args: { command: "gh pr merge 1 --squash" } }),
    /BLOCKED: fabricated for test/,
  );
});

test("tool.execute.before: an allowed bash call resolves without throwing", async () => {
  const path = join(process.cwd(), THIS_FILE_AS_HOOK);
  const { exec } = mockExec({ [path]: { status: 0, stderr: "" } });
  const handler = buildToolExecuteBeforeHook(process.cwd(), [gate("noop-allow")], exec);

  await assert.doesNotReject(() => handler({ tool: "bash", sessionID: "s1", callID: "c1" }, { args: { command: "echo hello" } }));
});

test("tool.execute.before: a non-bash tool call with no matching gate is a silent pass-through", async () => {
  const { exec, calls } = mockExec({});
  const handler = buildToolExecuteBeforeHook(process.cwd(), [gate("block-unreviewed-merge")], exec); // only wired to "bash"

  await assert.doesNotReject(() => handler({ tool: "read", sessionID: "s1", callID: "c1" }, { args: { filePath: "/repo/README.md" } }));
  assert.equal(calls.length, 0);
});

test("tool.execute.before: no ops root resolved => silent no-op (fails toward not-enforcing, never toward false-blocking)", async () => {
  const { exec, calls } = mockExec({});
  const handler = buildToolExecuteBeforeHook(undefined, [gate("block-unreviewed-merge")], exec);

  await assert.doesNotReject(() => handler({ tool: "bash", sessionID: "s1", callID: "c1" }, { args: { command: "gh pr merge 1 --squash" } }));
  assert.equal(calls.length, 0);
});

test("tool.execute.before: the first matching gate that blocks wins — later gates are not evaluated", async () => {
  const hookA = join(process.cwd(), THIS_FILE_AS_HOOK);
  const { exec, calls } = mockExec({ [hookA]: { status: 2, stderr: "first gate blocks\n" } });
  const gates = [gate("gate-a", THIS_FILE_AS_HOOK), gate("gate-b", THIS_FILE_AS_HOOK)];
  const handler = buildToolExecuteBeforeHook(process.cwd(), gates, exec);

  await assert.rejects(() => handler({ tool: "bash", sessionID: "s1", callID: "c1" }, { args: { command: "anything" } }), /first gate blocks/);
  assert.equal(calls.length, 1, "the second gate must not run once the first one already blocked");
});

// ---------------------------------------------------------------------
// registerGateDispatcher — the plugin-init entry point, with a
// resolveOpsRoot override (no real filesystem walk-up needed for this
// unit test) and an explicit gates override (bypassing settings.json
// parsing, which derive-gates.test.ts already covers on its own).
// ---------------------------------------------------------------------

test("registerGateDispatcher wires the returned Hooks object's tool.execute.before to the resolved ops root + gate table", async () => {
  // resolveOpsRoot is overridden to point at this package's own cwd (a real
  // directory) so existsSync(hookPath) — checked before the mocked exec is
  // ever called — passes for THIS_FILE_AS_HOOK, same trick every other test
  // in this file uses.
  const path = join(process.cwd(), THIS_FILE_AS_HOOK);
  const { exec } = mockExec({ [path]: { status: 2, stderr: "blocked via registerGateDispatcher\n" } });

  const hooks = registerGateDispatcher(
    { directory: "/wherever/opencode/was/launched/from", worktree: "/wherever" },
    {
      resolveOpsRoot: () => process.cwd(),
      gates: [gate("via-register", THIS_FILE_AS_HOOK)],
      execGateHook: exec,
    },
  );

  assert.ok(hooks["tool.execute.before"]);
  await assert.rejects(
    () => hooks["tool.execute.before"]!({ tool: "bash", sessionID: "s1", callID: "c1" }, { args: { command: "gh pr merge 1" } }),
    /blocked via registerGateDispatcher/,
  );
});

test("registerGateDispatcher: when resolveOpsRoot returns undefined, the hook is registered but is a permanent no-op", async () => {
  const { exec, calls } = mockExec({});
  const hooks = registerGateDispatcher(
    { directory: "/nowhere", worktree: "/nowhere" },
    { resolveOpsRoot: () => undefined, gates: [gate("unreachable")], execGateHook: exec },
  );

  await assert.doesNotReject(() => hooks["tool.execute.before"]!({ tool: "bash", sessionID: "s1", callID: "c1" }, { args: { command: "gh pr merge 1" } }));
  assert.equal(calls.length, 0);
});
