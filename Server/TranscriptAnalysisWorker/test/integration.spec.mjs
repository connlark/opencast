// Workerd-local integration tests: drive real HTTP requests through the
// compiled wasm Worker with local D1 + Durable Object bindings and a mocked
// Gemini upstream. These cover the wasm orchestration glue that host `cargo
// test` cannot reach. Requires `build/index.js` (see `yarn build:worker`).
//
// Unlike the ad-analysis template, the App Attest envelope tests run on
// SYNTHETIC identities only: the captured device fixture's assertion binds
// the ad-analysis path in its signed client data, so it cannot authenticate
// against this worker's routes. The real-fixture attestation coverage lives
// in `cargo test` (tests/app_attest_auth.rs).
import {
  SELF,
  abortAllDurableObjects,
  env,
  runDurableObjectAlarm,
} from "cloudflare:test";
import { afterAll, afterEach, beforeAll, describe, expect, it } from "vitest";
import {
  BASE,
  BEARER,
  BOOTSTRAP_PATH,
  EXPECTED_MODEL,
  GEMINI_TRUNCATED_RESPONSE,
  analysisFor,
  bytesToBase64,
  geminiResponse,
  installFetchStub,
  makeDenseRequest,
  makeRequest,
  makeSyntheticAppAttestIdentity,
  mockGeminiDeferred,
  mockGeminiOnce,
  observedGeminiPayloads,
  pendingGeminiResponses,
  postAnalyze,
  postEnvelope,
  postPoll,
  restoreFetchStub,
  seedSyntheticKey,
  sha256Bytes,
  syntheticAssertion,
  waitForTerminalPoll,
} from "./support.mjs";

const ANALYZE_PATH = "/v1/transcript-analysis/transcript";

beforeAll(() => {
  installFetchStub();
});

afterAll(() => {
  restoreFetchStub();
});

afterEach(() => {
  // Drain before asserting so one failed test cannot cascade stale mocked
  // responses into its neighbors.
  const leftover = pendingGeminiResponses.length;
  pendingGeminiResponses.length = 0;
  observedGeminiPayloads.length = 0;
  expect(leftover).toBe(0);
});

describe("routing", () => {
  it("serves health without auth", async () => {
    const response = await SELF.fetch(`${BASE}/health`);
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ message: "ok" });
  });

  it("returns 404 for unknown routes and internal-shaped paths", async () => {
    for (const path of ["/nope", "/internal/v1/analyze"]) {
      const response = await SELF.fetch(`${BASE}${path}`, { method: "POST" });
      expect(response.status).toBe(404);
    }
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
    const response = await postAnalyze(JSON.stringify(makeRequest()), {
      authorization: "Bearer wrong-token",
    });
    expect(response.status).toBe(401);
    expect((await response.json()).error).toBe("unauthorized");
  });

  it("rejects an envelope for an unregistered key", async () => {
    const identity = await makeSyntheticAppAttestIdentity();
    const payload = JSON.stringify(makeRequest());
    const assertion = await syntheticAssertion(identity, ANALYZE_PATH, payload, 1);
    const response = await postAnalyze(
      JSON.stringify({
        install_id: identity.installID,
        key_id: identity.keyID,
        payload,
        assertion,
      }),
    );
    expect(response.status).toBe(401);
    expect((await response.json()).error).toBe("unknown_key");
  });
});

describe("app attest envelope", () => {
  it("accepts a synthetic assertion once and rejects its replay", async () => {
    const identity = await makeSyntheticAppAttestIdentity();
    await seedSyntheticKey(identity);
    const payload = JSON.stringify(
      makeRequest({ fingerprint: "0".repeat(64) }),
    );
    const assertion = await syntheticAssertion(identity, ANALYZE_PATH, payload, 1);
    const envelope = JSON.stringify({
      install_id: identity.installID,
      key_id: identity.keyID,
      payload,
      assertion,
    });

    mockGeminiOnce(geminiResponse(analysisFor(12)));
    const first = await postAnalyze(envelope);
    expect(first.status).toBe(200);
    const body = await first.json();
    expect(body.schema_version).toBe(1);
    expect(body.policy).toBe("transcript_analysis_v2");
    expect(body.model).toBe(EXPECTED_MODEL);
    expect(body.chapters).toHaveLength(2);
    expect(body.chapters[0].start_segment_id).toBe(0);
    expect(body.chapters[0].start_time).toBe(0);
    expect(body.chapters[0].end_time).toBe(120);
    expect(body.summary.claims).toHaveLength(3);

    const replay = await postAnalyze(envelope);
    expect(replay.status).toBe(401);
    expect((await replay.json()).error).toBe("invalid_counter");
  });
});


