// Kill-switch lane: the public flag is forced off and no Podcast Index
// credentials are bound, proving the worker fails closed before it can
// need them.
import { cloudflareTest } from "@cloudflare/vitest-pool-workers";
import { defineConfig } from "vitest/config";

export default defineConfig({
  plugins: [
    cloudflareTest({
      wrangler: { configPath: "./wrangler.toml" },
      miniflare: {
        bindings: {
          PUBLIC_PODCAST_DIRECTORY_ENABLED: "false",
        },
      },
    }),
  ],
  test: {
    include: ["test/killswitch/*.spec.mjs"],
  },
});
