// Workerd-local integration tests: drive real HTTP requests through the
// compiled wasm Worker with local D1 + Durable Object bindings and a mocked
// Gemini upstream. These cover the wasm orchestration glue that host `cargo
// test` cannot reach. Requires `build/index.js` (see `yarn build:worker`).
import { SELF } from "cloudflare:test";
import { afterAll, afterEach, beforeAll, describe, expect, it } from "vitest";

const ANALYZE_PATH = "/v1/ad-analysis/transcript";
const BASE = "https://ad-analysis.integration.test";
const BEARER = "integration-test-bearer-token";
const fixture = {
  install_id: "integration-install",
  key_id: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
  challenge: "integration-challenge",
  attestation_object: "synthetic-invalid-attestation",
  assertion: "synthetic-invalid-assertion",
  payload: JSON.stringify({
    episode_id: "integration-episode",
    episode_title: "Integration Episode",
    podcast_id: "https://example.com/integration-feed.xml",
    podcast_title: "Integration Podcast",
    request_id: "integration-request",
    schema_version: 1,
    segments: [
      { end: 8, id: 1, start: 0, text: "Welcome back to the integration episode." },
      {
        end: 24,
        id: 2,
        start: 8,
        text: "This episode is brought to you by Seed Sponsor.",
      },
      { end: 45, id: 3, start: 24, text: "Now back to the episode." },
    ],
    transcript: {
      audio_duration: 45,
      fingerprint: "integration-fingerprint",
      language_code: "en",
      model_identifier: "integration-model",
      model_tree_sha256: "integration-tree-sha",
      model_version: "v1",
      segment_count: 3,
      state: "completed",
      updated_at: "2026-05-28T20:26:40Z",
    },
  }),
};

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
      const body = pendingGeminiResponses.shift();
      return new Response(JSON.stringify(body), {
        status: 200,
        headers: { "content-type": "application/json" },
      });
    }
    throw new Error(`unexpected outbound fetch in integration test: ${url}`);
  };
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
