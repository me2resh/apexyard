import { describe, expect, it } from "vitest";
import { isItemName } from "./item";

describe("item name", () => {
  it("accepts a non-empty name", () => {
    expect(isItemName("seed-item")).toBe(true);
  });

  it("rejects a blank name", () => {
    expect(isItemName("  ")).toBe(false);
  });

  it("rejects a non-string", () => {
    expect(isItemName(1)).toBe(false);
  });
});
