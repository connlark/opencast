// Workerd-local integration tests: drive real HTTP requests through the
// compiled wasm Worker with local D1 + Durable Object bindings and a mocked
// Gemini upstream. These cover the wasm orchestration glue that host `cargo
// test` cannot reach. Requires `build/index.js` (see `yarn build:worker`).
import {
  SELF,
  abortAllDurableObjects,
  env,
  runDurableObjectAlarm,
} from "cloudflare:test";
import { afterAll, afterEach, beforeAll, describe, expect, it } from "vitest";
import fixture from "../tests/fixtures/ad_analysis_app_attest_development_fixture.json";

const ANALYZE_PATH = "/v1/ad-analysis/transcript";
const BASE = "https://ad-analysis.integration.test";
const BEARER = "integration-test-bearer-token";

const GEMINI_MODEL_OUTPUT = JSON.stringify({
  spans: [
    {
      kind: "host_read_ad",
      label: "Seed Sponsor ad read",
      start_segment_id: 2,
      end_segment_id: 2,
      confidence: 0.95,
      evidence_quote: "This episode is brought to you by Seed Sponsor",
    },
  ],
});

const GEMINI_RESPONSE = {
  candidates: [
    {
      content: { parts: [{ text: GEMINI_MODEL_OUTPUT }] },
      finishReason: "STOP",
    },
  ],
  usageMetadata: {
    promptTokenCount: 120,
    candidatesTokenCount: 40,
    totalTokenCount: 160,
  },
};

// A MAX_TOKENS-truncated body: the model JSON is cut mid-object, which is the
// measured production degeneration that used to 502 the whole analysis.
const GEMINI_TRUNCATED_RESPONSE = {
  candidates: [
    {
      content: { parts: [{ text: '{"spans":[{"kind":' }] },
      finishReason: "MAX_TOKENS",
    },
  ],
  usageMetadata: {
    promptTokenCount: 120,
    candidatesTokenCount: 4096,
    totalTokenCount: 4216,
  },
};

// The vitest miniflare bindings set AD_ANALYSIS_GEMINI_MODEL to the fallback
// model, so the Worker must build its Gemini URL for it and report it back.
const EXPECTED_MODEL = "gemini-3.1-flash-lite";

// The `main` worker runs in the same isolate as the tests, so stubbing the
// global `fetch` intercepts the Worker's outbound Gemini call. Binding
// traffic (SELF, D1, Durable Objects) does not go through the global.
const realFetch = globalThis.fetch;
const pendingGeminiResponses = [];

function mockGeminiOnce(body = GEMINI_RESPONSE) {
  pendingGeminiResponses.push(body);
}

function mockGeminiDeferred(body) {
  let markStarted;
  let release;
  const started = new Promise((resolve) => {
    markStarted = resolve;
  });
  const gate = new Promise((resolve) => {
    release = resolve;
  });
  pendingGeminiResponses.push(async () => {
    markStarted();
    await gate;
    return body;
  });
  return { started, release };
}

function installFetchStub() {
  globalThis.fetch = async (input) => {
    const url = typeof input === "string" ? input : input.url;
    if (
      url ===
      `https://generativelanguage.googleapis.com/v1beta/models/${EXPECTED_MODEL}:generateContent`
    ) {
      if (pendingGeminiResponses.length === 0) {
        throw new Error("unexpected Gemini call: no mocked response pending");
      }
      const pending = pendingGeminiResponses.shift();
      const body = typeof pending === "function" ? await pending() : pending;
      return new Response(JSON.stringify(body), {
        status: 200,
        headers: { "content-type": "application/json" },
      });
    }
    throw new Error(`unexpected outbound fetch in integration test: ${url}`);
  };
}

function hexToBytes(hex) {
  const bytes = new Uint8Array(hex.length / 2);
  for (let i = 0; i < bytes.length; i += 1) {
    bytes[i] = Number.parseInt(hex.slice(i * 2, i * 2 + 2), 16);
  }
  return bytes;
}

function bytesToBase64(bytes) {
  return btoa(String.fromCharCode(...bytes));
}

function bytesToHex(bytes) {
  return Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join(
    "",
  );
}

function concatBytes(...parts) {
  const result = new Uint8Array(
    parts.reduce((total, part) => total + part.length, 0),
  );
  let offset = 0;
  for (const part of parts) {
    result.set(part, offset);
    offset += part.length;
  }
  return result;
}

