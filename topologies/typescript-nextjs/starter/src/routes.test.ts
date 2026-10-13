import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { GET as getHealth } from "./app/api/health/route";
import { GET as getItems, POST, createItemResponse, listItemsResponse } from "./app/api/items/route";
import { closeDb, resetData } from "./infrastructure/db.mjs";

let dir = "";

beforeEach(() => {
  dir = mkdtempSync(path.join(tmpdir(), "starter-route-"));
  process.env.DATA_DIR = dir;
  closeDb();
});

afterEach(() => {
  closeDb();
  delete process.env.DATA_DIR;
  rmSync(dir, { recursive: true, force: true });
});

function jsonRequest(body: string, contentType = "application/json"): Request {
  return new Request("http://local/api/items", {
    method: "POST",
    headers: { "content-type": contentType },
    body,
  });
}

describe("routes", () => {
  it("returns health", async () => {
    const response = getHealth();
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ status: "ok" });
  });

  it("rejects a non-JSON state change", async () => {
    const response = await POST(jsonRequest("name=widget", "text/plain"));
    expect(response.status).toBe(415);
    expect(response.headers.get("content-type")).toBe("application/problem+json");
    expect(await response.json()).toMatchObject({ code: "unsupported-media-type", status: 415 });
  });

  it("accepts a JSON media type with a charset", async () => {
    const response = await POST(jsonRequest(JSON.stringify({ name: "widget" }), "application/json; charset=utf-8"));
    expect(response.status).toBe(201);
  });

  it("rejects invalid JSON", async () => {
    const response = await POST(jsonRequest("{"));
    expect(response.status).toBe(400);
    expect(await response.json()).toMatchObject({ code: "invalid-json" });
  });

  it("rejects a non-object body", async () => {
    const response = await POST(jsonRequest("1"));
    expect(response.status).toBe(400);
    expect(await response.json()).toMatchObject({ code: "invalid-item" });
  });

  it("rejects an invalid item", async () => {
    const response = await POST(jsonRequest(JSON.stringify({ name: "  " })));
    expect(response.status).toBe(400);
    expect(await response.json()).toMatchObject({ code: "invalid-item" });
  });

  it("creates an item and lists it", async () => {
    const created = await POST(jsonRequest(JSON.stringify({ name: " widget " })));
    expect(created.status).toBe(201);
    expect(await created.json()).toEqual({ item: { id: 1, name: "widget" } });
    const listed = await getItems();
    expect(await listed.json()).toEqual({ items: [{ id: 1, name: "widget" }] });
  });

  it("returns a stable internal error code", async () => {
    const response = await createItemResponse(jsonRequest(JSON.stringify({ name: "widget" })), () => {
      throw new Error("boom");
    });
    expect(response.status).toBe(500);
    expect(response.headers.get("content-type")).toBe("application/problem+json");
    expect(await response.json()).toMatchObject({ code: "internal-error" });
  });

  it("returns a stable list error code", async () => {
    const response = await listItemsResponse(() => {
      throw new Error("boom");
    });
    expect(response.status).toBe(500);
    expect(response.headers.get("content-type")).toBe("application/problem+json");
    expect(await response.json()).toEqual({
      type: "about:blank",
      title: "Internal error",
      status: 500,
      code: "internal-error",
    });
  });

  it("resets stored items to the seed", async () => {
    await POST(jsonRequest(JSON.stringify({ name: "widget" })));
    await resetData();
    const listed = await getItems();
    expect(await listed.json()).toEqual({ items: [{ id: 1, name: "seed-item" }] });
  });
});
