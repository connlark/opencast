// Purchase-backend workerd matrix (Required Verification #3): the compiled
// Rust gateway with CREDIT_BACKEND=purchase talking to the REAL compiled
// PurchaseWorker (miniflare auxiliary worker) beside FAKE_MEDIA/FAKE_AI.
// JWS fixtures are signed in-test with the throwaway chain minted by the
// PurchaseWorker fixture tooling (leaf key + x5c arrive via bindings).
//
// Ordering matters: the first test proves job/redeem routes fail closed
// before ANY bootstrap has established an install→account link. Each later
// test bootstraps its own fresh Apple identity, so its account starts at the
// 3600 s free grant with no cross-test balance arithmetic.
import { SELF, env } from "cloudflare:test";
import { afterAll, describe, expect, it } from "vitest";
import jwt from "jsonwebtoken";

const BASE = "https://remote-transcription.integration.test";
const BEARER = "integration-test-bearer-token";
const BUNDLE_ID = "com.connor.opencast";
const HOURS20 = "com.connor.opencast.transcription.hours20.v1";
const CATALOG_SHA256 =
  "c2b007bc37825865aa679166a6fa7d1b0d74c141999f459c12e056f3c7134ec5";
const FREE = 3600;
const PACK = 72_000;

const ORIGIN_HOST = "https://origin.example.com";
const ORIGIN_URL = `${ORIGIN_HOST}/audio.mp3`;
const originBytes = makeBytes(1_048_576, 7);
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
  return `${prefix}-gw-${Date.now()}-${uniqueCounter}`;
}

// --- Apple-shaped JWS fixtures (throwaway chain via bindings) ---------------

function signJws(payload, { keyPem, x5c } = {}) {
  return jwt.sign(payload, keyPem ?? env.TEST_TRUSTED_LEAF_KEY_PEM, {
    algorithm: "ES256",
    header: { x5c: x5c ?? JSON.parse(env.TEST_TRUSTED_X5C) },
  });
}

function appTransactionJws(appTransactionId, overrides = {}, signOptions = {}) {
  return signJws(
    {
      receiptType: "Sandbox",
      bundleId: BUNDLE_ID,
      applicationVersion: "1",
      versionExternalIdentifier: 1,
      receiptCreationDate: Date.now(),
      originalPurchaseDate: Date.now(),
      originalApplicationVersion: "1.0",
      appTransactionId,
      ...overrides,
    },
    signOptions,
  );
}

function transactionJws(fields) {
  return signJws({
    transactionId: fields.transactionId,
    originalTransactionId: fields.transactionId,
    webOrderLineItemId: "0",
    bundleId: BUNDLE_ID,
    productId: fields.productId ?? HOURS20,
    purchaseDate: Date.now(),
    originalPurchaseDate: Date.now(),
    quantity: fields.quantity ?? 1,
    type: "Consumable",
    inAppOwnershipType: "PURCHASED",
    signedDate: Date.now(),
    environment: "Sandbox",
    transactionReason: "PURCHASE",
    storefront: "USA",
    storefrontId: "143441",
    price: 990,
    currency: "USD",
    ...(fields.appAccountToken ? { appAccountToken: fields.appAccountToken } : {}),
    ...(fields.appTransactionId ? { appTransactionId: fields.appTransactionId } : {}),
    ...(fields.extra ?? {}),
  });
}

function notificationJws(fields) {
  return signJws({
    notificationType: fields.type,
    ...(fields.subtype ? { subtype: fields.subtype } : {}),
    notificationUUID: fields.uuid,
    data: {
      bundleId: BUNDLE_ID,
      bundleVersion: "1",
      environment: "Sandbox",
      ...(fields.signedTransactionInfo
        ? { signedTransactionInfo: fields.signedTransactionInfo }
        : {}),
    },
    version: "2.0",
    signedDate: Date.now(),
  });
}

// --- Gateway wire helpers ----------------------------------------------------

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

async function balanceOf(appTransactionId) {
  return (await bootstrap(appTransactionId)).balance;
}

async function redeem(jws) {
  return post("/v1/remote-transcription/purchases/redeem", {
    schema_version: 1,
    transaction_jws: jws,
  });
}

async function sendNotification(type, uuid, signedTransactionInfo, extra) {
  return SELF.fetch(`${BASE}/v1/apple/storekit/notifications`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      signedPayload: notificationJws({ type, uuid, signedTransactionInfo, ...extra }),
    }),
  });
}

