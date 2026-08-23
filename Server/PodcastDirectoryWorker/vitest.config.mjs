import { cloudflareTest } from "@cloudflare/vitest-pool-workers";
import { defineConfig } from "vitest/config";

export default defineConfig({
  plugins: [
    cloudflareTest({
      wrangler: { configPath: "./wrangler.toml" },
      miniflare: {
        bindings: {
          PODCAST_INDEX_API_KEY: "integration-test-api-key",
          PODCAST_INDEX_API_SECRET: "integration-test-api-secret",
        },
      },
    }),
  ],
  test: {
    include: ["test/*.spec.mjs"],
    testTimeout: 30_000,
  },
});
