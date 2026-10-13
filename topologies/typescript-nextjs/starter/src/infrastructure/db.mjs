import { createRequire } from "node:module";
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import path from "node:path";
import { desc } from "drizzle-orm";
import { drizzle } from "drizzle-orm/sql-js";
import { integer, sqliteTable, text } from "drizzle-orm/sqlite-core";

const require = createRequire(path.join(process.cwd(), "package.json"));
const SEED_NAME = "seed-item";

export const items = sqliteTable("items", {
  id: integer("id").primaryKey({ autoIncrement: true }),
  name: text("name").notNull(),
});

let state = null;

export function dataDir() {
  return process.env.DATA_DIR ?? path.join(process.cwd(), "data");
}

function dbPath() {
  return path.join(dataDir(), "app.db");
}

function persist(current) {
  mkdirSync(dataDir(), { recursive: true });
  writeFileSync(dbPath(), Buffer.from(current.client.export()));
}

async function open() {
  if (state) return state;
  const initSqlJs = require("sql.js");
  const wasm = readFileSync(require.resolve("sql.js/dist/sql-wasm.wasm"));
  const SQL = await initSqlJs({ wasmBinary: wasm });
  const file = dbPath();
  const client = existsSync(file) ? new SQL.Database(readFileSync(file)) : new SQL.Database();
  client.run(
    "CREATE TABLE IF NOT EXISTS items (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL)",
  );
  const db = drizzle(client, { schema: { items } });
  state = { client, db };
  persist(state);
  return state;
}

export async function migrate() {
  await open();
}

export async function listItems() {
  const current = await open();
  return current.db
    .select()
    .from(items)
    .all()
    .map((row) => ({ id: Number(row.id), name: String(row.name) }));
}

export async function addItem(name) {
  const current = await open();
  current.db.insert(items).values({ name }).run();
  const rows = current.db.select().from(items).orderBy(desc(items.id)).limit(1).all();
  const row = rows[0];
  if (!row) {
    throw new Error("insert failed");
  }
  persist(current);
  return { id: Number(row.id), name: String(row.name) };
}

export async function seed() {
  const current = await open();
  const rows = current.db.select().from(items).all();
  if (rows.length === 0) {
    current.db.insert(items).values({ name: SEED_NAME }).run();
    persist(current);
  }
}

export async function resetData() {
  if (state) {
    state.client.close();
    state = null;
  }
  const file = dbPath();
  if (existsSync(file)) rmSync(file);
  await migrate();
  await seed();
}

export function closeDb() {
  if (!state) return;
  state.client.close();
  state = null;
}
