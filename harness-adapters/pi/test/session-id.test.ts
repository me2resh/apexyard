import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { registerGateDispatcher } from "../src/gate-dispatcher.ts";

test("session_start exports a stable native id to child shells and changes sessions", async () => {
  let start: Function | undefined;
  const pi = { on(name: string, handler: Function) { if (name === "session_start") start = handler; } };
  const old = process.env.APEXYARD_SESSION_ID;
  try {
    registerGateDispatcher(pi as unknown as ExtensionAPI);
    const fallback = process.env.APEXYARD_SESSION_ID;
    assert.ok(fallback);
    registerGateDispatcher(pi as unknown as ExtensionAPI);
    assert.notEqual(process.env.APEXYARD_SESSION_ID, fallback);
    const seen: string[] = [];
    for (const id of ["pi-A", "pi-A", "pi-B"]) {
      await start!({}, { sessionManager: { getSessionId: () => id } });
      seen.push(execFileSync("bash", ["-c", 'printf %s "$APEXYARD_SESSION_ID"'], { encoding: "utf8" }));
    }
    assert.deepEqual(seen, ["pi-A", "pi-A", "pi-B"]);
  } finally {
    if (old === undefined) delete process.env.APEXYARD_SESSION_ID;
    else process.env.APEXYARD_SESSION_ID = old;
  }
});
