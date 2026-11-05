/**
 * installer-version.test.ts — the install script's runtime-version guard.
 *
 * The guard exists to warn a user whose `opencode` predates the first release
 * that loads this adapter's object entrypoint. It ran silently on real 1.x
 * output because the old pattern required an `opencode ` prefix. These tests
 * stub `opencode --version` and assert the guard reads both output shapes.
 */

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(HERE, "../../..");
const INSTALLER = join(REPO_ROOT, "bin/install-opencode-adapter.sh");

/** Runs the installer with a stub `opencode` and returns its stderr. */
function installerStderr(versionOutput: string): string {
  const root = mkdtempSync(join(tmpdir(), "apexyard-installer-test-"));
  const bin = join(root, "bin");
  mkdirSync(bin);
  writeFileSync(join(bin, "opencode"), `#!/bin/sh\nprintf '%s\\n' '${versionOutput}'\n`, { mode: 0o755 });

  const result = spawnSync("bash", [INSTALLER, "--target-dir", join(root, "target"), "--root", REPO_ROOT], {
    env: { ...process.env, PATH: `${bin}:${process.env.PATH ?? ""}` },
    encoding: "utf-8",
  });

  assert.equal(result.status, 0, `installer failed: ${result.stderr}`);
  return result.stderr;
}

test("the version guard reads a bare 1.x version (a real 1.17.16 prints one)", () => {
  const stderr = installerStderr("1.17.16");
  assert.doesNotMatch(stderr, /predates 1\.3\.4/, "1.17.16 is newer than the verified floor");
});

test("the version guard reads a prefixed 2.x version (opencode v2.1.4)", () => {
  const stderr = installerStderr("opencode v2.1.4");
  assert.doesNotMatch(stderr, /predates 1\.3\.4/);
});

test("the version guard accepts the verified floor, 1.3.4", () => {
  const stderr = installerStderr("1.3.4");
  assert.doesNotMatch(stderr, /predates 1\.3\.4/, "1.3.4 is the first release that loads the object entrypoint");
});

test("the version guard warns below the verified floor, and names both versions", () => {
  const stderr = installerStderr("1.3.3");
  assert.match(stderr, /reports 1\.3\.3, which predates 1\.3\.4/);
  assert.match(stderr, /first release verified to load an object entrypoint/);
});

test("the version guard warns on a pre-1.0 major version", () => {
  const stderr = installerStderr("0.9.0");
  assert.match(stderr, /predates 1\.3\.4/);
});