describe("billing dark (BILLING_REQUIRED unset)", () => {
  it("analyzes without touching billing state, while bootstrap still links", async () => {
    const identity = await makeSyntheticAppAttestIdentity();
    await seedSyntheticKey(identity);

    // Envelope analyze with billing dark: no bootstrap needed, no billing
    // rows of any kind while the billing kill switch is dark.
    mockGeminiOnce(geminiResponse(analysisFor(12)));
    const response = await postEnvelope(
      identity,
      ANALYZE_PATH,
      makeRequest({ fingerprint: "d".repeat(64) }),
    );
    expect(response.status).toBe(200);
    const links = await env.TRANSCRIPT_ANALYSIS_DB.prepare(
      "SELECT COUNT(*) AS n FROM install_account_links WHERE install_id = ?1",
    )
      .bind(identity.installID)
      .first();
    expect(links.n).toBe(0);
    const reservations = await env.TRANSCRIPT_ANALYSIS_DB.prepare(
      "SELECT COUNT(*) AS n FROM dev_credit_reservations",
    ).first();
    expect(reservations.n).toBe(0);

    // The bootstrap route stays serviceable while dark so installs can
    // link BEFORE a lane's billing flips on (no flip-day race).
    const bootstrap = await postEnvelope(identity, BOOTSTRAP_PATH, {
      schema_version: 1,
    });
    expect(bootstrap.status).toBe(200);
    const body = await bootstrap.json();
    expect(body.account_id).toMatch(/^acct-/);
    expect(body.balance.available_seconds).toBe(36000);
    const linked = await env.TRANSCRIPT_ANALYSIS_DB.prepare(
      "SELECT account_id FROM install_account_links WHERE install_id = ?1",
    )
      .bind(identity.installID)
      .first();
    expect(linked.account_id).toBe(body.account_id);
  });
});

