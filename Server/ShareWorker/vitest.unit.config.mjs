import { defineConfig } from "vitest/config";
import { alias } from "./alias.ts";

// Node tests: the token decoder against the Swift-minted vectors, start-time
// parsing, the server-rendered page (through the same preact alias as the
// build), and config/toolchain contracts. No workerd needed.
export default defineConfig({
  resolve: { alias },
  test: {
    include: ["test/unit/**/*.spec.{mjs,ts,tsx}"],
    testTimeout: 30_000,
  },
});
