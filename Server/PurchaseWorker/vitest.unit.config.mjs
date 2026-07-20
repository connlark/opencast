import { defineConfig } from "vitest/config";

// Pure-Node tests: the ledger property suite, catalog/manifest drift, and
// wrangler-config contract checks. No workerd needed.
export default defineConfig({
  test: {
    include: ["test/unit/**/*.spec.mjs"],
    testTimeout: 30_000,
  },
});
