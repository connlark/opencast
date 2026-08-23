// Missing-secret lane: the flag is on but no Podcast Index credentials
// are bound, proving the worker answers 503 rather than calling
// upstream unauthenticated.
import { cloudflareTest } from "@cloudflare/vitest-pool-workers";
import { defineConfig } from "vitest/config";

export default defineConfig({
  plugins: [
    cloudflareTest({
      wrangler: { configPath: "./wrangler.toml" },
    }),
  ],
  test: {
    include: ["test/nosecrets/*.spec.mjs"],
  },
});
