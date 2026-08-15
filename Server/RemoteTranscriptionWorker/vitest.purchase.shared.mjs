// Shared harness for the purchase-backend workerd matrices (Required
// Verification #3): the gateway runs with CREDIT_BACKEND=purchase against the
// REAL compiled PurchaseWorker as a miniflare auxiliary worker, beside the
// existing FAKE_MEDIA/FAKE_AI upstreams. Requires `build/index.js` (gateway)
// and `../PurchaseWorker/dist/index.js` (`yarn workspace
// opencast-purchase-worker build:test-bundle`); see the `test:purchase` script.
//
// The gateway stays in the development lane so the dev bearer authenticates
// requests — strictly more production-shaped than the dev fake, while App
// Attest itself is exercised on physical devices (W7).
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import {
  cloudflareTest,
  readD1Migrations,
} from "@cloudflare/vitest-pool-workers";
import { mintFixtures } from "../PurchaseWorker/test/fixtures/mint.mjs";

const PURCHASE_TEST_DB_ID = "purchase-test-db";

/**
 * Stage the compiled PurchaseWorker bundle for miniflare. Two workerd
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

export async function makePurchaseConfig({ include, extraBindings = {} }) {
  const migrations = await readD1Migrations(
    path.join(import.meta.dirname, "migrations"),
  );
  const purchaseMigrations = await readD1Migrations(
    path.join(import.meta.dirname, "../PurchaseWorker/migrations"),
  );
  // Throwaway Apple-shaped chains (PurchaseWorker fixture minter); specs sign
  // JWS in-test with the leaf key passed through bindings.
  const fixtures = mintFixtures();

  return {
    plugins: [
      cloudflareTest({
        // The gateway's Workers AI binding is unused under FAKE_AI. Disable
        // remote proxies so these contract suites require no Cloudflare auth.
        remoteBindings: false,
        wrangler: { configPath: "./wrangler.toml" },
        miniflare: {
          serviceBindings: {
            // FAKE_MEDIA short-circuits before the service binding; this stub
            // exists only so the binding resolves.
            TRANSCRIPTION_MEDIA_WORKER() {
              return new Response("media worker unavailable in tests", {
                status: 501,
              });
            },
            // No purchase spec requests ad analysis; this stub exists only so
            // the binding added by the cloud-mode ad-detection lane resolves
            // (the pool refuses to start on an undefined service).
            AD_ANALYSIS_WORKER() {
              return new Response("ad analysis unavailable in purchase tests", {
                status: 501,
              });
            },
            // The real compiled PurchaseWorker (auxiliary worker below).
            PURCHASE_WORKER: "opencast-purchase",
          },
          // Same database ID as the auxiliary worker's PURCHASE_DB: the test
          // env needs a handle to apply PurchaseWorker's migrations.
          d1Databases: { PURCHASE_TEST_DB: PURCHASE_TEST_DB_ID },
          bindings: {
            TEST_MIGRATIONS: migrations,
            PURCHASE_TEST_MIGRATIONS: purchaseMigrations,
            DEV_BEARER_TOKEN: "integration-test-bearer-token",
            FAKE_MEDIA: "true",
            FAKE_AI: "true",
            CREDIT_BACKEND: "purchase",
            // Raised so a fresh account (3600 s free grant + 10800 s debt
            // cap = 14400 s headroom) can be blocked by a single job.
            MAX_CANONICAL_DURATION_SECONDS: "20000",
            // The multi-slot test drives concurrent jobs from one account.
            MAX_ACTIVE_JOBS_PER_ACCOUNT: "4",
            // Credit→resume in test time: retry every second, park for 30 s.
            AWAITING_CREDITS_DEADLINE_SECONDS: "30",
            AWAITING_CREDITS_RETRY_SECONDS: "1",
            POLL_AFTER_SECONDS: "1",
            // Fixture material for in-test JWS signing (throwaway keys).
            TEST_TRUSTED_LEAF_KEY_PEM: fixtures.trusted.leafKeyPem,
            TEST_TRUSTED_X5C: JSON.stringify(fixtures.trusted.x5c),
            TEST_ROGUE_LEAF_KEY_PEM: fixtures.rogue.leafKeyPem,
            TEST_ROGUE_X5C: JSON.stringify(fixtures.rogue.x5c),
            ...extraBindings,
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
                // trusted root (offline checks; W1 proved the online path).
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
      include,
      setupFiles: ["./test/purchase/apply-migrations.mjs"],
      // Debt/refund flows run 14400 s episodes (49 chunk objects) through
      // the fake media/AI path; give them generous wall clock.
      testTimeout: 120_000,
      maxWorkers: 1,
      isolate: false,
    },
  };
}