async function sha256Bytes(value) {
  const bytes =
    typeof value === "string" ? new TextEncoder().encode(value) : value;
  return new Uint8Array(await crypto.subtle.digest("SHA-256", bytes));
}

function derInteger(bytes) {
  let first = 0;
  while (first < bytes.length - 1 && bytes[first] === 0) {
    first += 1;
  }
  let value = bytes.slice(first);
  if ((value[0] & 0x80) !== 0) {
    value = concatBytes(Uint8Array.of(0), value);
  }
  return concatBytes(Uint8Array.of(0x02, value.length), value);
}

function ecdsaSignatureDER(signature) {
  if (signature[0] === 0x30) {
    return signature;
  }
  if (signature.length !== 64) {
    throw new Error(`unexpected ECDSA signature length ${signature.length}`);
  }
  const r = derInteger(signature.slice(0, 32));
  const s = derInteger(signature.slice(32));
  return concatBytes(Uint8Array.of(0x30, r.length + s.length), r, s);
}

function cborByteString(bytes) {
  if (bytes.length >= 256) {
    throw new Error("test CBOR helper only supports byte strings under 256 bytes");
  }
  return concatBytes(Uint8Array.of(0x58, bytes.length), bytes);
}

function cborText(value) {
  const bytes = new TextEncoder().encode(value);
  if (bytes.length > 23) {
    throw new Error("test CBOR helper only supports short text keys");
  }
  return concatBytes(Uint8Array.of(0x60 + bytes.length), bytes);
}

async function makeSyntheticAppAttestIdentity() {
  const keys = await crypto.subtle.generateKey(
    { name: "ECDSA", namedCurve: "P-256" },
    true,
    ["sign", "verify"],
  );
  const publicKey = new Uint8Array(
    await crypto.subtle.exportKey("raw", keys.publicKey),
  );
  return {
    installID: `synthetic-${crypto.randomUUID()}`,
    keyID: bytesToBase64(await sha256Bytes(publicKey)),
    privateKey: keys.privateKey,
    publicKey,
  };
}

async function seedSyntheticKey(identity) {
  const now = Math.floor(Date.now() / 1000);
  await env.AD_ANALYSIS_DB.prepare(
    "INSERT INTO app_attest_keys \
     (install_id, key_id, public_key, sign_counter, app_id, environment, created_at, last_used_at) \
     VALUES (?1, ?2, ?3, 0, ?4, ?5, ?6, ?6)",
  )
    .bind(
      identity.installID,
      identity.keyID,
      identity.publicKey.buffer,
      fixture.app_id,
      fixture.environment,
      now,
    )
    .run();
}

async function syntheticAssertion(identity, path, payload, counter) {
  const payloadHash = bytesToHex(await sha256Bytes(payload));
  const clientDataHash = await sha256Bytes(`POST\n${path}\n${payloadHash}`);
  const authenticatorData = new Uint8Array(37);
  authenticatorData.set(await sha256Bytes(fixture.app_id), 0);
  new DataView(authenticatorData.buffer).setUint32(33, counter, false);
  const nonce = await sha256Bytes(
    concatBytes(authenticatorData, clientDataHash),
  );
  const rawSignature = new Uint8Array(
    await crypto.subtle.sign(
      { name: "ECDSA", hash: "SHA-256" },
      identity.privateKey,
      nonce,
    ),
  );
  const signature = ecdsaSignatureDER(rawSignature);
  const cbor = concatBytes(
    Uint8Array.of(0xa2),
    cborText("signature"),
    cborByteString(signature),
    cborText("authenticatorData"),
    cborByteString(authenticatorData),
  );
  return bytesToBase64(cbor);
}

async function seedFixtureKey() {
  const now = Math.floor(Date.now() / 1000);
  await env.AD_ANALYSIS_DB.prepare(
    "INSERT INTO app_attest_keys \
     (install_id, key_id, public_key, sign_counter, app_id, environment, created_at, last_used_at) \
     VALUES (?1, ?2, ?3, 0, ?4, ?5, ?6, ?6)",
  )
    .bind(
      fixture.install_id,
      fixture.key_id,
      hexToBytes(fixture.public_key_sec1_hex).buffer,
      fixture.app_id,
      fixture.environment,
      now,
    )
    .run();
}

