import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, writeFileSync, mkdirSync, rmSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { buildToolExecuteBeforeHook, execGateHookReal } from "../src/gate-dispatcher.ts";
import type { GateDefinition } from "../src/derive-gates.ts";

/** Same sid precedence as `.claude/hooks/_lib-session-markers.sh`. */
const MARKER_PROBE = [
  "#!/bin/bash",
  'sid="${CLAUDE_CODE_SESSION_ID:-${APEXYARD_SESSION_ID:-}}"',
  '[ -n "$sid" ] || exit 2',
  'safe=$(printf %s "$sid" | tr -c "A-Za-z0-9._-" "_")',
  'printf %s ".claude/session/active-bootstrap.$safe"',
  "",
].join("\n");

const SHELL_PROBE = [
  'sid="${CLAUDE_CODE_SESSION_ID:-${APEXYARD_SESSION_ID:-}}"',
  '[ -n "$sid" ] || exit 2',
  'safe=$(printf %s "$sid" | tr -c "A-Za-z0-9._-" "_")',
  'printf %s ".claude/session/active-bootstrap.$safe"',
].join("\n");

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

test("inherited CLAUDE_CODE_SESSION_ID does not override adapter marker paths", async () => {
  const root = mkdtempSync(join(tmpdir(), "apexyard-session-opencode-inherit-"));
  const oldClaude = process.env.CLAUDE_CODE_SESSION_ID;
  const oldApex = process.env.APEXYARD_SESSION_ID;
  try {
    process.env.CLAUDE_CODE_SESSION_ID = "inherited-parent";
    delete process.env.APEXYARD_SESSION_ID;
    mkdirSync(join(root, ".claude/hooks"), { recursive: true });

    const hookPaths: string[] = [];
    const shellPaths: string[] = [];
    for (const sessionID of ["oc-A", "oc-B"]) {
      const outFile = join(root, `hook-${sessionID}`);
      writeFileSync(
        join(root, ".claude/hooks", `probe-${sessionID}.sh`),
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
      const gates: GateDefinition[] = [{
        name: `probe-${sessionID}`,
        hookRelativePath: `.claude/hooks/probe-${sessionID}.sh`,
        wires: [{ tool: "bash", commandGlob: null }],
      }];
      const before = buildToolExecuteBeforeHook(root, gates, execGateHookReal);
      const output = { args: { command: SHELL_PROBE } };
      await before({ tool: "bash", sessionID, callID: "call" }, output);
      hookPaths.push(readFileSync(outFile, "utf8"));
      shellPaths.push(execFileSync("bash", ["-c", output.args.command], { encoding: "utf8" }));
    }

    assert.deepEqual(hookPaths, [
      ".claude/session/active-bootstrap.oc-A",
      ".claude/session/active-bootstrap.oc-B",
    ]);
    assert.deepEqual(shellPaths, [
      ".claude/session/active-bootstrap.oc-A",
      ".claude/session/active-bootstrap.oc-B",
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
  const root = mkdtempSync(join(tmpdir(), "apexyard-session-opencode-none-"));
  const oldClaude = process.env.CLAUDE_CODE_SESSION_ID;
  const oldApex = process.env.APEXYARD_SESSION_ID;
  try {
    delete process.env.CLAUDE_CODE_SESSION_ID;
    delete process.env.APEXYARD_SESSION_ID;
    mkdirSync(join(root, ".claude/hooks"), { recursive: true });
    writeFileSync(join(root, ".claude/hooks/marker.sh"), MARKER_PROBE, { mode: 0o755 });
    const { status } = execGateHookReal(
      join(root, ".claude/hooks/marker.sh"),
      "{}",
      root,
      10 * 1024 * 1024,
      30_000,
      undefined,
    );
    assert.equal(status, 2);
  } finally {
    if (oldClaude === undefined) delete process.env.CLAUDE_CODE_SESSION_ID;
    else process.env.CLAUDE_CODE_SESSION_ID = oldClaude;
    if (oldApex === undefined) delete process.env.APEXYARD_SESSION_ID;
    else process.env.APEXYARD_SESSION_ID = oldApex;
    rmSync(root, { recursive: true, force: true });
  }
});
