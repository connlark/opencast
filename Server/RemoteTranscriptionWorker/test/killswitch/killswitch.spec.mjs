// Kill switch (decision 12) + limiter daily spend cap, on the purchase
// backend with the real PurchaseWorker. This config runs with
// PURCHASES_ENABLED=false and DAILY_SPEND_CAP_USD_MICRO=1000 (≈120 s of
// audio), so store surfaces are hidden and any real job trips the cap.
import { SELF, env } from "cloudflare:test";
import { afterAll, describe, expect, it } from "vitest";
import jwt from "jsonwebtoken";

const BASE = "https://remote-transcription.integration.test";
const BEARER = "integration-test-bearer-token";
const BUNDLE_ID = "com.connor.opencast";
const FREE = 3600;

const ORIGIN_HOST = "https://origin.example.com";
const ORIGIN_URL = `${ORIGIN_HOST}/audio.mp3`;
const originBytes = makeBytes(262_144, 7);
let originSha256 = null;

const realFetch = globalThis.fetch;
globalThis.fetch = async (input, init) => {
  const url = typeof input === "string" ? input : input.url;
  if (url.startsWith(ORIGIN_HOST)) {
    return new Response(originBytes, {
      status: 200,
      headers: {
        "content-type": "audio/mpeg",
        "content-length": String(originBytes.length),
      },
    });
  }
  return realFetch(input, init);
};

afterAll(() => {
  globalThis.fetch = realFetch;
});

function makeBytes(count, seed) {
  const bytes = new Uint8Array(count);
  let state = seed >>> 0;
  for (let index = 0; index < count; index += 1) {
    state = (state * 1_664_525 + 1_013_904_223) >>> 0;
    bytes[index] = state & 0xff;
  }
  return bytes;
}

async function sha256Hex(bytes) {
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return [...new Uint8Array(digest)]
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

let uniqueCounter = 0;
function uid(prefix) {
  uniqueCounter += 1;
  return `${prefix}-ks-${Date.now()}-${uniqueCounter}`;
}

function signJws(payload) {
  return jwt.sign(payload, env.TEST_TRUSTED_LEAF_KEY_PEM, {
    algorithm: "ES256",
    header: { x5c: JSON.parse(env.TEST_TRUSTED_X5C) },
  });
}

function appTransactionJws(appTransactionId) {
  return signJws({
    receiptType: "Sandbox",
    bundleId: BUNDLE_ID,
    applicationVersion: "1",
    receiptCreationDate: Date.now(),
    originalPurchaseDate: Date.now(),
    originalApplicationVersion: "1.0",
    appTransactionId,
  });
}

async function post(path, body) {
  return SELF.fetch(`${BASE}${path}`, {
    method: "POST",
    headers: {
      authorization: `Bearer ${BEARER}`,
      "content-type": "application/json",
    },
    body: JSON.stringify(body ?? {}),
  });
}

async function bootstrap(appTransactionId) {
  const response = await post("/v1/remote-transcription/account/bootstrap", {
    schema_version: 1,
    app_transaction_jws: appTransactionJws(appTransactionId),
  });
  expect(response.status).toBe(200);
  return response.json();
}

describe("purchase kill switch and spend cap", () => {
  it("keeps bootstrap/balances but flags the store as unavailable", async () => {
    const identity = uid("apptx");
    const body = await bootstrap(identity);
    expect(body.balance.available_seconds).toBe(FREE);
    expect(body.purchases_enabled).toBe(false);
  });

  it("hides redeem behind a stable purchases_disabled error", async () => {
    const identity = uid("apptx");
    const account = await bootstrap(identity);
    const response = await post("/v1/remote-transcription/purchases/redeem", {
      schema_version: 1,
      transaction_jws: signJws({
        transactionId: uid("txn"),
        originalTransactionId: uid("txn"),
        bundleId: BUNDLE_ID,
        productId: "com.connor.opencast.transcription.hours20.v1",
        purchaseDate: Date.now(),
        originalPurchaseDate: Date.now(),
        quantity: 1,
        type: "Consumable",
        appAccountToken: account.app_account_token,
        inAppOwnershipType: "PURCHASED",
        signedDate: Date.now(),
        environment: "Sandbox",
        transactionReason: "PURCHASE",
        storefront: "USA",
        appTransactionId: identity,
      }),
    });
    expect(response.status).toBe(503);
    expect((await response.json()).error).toBe("purchases_disabled");
  });

  it("keeps processing Apple notifications while the store is hidden", async () => {
    const response = await SELF.fetch(`${BASE}/v1/apple/storekit/notifications`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        signedPayload: signJws({
          notificationType: "TEST",
          notificationUUID: uid("uuid"),
          data: { bundleId: BUNDLE_ID, bundleVersion: "1", environment: "Sandbox" },
          version: "2.0",
          signedDate: Date.now(),
        }),
      }),
    });
    expect(response.status).toBe(200);
    expect((await response.json()).state).toBe("recorded");
  });

  it("fails a job closed at the daily spend cap without charging the customer", async () => {
    const identity = uid("apptx");
    await bootstrap(identity);

    const tag = uid("capped");
    const createResponse = await post("/v1/remote-transcription/jobs", {
      schema_version: 1,
      client_request_id: `req-${tag}`,
      episode_id: `ep-${tag}`,
      enclosure_url: ORIGIN_URL,
      declared_duration_seconds: 300,
    });
    expect(createResponse.status).toBe(200);
    const job = (await createResponse.json()).job;

    originSha256 ??= await sha256Hex(originBytes);
    const sourceResponse = await post(
      `/v1/remote-transcription/jobs/${job.job_id}/source`,
      {
        schema_version: 1,
        source_identity: {
          sha256: originSha256,
          byte_count: originBytes.length,
          duration_seconds: 300,
        },
      },
    );
    expect(sourceResponse.status).toBe(200);

    // 300 s estimates 2500 micro-USD > the 1000 cap: the first chunk's
    // admission is refused and the job fails closed as rate_limited.
    const deadline = Date.now() + 30_000;
    let last;
    while (Date.now() < deadline) {
      const response = await post(
        `/v1/remote-transcription/jobs/${job.job_id}/poll`,
        { schema_version: 1 },
      );
      last = await response.json();
      if (last.job.state === "failed") {
        break;
      }
      await new Promise((resolve) => setTimeout(resolve, 300));
    }
    expect(last.job.state).toBe("failed");
    expect(last.job.error.code).toBe("rate_limited");

    // The reservation was released through the purchase seam: full grant
    // intact, nothing reserved, no debt.
    expect((await bootstrap(identity)).balance).toEqual({
      available_seconds: FREE,
      reserved_seconds: 0,
      debt_seconds: 0,
    });
  });
});
