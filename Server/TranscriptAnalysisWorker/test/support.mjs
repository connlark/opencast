// Shared workerd-spec helpers: synthetic App Attest identities/envelopes,
// the Gemini fetch stub, and request/response fixtures. Used by the standard
// integration suite and the billing suites (dev-fake + PurchaseWorker
// matrices), which run under separate vitest configs with different worker
// bindings.
//
// The App Attest identities are SYNTHETIC only: the captured device
// fixture's assertion binds the ad-analysis path in its signed client data,
// so it cannot authenticate against this worker's routes. Real-fixture
// attestation coverage lives in `cargo test` (tests/app_attest_auth.rs).
import { SELF, env } from "cloudflare:test";

export const ANALYZE_PATH = "/v1/transcript-analysis/transcript";
export const BOOTSTRAP_PATH = "/v1/transcript-analysis/account/bootstrap";
export const BASE = "https://transcript-analysis.integration.test";
export const BEARER = "integration-test-bearer-token";
// Derived from the worker's own env vars (wrangler.toml [vars]) rather than
// hardcoded, so the OSS scrub of that config carries this test with it and no
// private team ID lives in the spec (AdAnalysisWorker reads fixture.app_id for
// the same reason). Read lazily: `env` is populated by the time a test runs,
// and the worker computes its app id from the identical two vars.
export const appID = () => `${env.APPLE_TEAM_ID}.${env.APPLE_BUNDLE_ID}`;
export const ENVIRONMENT = "development";
// The vitest miniflare bindings set TRANSCRIPT_ANALYSIS_GEMINI_MODEL to the
// BANNED gemini-2.5-flash; the single-entry allowlist must clamp to the
// default, so the stub only answers for it and the response must report it.
export const EXPECTED_MODEL = "gemini-3.5-flash";

// The `main` worker runs in the same isolate as the tests, so stubbing the
// global `fetch` intercepts the Worker's outbound Gemini call. Binding
// traffic (SELF, D1, Durable Objects) does not go through the global.
const realFetch = globalThis.fetch;
export const pendingGeminiResponses = [];
export const observedGeminiPayloads = [];

export function mockGeminiOnce(body) {
  pendingGeminiResponses.push(body);
}

