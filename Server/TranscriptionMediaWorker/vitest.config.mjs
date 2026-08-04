import { defineConfig } from "vitest/config";

// Plain node environment: the media worker's testable surface is pure key
// and routing logic (src/keys.ts); the container itself is exercised by the
// Python container tests and the RTW gateway's integration suite.
export default defineConfig({
  test: {
    include: ["test/**/*.test.ts"],
  },
});
