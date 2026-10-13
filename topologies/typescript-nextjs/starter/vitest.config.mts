import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    environment: "node",
    fileParallelism: false,
    coverage: {
      provider: "v8",
      reporter: ["text", "json-summary"],
      reportsDirectory: "coverage",
      include: ["src/**/*.ts", "src/**/*.mjs"],
      exclude: ["src/**/*.test.ts", "src/**/*.d.ts", "src/**/*.d.mts"],
      thresholds: {
        lines: 80,
      },
    },
  },
});
