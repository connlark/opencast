import path from "node:path";
import {
  cloudflareTest,
  readD1Migrations,
} from "@cloudflare/vitest-pool-workers";
import { defineConfig } from "vitest/config";

export default defineConfig(async () => {
  const migrations = await readD1Migrations(
    path.join(import.meta.dirname, "migrations"),
  );

  return {
    plugins: [
      cloudflareTest({
        wrangler: { configPath: "./wrangler.toml" },
        miniflare: {
          bindings: {
            TEST_MIGRATIONS: migrations,
            AD_ANALYSIS_CLIENT_TOKEN: "integration-test-bearer-token",
            GEMINI_API_KEY: "integration-test-gemini-key",
            // Overrides the wrangler.toml default (gemini-3.5-flash) so the
            // suite witnesses the documented fallback flip end to end: the
            // env var selects the model, the outbound URL targets it, and
            // the response reports it.
            AD_ANALYSIS_GEMINI_MODEL: "gemini-3.1-flash-lite",
          },
        },
      }),
    ],
    test: {
      include: ["test/**/*.spec.mjs"],
      setupFiles: ["./test/apply-migrations.mjs"],
    },
  };
});