function envelopeBody() {
  return JSON.stringify({
    install_id: fixture.install_id,
    key_id: fixture.key_id,
    payload: fixture.payload,
    assertion: fixture.assertion,
  });
}

function postAnalyze(body, headers = {}) {
  return SELF.fetch(`${BASE}${ANALYZE_PATH}`, {
    method: "POST",
    headers: { "content-type": "application/json", ...headers },
    body,
  });
}

function postPoll(jobID, headers = {}) {
  return SELF.fetch(`${BASE}/v1/ad-analysis/jobs/${jobID}`, {
    method: "POST",
    headers: { "content-type": "application/json", ...headers },
    body: JSON.stringify({ job_id: jobID }),
  });
}

function geminiResponseForSpan(segmentID, evidenceQuote) {
  return {
    candidates: [
      {
        content: {
          parts: [
            {
              text: JSON.stringify({
                spans: [
                  {
                    kind: "host_read_ad",
                    label: `Sponsor at ${segmentID}`,
                    start_segment_id: segmentID,
                    end_segment_id: segmentID,
                    confidence: 0.96,
                    evidence_quote: evidenceQuote,
                  },
                ],
              }),
            },
          ],
        },
        finishReason: "STOP",
      },
    ],
    usageMetadata: {
      promptTokenCount: 120,
      candidatesTokenCount: 40,
      totalTokenCount: 160,
    },
  };
}

function makeLongRequest({
  fingerprint = "a".repeat(64),
  asyncSupported = true,
  segmentCount = 2100,
} = {}) {
  const firstEvidence =
    "This episode is brought to you by Window One Sponsor for a special offer.";
  const secondEvidence =
    "This episode is brought to you by Window Two Sponsor for a special offer.";
  const segments = Array.from({ length: segmentCount }, (_, index) => ({
    id: index,
    start: index * 20,
    end: (index + 1) * 20,
    text:
      index === 2
        ? firstEvidence
        : index === 1802
          ? secondEvidence
          : `Discussion segment ${index} continues the episode conversation.`,
  }));
  const request = {
    schema_version: 1,
    request_id: `integration-${fingerprint.slice(0, 8)}`,
    episode_id: `episode-${fingerprint.slice(0, 8)}`,
    podcast_id: "https://example.com/long-feed.xml",
    episode_title: "Long integration episode",
    podcast_title: "Integration Podcast",
    transcript: {
      language_code: "en",
      audio_duration: segmentCount * 20,
      fingerprint,
      updated_at: "2026-07-15T00:00:00Z",
      state: "completed",
      segment_count: segmentCount,
    },
    segments,
  };
  if (asyncSupported !== undefined) {
    request.async_supported = asyncSupported;
  }
  return { request, firstEvidence, secondEvidence };
}

async function waitForTerminalPoll(jobID) {
  for (let attempt = 0; attempt < 100; attempt += 1) {
    const response = await postPoll(jobID, {
      authorization: `Bearer ${BEARER}`,
    });
    if (response.status !== 202) {
      return response;
    }
    await new Promise((resolve) => setTimeout(resolve, 1));
  }
  throw new Error(`job ${jobID} did not reach a terminal poll response`);
}

async function waitForCompletedResubmit(request) {
  for (let attempt = 0; attempt < 100; attempt += 1) {
    const response = await postAnalyze(JSON.stringify(request), {
      authorization: `Bearer ${BEARER}`,
    });
    if (response.status !== 202) {
      return response;
    }
    await new Promise((resolve) => setTimeout(resolve, 1));
  }
  throw new Error("completed job was not served from a repeated submit");
}

beforeAll(() => {
  installFetchStub();
});

afterAll(() => {
  globalThis.fetch = realFetch;
});

afterEach(() => {
  expect(pendingGeminiResponses.length).toBe(0);
});

describe("routing", () => {
  it("serves health without auth", async () => {
    const response = await SELF.fetch(`${BASE}/health`);
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ message: "ok" });
  });

  it("returns 404 for unknown routes", async () => {
    const response = await SELF.fetch(`${BASE}/nope`);
    expect(response.status).toBe(404);
    expect((await response.json()).error).toBe("not_found");
  });

  it("returns 405 for GET on the analyze route", async () => {
    const response = await SELF.fetch(`${BASE}${ANALYZE_PATH}`);
    expect(response.status).toBe(405);
  });
});