describe("bearer bridge", () => {
  it("analyzes inline, clamps the banned model env var, and reports usage", async () => {
    mockGeminiOnce(geminiResponse(analysisFor(12)));
    const response = await postAnalyze(JSON.stringify(makeRequest()), {
      authorization: `Bearer ${BEARER}`,
    });
    expect(response.status).toBe(200);
    const body = await response.json();
    expect(body.chapters).toHaveLength(2);
    expect(body.policy).toBe("transcript_analysis_v2");
    // TRANSCRIPT_ANALYSIS_GEMINI_MODEL is the banned gemini-2.5-flash; the
    // stub above proves the outbound URL targeted the default and this
    // proves it is reported.
    expect(body.model).toBe(EXPECTED_MODEL);
    expect(body.usage).toEqual({
      prompt_token_count: 120,
      candidates_token_count: 40,
      thoughts_token_count: 300,
      total_token_count: 460,
    });
    expect(
      observedGeminiPayloads[0].generationConfig.thinkingConfig.thinkingLevel,
    ).toBe("medium");
    expect(observedGeminiPayloads[0].generationConfig.maxOutputTokens).toBe(
      32768,
    );
  });

  it("starts high when coalescing still leaves more than 1399 model units", async () => {
    const request = makeRequest({
      fingerprint: "1".repeat(64),
      segmentCount: 1400,
    });
    mockGeminiOnce(geminiResponse(analysisFor(1400)));
    const response = await postAnalyze(JSON.stringify(request), {
      authorization: `Bearer ${BEARER}`,
    });
    expect(response.status).toBe(200);
    expect(
      observedGeminiPayloads[0].generationConfig.thinkingConfig.thinkingLevel,
    ).toBe("high");
  });

  it("coalesces, validates in unit space, remaps, and returns an original-id partition", async () => {
    const request = makeDenseRequest();
    const unitCount = 280;
    mockGeminiOnce(geminiResponse(analysisFor(unitCount)));

    const response = await postAnalyze(JSON.stringify(request), {
      authorization: `Bearer ${BEARER}`,
    });

    expect(response.status).toBe(200);
    const body = await response.json();
    const prompt =
      observedGeminiPayloads[0].contents[0].parts[0].text;
    const segmentLines = prompt
      .split("\n")
      .filter((line) => /^\[\d+ \|/.test(line));

    expect(segmentLines).toHaveLength(unitCount);
    expect(segmentLines[0]).toBe(
      "[0 | 0.000-5.000] word-0 word-1 word-2 word-3 word-4",
    );
    expect(segmentLines.at(-1)).toBe(
      "[279 | 1395.000-1400.000] word-1395 word-1396 word-1397 word-1398 word-1399",
    );
    expect(
      observedGeminiPayloads[0].generationConfig.thinkingConfig.thinkingLevel,
    ).toBe("medium");

    expect(
      body.chapters.map((chapter) => [
        chapter.start_segment_id,
        chapter.end_segment_id,
      ]),
    ).toEqual([
      [0, 699],
      [700, 1399],
    ]);
    expect(body.chapters[0].start_time).toBe(0);
    expect(body.chapters[0].end_time).toBe(700);
    expect(body.chapters[1].start_time).toBe(700);
    expect(body.chapters[1].end_time).toBe(1400);
    expect(
      body.summary.claims.map((claim) => claim.evidence_segment_id),
    ).toEqual([0, 700, 1395]);

    // The returned original-id ranges are an exact, gap-free partition.
    expect(body.chapters[0].start_segment_id).toBe(request.segments[0].id);
    expect(body.chapters.at(-1).end_segment_id).toBe(
      request.segments.at(-1).id,
    );
    for (let index = 1; index < body.chapters.length; index += 1) {
      expect(body.chapters[index].start_segment_id).toBe(
        body.chapters[index - 1].end_segment_id + 1,
      );
    }
  });

  it("rejects transcripts over the model-unit cap with a typed error", async () => {
    const request = makeRequest({
      fingerprint: "2".repeat(64),
      segmentCount: 2401,
    });
    const response = await postAnalyze(JSON.stringify(request), {
      authorization: `Bearer ${BEARER}`,
    });
    expect(response.status).toBe(400);
    expect((await response.json()).error).toBe("transcript_too_long");
  });
});

describe("async jobs", () => {
  it("submits, attaches without new model calls, then serves the result idempotently", async () => {
    const request = makeRequest({
      fingerprint: "b".repeat(64),
      asyncSupported: true,
    });
    const deferred = mockGeminiDeferred(geminiResponse(analysisFor(12)));

    const submitted = await postAnalyze(JSON.stringify(request), {
      authorization: `Bearer ${BEARER}`,
    });
    expect(submitted.status).toBe(202);
    expect(await submitted.json()).toEqual({
      job_id: request.transcript.fingerprint,
      state: "running",
      poll_after_seconds: 15,
    });
    await deferred.started;

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

    deferred.release();
    const completed = await waitForTerminalPoll(request.transcript.fingerprint);
    expect(completed.status).toBe(200);
    const result = await completed.json();
    expect(result.request_id).toBe(request.request_id);
    expect(result.chapters.map((chapter) => chapter.start_segment_id)).toEqual([
      0, 6,
    ]);
    expect(result.summary.one_line_description).toBe("A two-act conversation");

    const repeated = await postPoll(request.transcript.fingerprint, {
      authorization: `Bearer ${BEARER}`,
    });
    expect(repeated.status).toBe(200);
    expect(await repeated.json()).toEqual(result);
  });

  it("turns an evicted running job into a transient failure on its alarm", async () => {
    const request = makeRequest({
      fingerprint: "c".repeat(64),
      asyncSupported: true,
    });
    const deferred = mockGeminiDeferred(geminiResponse(analysisFor(12)));

    const submitted = await postAnalyze(JSON.stringify(request), {
      authorization: `Bearer ${BEARER}`,
    });
    expect(submitted.status).toBe(202);
    await deferred.started;

    await abortAllDurableObjects();
    const stub = env.TRANSCRIPT_ANALYSIS_JOB.getByName(
      `transcript-analysis:v1:job:${request.transcript.fingerprint}`,
    );
    expect(await runDurableObjectAlarm(stub)).toBe(true);

    const failed = await postPoll(request.transcript.fingerprint, {
      authorization: `Bearer ${BEARER}`,
    });
    expect(failed.status).toBe(503);
    expect((await failed.json()).error).toBe("job_failed_transient");
    deferred.release();
  });

  it("authenticates the exact dynamic poll path before rejecting a payload mismatch", async () => {
    const identity = await makeSyntheticAppAttestIdentity();
    await seedSyntheticKey(identity);
    const pathJobID = "e".repeat(64);
    const payloadJobID = "f".repeat(64);
    const path = `/v1/transcript-analysis/jobs/${pathJobID}`;
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
      `${BASE}/v1/transcript-analysis/jobs/${"9".repeat(64)}`,
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
  it("retries one truncated response and succeeds with warnings", async () => {
    mockGeminiOnce(GEMINI_TRUNCATED_RESPONSE);
    mockGeminiOnce(geminiResponse(analysisFor(12)));

    const response = await postAnalyze(
      JSON.stringify(makeRequest({ fingerprint: "3".repeat(64) })),
      { authorization: `Bearer ${BEARER}` },
    );

    expect(response.status).toBe(200);
    const body = await response.json();
    expect(body.chapters).toHaveLength(2);
    expect(body.warnings).toContain("gemini_finish_reason:MAX_TOKENS");
    // `_high`: the retry escalated to high thinking.
    expect(body.warnings).toContain("max_tokens_truncated_retried_high");
    // Both attempts' burned tokens are folded for cost instrumentation.
    expect(body.usage.total_token_count).toBe(32888 + 460);
  });

  it("fails typed when truncation survives all three attempts", async () => {
    mockGeminiOnce(GEMINI_TRUNCATED_RESPONSE);
    mockGeminiOnce(GEMINI_TRUNCATED_RESPONSE);
    mockGeminiOnce(GEMINI_TRUNCATED_RESPONSE);

    const response = await postAnalyze(
      JSON.stringify(makeRequest({ fingerprint: "4".repeat(64) })),
      { authorization: `Bearer ${BEARER}` },
    );

    expect(response.status).toBe(502);
    expect((await response.json()).error).toBe("model_output_truncated");
  });

  it("fails typed when id-discipline violations survive all three attempts", async () => {
    const broken = analysisFor(12);
    // Seconds in an id field — the DQ class the validator must catch.
    broken.chapters[1].end_segment_id = 240;
    mockGeminiOnce(geminiResponse(broken));
    mockGeminiOnce(geminiResponse(broken));
    mockGeminiOnce(geminiResponse(broken));

    const response = await postAnalyze(
      JSON.stringify(makeRequest({ fingerprint: "5".repeat(64) })),
      { authorization: `Bearer ${BEARER}` },
    );

    expect(response.status).toBe(502);
    expect((await response.json()).error).toBe("invalid_model_output");
  });

  it("escalates a medium retry to high thinking and recovers", async () => {
    // Attempt 0 (medium, count-based) returns seconds-in-an-id-field; the
    // retry must escalate to high and, on a clean draw, succeed. This directly
    // verifies the escalate-on-retry policy.
    const broken = analysisFor(12);
    broken.chapters[1].end_segment_id = 240;
    mockGeminiOnce(geminiResponse(broken));
    mockGeminiOnce(geminiResponse(analysisFor(12)));

    const response = await postAnalyze(
      JSON.stringify(makeRequest({ fingerprint: "6".repeat(64) })),
      { authorization: `Bearer ${BEARER}` },
    );

    expect(response.status).toBe(200);
    const body = await response.json();
    expect(body.chapters).toHaveLength(2);
    expect(
      body.warnings.some((warning) =>
        warning.startsWith("invalid_model_output_retried_high"),
      ),
    ).toBe(true);
    expect(
      observedGeminiPayloads[0].generationConfig.thinkingConfig.thinkingLevel,
    ).toBe("medium");
    expect(
      observedGeminiPayloads[1].generationConfig.thinkingConfig.thinkingLevel,
    ).toBe("high");
  });

  it("recovers a coalesced unit-id failure at high and returns only original ids", async () => {
    const request = makeDenseRequest({ fingerprint: "8".repeat(64) });
    const unitCount = 280;
    const broken = analysisFor(unitCount);
    // This is a valid raw id but is outside the internal 0...279 unit space.
    broken.chapters[1].end_segment_id = 1399;
    mockGeminiOnce(geminiResponse(broken));
    mockGeminiOnce(geminiResponse(analysisFor(unitCount)));

    const response = await postAnalyze(JSON.stringify(request), {
      authorization: `Bearer ${BEARER}`,
    });

    expect(response.status).toBe(200);
    const body = await response.json();
    expect(
      observedGeminiPayloads.map(
        (payload) =>
          payload.generationConfig.thinkingConfig.thinkingLevel,
      ),
    ).toEqual(["medium", "high"]);
    expect(
      body.chapters.map((chapter) => [
        chapter.start_segment_id,
        chapter.end_segment_id,
      ]),
    ).toEqual([
      [0, 699],
      [700, 1399],
    ]);
    expect(
      body.summary.claims.map((claim) => claim.evidence_segment_id),
    ).toEqual([0, 700, 1395]);
    expect(
      body.warnings.some((warning) =>
        warning.startsWith("invalid_model_output_retried_high:id_discipline"),
      ),
    ).toBe(true);
  });

  it("fails an over-budget result with result_oversized instead of hanging", async () => {
    // 360 segments (7200 s) allow up to 30 chapters; multi-kilobyte titles
    // are only SOFT violations, so this output validates hard-clean while
    // its serialized result exceeds MAX_RESULT_JSON_BYTES.
    const segmentCount = 360;
    const request = makeRequest({
      fingerprint: "d".repeat(64),
      asyncSupported: true,
      segmentCount,
    });
    const chapters = Array.from({ length: 30 }, (_, index) => ({
      title: `Chapter ${index} ${"x".repeat(4000)}`,
      start_segment_id: index * 12,
      end_segment_id: index * 12 + 11,
      confidence: 0.5,
    }));
    const oversized = {
      chapters,
      summary: {
        summary: "s",
        one_line_description: "o",
        claims: [{ text: "c", evidence_segment_id: 0 }],
      },
    };
    mockGeminiOnce(geminiResponse(oversized));

    const submitted = await postAnalyze(JSON.stringify(request), {
      authorization: `Bearer ${BEARER}`,
    });
    expect(submitted.status).toBe(202);

    const failed = await waitForTerminalPoll(request.transcript.fingerprint);
    expect(failed.status).toBe(502);
    expect((await failed.json()).error).toBe("result_oversized");
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
        body: JSON.stringify({
          install_id: "itest-install",
          purpose: "register",
        }),
      });
      expect(response.status).toBe(200);
      const body = await response.json();
      expect(body.challenge_id).toBeTruthy();
      expect(body.challenge).toBeTruthy();
    }

    const capped = await SELF.fetch(`${BASE}/v1/app-attest/challenge`, {
      method: "POST",
      headers: CHALLENGE_HEADERS,
      body: JSON.stringify({
        install_id: "itest-install",
        purpose: "register",
      }),
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
        install_id: "itest-install",
        key_id: bytesToBase64(await sha256Bytes("register-test-key")),
        challenge_id: "no-such-challenge",
        challenge: "plain-challenge",
        attestation_object: "bm90LWEtcmVhbC1hdHRlc3RhdGlvbg==",
      }),
    });
    expect(response.status).toBe(401);
    expect((await response.json()).error).toBe("invalid_challenge");
  });
});
