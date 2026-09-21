import path from "node:path";
import {
  cloudflareTest,
  readD1Migrations,
} from "@cloudflare/vitest-pool-workers";
import { defineConfig } from "vitest/config";

export default defineConfig(async () => {
  const v3 = process.env.OPENCAST_TEST_AD_POLICY === "v3";
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
            AD_ANALYSIS_POLICY: v3
              ? "promo_ad_breaks_v3"
              : "promo_ad_breaks_v2",
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
      include: [v3 ? "test/promo-v3.spec.mjs" : "test/integration.spec.mjs", "test/retention.spec.mjs"],
      setupFiles: ["./test/apply-migrations.mjs"],
    },
  };
});