describe("analyze auth", () => {
  it("rejects an unauthenticated request", async () => {
    const response = await postAnalyze(JSON.stringify({}));
    expect(response.status).toBe(401);
    expect((await response.json()).error).toBe("missing_assertion");
  });

  it("rejects a wrong bearer token", async () => {
    const response = await postAnalyze(fixture.payload, {
      authorization: "Bearer wrong-token",
    });
    expect(response.status).toBe(401);
    expect((await response.json()).error).toBe("unauthorized");
  });

  it("rejects an envelope for an unregistered key", async () => {
    const response = await postAnalyze(envelopeBody());
    expect(response.status).toBe(401);
    expect((await response.json()).error).toBe("unknown_key");
  });
});

describe("app attest envelope", () => {
  it("accepts the real fixture assertion once and rejects its replay", async () => {
    await seedFixtureKey();

    mockGeminiOnce();
    const first = await postAnalyze(envelopeBody());
    expect(first.status).toBe(200);
    const body = await first.json();
    expect(body.schema_version).toBe(1);
    expect(body.request_id).toBe(fixture.response_request_id);
    expect(body.policy).toBe("promo_ad_breaks_v2");
    expect(body.spans).toHaveLength(1);
    expect(body.spans[0].kind).toBe("host_read_ad");
    expect(body.spans[0].start_segment_id).toBe(2);
    expect(body.spans[0].start_time).toBe(8);
    expect(body.spans[0].end_time).toBe(24);

    const replay = await postAnalyze(envelopeBody());
    expect(replay.status).toBe(401);
    expect((await replay.json()).error).toBe("invalid_counter");
  });
});

describe("bearer bridge", () => {
  it("analyzes with the internal bearer token through the usage limiter", async () => {
    mockGeminiOnce();
    const response = await postAnalyze(fixture.payload, {
      authorization: `Bearer ${BEARER}`,
    });
    expect(response.status).toBe(200);
    const body = await response.json();
    expect(body.spans).toHaveLength(1);
    expect(body.policy).toBe("promo_ad_breaks_v2");
    // AD_ANALYSIS_GEMINI_MODEL selected the fallback model; the stub above
    // proves the outbound URL targeted it and this proves it is reported.
    expect(body.model).toBe(EXPECTED_MODEL);
  });
});

