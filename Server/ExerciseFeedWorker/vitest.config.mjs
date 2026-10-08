import { cloudflareTest } from "@cloudflare/vitest-plugin";
import { defineConfig } from "vitest/config";

export default defineConfig({
  plugins: [
    cloudflareTest({
      wrangler: { configPath: "./wrangler.toml" },
      miniflare: {
        bindings: {
          ADMIN_TOKEN: "integration-test-admin-token",
        },
      },
    }),
  ],
  test: {
    include: ["test/**/*.spec.mjs"],
  },
});