async function createJob({ clientRequestId, episodeId, durationSeconds, languageCode }) {
  const response = await post("/v1/remote-transcription/jobs", {
    schema_version: 1,
    client_request_id: clientRequestId,
    episode_id: episodeId,
    enclosure_url: ORIGIN_URL,
    declared_duration_seconds: durationSeconds,
    language_code: languageCode,
  });
  expect(response.status).toBe(200);
  const body = await response.json();
  expect(body.job.job_id).toBeTruthy();
  return body.job;
}

async function reportSource(jobId, durationSeconds) {
  originSha256 ??= await sha256Hex(originBytes);
  const response = await post(`/v1/remote-transcription/jobs/${jobId}/source`, {
    schema_version: 1,
    source_identity: {
      sha256: originSha256,
      byte_count: originBytes.length,
      duration_seconds: durationSeconds,
    },
  });
  expect(response.status).toBe(200);
  return (await response.json()).job;
}

async function pollJob(jobId) {
  const response = await post(`/v1/remote-transcription/jobs/${jobId}/poll`, {
    schema_version: 1,
  });
  expect(response.status).toBe(200);
  return response.json();
}

async function waitForState(jobId, states, timeoutMs = 30_000) {
  const deadline = Date.now() + timeoutMs;
  let last;
  while (Date.now() < deadline) {
    last = await pollJob(jobId);
    if (states.includes(last.job.state)) {
      return last;
    }
    await new Promise((resolve) => setTimeout(resolve, 300));
  }
  throw new Error(
    `job ${jobId} never reached ${states}; last=${JSON.stringify(last)}`,
  );
}

async function runJob({ tag, durationSeconds, languageCode, timeoutMs }) {
  const job = await createJob({
    clientRequestId: `req-${tag}`,
    episodeId: `ep-${tag}`,
    durationSeconds,
    languageCode,
  });
  await reportSource(job.job_id, durationSeconds);
  const ready = await waitForState(job.job_id, ["result_ready"], timeoutMs);
  await post(`/v1/remote-transcription/jobs/${job.job_id}/ack`, {
    schema_version: 1,
  });
  return ready;
}