describe("async jobs", () => {
  it("submits, attaches without new model calls, then serves folded spans idempotently", async () => {
    const { request, firstEvidence, secondEvidence } = makeLongRequest();
    const first = mockGeminiDeferred(geminiResponseForSpan(2, firstEvidence));
    const second = mockGeminiDeferred(
      geminiResponseForSpan(1802, secondEvidence),
    );

    const submitted = await postAnalyze(JSON.stringify(request), {
      authorization: `Bearer ${BEARER}`,
    });
    expect(submitted.status).toBe(202);
    expect(await submitted.json()).toEqual({
      job_id: request.transcript.fingerprint,
      state: "running",
      poll_after_seconds: 15,
    });
    await Promise.all([first.started, second.started]);

    const attached = await postAnalyze(JSON.stringify(request), {
      authorization: `Bearer ${BEARER}`,
    });
    expect(attached.status).toBe(202);
    expect((await attached.json()).job_id).toBe(request.transcript.fingerprint);

    const running = await postPoll(request.transcript.fingerprint, {
      authorization: `Bearer ${BEARER}`,
    });
    expect(running.status).toBe(202);
    expect(await running.json()).toEqual({
      job_id: request.transcript.fingerprint,
      state: "running",
      poll_after_seconds: 10,
    });

    first.release();
    second.release();
    const completed = await waitForTerminalPoll(request.transcript.fingerprint);
    expect(completed.status).toBe(200);
    const result = await completed.json();
    expect(result.request_id).toBe(request.request_id);
    expect(result.spans.map((span) => span.start_segment_id)).toEqual([
      2, 1802,
    ]);
    expect(result.usage).toEqual({
      prompt_token_count: 240,
      candidates_token_count: 80,
      total_token_count: 320,
    });

    const repeated = await postPoll(request.transcript.fingerprint, {
      authorization: `Bearer ${BEARER}`,
    });
    expect(repeated.status).toBe(200);
    expect(await repeated.json()).toEqual(result);
  });

  it("serves a completed unfetched job directly from a repeated submit", async () => {
    const { request, firstEvidence, secondEvidence } = makeLongRequest({
      fingerprint: "b".repeat(64),
    });
    mockGeminiOnce(geminiResponseForSpan(2, firstEvidence));
    mockGeminiOnce(geminiResponseForSpan(1802, secondEvidence));

    const submitted = await postAnalyze(JSON.stringify(request), {
      authorization: `Bearer ${BEARER}`,
    });
    expect(submitted.status).toBe(202);

    const completed = await waitForCompletedResubmit(request);
    expect(completed.status).toBe(200);
    const result = await completed.json();
    expect(result.spans).toHaveLength(2);

    const repeated = await postPoll(request.transcript.fingerprint, {
      authorization: `Bearer ${BEARER}`,
    });
    expect(repeated.status).toBe(200);
    expect(await repeated.json()).toEqual(result);
  });

  it("turns an evicted running job into a transient failure on its alarm", async () => {
    const { request, firstEvidence, secondEvidence } = makeLongRequest({
      fingerprint: "c".repeat(64),
    });
    const first = mockGeminiDeferred(geminiResponseForSpan(2, firstEvidence));
    const second = mockGeminiDeferred(
      geminiResponseForSpan(1802, secondEvidence),
    );

    const submitted = await postAnalyze(JSON.stringify(request), {
      authorization: `Bearer ${BEARER}`,
    });
    expect(submitted.status).toBe(202);
    await Promise.all([first.started, second.started]);

    await abortAllDurableObjects();
    const stub = env.AD_ANALYSIS_JOB.getByName(
      `ad-analysis:v1:job:${request.transcript.fingerprint}`,
    );
    expect(await runDurableObjectAlarm(stub)).toBe(true);

    const failed = await postPoll(request.transcript.fingerprint, {
      authorization: `Bearer ${BEARER}`,
    });
    expect(failed.status).toBe(503);
    expect((await failed.json()).error).toBe("job_failed_transient");
    first.release();
    second.release();
  });

  it("keeps legacy requests synchronous and runs opted-in single-window requests asynchronously", async () => {
    const legacy = makeLongRequest({
      fingerprint: "d".repeat(64),
    });
    delete legacy.request.async_supported;
    mockGeminiOnce(geminiResponseForSpan(2, legacy.firstEvidence));
    mockGeminiOnce(geminiResponseForSpan(1802, legacy.secondEvidence));
    const legacyResponse = await postAnalyze(JSON.stringify(legacy.request), {
      authorization: `Bearer ${BEARER}`,
    });
    expect(legacyResponse.status).toBe(200);
    expect((await legacyResponse.json()).spans).toHaveLength(2);

    const singleWindow = JSON.parse(fixture.payload);
    singleWindow.async_supported = true;
    mockGeminiOnce();
    const singleResponse = await postAnalyze(JSON.stringify(singleWindow), {
      authorization: `Bearer ${BEARER}`,
    });
    expect(singleResponse.status).toBe(202);
    expect((await singleResponse.json()).job_id).toBe(
      singleWindow.transcript.fingerprint,
    );
    const completedSingleWindow = await waitForTerminalPoll(
      singleWindow.transcript.fingerprint,
    );
    expect(completedSingleWindow.status).toBe(200);
    expect((await completedSingleWindow.json()).spans).toHaveLength(1);
  });

  it("authenticates the exact dynamic poll path before rejecting a payload mismatch", async () => {
    const identity = await makeSyntheticAppAttestIdentity();
    await seedSyntheticKey(identity);
    const pathJobID = "e".repeat(64);
    const payloadJobID = "f".repeat(64);
    const path = `/v1/ad-analysis/jobs/${pathJobID}`;
    const payload = JSON.stringify({ job_id: payloadJobID });
    const assertion = await syntheticAssertion(identity, path, payload, 1);

    const response = await SELF.fetch(`${BASE}${path}`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        install_id: identity.installID,
        key_id: identity.keyID,
        payload,
        assertion,
      }),
    });

    expect(response.status).toBe(400);
    expect((await response.json()).error).toBe("job_id_mismatch");
  });

  it("caps the complete App Attest poll envelope at 16 KiB", async () => {
    const response = await SELF.fetch(
      `${BASE}/v1/ad-analysis/jobs/${"9".repeat(64)}`,
      {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ payload: "x".repeat(17 * 1024) }),
      },
    );

    expect(response.status).toBe(413);
    expect((await response.json()).error).toBe("payload_too_large");
  });
});

