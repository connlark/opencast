// Billing matrix, PurchaseWorker backend: the compiled
// gateway with BILLING_REQUIRED=true and CREDIT_BACKEND=purchase talking to
// the compiled PurchaseWorker as a miniflare auxiliary worker. Requires
// `build/index.js` (gateway)
// and `../PurchaseWorker/dist/index.js` (`yarn workspace
// opencast-purchase-worker build:test-bundle`); see the `test:purchase`
// script. The gateway stays in the development lane; billing flows ride
// synthetic App Attest envelopes, the bearer probe lane stays exempt.
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import {
  cloudflareTest,
  readD1Migrations,
} from "@cloudflare/vitest-pool-workers";
import { defineConfig } from "vitest/config";
import { mintFixtures } from "../PurchaseWorker/test/fixtures/mint.mjs";

const PURCHASE_TEST_DB_ID = "purchase-test-db";

/**
 * Prepare the compiled PurchaseWorker bundle for miniflare. Two workerd
 * constraints: module paths must live under the worker root (this package
 * directory — `../PurchaseWorker/dist` escapes it and workerd refuses with
 * "can't use '..' to break out of starting directory"), and the wrangler
 * bundle's sourceMappingURL comment must go (miniflare follows it and the
 * map's `../src/...` sources escape the root the same way). Copy a stripped
 * bundle into build/ (gitignored) and point the auxiliary worker at it.
 */
function purchaseWorkerModule() {
  const bundlePath = path.join(
    import.meta.dirname,
    "../PurchaseWorker/dist/index.js",
  );
  const contents = readFileSync(bundlePath, "utf8").replace(
    /^\/\/# sourceMappingURL=.*$/m,
    "",
  );
  const stagedPath = path.join(
    import.meta.dirname,
    "build/purchase-worker.test-bundle.mjs",
  );
  mkdirSync(path.dirname(stagedPath), { recursive: true });
  writeFileSync(stagedPath, contents);
  return { type: "ESModule", path: stagedPath };
}

export default defineConfig(async () => {
  const migrations = await readD1Migrations(
    path.join(import.meta.dirname, "migrations"),
  );
  const purchaseMigrations = await readD1Migrations(
    path.join(import.meta.dirname, "../PurchaseWorker/migrations"),
  );
  // Throwaway Apple-shaped chains (PurchaseWorker fixture minter); specs
  // sign AppTransaction JWS in-test with the leaf key passed via bindings.
  const fixtures = mintFixtures();

  return {
    plugins: [
      cloudflareTest({
        remoteBindings: false,
        wrangler: { configPath: "./wrangler.toml" },
        miniflare: {
          serviceBindings: {
            // The real compiled PurchaseWorker (auxiliary worker below).
            PURCHASE_WORKER: "opencast-purchase",
          },
          // Same database ID as the auxiliary worker's PURCHASE_DB: the test
          // env needs a handle to apply PurchaseWorker's migrations and to
          // assert on the global reservation_index.
          d1Databases: { PURCHASE_TEST_DB: PURCHASE_TEST_DB_ID },
          bindings: {
            TEST_MIGRATIONS: migrations,
            PURCHASE_TEST_MIGRATIONS: purchaseMigrations,
            TRANSCRIPT_ANALYSIS_CLIENT_TOKEN: "integration-test-bearer-token",
            GEMINI_API_KEY: "integration-test-gemini-key",
            TRANSCRIPT_ANALYSIS_GEMINI_MODEL: "gemini-3.5-flash",
            BILLING_REQUIRED: "true",
            CREDIT_BACKEND: "purchase",
            // Fixture material for in-test JWS signing (throwaway keys).
            TEST_TRUSTED_LEAF_KEY_PEM: fixtures.trusted.leafKeyPem,
            TEST_TRUSTED_X5C: JSON.stringify(fixtures.trusted.x5c),
            TEST_ROGUE_LEAF_KEY_PEM: fixtures.rogue.leafKeyPem,
            TEST_ROGUE_X5C: JSON.stringify(fixtures.rogue.x5c),
          },
          workers: [
            {
              name: "opencast-purchase",
              modules: [purchaseWorkerModule()],
              compatibilityDate: "2026-07-09",
              compatibilityFlags: ["nodejs_compat"],
              d1Databases: { PURCHASE_DB: PURCHASE_TEST_DB_ID },
              durableObjects: {
                PURCHASE_ACCOUNT: {
                  className: "PurchaseAccount",
                  useSQLite: true,
                },
              },
              bindings: {
                LANE: "development",
                STOREKIT_ENVIRONMENT: "Sandbox",
                APPLE_BUNDLE_ID: "com.connor.opencast",
                ALLOW_MISSING_APP_APPLE_ID: "true",
                ENABLE_ONLINE_CHECKS: "false",
                APPLE_ROOT_CAS_BASE64: "",
                // Development-lane-only override pointing at the minted
                // trusted root (offline checks).
                APPLE_ROOT_CAS_OVERRIDE_BASE64: fixtures.trusted.rootDerBase64,
                RECONCILE_BATCH_ACCOUNTS: "20",
                RECONCILE_INTERVAL_SECONDS: "21600",
                // Fixed throwaway identity keys (never real material).
                APP_TX_HMAC_KEY: "cHVyY2hhc2UtdGVzdC1obWFjLWtleS0zMmJ5dGVzISE=",
                APP_TX_ENCRYPTION_KEY:
                  "v1:cHVyY2hhc2UtdGVzdC1lbmNyLWtleS0zMmJ5dGVzISE=",
              },
            },
          ],
        },
      }),
    ],
    test: {
      include: ["test/purchase/*.spec.mjs"],
      setupFiles: ["./test/purchase/apply-migrations.mjs"],
      maxWorkers: 1,
      isolate: false,
    },
  };
});
