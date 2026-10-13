export type ItemRow = {
  id: number;
  name: string;
};

export function dataDir(): string;
export function migrate(): Promise<void>;
export function seed(): Promise<void>;
export function listItems(): Promise<ItemRow[]>;
export function addItem(name: string): Promise<ItemRow>;
export function resetData(): Promise<void>;
export function closeDb(): void;
