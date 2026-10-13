import { migrate, seed } from "../src/infrastructure/db.mjs";

await migrate();
await seed();
