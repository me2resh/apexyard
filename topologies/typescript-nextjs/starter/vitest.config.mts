import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    environment: "node",
    fileParallelism: false,
    coverage: {
      provider: "v8",
      reporter: ["text", "json-summary"],
      reportsDirectory: "coverage",
      include: ["src/**/*.{ts,tsx,mjs}"],
      exclude: [
        "src/**/*.test.ts",
        "src/**/*.test.tsx",
        "**/*.d.ts",
        "**/*.d.mts",
        "next.config.ts",
        "next-env.d.ts",
      ],
      thresholds: {
        lines: 80,
      },
    },
  },
});
