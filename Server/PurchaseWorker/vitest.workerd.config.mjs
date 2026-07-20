import path from "node:path";
import {
  cloudflareTest,
  readD1Migrations,
} from "@cloudflare/vitest-pool-workers";
import { defineConfig } from "vitest/config";
import jwt from "jsonwebtoken";
import { mintFixtures } from "./test/fixtures/mint.mjs";

export default defineConfig(async () => {
  const migrations = await readD1Migrations(
    path.join(import.meta.dirname, "migrations"),
  );
  // Mint the throwaway Apple-shaped chains before miniflare reads bindings.
  const fixtures = mintFixtures();

  // Fake Apple history host (reconcile.spec.mjs): deterministic per identity —
  // one consumable purchase `txn-history-<identity>`, revoked when the
  // identity ends in "-revoked". Runs in Node; only unexpected hosts 502.
  const outboundService = async (request) => {
    const url = new URL(request.url);
    if (
      url.hostname === "api.storekit-sandbox.apple.com" &&
      url.pathname.startsWith("/inApps/v2/history/")
    ) {
      const identity = decodeURIComponent(url.pathname.split("/").pop() ?? "");
      const payload = {
        transactionId: `txn-history-${identity}`,
        originalTransactionId: `txn-history-${identity}`,
        bundleId: "com.connor.opencast",
        productId: "com.connor.opencast.transcription.hours20.v1",
        purchaseDate: Date.now(),
        originalPurchaseDate: Date.now(),
        quantity: 1,
        type: "Consumable",
        inAppOwnershipType: "PURCHASED",
        signedDate: Date.now(),
        environment: "Sandbox",
        transactionReason: "PURCHASE",
        storefront: "USA",
        appTransactionId: identity,
        ...(identity.endsWith("-revoked")
          ? { revocationDate: Date.now(), revocationReason: 0 }
          : {}),
      };
      const signed = jwt.sign(payload, fixtures.trusted.leafKeyPem, {
        algorithm: "ES256",
        header: { x5c: fixtures.trusted.x5c },
      });
      return new Response(
        JSON.stringify({
          revision: "rev-1",
          bundleId: "com.connor.opencast",
          environment: "Sandbox",
          hasMore: false,
          signedTransactions: [signed],
        }),
        { headers: { "content-type": "application/json" } },
      );
    }
    return new Response("unexpected outbound request in tests", { status: 502 });
  };

  return {
    plugins: [
      cloudflareTest({
        wrangler: { configPath: "./wrangler.toml" },
        miniflare: {
          outboundService,
          bindings: {
            TEST_MIGRATIONS: migrations,
            APPLE_BUNDLE_ID: "com.connor.opencast",
            // Development-lane-only root override pointing at the minted
            // trusted root; offline checks (no OCSP responder here — the W1
            // spike proved the online path separately).
            APPLE_ROOT_CAS_OVERRIDE_BASE64: fixtures.trusted.rootDerBase64,
            ENABLE_ONLINE_CHECKS: "false",
            // Fixed throwaway identity keys (never real material; 32 bytes).
            APP_TX_HMAC_KEY: "cHVyY2hhc2UtdGVzdC1obWFjLWtleS0zMmJ5dGVzISE=",
            APP_TX_ENCRYPTION_KEY: "v1:cHVyY2hhc2UtdGVzdC1lbmNyLWtleS0zMmJ5dGVzISE=",
            // Throwaway In-App Purchase API key material for the mocked
            // Apple history endpoint (reconcile.spec.mjs).
            APPLE_IAP_KEY_ID: "TESTKEY123",
            APPLE_IAP_ISSUER_ID: "00000000-0000-0000-0000-000000000000",
            APPLE_IAP_PRIVATE_KEY: fixtures.apiKeyPem,
          },
        },
      }),
    ],
    test: {
      include: ["test/workerd/**/*.spec.mjs"],
      setupFiles: ["./test/workerd/apply-migrations.mjs"],
      testTimeout: 30_000,
      poolOptions: {
        workers: {
          isolatedStorage: false,
          singleWorker: true,
        },
      },
    },
  };
});
