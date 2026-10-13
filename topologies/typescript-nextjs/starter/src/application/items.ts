import { isItemName, type Item } from "../domain/item";
import { addItem as insertItem, listItems as readItems } from "../infrastructure/db.mjs";

export type AddResult = { ok: true; item: Item } | { ok: false; code: "invalid-item" };

export async function listItems(): Promise<Item[]> {
  return readItems();
}

export async function addItem(input: unknown): Promise<AddResult> {
  if (typeof input !== "object" || input === null || !("name" in input)) {
    return { ok: false, code: "invalid-item" };
  }
  const candidate = input.name;
  if (!isItemName(candidate)) {
    return { ok: false, code: "invalid-item" };
  }
  const item = await insertItem(candidate.trim());
  return { ok: true, item };
}
