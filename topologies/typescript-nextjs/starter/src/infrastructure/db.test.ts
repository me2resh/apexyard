import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { addItem, listItems } from "../application/items";
import { closeDb, dataDir, migrate, resetData, seed } from "./db.mjs";

let dir = "";

beforeEach(() => {
  dir = mkdtempSync(path.join(tmpdir(), "starter-db-"));
  process.env.DATA_DIR = dir;
  closeDb();
});

afterEach(() => {
  closeDb();
  delete process.env.DATA_DIR;
  rmSync(dir, { recursive: true, force: true });
});

describe("local store", () => {
  it("uses the project data directory by default", () => {
    delete process.env.DATA_DIR;
    expect(dataDir()).toBe(path.join(process.cwd(), "data"));
  });

  it("migrates and reopens the same file", async () => {
    await migrate();
    closeDb();
    await migrate();
    expect(await listItems()).toEqual([]);
  });

  it("seeds one row and does not duplicate it", async () => {
    await seed();
    await seed();
    const rows = await listItems();
    expect(rows).toEqual([{ id: 1, name: "seed-item" }]);
  });

  it("resets local data to the seed", async () => {
    await resetData();
    await addItem({ name: "extra" });
    await resetData();
    expect(await listItems()).toEqual([{ id: 1, name: "seed-item" }]);
  });
});