export function mockGeminiDeferred(body) {
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

export function installFetchStub() {
  globalThis.fetch = async (input, init) => {
    const url = typeof input === "string" ? input : input.url;
    if (
      url ===
      `https://generativelanguage.googleapis.com/v1beta/models/${EXPECTED_MODEL}:generateContent`
    ) {
      if (pendingGeminiResponses.length === 0) {
        throw new Error("unexpected Gemini call: no mocked response pending");
      }
      const rawBody =
        typeof input === "string" ? init?.body : await input.clone().text();
      if (rawBody) {
        observedGeminiPayloads.push(JSON.parse(rawBody));
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

export function restoreFetchStub() {
  globalThis.fetch = realFetch;
}

export function bytesToBase64(bytes) {
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

export async function sha256Bytes(value) {
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
    throw new Error(
      "test CBOR helper only supports byte strings under 256 bytes",
    );
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

export async function makeSyntheticAppAttestIdentity() {
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
    counter: 0,
  };
}

export async function seedSyntheticKey(identity) {
  const now = Math.floor(Date.now() / 1000);
  await env.TRANSCRIPT_ANALYSIS_DB.prepare(
    "INSERT INTO app_attest_keys \
     (install_id, key_id, public_key, sign_counter, app_id, environment, created_at, last_used_at) \
     VALUES (?1, ?2, ?3, 0, ?4, ?5, ?6, ?6)",
  )
    .bind(
      identity.installID,
      identity.keyID,
      identity.publicKey.buffer,
      appID(),
      ENVIRONMENT,
      now,
    )
    .run();
}

export async function syntheticAssertion(identity, path, payload, counter) {
  const payloadHash = bytesToHex(await sha256Bytes(payload));
  const clientDataHash = await sha256Bytes(`POST\n${path}\n${payloadHash}`);
  const authenticatorData = new Uint8Array(37);
  authenticatorData.set(await sha256Bytes(appID()), 0);
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

/// Envelope POST as the given seeded identity, auto-incrementing its sign
/// counter (each identity's counter is process-local test state).
export async function postEnvelope(identity, path, payloadObject) {
  const payload = JSON.stringify(payloadObject);
  identity.counter += 1;
  const assertion = await syntheticAssertion(
    identity,
    path,
    payload,
    identity.counter,
  );
  return SELF.fetch(`${BASE}${path}`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      install_id: identity.installID,
      key_id: identity.keyID,
      payload,
      assertion,
    }),
  });
}

export function postAnalyze(body, headers = {}) {
  return SELF.fetch(`${BASE}${ANALYZE_PATH}`, {
    method: "POST",
    headers: { "content-type": "application/json", ...headers },
    body,
  });
}

export function postPoll(jobID, headers = {}) {
  return SELF.fetch(`${BASE}/v1/transcript-analysis/jobs/${jobID}`, {
    method: "POST",
    headers: { "content-type": "application/json", ...headers },
    body: JSON.stringify({ job_id: jobID }),
  });
}

export function makeRequest({
  fingerprint = "a".repeat(64),
  asyncSupported = false,
  segmentCount = 12,
} = {}) {
  const segments = Array.from({ length: segmentCount }, (_, index) => ({
    id: index,
    start: index * 20,
    end: (index + 1) * 20,
    text: `Discussion segment ${index} continues the episode conversation.`,
  }));
  const request = {
    schema_version: 1,
    request_id: `integration-${fingerprint.slice(0, 8)}`,
    episode_id: `episode-${fingerprint.slice(0, 8)}`,
    podcast_id: "https://example.com/feed.xml",
    episode_title: "Integration episode",
    podcast_title: "Integration Podcast",
    transcript: {
      language_code: "en",
      audio_duration: segmentCount * 20,
      fingerprint,
      updated_at: "2026-08-23T00:00:00Z",
      state: "completed",
      segment_count: segmentCount,
    },
    segments,
  };
  if (asyncSupported) {
    request.async_supported = true;
  }
  return request;
}

export function makeDenseRequest({
  fingerprint = "7".repeat(64),
  segmentCount = 1400,
} = {}) {
  const request = makeRequest({ fingerprint, segmentCount });
  request.transcript.audio_duration = segmentCount;
  request.segments = request.segments.map((segment, index) => ({
    ...segment,
    start: index,
    end: index + 1,
    text: `word-${index}`,
  }));
  return request;
}

// A clean two-chapter model output for a segmentCount-segment request:
// chapter 1 covers the first half, chapter 2 the rest, claims anchored to
// real ids.
export function analysisFor(segmentCount, titlePrefix = "Chapter") {
  const split = Math.floor(segmentCount / 2);
  return {
    chapters: [
      {
        title: `${titlePrefix} one`,
        start_segment_id: 0,
        end_segment_id: split - 1,
        confidence: 0.9,
      },
      {
        title: `${titlePrefix} two`,
        start_segment_id: split,
        end_segment_id: segmentCount - 1,
        confidence: 0.85,
      },
    ],
    summary: {
      summary: "The hosts continue the episode conversation across two acts.",
      one_line_description: "A two-act conversation",
      claims: [
        { text: "The conversation opens the episode", evidence_segment_id: 0 },
        { text: "A second act follows", evidence_segment_id: split },
        {
          text: "The conversation runs to the end",
          evidence_segment_id: segmentCount - 1,
        },
      ],
    },
  };
}

export function geminiResponse(modelOutput, finishReason = "STOP") {
  return {
    candidates: [
      {
        content: { parts: [{ text: JSON.stringify(modelOutput) }] },
        finishReason,
      },
    ],
    usageMetadata: {
      promptTokenCount: 120,
      candidatesTokenCount: 40,
      thoughtsTokenCount: 300,
      totalTokenCount: 460,
    },
  };
}

// A MAX_TOKENS-truncated body: the model JSON is cut mid-object — the
// measured transient thinking-overflow class.
export const GEMINI_TRUNCATED_RESPONSE = {
  candidates: [
    {
      content: { parts: [{ text: '{"chapters":[{"title":' }] },
      finishReason: "MAX_TOKENS",
    },
  ],
  usageMetadata: {
    promptTokenCount: 120,
    candidatesTokenCount: 32768,
    totalTokenCount: 32888,
  },
};

export async function waitForTerminalPoll(jobID) {
  for (let attempt = 0; attempt < 200; attempt += 1) {
    const response = await postPoll(jobID, {
      authorization: `Bearer ${BEARER}`,
    });
    if (response.status !== 202) {
      return response;
    }
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
  throw new Error(`job ${jobID} did not reach a terminal poll response`);
}

/// Envelope-authenticated terminal poll: a billed job's subject set holds
/// the submitting App Attest key, so the bearer poll helper would see 404s.
export async function waitForTerminalPollAs(identity, jobID) {
  for (let attempt = 0; attempt < 200; attempt += 1) {
    const response = await postEnvelope(
      identity,
      `/v1/transcript-analysis/jobs/${jobID}`,
      { job_id: jobID },
    );
    if (response.status !== 202) {
      return response;
    }
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
  throw new Error(`job ${jobID} did not reach a terminal poll response`);
}

/// The job DO for a fingerprint, for driving its alarm from a test.
export function jobStub(fingerprint) {
  return env.TRANSCRIPT_ANALYSIS_JOB.getByName(
    `transcript-analysis:v1:job:${fingerprint}`,
  );
}
