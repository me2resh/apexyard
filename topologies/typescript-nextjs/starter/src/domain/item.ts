export type Item = {
  id: number;
  name: string;
};

export function isItemName(value: unknown): value is string {
  return typeof value === "string" && value.trim() !== "";
}
