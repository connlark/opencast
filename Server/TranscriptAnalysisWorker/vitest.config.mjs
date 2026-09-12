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
            TRANSCRIPT_ANALYSIS_CLIENT_TOKEN: "integration-test-bearer-token",
            GEMINI_API_KEY: "integration-test-gemini-key",
            // This suite is the billing-dark matrix ("billing dark" describe):
            // pin it off regardless of the lane default in wrangler.toml, which
            // flipped to "true" on 2026-08-29 and turned sync envelope analyzes
            // into async_required 400s here. The billing suites run under
            // vitest.billing / vitest.purchase with their own bindings.
            BILLING_REQUIRED: "false",
            // Overrides the wrangler.toml default with the BANNED model so
            // the suite witnesses the single-entry allowlist clamp end to
            // end: the env var is ignored, the outbound URL targets the
            // default, and the response reports the default.
            TRANSCRIPT_ANALYSIS_GEMINI_MODEL: "gemini-2.5-flash",
          },
        },
      }),
    ],
    test: {
      // The billing suites run under their own configs (vitest.billing /
      // vitest.purchase) with different worker bindings.
      include: ["test/integration.spec.mjs"],
      setupFiles: ["./test/apply-migrations.mjs"],
    },
  };
});
