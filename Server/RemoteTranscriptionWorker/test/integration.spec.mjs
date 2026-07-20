// Workerd-local integration tests: drive real HTTP requests through the
// compiled wasm Worker with local D1, R2, and Durable Object bindings, a
// mocked origin (global fetch), and the development-lane fake media/AI
// upstreams. Requires `build/index.js` (see `yarn build:worker`).
//
// The suite shares storage and one dev-bearer account (grant 1000s); tests
// run sequentially and their credit spends are cumulative by design.
import {
  SELF,
  createExecutionContext,
  createScheduledController,
  env,
  waitOnExecutionContext,
} from "cloudflare:test";
import { afterAll, describe, expect, it } from "vitest";
import RemoteTranscriptionWorker from "../build/index.js";

const BASE = "https://remote-transcription.integration.test";
const BEARER = "integration-test-bearer-token";
// Must match DEV_CREDIT_GRANT_SECONDS in vitest.config.mjs. Tests run
// sequentially against one account, so expected balances are written as
// GRANT minus the settled spend accumulated up to that point.
const GRANT = 7000;
const ORIGIN_HOST = "https://origin.example.com";
const ORIGIN_URL = `${ORIGIN_HOST}/audio.mp3`;
const ORIGIN_REDIRECT_URL = `${ORIGIN_HOST}/redirect/audio.mp3`;
const LARGE_ORIGIN_URL = `${ORIGIN_HOST}/large.mp3`;
// Podtrac/mgln class: the origin refuses Workers fetches outright.
const FAILING_ORIGIN_URL = `${ORIGIN_HOST}/blocked.mp3`;
// Fake S3 endpoint for presigned UploadPart PUTs (must match R2_S3_HOST /
// R2_S3_BUCKET in vitest.config.mjs); the fetch mock below maps PUTs onto
// the R2 binding's real multipart machinery.
const R2_SIM_PREFIX = "https://r2-sim.test/test-bucket/";
const PUSHOVER_URL = "https://api.pushover.net/1/messages.json";
const pushoverAlerts = [];

// Chunk sizes deliberately misaligned with the 8 MiB R2 part size: staging
// that flushes parts at whatever size the buffer crossed the boundary would
// upload non-final parts of 8 MiB + 1 and 8 MiB + 2 bytes, which R2 rejects
// at `complete` (all non-final parts must be byte-identical in size).
const LARGE_CHUNK_SIZES = [
  5 * 1024 * 1024,
  3 * 1024 * 1024 + 1,
  8 * 1024 * 1024 + 2,
  1_000_000,
];
const LARGE_ORIGIN_TOTAL = LARGE_CHUNK_SIZES.reduce((sum, size) => sum + size, 0);
let largeOriginBytes = null;

const originBytes = makeBytes(1_048_576, 7);
let originSha256 = null;

