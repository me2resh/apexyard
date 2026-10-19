import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, writeFileSync, mkdirSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { buildToolExecuteBeforeHook, execGateHookReal } from "../src/gate-dispatcher.ts";
import type { GateDefinition } from "../src/derive-gates.ts";

test("native session id reaches both the hook and the skill shell", async () => {
  const root = mkdtempSync(join(tmpdir(), "apexyard-session-opencode-"));
  try {
    mkdirSync(join(root, ".claude/hooks"), { recursive: true });
    writeFileSync(
      join(root, ".claude/hooks/session.sh"),
      'test "$APEXYARD_SESSION_ID" = "$EXPECTED_ID" || exit 2\n',
    );
    const gates: GateDefinition[] = [{
      name: "session",
      hookRelativePath: ".claude/hooks/session.sh",
      wires: [{ tool: "bash", commandGlob: null }],
    }];
    const before = buildToolExecuteBeforeHook(root, gates, execGateHookReal);
    const seen: string[] = [];
    for (const sessionID of ["native-A", "native-A", "native-B", "quote'id"]) {
      process.env.EXPECTED_ID = sessionID;
      const output = { args: { command: 'printf %s "$APEXYARD_SESSION_ID"' } };
      await before({ tool: "bash", sessionID, callID: "call" }, output);
      seen.push(execFileSync("bash", ["-c", output.args.command], { encoding: "utf8" }));
    }
    assert.deepEqual(seen, ["native-A", "native-A", "native-B", "quote'id"]);
  } finally {
    delete process.env.EXPECTED_ID;
    rmSync(root, { recursive: true, force: true });
  }
});
