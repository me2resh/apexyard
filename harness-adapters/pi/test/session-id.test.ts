import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, mkdirSync, writeFileSync, rmSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { registerGateDispatcher, runGateHook, type GateDefinition } from "../src/gate-dispatcher.ts";

/** Same sid precedence as `.claude/hooks/_lib-session-markers.sh`. */
const MARKER_PROBE = [
  "#!/bin/bash",
  'sid="${CLAUDE_CODE_SESSION_ID:-${APEXYARD_SESSION_ID:-}}"',
  '[ -n "$sid" ] || exit 2',
  'safe=$(printf %s "$sid" | tr -c "A-Za-z0-9._-" "_")',
  'printf %s ".claude/session/active-bootstrap.$safe"',
  "",
].join("\n");

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

test("session_start exports the native id to a gate hook via runGateHook", async () => {
  let start: Function | undefined;
  const pi = { on(name: string, handler: Function) { if (name === "session_start") start = handler; } };
  const root = mkdtempSync(join(tmpdir(), "apexyard-session-pi-"));
  const old = process.env.APEXYARD_SESSION_ID;
  const oldWant = process.env.WANT;
  try {
    mkdirSync(join(root, ".claude/hooks"), { recursive: true });
    writeFileSync(
      join(root, ".claude/hooks/sid.sh"),
      '#!/bin/bash\ntest "$APEXYARD_SESSION_ID" = "$WANT" || exit 2\n',
      { mode: 0o755 },
    );
    const gate: GateDefinition = {
      name: "sid",
      hookRelativePath: ".claude/hooks/sid.sh",
      wires: [{ tool: "bash", commandGlob: null }],
    };
    registerGateDispatcher(pi as unknown as ExtensionAPI);
    for (const id of ["pi-A", "pi-B"]) {
      await start!({}, { sessionManager: { getSessionId: () => id } });
      process.env.WANT = id;
      const result = runGateHook(root, gate, { command: "anything" }, "Bash");
      assert.equal(result, undefined, `hook must allow when WANT=${id}`);
    }
    await start!({}, { sessionManager: { getSessionId: () => "pi-A" } });
    process.env.WANT = "pi-B";
    const blocked = runGateHook(root, gate, { command: "anything" }, "Bash");
    assert.equal(blocked?.block, true, "mismatched WANT must block");
  } finally {
    if (old === undefined) delete process.env.APEXYARD_SESSION_ID;
    else process.env.APEXYARD_SESSION_ID = old;
    if (oldWant === undefined) delete process.env.WANT;
    else process.env.WANT = oldWant;
    rmSync(root, { recursive: true, force: true });
  }
});

test("inherited CLAUDE_CODE_SESSION_ID does not override adapter marker paths", async () => {
  let start: Function | undefined;
  const pi = { on(name: string, handler: Function) { if (name === "session_start") start = handler; } };
  const root = mkdtempSync(join(tmpdir(), "apexyard-session-pi-inherit-"));
  const oldClaude = process.env.CLAUDE_CODE_SESSION_ID;
  const oldApex = process.env.APEXYARD_SESSION_ID;
  try {
    process.env.CLAUDE_CODE_SESSION_ID = "inherited-parent";
    delete process.env.APEXYARD_SESSION_ID;
    mkdirSync(join(root, ".claude/hooks"), { recursive: true });

    const hookPaths: string[] = [];
    const shellPaths: string[] = [];
    registerGateDispatcher(pi as unknown as ExtensionAPI);

    for (const id of ["pi-A", "pi-B"]) {
      const outFile = join(root, `hook-${id}`);
      writeFileSync(
        join(root, ".claude/hooks", `probe-${id}.sh`),
        [
          "#!/bin/bash",
          'sid="${CLAUDE_CODE_SESSION_ID:-${APEXYARD_SESSION_ID:-}}"',
          '[ -n "$sid" ] || exit 2',
          'safe=$(printf %s "$sid" | tr -c "A-Za-z0-9._-" "_")',
          `printf %s ".claude/session/active-bootstrap.$safe" > '${outFile.replaceAll("'", "'\\''")}'`,
          "",
        ].join("\n"),
        { mode: 0o755 },
      );
      await start!({}, { sessionManager: { getSessionId: () => id } });
      const gate: GateDefinition = {
        name: `probe-${id}`,
        hookRelativePath: `.claude/hooks/probe-${id}.sh`,
        wires: [{ tool: "bash", commandGlob: null }],
      };
      const result = runGateHook(root, gate, { command: "anything" }, "Bash");
      assert.equal(result, undefined, `marker probe must allow for ${id}`);
      hookPaths.push(readFileSync(outFile, "utf8"));
      shellPaths.push(
        execFileSync("bash", ["-c", MARKER_PROBE.replace(/^#!\/bin\/bash\n/, "")], { encoding: "utf8" }),
      );
    }

    assert.deepEqual(hookPaths, [
      ".claude/session/active-bootstrap.pi-A",
      ".claude/session/active-bootstrap.pi-B",
    ]);
    assert.deepEqual(shellPaths, [
      ".claude/session/active-bootstrap.pi-A",
      ".claude/session/active-bootstrap.pi-B",
    ]);
    assert.notEqual(hookPaths[0], hookPaths[1]);
  } finally {
    if (oldClaude === undefined) delete process.env.CLAUDE_CODE_SESSION_ID;
    else process.env.CLAUDE_CODE_SESSION_ID = oldClaude;
    if (oldApex === undefined) delete process.env.APEXYARD_SESSION_ID;
    else process.env.APEXYARD_SESSION_ID = oldApex;
    rmSync(root, { recursive: true, force: true });
  }
});

test("neither session id keeps the marker gate fail-closed", async () => {
  const root = mkdtempSync(join(tmpdir(), "apexyard-session-pi-none-"));
  const oldClaude = process.env.CLAUDE_CODE_SESSION_ID;
  const oldApex = process.env.APEXYARD_SESSION_ID;
  try {
    delete process.env.CLAUDE_CODE_SESSION_ID;
    delete process.env.APEXYARD_SESSION_ID;
    mkdirSync(join(root, ".claude/hooks"), { recursive: true });
    writeFileSync(join(root, ".claude/hooks/marker.sh"), MARKER_PROBE, { mode: 0o755 });
    const gate: GateDefinition = {
      name: "marker",
      hookRelativePath: ".claude/hooks/marker.sh",
      wires: [{ tool: "bash", commandGlob: null }],
    };
    const blocked = runGateHook(root, gate, { command: "anything" }, "Bash");
    assert.equal(blocked?.block, true);
  } finally {
    if (oldClaude === undefined) delete process.env.CLAUDE_CODE_SESSION_ID;
    else process.env.CLAUDE_CODE_SESSION_ID = oldClaude;
    if (oldApex === undefined) delete process.env.APEXYARD_SESSION_ID;
    else process.env.APEXYARD_SESSION_ID = oldApex;
    rmSync(root, { recursive: true, force: true });
  }
});