const realFetch = globalThis.fetch;
globalThis.fetch = async (input, init) => {
  const url = typeof input === "string" ? input : input.url;
  if (url === PUSHOVER_URL) {
    const rawBody = init?.body
      ?? (typeof input === "string" ? "" : await input.clone().text());
    const body = new URLSearchParams(rawBody);
    pushoverAlerts.push({
      token: body.get("token"),
      user: body.get("user"),
      title: body.get("title"),
      message: body.get("message"),
    });
    return Response.json({ status: 1, request: "test-request" });
  }
  if (url.startsWith(R2_SIM_PREFIX)) {
    // Presigned UploadPart PUT: apply it to the R2 binding's real multipart
    // upload so ETags, part bookkeeping, and complete/abort semantics are
    // miniflare's own.
    const parsed = new URL(url);
    const key = decodeURIComponent(
      parsed.pathname.replace("/test-bucket/", ""),
    );
    const partNumber = Number(parsed.searchParams.get("partNumber"));
    const uploadId = parsed.searchParams.get("uploadId");
    const body = init?.body ?? (typeof input === "string" ? null : input.body);
    try {
      const upload = env.TRANSCRIPTION_AUDIO.resumeMultipartUpload(
        key,
        uploadId,
      );
      const part = await upload.uploadPart(partNumber, body);
      return new Response(null, {
        status: 200,
        headers: { etag: part.etag },
      });
    } catch (error) {
      return new Response(String(error), { status: 400 });
    }
  }
  if (url === FAILING_ORIGIN_URL) {
    return new Response("blocked", { status: 500 });
  }
  if (url.startsWith(`${ORIGIN_HOST}/redirect/`)) {
    return new Response(null, {
      status: 302,
      headers: { location: ORIGIN_URL },
    });
  }
  if (url === LARGE_ORIGIN_URL) {
    largeOriginBytes ??= makeBytes(LARGE_ORIGIN_TOTAL, 11);
    let offset = 0;
    const sizes = [...LARGE_CHUNK_SIZES];
    const stream = new ReadableStream({
      pull(controller) {
        if (sizes.length === 0) {
          controller.close();
          return;
        }
        const size = sizes.shift();
        controller.enqueue(largeOriginBytes.subarray(offset, offset + size));
        offset += size;
      },
    });
    return new Response(stream, {
      status: 200,
      headers: {
        "content-type": "audio/mpeg",
        "content-length": String(LARGE_ORIGIN_TOTAL),
      },
    });
  }
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

async function bootstrapBalance() {
  const response = await post("/v1/remote-transcription/account/bootstrap", {
    schema_version: 1,
  });
  expect(response.status).toBe(200);
  return response.json();
}

async function createJob({
  clientRequestId,
  episodeId,
  durationSeconds,
  languageCode,
  enclosureUrl = ORIGIN_URL,
}) {
  const response = await post("/v1/remote-transcription/jobs", {
    schema_version: 1,
    client_request_id: clientRequestId,
    episode_id: episodeId,
    enclosure_url: enclosureUrl,
    declared_duration_seconds: durationSeconds,
    language_code: languageCode,
  });
  expect(response.status).toBe(200);
  const body = await response.json();
  expect(body.job.job_id).toBeTruthy();
  return body.job;
}

async function reportSource(jobId, identity) {
  const response = await post(`/v1/remote-transcription/jobs/${jobId}/source`, {
    schema_version: 1,
    source_identity: identity,
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

async function waitForState(jobId, states, timeoutMs = 20_000) {
  const deadline = Date.now() + timeoutMs;
  let last;
  while (Date.now() < deadline) {
    last = await pollJob(jobId);
    if (states.includes(last.job.state)) {
      return last;
    }
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
  throw new Error(
    `job ${jobId} never reached ${states}; last=${JSON.stringify(last)}`,
  );
}

async function waitForJob(jobId, predicate, description, timeoutMs = 20_000) {
  const deadline = Date.now() + timeoutMs;
  let last;
  while (Date.now() < deadline) {
    last = await pollJob(jobId);
    if (predicate(last.job)) {
      return last;
    }
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
  throw new Error(
    `job ${jobId} never reached ${description}; last=${JSON.stringify(last)}`,
  );
}

async function bucketKeys(prefix) {
  const listing = await env.TRANSCRIPTION_AUDIO.list({ prefix });
  return listing.objects.map((object) => object.key);
}

async function expectJobStorageEmpty(jobId) {
  for (const prefix of [
    `raw/${jobId}/`,
    `uploads/${jobId}/`,
    `chunks/${jobId}/`,
    `responses/${jobId}/`,
    `results/${jobId}/`,
  ]) {
    expect(await bucketKeys(prefix), prefix).toEqual([]);
  }
}

async function deviceIdentity(durationSeconds) {
  originSha256 ??= await sha256Hex(originBytes);
  return {
    sha256: originSha256,
    byte_count: originBytes.length,
    duration_seconds: durationSeconds,
  };
}

describe("remote transcription dev lane", () => {
  it("serves health", async () => {
    const response = await SELF.fetch(`${BASE}/health`);
    expect(response.status).toBe(200);
  });

  it("rejects unauthenticated requests", async () => {
    const response = await SELF.fetch(
      `${BASE}/v1/remote-transcription/account/bootstrap`,
      {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ schema_version: 1 }),
      },
    );
    expect(response.status).toBe(401);
  });

  it("bootstraps the dev account with the fixed grant exactly once", async () => {
    const first = await bootstrapBalance();
    expect(first.schema_version).toBe(1);
    expect(first.account_id).toMatch(/^acct-/);
    expect(first.balance.available_seconds).toBe(GRANT);
    expect(first.balance.reserved_seconds).toBe(0);

    const second = await bootstrapBalance();
    expect(second.account_id).toBe(first.account_id);
    expect(second.balance.available_seconds).toBe(GRANT);
  });

  it("runs create -> hash match -> reserve -> chunk -> fake AI -> stitch -> result -> ack with verified deletes", async () => {
    const job = await createJob({
      clientRequestId: "e2e-normal-1",
      episodeId: "ep-e2e-1",
      durationSeconds: 600,
    });
    await reportSource(job.job_id, await deviceIdentity(600));

    const ready = await waitForState(job.job_id, ["result_ready"]);
    expect(ready.job.progress.chunks_total).toBe(3);
    expect(ready.job.progress.chunks_completed).toBe(3);

    // Charge point: exactly ceil(duration) settled, nothing more.
    const balance = (await bootstrapBalance()).balance;
    expect(balance.available_seconds).toBe(GRANT - 600);
    expect(balance.reserved_seconds).toBe(0);

    const resultResponse = await post(
      `/v1/remote-transcription/jobs/${job.job_id}/result`,
      { schema_version: 1 },
    );
    expect(resultResponse.status).toBe(200);
    expect(resultResponse.headers.get("cache-control")).toBe("no-store");
    const payload = await resultResponse.json();
    expect(payload.schema_version).toBe(1);
    expect(payload.result.source_identity.sha256).toBe(originSha256);
    expect(payload.result.duration_seconds).toBe(600);
    expect(payload.result.segments.length).toBeGreaterThan(0);
    expect(payload.result.segments[0].words.length).toBeGreaterThan(0);
    expect(payload.result.provenance.provider).toBe("cloudflare-workers-ai");
    expect(payload.result.provenance.pipeline_version).toBe("stitch-v2");
    expect(payload.result.provenance.normalized_transcript_sha256).toMatch(
      /^[0-9a-f]{64}$/,
    );

    // Duplicate (account, clientRequestID) attaches to the same job.
    const duplicate = await createJob({
      clientRequestId: "e2e-normal-1",
      episodeId: "ep-e2e-1",
      durationSeconds: 600,
    });
    expect(duplicate.job_id).toBe(job.job_id);

    const ackResponse = await post(
      `/v1/remote-transcription/jobs/${job.job_id}/ack`,
      {
        schema_version: 1,
        normalized_transcript_sha256:
          payload.result.provenance.normalized_transcript_sha256,
      },
    );
    expect(ackResponse.status).toBe(200);
    expect((await ackResponse.json()).job.state).toBe("acknowledged");

    await expectJobStorageEmpty(job.job_id);
  });

  it("routes a hash mismatch to exact-device upload and transcribes the uploaded bytes", async () => {
    // The device's copy (a DAI variant): what actually gets uploaded.
    const deviceBytes = makeBytes(12 * 1024 * 1024 + 512 * 1024, 23);
    const deviceSha = await sha256Hex(deviceBytes);
    const job = await createJob({
      clientRequestId: "e2e-mismatch-1",
      episodeId: "ep-mismatch-1",
      durationSeconds: 600,
    });
    await reportSource(job.job_id, {
      sha256: deviceSha,
      byte_count: deviceBytes.length,
      duration_seconds: 600,
    });

    // Mismatch: the server copy is deleted BEFORE upload capability exists.
    await waitForState(job.job_id, ["exact_upload_required"]);
    expect(await bucketKeys(`raw/${job.job_id}/`)).toEqual([]);
    // Nothing spent or reserved while waiting for the upload.
    let balance = (await bootstrapBalance()).balance;
    expect(balance.available_seconds).toBe(GRANT - 600);
    expect(balance.reserved_seconds).toBe(0);

    const startResponse = await post(
      `/v1/remote-transcription/jobs/${job.job_id}/upload/start`,
      { schema_version: 1 },
    );
    expect(startResponse.status).toBe(200);
    const grant = await startResponse.json();
    expect(grant.part_size_bytes).toBe(5 * 1024 * 1024);
    expect(grant.part_count).toBe(3);
    expect(grant.parts.length).toBe(3);
    for (const part of grant.parts) {
      expect(part.url).toContain("X-Amz-Signature=");
      expect(part.url).toContain(`partNumber=${part.part_number}`);
      expect(part.expires_at).toBeGreaterThan(Date.now() / 1000);
    }

    // Idempotent re-start: same upload, fresh URLs.
    const restartResponse = await post(
      `/v1/remote-transcription/jobs/${job.job_id}/upload/start`,
      { schema_version: 1 },
    );
    expect(restartResponse.status).toBe(200);
    expect((await restartResponse.json()).upload_key_id).toBe(
      grant.upload_key_id,
    );

    // Refresh the last part's URL through upload/parts (the 403-refresh
    // path) and use the refreshed URL for its PUT.
    const refreshResponse = await post(
      `/v1/remote-transcription/jobs/${job.job_id}/upload/parts`,
      { schema_version: 1, part_numbers: [3], for_background: true },
    );
    expect(refreshResponse.status).toBe(200);
    const refreshed = await refreshResponse.json();
    expect(refreshed.parts.length).toBe(1);
    expect(refreshed.parts[0].part_number).toBe(3);
    // Background batches carry the longer bounded expiry.
    expect(refreshed.parts[0].expires_at - grant.parts[0].expires_at).toBeGreaterThan(
      3600,
    );

    const urls = new Map(grant.parts.map((part) => [part.part_number, part.url]));
    urls.set(3, refreshed.parts[0].url);
    const etags = [];
    for (const partNumber of [1, 2, 3]) {
      const start = (partNumber - 1) * grant.part_size_bytes;
      const end = Math.min(start + grant.part_size_bytes, deviceBytes.length);
      const put = await fetch(urls.get(partNumber), {
        method: "PUT",
        body: deviceBytes.subarray(start, end),
      });
      expect(put.status).toBe(200);
      etags.push({ part_number: partNumber, etag: put.headers.get("etag") });
    }

    const completeResponse = await post(
      `/v1/remote-transcription/jobs/${job.job_id}/upload/complete`,
      { schema_version: 1, parts: etags },
    );
    expect(completeResponse.status).toBe(200);

    // A repeated complete is idempotent, never a second run.
    const repeatResponse = await post(
      `/v1/remote-transcription/jobs/${job.job_id}/upload/complete`,
      { schema_version: 1, parts: etags },
    );
    expect(repeatResponse.status).toBe(200);

    const ready = await waitForState(job.job_id, ["result_ready"]);
    expect(ready.job.progress.chunks_completed).toBe(3);

    const resultResponse = await post(
      `/v1/remote-transcription/jobs/${job.job_id}/result`,
      { schema_version: 1 },
    );
    const payload = await resultResponse.json();
    // The transcript is provably of the device's exact bytes.
    expect(payload.result.source_identity.sha256).toBe(deviceSha);
    expect(payload.result.source_identity.byte_count).toBe(deviceBytes.length);
    expect(payload.result.provenance.source_match_mode).toBe(
      "exact_device_upload",
    );

    // Settle is exactly ceil(duration) — upload changes no accounting.
    balance = (await bootstrapBalance()).balance;
    expect(balance.available_seconds).toBe(GRANT - 600 - 600);
    expect(balance.reserved_seconds).toBe(0);

    await post(`/v1/remote-transcription/jobs/${job.job_id}/ack`, {
      schema_version: 1,
    });
    await expectJobStorageEmpty(job.job_id);
  });

  it("requests exact upload when origin staging fails, spending nothing", async () => {
    const job = await createJob({
      clientRequestId: "e2e-originfail-1",
      episodeId: "ep-originfail-1",
      durationSeconds: 600,
      enclosureUrl: FAILING_ORIGIN_URL,
    });
    const required = await waitForState(job.job_id, ["exact_upload_required"]);
    expect(required.job.error).toBeFalsy();
    expect(await bucketKeys(`raw/${job.job_id}/`)).toEqual([]);
    const balance = (await bootstrapBalance()).balance;
    expect(balance.available_seconds).toBe(GRANT - 1200);
    expect(balance.reserved_seconds).toBe(0);

    // Cancel while waiting for the upload: clean, chargeless exit.
    const cancelResponse = await post(
      `/v1/remote-transcription/jobs/${job.job_id}/cancel`,
      { schema_version: 1 },
    );
    expect((await cancelResponse.json()).job.state).toBe("cancelled");
    await expectJobStorageEmpty(job.job_id);
  });

  it("routes policy-unsafe origins straight to exact upload at create", async () => {
    const response = await post("/v1/remote-transcription/jobs", {
      schema_version: 1,
      client_request_id: "e2e-unsafe-origin-1",
      episode_id: "ep-unsafe-1",
      enclosure_url: "http://origin.example.com/audio.mp3",
      declared_duration_seconds: 300,
    });
    expect(response.status).toBe(200);
    const created = (await response.json()).job;
    expect(created.state).toBe("exact_upload_required");

    const cancelResponse = await post(
      `/v1/remote-transcription/jobs/${created.job_id}/cancel`,
      { schema_version: 1 },
    );
    expect((await cancelResponse.json()).job.state).toBe("cancelled");
    await expectJobStorageEmpty(created.job_id);
  });

  it("rejects a wrong-hash upload with zero spend", async () => {
    const claimedBytes = makeBytes(6 * 1024 * 1024, 31);
    const actualBytes = makeBytes(6 * 1024 * 1024, 37);
    const job = await createJob({
      clientRequestId: "e2e-wronghash-1",
      episodeId: "ep-wronghash-1",
      durationSeconds: 600,
    });
    // The device claims one identity but uploads different bytes of the
    // same length, so the container hash check is the gate that fires.
    await reportSource(job.job_id, {
      sha256: await sha256Hex(claimedBytes),
      byte_count: claimedBytes.length,
      duration_seconds: 600,
    });
    await waitForState(job.job_id, ["exact_upload_required"]);

    const grant = await (
      await post(`/v1/remote-transcription/jobs/${job.job_id}/upload/start`, {
        schema_version: 1,
      })
    ).json();
    expect(grant.part_count).toBe(2);
    const etags = [];
    for (const part of grant.parts) {
      const start = (part.part_number - 1) * grant.part_size_bytes;
      const end = Math.min(start + grant.part_size_bytes, actualBytes.length);
      const put = await fetch(part.url, {
        method: "PUT",
        body: actualBytes.subarray(start, end),
      });
      expect(put.status).toBe(200);
      etags.push({ part_number: part.part_number, etag: put.headers.get("etag") });
    }
    const completeResponse = await post(
      `/v1/remote-transcription/jobs/${job.job_id}/upload/complete`,
      { schema_version: 1, parts: etags },
    );
    expect(completeResponse.status).toBe(200);

    const failed = await waitForState(job.job_id, ["failed"]);
    expect(failed.job.error.code).toBe("upload_identity_mismatch");
    await expectJobStorageEmpty(job.job_id);
    // Zero spend: verification failed before any reservation.
    const balance = (await bootstrapBalance()).balance;
    expect(balance.available_seconds).toBe(GRANT - 1200);
    expect(balance.reserved_seconds).toBe(0);
  });

  it("aborts the multipart upload on cancel mid-upload", async () => {
    const deviceBytes = makeBytes(6 * 1024 * 1024, 41);
    const job = await createJob({
      clientRequestId: "e2e-cancel-upload-1",
      episodeId: "ep-cancel-upload-1",
      durationSeconds: 600,
      enclosureUrl: FAILING_ORIGIN_URL,
    });
    await reportSource(job.job_id, {
      sha256: await sha256Hex(deviceBytes),
      byte_count: deviceBytes.length,
      duration_seconds: 600,
    });
    await waitForState(job.job_id, ["exact_upload_required"]);
    const grant = await (
      await post(`/v1/remote-transcription/jobs/${job.job_id}/upload/start`, {
        schema_version: 1,
      })
    ).json();
    const firstPut = await fetch(grant.parts[0].url, {
      method: "PUT",
      body: deviceBytes.subarray(0, grant.part_size_bytes),
    });
    expect(firstPut.status).toBe(200);

    const cancelResponse = await post(
      `/v1/remote-transcription/jobs/${job.job_id}/cancel`,
      { schema_version: 1 },
    );
    expect((await cancelResponse.json()).job.state).toBe("cancelled");
    await expectJobStorageEmpty(job.job_id);

    // The multipart upload is aborted server-side: a re-PUT of a live part
    // URL now fails instead of resurrecting storage.
    const latePut = await fetch(grant.parts[1].url, {
      method: "PUT",
      body: deviceBytes.subarray(grant.part_size_bytes),
    });
    expect(latePut.status).not.toBe(200);
    expect(await bucketKeys(`uploads/${job.job_id}/`)).toEqual([]);
  });

  it("expires an unclaimed exact-upload job at its deadline", async () => {
    const job = await createJob({
      clientRequestId: "e2e-upload-deadline-1",
      episodeId: "ep-upload-deadline-1",
      durationSeconds: 600,
      enclosureUrl: FAILING_ORIGIN_URL,
    });
    await waitForState(job.job_id, ["exact_upload_required"]);
    // EXACT_UPLOAD_REQUIRED_DEADLINE_SECONDS=4 in this suite.
    const expired = await waitForState(job.job_id, ["cancelled"], 15_000);
    expect(expired.job.error.code).toBe("deadline_expired");
    await expectJobStorageEmpty(job.job_id);
  });

  it("409s upload routes on a job that never required upload", async () => {
    const job = await createJob({
      clientRequestId: "e2e-upload-409-1",
      episodeId: "ep-upload-409-1",
      durationSeconds: 600,
    });
    const startResponse = await post(
      `/v1/remote-transcription/jobs/${job.job_id}/upload/start`,
      { schema_version: 1 },
    );
    expect(startResponse.status).toBe(409);
    const partsResponse = await post(
      `/v1/remote-transcription/jobs/${job.job_id}/upload/parts`,
      { schema_version: 1, part_numbers: [1] },
    );
    expect(partsResponse.status).toBe(409);
    const completeResponse = await post(
      `/v1/remote-transcription/jobs/${job.job_id}/upload/complete`,
      { schema_version: 1, parts: [{ part_number: 1, etag: "x" }] },
    );
    expect(completeResponse.status).toBe(409);
    await post(`/v1/remote-transcription/jobs/${job.job_id}/cancel`, {
      schema_version: 1,
    });
  });

  it("cancels during staging/waiting and cleans up", async () => {
    const job = await createJob({
      clientRequestId: "e2e-cancel-staging-1",
      episodeId: "ep-cancel-1",
      durationSeconds: 300,
    });
    await waitForState(job.job_id, ["waiting_for_device_source"]);

    const cancelResponse = await post(
      `/v1/remote-transcription/jobs/${job.job_id}/cancel`,
      { schema_version: 1 },
    );
    expect(cancelResponse.status).toBe(200);
    expect((await cancelResponse.json()).job.state).toBe("cancelled");
    await expectJobStorageEmpty(job.job_id);
    expect((await bootstrapBalance()).balance.available_seconds).toBe(GRANT - 1200);
  });

  it("cancels during transcription and releases the reservation", async () => {
    const job = await createJob({
      clientRequestId: "e2e-cancel-transcribing-1",
      episodeId: "ep-cancel-2",
      durationSeconds: 350,
      // Retryable first-attempt failure parks the job in transcribing for the
      // backoff window so cancellation is deterministic.
      languageCode: "fake-fail:429 rate limited",
    });
    await reportSource(job.job_id, await deviceIdentity(350));
    await waitForState(job.job_id, ["transcribing"]);

    const midBalance = (await bootstrapBalance()).balance;
    expect(midBalance.reserved_seconds).toBe(350);

    const cancelResponse = await post(
      `/v1/remote-transcription/jobs/${job.job_id}/cancel`,
      { schema_version: 1 },
    );
    expect((await cancelResponse.json()).job.state).toBe("cancelled");
    await expectJobStorageEmpty(job.job_id);

    const balance = (await bootstrapBalance()).balance;
    expect(balance.available_seconds).toBe(GRANT - 1200);
    expect(balance.reserved_seconds).toBe(0);
  });

  it("parks at awaiting_credits on insufficient balance, then expires", async () => {
    // Larger than anything the grant leaves at this point in the suite.
    const job = await createJob({
      clientRequestId: "e2e-credits-1",
      episodeId: "ep-credits-1",
      durationSeconds: 7000,
    });
    await reportSource(job.job_id, await deviceIdentity(7000));
    await waitForState(job.job_id, ["awaiting_credits"]);

    // Deadline (2s in this suite) drives the normal cancellation path.
    const expired = await waitForState(job.job_id, ["cancelled"]);
    expect(expired.job.error.code).toBe("deadline_expired");
    await expectJobStorageEmpty(job.job_id);
    expect((await bootstrapBalance()).balance.available_seconds).toBe(GRANT - 1200);
  });

  it("retries a retryable AI failure and completes", async () => {
    const job = await createJob({
      clientRequestId: "e2e-retry-1",
      episodeId: "ep-retry-1",
      durationSeconds: 300,
      languageCode: "fake-fail:429 rate limited",
    });
    await reportSource(job.job_id, await deviceIdentity(300));
    const ready = await waitForState(job.job_id, ["result_ready"]);
    // 300 s spans two 298 s steps.
    expect(ready.job.progress.chunks_completed).toBe(2);

    // Mid-wave retryable failure retried only the failing chunk: chunk 0
    // burned one attempt, its sibling none, and both finished their AI span.
    const spans = [...ready.job.phase_timestamps.chunks].sort(
      (a, b) => a.index - b.index,
    );
    expect(spans.map((span) => span.failed_attempts)).toEqual([1, 0]);
    for (const span of spans) {
      expect(span.ai_started_at).toBeTruthy();
      expect(span.ai_ended_at).toBeTruthy();
    }

    const balance = (await bootstrapBalance()).balance;
    expect(balance.available_seconds).toBe(GRANT - 1500);

    const ackResponse = await post(
      `/v1/remote-transcription/jobs/${job.job_id}/ack`,
      { schema_version: 1 },
    );
    expect((await ackResponse.json()).job.state).toBe("acknowledged");
    await expectJobStorageEmpty(job.job_id);
  });

  it("fails closed on a fatal AI error and releases the reservation", async () => {
    const job = await createJob({
      clientRequestId: "e2e-fatal-1",
      episodeId: "ep-fatal-1",
      durationSeconds: 90,
      languageCode:
        "fake-fail:AiError: 5006: Error: required properties at '/' are 'audio'",
    });
    await reportSource(job.job_id, await deviceIdentity(90));
    const failed = await waitForState(job.job_id, ["failed"]);
    expect(failed.job.error.code).toBe("transcription_failed");
    await expectJobStorageEmpty(job.job_id);
    expect((await bootstrapBalance()).balance.available_seconds).toBe(GRANT - 1500);
  });

  it("expires waiting_for_device_source at its deadline", async () => {
    const job = await createJob({
      clientRequestId: "e2e-deadline-1",
      episodeId: "ep-deadline-1",
      durationSeconds: 90,
    });
    const expired = await waitForState(job.job_id, ["cancelled"]);
    expect(expired.job.error.code).toBe("deadline_expired");
    await expectJobStorageEmpty(job.job_id);
  });

  it("follows and revalidates redirects while staging", async () => {
    const job = await createJob({
      clientRequestId: "e2e-redirect-1",
      episodeId: "ep-redirect-1",
      durationSeconds: 90,
      enclosureUrl: ORIGIN_REDIRECT_URL,
    });
    await reportSource(job.job_id, await deviceIdentity(90));
    await waitForState(job.job_id, ["result_ready"]);

    const balance = (await bootstrapBalance()).balance;
    expect(balance.available_seconds).toBe(GRANT - 1590);

    await post(`/v1/remote-transcription/jobs/${job.job_id}/ack`, {
      schema_version: 1,
    });
    await expectJobStorageEmpty(job.job_id);
  });

  it("stages sources spanning 3+ R2 parts from a misaligned stream", async () => {
    const job = await createJob({
      clientRequestId: "e2e-large-origin-1",
      episodeId: "ep-large-1",
      durationSeconds: 90,
      enclosureUrl: LARGE_ORIGIN_URL,
    });
    const staged = await waitForState(job.job_id, [
      "waiting_for_device_source",
      "failed",
    ]);
    expect(staged.job.state).toBe("waiting_for_device_source");

    const rawKeys = await bucketKeys(`raw/${job.job_id}/`);
    expect(rawKeys.length).toBe(1);
    const head = await env.TRANSCRIPTION_AUDIO.head(rawKeys[0]);
    expect(head.size).toBe(LARGE_ORIGIN_TOTAL);

    const cancelResponse = await post(
      `/v1/remote-transcription/jobs/${job.job_id}/cancel`,
      { schema_version: 1 },
    );
    expect((await cancelResponse.json()).job.state).toBe("cancelled");
    await expectJobStorageEmpty(job.job_id);
  });

  // --- Pass 0.5: bounded chunk fan-out (A4). 900 s spans four 298 s steps;
  // the fake:latency hook makes each chunk's AI call take a fixed wall time
  // so overlap (or its absence) is visible in phase_timestamps. ---

  it("overlaps chunk AI calls at the fan-out default and settles unchanged", async () => {
    const job = await createJob({
      clientRequestId: "e2e-fanout-4",
      episodeId: "ep-fanout-4",
      durationSeconds: 900,
      languageCode: "fake:latency=2000",
    });
    await reportSource(job.job_id, await deviceIdentity(900));
    const ready = await waitForState(job.job_id, ["result_ready"]);
    expect(ready.job.progress.chunks_total).toBe(4);
    expect(ready.job.progress.chunks_completed).toBe(4);

    const timestamps = ready.job.phase_timestamps;
    expect(timestamps).toBeTruthy();
    const spans = [...timestamps.chunks].sort((a, b) => a.index - b.index);
    expect(spans.length).toBe(4);
    for (const span of spans) {
      expect(span.ai_started_at).toBeTruthy();
      expect(span.ai_ended_at).toBeTruthy();
      expect(span.failed_attempts).toBe(0);
    }
    // All four chunks were in flight simultaneously: the last to start began
    // before the first finished (each fake AI call takes 2 s).
    const lastStart = Math.max(...spans.map((span) => span.ai_started_at));
    const firstEnd = Math.min(...spans.map((span) => span.ai_ended_at));
    expect(lastStart).toBeLessThan(firstEnd);
    // Transcribe wall clock is one wave (~2 s), not the ~8 s chunk sum.
    const transcribeWall =
      timestamps.states.stitching - timestamps.states.transcribing;
    expect(transcribeWall).toBeLessThan(6);

    // Concurrency changes nothing about the charge: exactly ceil(duration).
    const balance = (await bootstrapBalance()).balance;
    expect(balance.available_seconds).toBe(GRANT - 1590 - 900);
    expect(balance.reserved_seconds).toBe(0);

    await post(`/v1/remote-transcription/jobs/${job.job_id}/ack`, {
      schema_version: 1,
    });
    await expectJobStorageEmpty(job.job_id);
  });

  it("reproduces the pass-0 sequential walk at CHUNK_AI_CONCURRENCY=1", async () => {
    const job = await createJob({
      clientRequestId: "e2e-fanout-1",
      episodeId: "ep-fanout-1",
      durationSeconds: 900,
      languageCode: "fake:conc=1;latency=2000",
    });
    await reportSource(job.job_id, await deviceIdentity(900));
    const ready = await waitForState(job.job_id, ["result_ready"], 25_000);
    expect(ready.job.progress.chunks_total).toBe(4);
    expect(ready.job.progress.chunks_completed).toBe(4);

    const timestamps = ready.job.phase_timestamps;
    const spans = [...timestamps.chunks].sort((a, b) => a.index - b.index);
    // Strictly sequential single-chunk waves — the pass-0 walk: each chunk
    // starts no earlier than its predecessor finished.
    for (let index = 1; index < spans.length; index += 1) {
      expect(spans[index].ai_started_at).toBeGreaterThanOrEqual(
        spans[index - 1].ai_ended_at,
      );
    }
    const transcribeWall =
      timestamps.states.stitching - timestamps.states.transcribing;
    expect(transcribeWall).toBeGreaterThanOrEqual(8);

    // Identical settle math to the overlapped run of the same episode.
    const balance = (await bootstrapBalance()).balance;
    expect(balance.available_seconds).toBe(GRANT - 1590 - 1800);
    expect(balance.reserved_seconds).toBe(0);

    await post(`/v1/remote-transcription/jobs/${job.job_id}/ack`, {
      schema_version: 1,
    });
    await expectJobStorageEmpty(job.job_id);
  });

  it("fails the job on a mid-wave fatal AI error after awaiting siblings", async () => {
    const job = await createJob({
      clientRequestId: "e2e-fanout-fatal",
      episodeId: "ep-fanout-fatal",
      durationSeconds: 900,
      languageCode:
        "fake:latency=1500;fail=1:always:AiError: 5006: Error: required properties at '/' are 'audio'",
    });
    await reportSource(job.job_id, await deviceIdentity(900));
    const failed = await waitForState(job.job_id, ["failed"]);
    expect(failed.job.error.code).toBe("transcription_failed");

    // Chunk 1 hit the fatal error mid-wave; its in-flight siblings were
    // awaited (their AI spans completed) and then discarded with the job.
    const spans = [...failed.job.phase_timestamps.chunks].sort(
      (a, b) => a.index - b.index,
    );
    expect(spans[1].failed_attempts).toBe(1);
    const finishedSiblings = spans.filter(
      (span) => span.index !== 1 && span.ai_ended_at,
    );
    expect(finishedSiblings.length).toBe(3);

    // Reservation released, limiter freed, storage cleaned: the customer is
    // never charged for a failed wave.
    await expectJobStorageEmpty(job.job_id);
    const balance = (await bootstrapBalance()).balance;
    expect(balance.available_seconds).toBe(GRANT - 1590 - 1800);
    expect(balance.reserved_seconds).toBe(0);
  });

  // --- Pass 0.5 lever 2: chunking/transcription overlap. The mlat hook
  // paces fake-media chunk writes; the latency hook paces fake AI calls. ---

  it("transcribes chunks while chunking is still writing the rest", async () => {
    const job = await createJob({
      clientRequestId: "e2e-overlap-4",
      episodeId: "ep-overlap-4",
      durationSeconds: 900,
      languageCode: "fake:mlat=1000;latency=500",
    });
    await reportSource(job.job_id, await deviceIdentity(900));
    const chunking = await waitForState(job.job_id, ["chunking"]);
    expect(chunking.job.progress).toMatchObject({
      chunks_completed: 0,
      chunks_total: 4,
      estimate_status: "on_track",
    });
    expect(chunking.job.progress.estimated_remaining_seconds).toBeGreaterThan(0);

    const advancedDuringChunking = await waitForJob(
      job.job_id,
      ({ state, progress }) =>
        state === "chunking" && progress?.chunks_completed > 0,
      "durable chunk completion while chunking",
    );
    expect(advancedDuringChunking.job.progress.chunks_total).toBe(4);
    const ready = await waitForState(job.job_id, ["result_ready"], 25_000);
    expect(ready.job.progress.chunks_completed).toBe(4);

    const timestamps = ready.job.phase_timestamps;
    const spans = [...timestamps.chunks].sort((a, b) => a.index - b.index);
    // AI began before the chunking phase ended: the first AI span starts
    // before the state machine ever left `chunking` for `transcribing`.
    const firstAiStart = Math.min(...spans.map((span) => span.ai_started_at));
    expect(firstAiStart).toBeLessThan(timestamps.states.transcribing);
    for (const span of spans) {
      expect(span.ai_ended_at).toBeTruthy();
      expect(span.failed_attempts).toBe(0);
    }

    // Overlap changes nothing about the charge or cleanup.
    const balance = (await bootstrapBalance()).balance;
    expect(balance.available_seconds).toBe(GRANT - 1590 - 1800 - 900);
    expect(balance.reserved_seconds).toBe(0);
    await post(`/v1/remote-transcription/jobs/${job.job_id}/ack`, {
      schema_version: 1,
    });
    await expectJobStorageEmpty(job.job_id);
  });

  it("keeps the pass-0 chunk-then-transcribe walk at CHUNK_AI_CONCURRENCY=1", async () => {
    const job = await createJob({
      clientRequestId: "e2e-overlap-1",
      episodeId: "ep-overlap-1",
      durationSeconds: 900,
      languageCode: "fake:conc=1;mlat=500;latency=800",
    });
    await reportSource(job.job_id, await deviceIdentity(900));
    const ready = await waitForState(job.job_id, ["result_ready"], 25_000);
    expect(ready.job.progress.chunks_completed).toBe(4);

    const timestamps = ready.job.phase_timestamps;
    const spans = [...timestamps.chunks].sort((a, b) => a.index - b.index);
    // No overlap at concurrency 1: every AI span starts at or after the
    // transcribing transition (the rollback story).
    const firstAiStart = Math.min(...spans.map((span) => span.ai_started_at));
    expect(firstAiStart).toBeGreaterThanOrEqual(timestamps.states.transcribing);

    const balance = (await bootstrapBalance()).balance;
    expect(balance.available_seconds).toBe(GRANT - 1590 - 1800 - 1800);
    expect(balance.reserved_seconds).toBe(0);
    await post(`/v1/remote-transcription/jobs/${job.job_id}/ack`, {
      schema_version: 1,
    });
    await expectJobStorageEmpty(job.job_id);
  });

  it(
    "queues a second job with a combined ETA, then returns it to on_track",
    async () => {
      const first = await createJob({
        clientRequestId: "e2e-fifo-first",
        episodeId: "ep-fifo-first",
        durationSeconds: 300,
        languageCode: "fake:conc=1;latency=20000",
      });
      await reportSource(first.job_id, await deviceIdentity(300));
      await waitForState(first.job_id, ["transcribing"]);

      const second = await createJob({
        clientRequestId: "e2e-fifo-second",
        episodeId: "ep-fifo-second",
        durationSeconds: 300,
        languageCode: "fake:latency=3000",
      });
      await reportSource(second.job_id, await deviceIdentity(300));

      const queued = await waitForJob(
        second.job_id,
        ({ progress }) => progress?.estimate_status === "queued",
        "queued estimate",
      );
      expect(queued.job.progress.estimated_remaining_seconds).toBeGreaterThan(0);
      expect(queued.job.progress.chunks_total).toBe(2);

      // The first job still owns the slot beyond the 30-second staleness
      // threshold. Repeated limiter snapshots keep queued authoritative,
      // so this must never degrade into delayed.
      await new Promise((resolve) => setTimeout(resolve, 31_000));
      const stillQueued = await pollJob(second.job_id);
      expect(stillQueued.job.progress.estimate_status).toBe("queued");
      expect(stillQueued.job.progress.estimated_remaining_seconds).toBeGreaterThan(0);

      await waitForState(first.job_id, ["result_ready"], 20_000);
      const admitted = await waitForJob(
        second.job_id,
        ({ state, progress }) =>
          state === "transcribing" && progress?.estimate_status === "on_track",
        "on_track after FIFO admission",
        20_000,
      );
      expect(admitted.job.progress.estimated_remaining_seconds).toBeGreaterThan(0);
      await waitForState(second.job_id, ["result_ready"], 20_000);

      for (const completed of [first, second]) {
        const ack = await post(
          `/v1/remote-transcription/jobs/${completed.job_id}/ack`,
          { schema_version: 1 },
        );
        expect(ack.status).toBe(200);
        await expectJobStorageEmpty(completed.job_id);
      }
    },
    70_000,
  );

  it("rejects unparseable enclosure URLs at create time", async () => {
    // Policy-unsafe URLs (http, userinfo, …) now route to exact upload; only
    // a URL that cannot name an enclosure at all still rejects.
    const response = await post("/v1/remote-transcription/jobs", {
      schema_version: 1,
      client_request_id: "e2e-badorigin-1",
      episode_id: "ep-badorigin-1",
      enclosure_url: "not a url",
    });
    expect(response.status).toBe(400);
    expect((await response.json()).error).toBe("invalid_request");
  });

  it("404s unknown jobs", async () => {
    const response = await post(
      "/v1/remote-transcription/jobs/job-does-not-exist/poll",
      { schema_version: 1 },
    );
    expect(response.status).toBe(404);
  });

  it("scheduled sweeper records and alerts a forced stale-job drill", async () => {
    const jobId = `job-orphan-drill-${Date.now()}`;
    const staleAt = Math.floor(Date.now() / 1000) - 86_400;
    await env.TRANSCRIPTION_DB.prepare(
      `INSERT INTO jobs
       (job_id, account_id, client_request_id, episode_id, state, created_at, updated_at)
       VALUES (?1, 'acct-orphan-drill', ?2, 'ep-content-must-not-leak',
               'staging_origin', ?3, ?3)`,
    )
      .bind(jobId, `req-${jobId}`, staleAt)
      .run();

    const ctx = createExecutionContext();
    const worker = new RemoteTranscriptionWorker(ctx, env);
    await worker.scheduled(createScheduledController());
    await waitOnExecutionContext(ctx);

    const counters = await env.TRANSCRIPTION_DB.prepare(
      `SELECT name, value FROM counters
       WHERE name IN ('orphan_sweeper_runs', 'stale_jobs_found', 'orphan_alerts_sent')`,
    ).all();
    const byName = Object.fromEntries(
      counters.results.map(({ name, value }) => [name, Number(value)]),
    );
    expect(byName.orphan_sweeper_runs).toBeGreaterThanOrEqual(1);
    expect(byName.stale_jobs_found).toBeGreaterThanOrEqual(1);
    expect(byName.orphan_alerts_sent).toBeGreaterThanOrEqual(1);

    const alert = pushoverAlerts.find(({ message }) => message?.includes(jobId));
    expect(alert).toMatchObject({
      token: "test-pushover-token",
      user: "test-pushover-user",
      title: "OpenCast transcription alert (development)",
    });
    expect(alert.message).not.toContain("ep-content-must-not-leak");
  });
});
