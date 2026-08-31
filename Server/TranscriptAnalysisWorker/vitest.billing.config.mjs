// Billing matrix, development fake backend: the compiled worker with
// BILLING_REQUIRED=true and the D1 dev-credit fake (no PURCHASE_WORKER
// binding — CREDIT_BACKEND derives to `dev` in the development lane). This
// is the development-lane E2E verification of the billing contract:
// real HTTP through the wasm worker, synthetic App Attest envelopes, real
// reserve/settle/release semantics against D1.
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
            TRANSCRIPT_ANALYSIS_GEMINI_MODEL: "gemini-3.5-flash",
            BILLING_REQUIRED: "true",
          },
        },
      }),
    ],
    test: {
      include: ["test/billing-dev.spec.mjs"],
      setupFiles: ["./test/apply-migrations.mjs"],
    },
  };
});
