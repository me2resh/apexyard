import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const nextVitals = require("eslint-config-next/core-web-vitals");

const config = [
  { ignores: ["coverage/**", "data/**"] },
  ...nextVitals,
  {
    rules: {
      "no-debugger": "error",
    },
  },
];

export default config;