describe("model output resilience", () => {
  it("degrades truncated model JSON to warnings plus empty, never 502", async () => {
    // Initial call and the single full re-request both come back truncated.
    mockGeminiOnce(GEMINI_TRUNCATED_RESPONSE);
    mockGeminiOnce(GEMINI_TRUNCATED_RESPONSE);

    const response = await postAnalyze(fixture.payload, {
      authorization: `Bearer ${BEARER}`,
    });

    expect(response.status).toBe(200);
    const body = await response.json();
    expect(body.spans).toHaveLength(0);
    expect(body.warnings).toContain("gemini_finish_reason:MAX_TOKENS");
    expect(body.warnings).toContain("malformed_model_json_skipped");
  });
});

describe("challenges", () => {
  const CHALLENGE_HEADERS = {
    "content-type": "application/json",
    "cf-connecting-ip": "203.0.113.7",
  };

  it("issues a challenge and enforces the per-install hourly cap", async () => {
    for (let i = 0; i < 20; i += 1) {
      const response = await SELF.fetch(`${BASE}/v1/app-attest/challenge`, {
        method: "POST",
        headers: CHALLENGE_HEADERS,
        body: JSON.stringify({ install_id: "itest-install", purpose: "register" }),
      });
      expect(response.status).toBe(200);
      const body = await response.json();
      expect(body.challenge_id).toBeTruthy();
      expect(body.challenge).toBeTruthy();
    }

    const capped = await SELF.fetch(`${BASE}/v1/app-attest/challenge`, {
      method: "POST",
      headers: CHALLENGE_HEADERS,
      body: JSON.stringify({ install_id: "itest-install", purpose: "register" }),
    });
    expect(capped.status).toBe(429);
    expect((await capped.json()).error).toBe("challenge_rate_limited");
  });

  it("rejects a challenge with the wrong purpose", async () => {
    const response = await SELF.fetch(`${BASE}/v1/app-attest/challenge`, {
      method: "POST",
      headers: CHALLENGE_HEADERS,
      body: JSON.stringify({ install_id: "itest-install", purpose: "other" }),
    });
    expect(response.status).toBe(400);
    expect((await response.json()).error).toBe("invalid_challenge_request");
  });
});

describe("register", () => {
  it("rejects registration against an unknown challenge", async () => {
    const response = await SELF.fetch(`${BASE}/v1/app-attest/register`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        install_id: fixture.install_id,
        key_id: fixture.key_id,
        challenge_id: "no-such-challenge",
        challenge: fixture.challenge,
        attestation_object: fixture.attestation_object,
      }),
    });
    expect(response.status).toBe(401);
    expect((await response.json()).error).toBe("invalid_challenge");
  });
});

