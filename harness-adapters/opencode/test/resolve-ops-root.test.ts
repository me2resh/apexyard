/**
 * resolve-ops-root.test.ts — proves the opencode-flavored ops-root walk-up
 * matches the anchor conditions `_lib-ops-root.sh` recognises. Hermetic —
 * builds real temp directories, no network, no real opencode install
 * needed.
 */

import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import { isOpsRootAnchor, resolveOpsRootForOpencode, walkUpOpsRoot } from "../src/resolve-ops-root.ts";

function makeTempTree(): { root: string; nested: string } {
  const root = mkdtempSync(join(tmpdir(), "apexyard-opencode-ops-root-test-"));
  const nested = join(root, "workspace", "some-project", "src");
  mkdirSync(nested, { recursive: true });
  return { root, nested };
}

test("isOpsRootAnchor: a .apexyard-fork marker file is a valid anchor", () => {
  const { root } = makeTempTree();
  writeFileSync(join(root, ".apexyard-fork"), "");
  assert.ok(isOpsRootAnchor(root));
});

test("isOpsRootAnchor: the legacy onboarding.yaml + apexyard.projects.yaml pair is a valid anchor", () => {
  const { root } = makeTempTree();
  writeFileSync(join(root, "onboarding.yaml"), "");
  writeFileSync(join(root, "apexyard.projects.yaml"), "");
  assert.ok(isOpsRootAnchor(root));
});

test("isOpsRootAnchor: onboarding.yaml alone (no registry) is NOT a valid anchor", () => {
  const { root } = makeTempTree();
  writeFileSync(join(root, "onboarding.yaml"), "");
  assert.ok(!isOpsRootAnchor(root));
});

test("isOpsRootAnchor: a directory with neither marker is not an anchor", () => {
  const { root } = makeTempTree();
  assert.ok(!isOpsRootAnchor(root));
});

test("walkUpOpsRoot: finds the marker several directories above the start point", () => {
  const { root, nested } = makeTempTree();
  writeFileSync(join(root, ".apexyard-fork"), "");
  assert.equal(walkUpOpsRoot(nested), root);
});

test("walkUpOpsRoot: returns undefined when no ancestor has an anchor", () => {
  const { nested } = makeTempTree();
  assert.equal(walkUpOpsRoot(nested), undefined);
});

test("resolveOpsRootForOpencode: an explicit APEXYARD_OPS_ROOT env var wins over the walk-up, when valid", () => {
  const { root: walkRoot, nested } = makeTempTree();
  writeFileSync(join(walkRoot, ".apexyard-fork"), "");

  const { root: envRoot } = makeTempTree();
  writeFileSync(join(envRoot, ".apexyard-fork"), "");

  const resolved = resolveOpsRootForOpencode({ startCwd: nested, env: { APEXYARD_OPS_ROOT: envRoot } });
  assert.equal(resolved, envRoot);
});

test("resolveOpsRootForOpencode: an invalid APEXYARD_OPS_ROOT falls through to the walk-up instead of trusting it blindly", () => {
  const { root, nested } = makeTempTree();
  writeFileSync(join(root, ".apexyard-fork"), "");
  const notAnAnchor = mkdtempSync(join(tmpdir(), "apexyard-opencode-not-an-anchor-"));

  const resolved = resolveOpsRootForOpencode({ startCwd: nested, env: { APEXYARD_OPS_ROOT: notAnAnchor } });
  assert.equal(resolved, root);
});

test("resolveOpsRootForOpencode: no anchor anywhere and no override => undefined (fails toward not-enforcing)", () => {
  const { nested } = makeTempTree();
  const resolved = resolveOpsRootForOpencode({ startCwd: nested, env: {} });
  assert.equal(resolved, undefined);
});

test("resolveOpsRootForOpencode: options.explicitOpsRoot takes priority over the env var", () => {
  const { root: fromOption } = makeTempTree();
  writeFileSync(join(fromOption, ".apexyard-fork"), "");
  const { root: fromEnv } = makeTempTree();
  writeFileSync(join(fromEnv, ".apexyard-fork"), "");

  const resolved = resolveOpsRootForOpencode({
    startCwd: "/irrelevant",
    explicitOpsRoot: fromOption,
    env: { APEXYARD_OPS_ROOT: fromEnv },
  });
  assert.equal(resolved, fromOption);
});