describe("gateway with the real PurchaseWorker credit backend", () => {
  it("fails closed with bootstrap_required before any bootstrap", async () => {
    const jobResponse = await post("/v1/remote-transcription/jobs", {
      schema_version: 1,
      client_request_id: "pre-bootstrap-1",
      episode_id: "ep-pre-1",
      enclosure_url: ORIGIN_URL,
      declared_duration_seconds: 60,
    });
    expect(jobResponse.status).toBe(403);
    expect((await jobResponse.json()).error).toBe("bootstrap_required");

    const redeemResponse = await redeem(
      transactionJws({ transactionId: uid("txn") }),
    );
    expect(redeemResponse.status).toBe(403);
    expect((await redeemResponse.json()).error).toBe("bootstrap_required");
  });

  it("bootstraps through PurchaseWorker: verified JWS, free grant once, catalog", async () => {
    const identity = uid("apptx");
    const first = await bootstrap(identity);
    expect(first.schema_version).toBe(1);
    expect(first.account_id).toMatch(/^pacct-/);
    expect(first.balance).toEqual({
      available_seconds: FREE,
      reserved_seconds: 0,
      debt_seconds: 0,
    });
    expect(first.app_account_token).toMatch(/[0-9a-f-]{36}/);
    expect(first.catalog_sha256).toBe(CATALOG_SHA256);
    expect(first.catalog.map((product) => product.product_id).sort()).toEqual([
      "com.connor.opencast.transcription.hours100.v1",
      HOURS20,
    ]);
    expect(first.purchases_enabled).toBe(true);

    // Reinstall/second-bootstrap: same account, same token, no second grant.
    const second = await bootstrap(identity);
    expect(second.account_id).toBe(first.account_id);
    expect(second.app_account_token).toBe(first.app_account_token);
    expect(second.balance.available_seconds).toBe(FREE);
  });

  it("mirrors PurchaseWorker verification failures and rejects missing JWS", async () => {
    const missing = await post("/v1/remote-transcription/account/bootstrap", {
      schema_version: 1,
    });
    expect(missing.status).toBe(400);
    expect((await missing.json()).error).toBe("invalid_request");

    const rogue = await post("/v1/remote-transcription/account/bootstrap", {
      schema_version: 1,
      app_transaction_jws: appTransactionJws(uid("apptx"), {}, {
        keyPem: env.TEST_ROGUE_LEAF_KEY_PEM,
        x5c: JSON.parse(env.TEST_ROGUE_X5C),
      }),
    });
    expect(rogue.status).toBeGreaterThanOrEqual(400);
    expect((await rogue.json()).error).toBe("invalid_app_transaction");

    const wrongBundle = await post("/v1/remote-transcription/account/bootstrap", {
      schema_version: 1,
      app_transaction_jws: appTransactionJws(uid("apptx"), {
        bundleId: "com.evil.app",
      }),
    });
    expect(wrongBundle.status).toBeGreaterThanOrEqual(400);
    expect((await wrongBundle.json()).error).toBe("invalid_app_transaction");
  });

  it("settles a real job against the purchase ledger end to end", async () => {
    const identity = uid("apptx");
    await bootstrap(identity);

    await runJob({ tag: uid("e2e"), durationSeconds: 600 });

    expect(await balanceOf(identity)).toEqual({
      available_seconds: FREE - 600,
      reserved_seconds: 0,
      debt_seconds: 0,
    });
  });

  it("credits exactly once across concurrent redeem and notification", async () => {
    const identity = uid("apptx");
    const account = await bootstrap(identity);
    const transactionId = uid("txn");
    const jws = transactionJws({
      transactionId,
      appAccountToken: account.app_account_token,
      appTransactionId: identity,
    });

    const [redeemResponse, notificationResponse] = await Promise.all([
      redeem(jws),
      sendNotification("ONE_TIME_CHARGE", uid("uuid"), jws),
    ]);
    expect(redeemResponse.status).toBe(200);
    expect(notificationResponse.status).toBe(200);
    expect(await balanceOf(identity)).toEqual({
      available_seconds: FREE + PACK,
      reserved_seconds: 0,
      debt_seconds: 0,
    });

    // Every duplicate path returns the applied result without re-crediting.
    const duplicateRedeem = await redeem(jws);
    expect(duplicateRedeem.status).toBe(200);
    expect((await duplicateRedeem.json()).outcome).toBe("already_credited");
    const duplicateNotification = await sendNotification(
      "ONE_TIME_CHARGE",
      uid("uuid"),
      jws,
    );
    expect(duplicateNotification.status).toBe(200);
    expect(await balanceOf(identity)).toEqual({
      available_seconds: FREE + PACK,
      reserved_seconds: 0,
      debt_seconds: 0,
    });
  });

  it("admits an overdraft job within the debt cap and repays debt first on credit", async () => {
    const identity = uid("apptx");
    const account = await bootstrap(identity);

    // 4000 s > the 3600 s grant but within headroom (3600 + 10800).
    await runJob({ tag: uid("overdraft"), durationSeconds: 4000, timeoutMs: 60_000 });
    expect(await balanceOf(identity)).toEqual({
      available_seconds: 0,
      reserved_seconds: 0,
      debt_seconds: 400,
    });

    const redeemResponse = await redeem(
      transactionJws({
        transactionId: uid("txn"),
        appAccountToken: account.app_account_token,
        appTransactionId: identity,
      }),
    );
    expect(redeemResponse.status).toBe(200);
    const body = await redeemResponse.json();
    expect(body.outcome).toBe("credited");
    // Debt repayment first: 72000 − 400.
    expect(body.balance).toEqual({
      available_seconds: PACK - 400,
      reserved_seconds: 0,
      debt_seconds: 0,
    });
  });

  it("parks beyond headroom, then resumes when a purchase lands", async () => {
    const identity = uid("apptx");
    const account = await bootstrap(identity);

    // 15000 s > 14400 s headroom on a fresh account: no reservation, no
    // model call — the job parks awaiting credits.
    const job = await createJob({
      clientRequestId: `req-${uid("park")}`,
      episodeId: `ep-${uid("park")}`,
      durationSeconds: 15_000,
    });
    await reportSource(job.job_id, 15_000);
    await waitForState(job.job_id, ["awaiting_credits"]);

    const redeemResponse = await redeem(
      transactionJws({
        transactionId: uid("txn"),
        appAccountToken: account.app_account_token,
        appTransactionId: identity,
      }),
    );
    expect(redeemResponse.status).toBe(200);

    // The 1 s reservation retry picks the credit up and the job completes.
    await waitForState(job.job_id, ["result_ready"], 110_000);
    await post(`/v1/remote-transcription/jobs/${job.job_id}/ack`, {
      schema_version: 1,
    });
    expect(await balanceOf(identity)).toEqual({
      available_seconds: FREE + PACK - 15_000,
      reserved_seconds: 0,
      debt_seconds: 0,
    });
  });

  it("books refund debt honestly and blocks new reservations at zero headroom", async () => {
    const identity = uid("apptx");
    const account = await bootstrap(identity);
    const transactionId = uid("txn");
    const redeemResponse = await redeem(
      transactionJws({
        transactionId,
        appAccountToken: account.app_account_token,
        appTransactionId: identity,
      }),
    );
    expect(redeemResponse.status).toBe(200);

    // Consume 14400 s: the free lot's 3600 first, then 10800 from the pack.
    await runJob({ tag: uid("refundjob"), durationSeconds: 14_400, timeoutMs: 110_000 });
    expect(await balanceOf(identity)).toEqual({
      available_seconds: FREE + PACK - 14_400,
      reserved_seconds: 0,
      debt_seconds: 0,
    });

    // Full refund of the pack: its remaining 61200 s leave `available`; the
    // 10800 s already consumed become debt — exactly the cap, headroom 0.
    const refund = await sendNotification(
      "REFUND",
      uid("uuid"),
      transactionJws({
        transactionId,
        appAccountToken: account.app_account_token,
        appTransactionId: identity,
        extra: { revocationDate: Date.now(), revocationReason: 0 },
      }),
    );
    expect(refund.status).toBe(200);
    expect((await refund.json()).state).toBe("processed");
    expect(await balanceOf(identity)).toEqual({
      available_seconds: 0,
      reserved_seconds: 0,
      debt_seconds: 10_800,
    });

    // No headroom: even a tiny job cannot reserve.
    const blocked = await createJob({
      clientRequestId: `req-${uid("blocked")}`,
      episodeId: `ep-${uid("blocked")}`,
      durationSeconds: 60,
    });
    await reportSource(blocked.job_id, 60);
    await waitForState(blocked.job_id, ["awaiting_credits"]);
    const cancel = await post(
      `/v1/remote-transcription/jobs/${blocked.job_id}/cancel`,
      { schema_version: 1 },
    );
    expect((await cancel.json()).job.state).toBe("cancelled");
  });

  it("forwards notifications: TEST recorded, duplicate deduped, tampered rejected", async () => {
    const uuid = uid("uuid");
    const first = await sendNotification("TEST", uuid);
    expect(first.status).toBe(200);
    expect((await first.json()).state).toBe("recorded");

    const duplicate = await sendNotification("TEST", uuid);
    expect(duplicate.status).toBe(200);
    expect((await duplicate.json()).duplicate).toBe(true);

    const tampered = await SELF.fetch(`${BASE}/v1/apple/storekit/notifications`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ signedPayload: "garbage.payload.signature" }),
    });
    expect(tampered.status).toBeGreaterThanOrEqual(400);
  });

  it("runs two jobs concurrently on two slots while a third queues", async () => {
    const identity = uid("apptx");
    await bootstrap(identity);

    const tags = [uid("slot-a"), uid("slot-b"), uid("slot-c")];
    const jobs = [];
    for (const tag of tags) {
      const job = await createJob({
        clientRequestId: `req-${tag}`,
        episodeId: `ep-${tag}`,
        durationSeconds: 200,
        // 2 s of fake AI latency per chunk makes overlap observable.
        languageCode: "fake:latency=2000",
      });
      jobs.push(job);
    }
    await Promise.all(jobs.map((job) => reportSource(job.job_id, 200)));
    const readies = await Promise.all(
      jobs.map((job) => waitForState(job.job_id, ["result_ready"], 60_000)),
    );

    // One chunk per 200 s job: exactly two AI spans may overlap at any
    // moment (2 limiter slots), and the third had to wait for a free slot.
    const spans = readies.map((ready) => {
      const chunk = ready.job.phase_timestamps.chunks[0];
      return { start: chunk.ai_started_at, end: chunk.ai_ended_at };
    });
    console.log("slot spans", JSON.stringify(spans));
    const overlaps = (a, b) => a.start < b.end && b.start < a.end;
    let concurrentPairs = 0;
    for (let i = 0; i < spans.length; i += 1) {
      for (let j = i + 1; j < spans.length; j += 1) {
        if (overlaps(spans[i], spans[j])) {
          concurrentPairs += 1;
        }
      }
    }
    expect(concurrentPairs).toBeGreaterThanOrEqual(1);
    // All three overlapping pairwise would mean 3 simultaneous model calls.
    expect(concurrentPairs).toBeLessThan(3);

    for (const job of jobs) {
      await post(`/v1/remote-transcription/jobs/${job.job_id}/ack`, {
        schema_version: 1,
      });
    }
    expect(await balanceOf(identity)).toEqual({
      available_seconds: FREE - 600,
      reserved_seconds: 0,
      debt_seconds: 0,
    });
  });

  it("fails a job loud when a reserve replay carries mismatched seconds (PW-3 seam mapping)", async () => {
    const identity = uid("apptx");
    const account = await bootstrap(identity);

    const tag = uid("mismatch");
    const job = await createJob({
      clientRequestId: `req-${tag}`,
      episodeId: `ep-${tag}`,
      durationSeconds: 350,
    });
    // Before /source (so the DO has not reserved yet), poison the seam:
    // seed a reservation under the job's id with different seconds through
    // the same internal surface RTW calls.
    const seeded = await env.PURCHASE_WORKER.fetch(
      "https://opencast-purchase.internal/internal/v1/reserve",
      {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          schema_version: 1,
          account_id: account.account_id,
          job_id: job.job_id,
          seconds: 1,
        }),
      },
    );
    expect(seeded.status).toBe(200);

    await reportSource(job.job_id, 350);
    // The DO's own reserve (350 s) now replays the job id with different
    // seconds; PurchaseWorker answers 409 reservation_seconds_mismatch and
    // the gateway maps it to release_and_fail on the existing internal
    // shape — nothing new reaches the app client.
    const failed = await waitForState(job.job_id, ["failed"]);
    expect(failed.job.error.code).toBe("internal_error");
    // release_and_fail also freed the poisoned reservation.
    expect(await balanceOf(identity)).toEqual({
      available_seconds: FREE,
      reserved_seconds: 0,
      debt_seconds: 0,
    });
  });

  it("releases the reservation through the seam when a job is cancelled", async () => {
    const identity = uid("apptx");
    await bootstrap(identity);

    const tag = uid("cancel");
    const job = await createJob({
      clientRequestId: `req-${tag}`,
      episodeId: `ep-${tag}`,
      durationSeconds: 350,
      // A retryable first-attempt failure parks the job in transcribing for
      // the backoff window so cancellation is deterministic (dev-suite trick).
      languageCode: "fake-fail:429 rate limited",
    });
    await reportSource(job.job_id, 350);
    await waitForState(job.job_id, ["transcribing"]);

    expect((await balanceOf(identity)).reserved_seconds).toBe(350);

    const cancel = await post(
      `/v1/remote-transcription/jobs/${job.job_id}/cancel`,
      { schema_version: 1 },
    );
    expect((await cancel.json()).job.state).toBe("cancelled");
    expect(await balanceOf(identity)).toEqual({
      available_seconds: FREE,
      reserved_seconds: 0,
      debt_seconds: 0,
    });
  });

  it("fails upload/start closed with upload_unavailable when the lane has no R2 S3 credential", async () => {
    // This config deliberately carries no R2_S3_ACCESS_KEY_ID /
    // R2_S3_SECRET_ACCESS_KEY. A policy-unsafe origin routes the job to the
    // upload path without any fetch, proving that the lane fails closed until
    // an operator supplies scoped credentials.
    const identity = uid("apptx");
    await bootstrap(identity);
    const tag = uid("uploadgate");
    const response = await post("/v1/remote-transcription/jobs", {
      schema_version: 1,
      client_request_id: `req-${tag}`,
      episode_id: `ep-${tag}`,
      enclosure_url: "http://tracking.example.com/audio.mp3",
      declared_duration_seconds: 300,
    });
    expect(response.status).toBe(200);
    const job = (await response.json()).job;
    expect(job.state).toBe("exact_upload_required");
    await reportSource(job.job_id, 300);

    const startResponse = await post(
      `/v1/remote-transcription/jobs/${job.job_id}/upload/start`,
      { schema_version: 1 },
    );
    expect(startResponse.status).toBe(503);
    expect((await startResponse.json()).error).toBe("upload_unavailable");

    // Fail-closed means no server state was created and nothing was spent.
    const cancel = await post(
      `/v1/remote-transcription/jobs/${job.job_id}/cancel`,
      { schema_version: 1 },
    );
    expect((await cancel.json()).job.state).toBe("cancelled");
    expect(await balanceOf(identity)).toEqual({
      available_seconds: FREE,
      reserved_seconds: 0,
      debt_seconds: 0,
    });
  });
});