describe("internal transcription surface", () => {
  const INTERNAL_BASE = "https://opencast-ad-analysis.internal";

  function postInternalAnalyze(request, overrides = {}) {
    return SELF.fetch(`${INTERNAL_BASE}/internal/v1/analyze`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        schema_version: 1,
        account_id: "acct-integration-1",
        transcription_job_id: "job-integration-1",
        request,
        ...overrides,
      }),
    });
  }

  function postInternalPoll(jobID) {
    return SELF.fetch(`${INTERNAL_BASE}/internal/v1/jobs/${jobID}/poll`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ job_id: jobID }),
    });
  }

  it("404s internal paths on the public host even with every flag on", async () => {
    const analyze = await SELF.fetch(`${BASE}/internal/v1/analyze`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: "{}",
    });
    expect(analyze.status).toBe(404);

    const poll = await SELF.fetch(
      `${BASE}/internal/v1/jobs/${"a".repeat(64)}/poll`,
      {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: "{}",
      },
    );
    expect(poll.status).toBe(404);
  });

  it("rejects malformed internal envelopes and invalid payloads", async () => {
    const { request } = makeLongRequest({
      fingerprint: "b".repeat(64),
      segmentCount: 5,
    });

    const badVersion = await postInternalAnalyze(request, { schema_version: 2 });
    expect(badVersion.status).toBe(400);
    expect((await badVersion.json()).error).toBe("invalid_internal_request");

    const emptyAccount = await postInternalAnalyze(request, { account_id: " " });
    expect(emptyAccount.status).toBe(400);
    expect((await emptyAccount.json()).error).toBe("invalid_internal_request");

    const invalidInner = await postInternalAnalyze({
      ...request,
      podcast_id: "",
    });
    expect(invalidInner.status).toBe(400);
    expect((await invalidInner.json()).error).toBe("empty_podcast_id");
  });

  it("runs a single-window internal analyze always-async with attach dedupe", async () => {
    const fingerprint = "c".repeat(64);
    // async_supported=false proves the internal path lifts the public
    // multi-window-only async restriction: it still runs as a job.
    const { request, firstEvidence } = makeLongRequest({
      fingerprint,
      asyncSupported: false,
      segmentCount: 5,
    });
    const deferred = mockGeminiDeferred(geminiResponseForSpan(2, firstEvidence));

    const submitted = await postInternalAnalyze(request);
    expect(submitted.status).toBe(202);
    expect(await submitted.json()).toEqual({
      job_id: fingerprint,
      state: "running",
      poll_after_seconds: 15,
    });
    await deferred.started;

    // A duplicate submit attaches to the running fingerprint-keyed job
    // without a second Gemini call (afterEach proves no pending mocks).
    const attached = await postInternalAnalyze(request);
    expect(attached.status).toBe(202);
    expect((await attached.json()).job_id).toBe(fingerprint);

    const running = await postInternalPoll(fingerprint);
    expect(running.status).toBe(202);

    deferred.release();
    let completed;
    for (let attempt = 0; attempt < 100; attempt += 1) {
      completed = await postInternalPoll(fingerprint);
      if (completed.status !== 202) {
        break;
      }
      await new Promise((resolve) => setTimeout(resolve, 1));
    }
    expect(completed.status).toBe(200);
    const result = await completed.json();
    expect(result.request_id).toBe(request.request_id);
    expect(result.policy).toBe("promo_ad_breaks_v2");
    expect(result.spans).toHaveLength(1);
    expect(result.spans[0].start_segment_id).toBe(2);

    // Completion stays idempotently readable until the TTL alarm purges it.
    const repeated = await postInternalPoll(fingerprint);
    expect(repeated.status).toBe(200);
    expect(await repeated.json()).toEqual(result);
  });

  it("404s an unknown internal job id", async () => {
    const response = await postInternalPoll("d".repeat(64));
    expect(response.status).toBe(404);
    expect((await response.json()).error).toBe("job_not_found");
  });
});

// --- Phase 10.5 E (AA-5): an over-budget result fails with a stable code
// instead of stranding the job. Pre-fix there was NO in-code size cap on
// the result path: the post-paid-call record write died on the DO's
// 128 KiB per-value platform limit, the error vanished into the spawn
// catch, and the job sat Running for the full 600 s deadline.

describe("result budget (AA-5)", () => {
  it("fails an over-budget result with result_oversized instead of hanging", async () => {
    const { request } = makeLongRequest({ fingerprint: "e".repeat(64) });
    // Two windows → two Gemini calls. Each returns degenerate output whose
    // huge unknown span kinds stay inside every span cap (30 ≤ 32 per
    // window) but get echoed into validation warnings, pushing the
    // assembled result_json far past MAX_RESULT_JSON_BYTES.
    const degenerate = {
      candidates: [
        {
          content: {
            parts: [
              {
                text: JSON.stringify({
                  spans: Array.from({ length: 30 }, (_, index) => ({
                    kind: `degenerate-kind-${index}-${"x".repeat(4000)}`,
                    label: "n/a",
                    start_segment_id: 2,
                    end_segment_id: 2,
                    confidence: 0.5,
                    evidence_quote: "n/a",
                  })),
                }),
              },
            ],
          },
          finishReason: "STOP",
        },
      ],
      usageMetadata: {
        promptTokenCount: 100,
        candidatesTokenCount: 10,
        totalTokenCount: 110,
      },
    };
    mockGeminiOnce(degenerate);
    mockGeminiOnce(degenerate);

    const submitted = await postAnalyze(JSON.stringify(request), {
      authorization: `Bearer ${BEARER}`,
    });
    expect(submitted.status).toBe(202);

    let failed;
    for (let attempt = 0; attempt < 200; attempt += 1) {
      failed = await postPoll(request.transcript.fingerprint, {
        authorization: `Bearer ${BEARER}`,
      });
      if (failed.status !== 202) {
        break;
      }
      await new Promise((resolve) => setTimeout(resolve, 25));
    }
    expect(failed.status).toBe(502);
    expect((await failed.json()).error).toBe("result_oversized");
  });
});
