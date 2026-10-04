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
  runInDurableObject,
} from "cloudflare:test";
import { afterAll, afterEach, beforeAll, describe, expect, it } from "vitest";
import {
  BASE,
  BEARER,
  BOOTSTRAP_PATH,
  EXPECTED_MODEL,
  GEMINI_TRUNCATED_RESPONSE,
  abortedGeminiCalls,
  analysisFor,
  bytesToBase64,
  geminiResponse,
  bearerLimiterStub,
  globalLimiterStub,
  limiterUsage,
  setLimiterUsage,
  installFetchStub,
  jobStub,
  makeDenseRequest,
  makeRequest,
  makeSyntheticAppAttestIdentity,
  mockGeminiDeferred,
  mockGeminiHang,
  mockGeminiOnce,
  mockGeminiReject,
  mockGeminiStatus,
  observedGeminiCallTimes,
  observedGeminiPayloads,
  pendingGeminiResponses,
  postAnalyze,
  postEnvelope,
  counterDiff,
  postPoll,
  readCounters,
  restoreFetchStub,
  seedSyntheticKey,
  sha256Bytes,
  syntheticAssertion,
  waitForCounterDelta,
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
  observedGeminiCallTimes.length = 0;
  abortedGeminiCalls.count = 0;
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
    const countersBefore = await readCounters();
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
    // The inline lane records its spend in the same content-free counters
    // as job runs, plus its own volume counter.
    expect(counterDiff(countersBefore, await readCounters())).toEqual({
      analysis_attempts: 1,
      candidates_tokens: 40,
      prompt_tokens: 120,
      sync_analyses: 1,
      thoughts_tokens: 300,
      total_tokens: 460,
    });
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
    const countersBefore = await readCounters();
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
    const stored = await runInDurableObject(jobStub(request.transcript.fingerprint), async (_instance, state) =>
      JSON.parse(await state.storage.get("job")));
    expect(stored.purge_at - Math.floor(Date.now() / 1000)).toBeGreaterThanOrEqual(86395);
    expect(stored.purge_at - Math.floor(Date.now() / 1000)).toBeLessThanOrEqual(86400);


    const repeated = await postPoll(request.transcript.fingerprint, {
      authorization: `Bearer ${BEARER}`,
    });
    expect(repeated.status).toBe(200);
    expect(await repeated.json()).toEqual(result);

    // One started run, one completion, one attempt's tokens: the attach and
    // the idempotent re-poll bump nothing.
    expect(await waitForCounterDelta(countersBefore, "jobs_completed", 1)).toEqual({
      analysis_attempts: 1,
      candidates_tokens: 40,
      jobs_completed: 1,
      jobs_started: 1,
      prompt_tokens: 120,
      thoughts_tokens: 300,
      total_tokens: 460,
    });
  });

  it("turns an evicted running job into a transient failure on its alarm", async () => {
    const countersBefore = await readCounters();
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
    // The evicted run never returned from Gemini, so no spend is known for
    // it: started and transient-failed, nothing else.
    expect(await waitForCounterDelta(countersBefore, "jobs_failed_transient", 1)).toEqual({
      jobs_failed_transient: 1,
      jobs_started: 1,
    });
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
    const countersBefore = await readCounters();
    mockGeminiOnce(GEMINI_TRUNCATED_RESPONSE);
    mockGeminiOnce(GEMINI_TRUNCATED_RESPONSE);
    mockGeminiOnce(GEMINI_TRUNCATED_RESPONSE);

    const response = await postAnalyze(
      JSON.stringify(makeRequest({ fingerprint: "4".repeat(64) })),
      { authorization: `Bearer ${BEARER}` },
    );

    expect(response.status).toBe(502);
    expect((await response.json()).error).toBe("model_output_truncated");
    // The failure arm still records what the three attempts consumed (the
    // truncated fixture carries no thoughts, so that counter is never
    // written rather than written as zero), which class rejected each
    // attempt, and the terminal code.
    expect(counterDiff(countersBefore, await readCounters())).toEqual({
      analysis_attempts: 3,
      candidates_tokens: 3 * 32768,
      failed_model_output_truncated: 1,
      prompt_tokens: 3 * 120,
      rejected_attempts: 3,
      rejected_truncated: 3,
      sync_analyses: 1,
      total_tokens: 3 * 32888,
    });
  });

  it("fails typed when id-discipline violations survive all three attempts", async () => {
    const countersBefore = await readCounters();
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
    // Every rejected attempt is classed (id discipline takes precedence
    // over the ordering/overlap rules it drags along) and the terminal
    // code gets its own row.
    expect(counterDiff(countersBefore, await readCounters())).toEqual({
      analysis_attempts: 3,
      candidates_tokens: 3 * 40,
      failed_invalid_model_output: 1,
      prompt_tokens: 3 * 120,
      rejected_attempts: 3,
      rejected_id_discipline: 3,
      sync_analyses: 1,
      thoughts_tokens: 3 * 300,
      total_tokens: 3 * 460,
    });
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
    const countersBefore = await readCounters();

    const submitted = await postAnalyze(JSON.stringify(request), {
      authorization: `Bearer ${BEARER}`,
    });
    expect(submitted.status).toBe(202);

    const failed = await waitForTerminalPoll(request.transcript.fingerprint);
    expect(failed.status).toBe(502);
    expect((await failed.json()).error).toBe("result_oversized");
    // The terminal code lands beside jobs_failed_upstream in one write.
    expect(await waitForCounterDelta(countersBefore, "failed_result_oversized", 1)).toEqual({
      analysis_attempts: 1,
      candidates_tokens: 40,
      failed_result_oversized: 1,
      jobs_failed_upstream: 1,
      jobs_started: 1,
      prompt_tokens: 120,
      thoughts_tokens: 300,
      total_tokens: 460,
    });
  });
});

describe("transport ladder", () => {
  // The suite runs the ladder at 10 ms per ladder second (vitest.config):
  // medium cap 1.2 s, high 3 s, budget 5.4 s. Real deadlines, real aborts.
  const LADDER_TEST_TIMEOUT = 30_000;
  const MEDIUM_CAP_MS = 1_200;
  const SUCCESS_SYNC_COUNTERS = {
    analysis_attempts: 1,
    candidates_tokens: 40,
    prompt_tokens: 120,
    sync_analyses: 1,
    thoughts_tokens: 300,
    total_tokens: 460,
  };
  const levels = () =>
    observedGeminiPayloads.map(
      (payload) => payload.generationConfig.thinkingConfig.thinkingLevel,
    );
  const rateLimitBody = () => ({
    error: {
      code: 429,
      message: "Too many requests, try again later.",
      status: "RESOURCE_EXHAUSTED",
    },
  });
  const hardQuotaBody = () => ({
    error: {
      code: 429,
      message: "You exceeded your current quota, please check your plan and billing details.",
      status: "RESOURCE_EXHAUSTED",
    },
  });

  it("times out a stalled header exchange, aborts it, resends once at the same level, and succeeds", async () => {
    const countersBefore = await readCounters();
    mockGeminiHang({ phase: "headers" });
    mockGeminiOnce(geminiResponse(analysisFor(12)));

    const started = performance.now();
    const response = await postAnalyze(
      JSON.stringify(makeRequest({ fingerprint: "9a".repeat(32) })),
      { authorization: `Bearer ${BEARER}` },
    );

    expect(response.status).toBe(200);
    // The deadline released the ladder, not the mock.
    expect(performance.now() - started).toBeGreaterThanOrEqual(MEDIUM_CAP_MS - 100);
    expect(abortedGeminiCalls.count).toBe(1);
    expect(levels()).toEqual(["medium", "medium"]);
    expect((await response.json()).chapters).toHaveLength(2);
    expect(counterDiff(countersBefore, await readCounters())).toEqual({
      ...SUCCESS_SYNC_COUNTERS,
      gemini_call_timeouts: 1,
      transport_retries: 1,
    });
  }, LADDER_TEST_TIMEOUT);

  it("times out a stalled body, aborts it, resends once at the same level, and succeeds", async () => {
    const countersBefore = await readCounters();
    mockGeminiHang({ phase: "body" });
    mockGeminiOnce(geminiResponse(analysisFor(12)));

    const started = performance.now();
    const response = await postAnalyze(
      JSON.stringify(makeRequest({ fingerprint: "9b".repeat(32) })),
      { authorization: `Bearer ${BEARER}` },
    );

    expect(response.status).toBe(200);
    expect(performance.now() - started).toBeGreaterThanOrEqual(MEDIUM_CAP_MS - 100);
    expect(abortedGeminiCalls.count).toBe(1);
    expect(levels()).toEqual(["medium", "medium"]);
    expect(counterDiff(countersBefore, await readCounters())).toEqual({
      ...SUCCESS_SYNC_COUNTERS,
      gemini_call_timeouts: 1,
      transport_retries: 1,
    });
  }, LADDER_TEST_TIMEOUT);

  it("moves to a high attempt after two timeouts and reports the transport warning", async () => {
    const countersBefore = await readCounters();
    mockGeminiHang({ phase: "headers" });
    mockGeminiHang({ phase: "body" });
    mockGeminiOnce(geminiResponse(analysisFor(12)));

    const response = await postAnalyze(
      JSON.stringify(makeRequest({ fingerprint: "9c".repeat(32) })),
      { authorization: `Bearer ${BEARER}` },
    );

    expect(response.status).toBe(200);
    expect((await response.json()).warnings).toContain("gemini_timeout_retried_high");
    expect(abortedGeminiCalls.count).toBe(2);
    expect(levels()).toEqual(["medium", "medium", "high"]);
    expect(counterDiff(countersBefore, await readCounters())).toEqual({
      ...SUCCESS_SYNC_COUNTERS,
      analysis_attempts: 2,
      gemini_call_timeouts: 2,
      transport_retries: 1,
    });
  }, LADDER_TEST_TIMEOUT);

  it("fails with gemini_timeout and the budget counter when every call stalls", async () => {
    const countersBefore = await readCounters();
    const request = makeRequest({
      fingerprint: "9d".repeat(32),
      asyncSupported: true,
    });
    // Attempt 1 (medium): timeout, resend, timeout. Attempt 2 (high) gets
    // the remaining budget, times out, and the resend is refused: the run
    // budget, not the attempt count, ends the run.
    mockGeminiHang({ phase: "headers" });
    mockGeminiHang({ phase: "headers" });
    mockGeminiHang({ phase: "body" });

    const submitted = await postAnalyze(JSON.stringify(request), {
      authorization: `Bearer ${BEARER}`,
    });
    expect(submitted.status).toBe(202);

    const failed = await waitForTerminalPoll(request.transcript.fingerprint);
    expect(failed.status).toBe(503);
    expect((await failed.json()).error).toBe("gemini_timeout");
    expect(abortedGeminiCalls.count).toBe(3);
    expect(levels()).toEqual(["medium", "medium", "high"]);
    expect(await waitForCounterDelta(countersBefore, "jobs_failed_upstream", 1)).toEqual({
      analysis_attempts: 2,
      analysis_budget_exhausted: 1,
      failed_gemini_timeout: 1,
      gemini_call_timeouts: 3,
      jobs_failed_upstream: 1,
      jobs_started: 1,
      transport_retries: 1,
    });
  }, LADDER_TEST_TIMEOUT);

  it("backs off through a 503, a fetch rejection and a rate-limit 429 inside one attempt", async () => {
    const countersBefore = await readCounters();
    mockGeminiStatus(503);
    mockGeminiReject();
    mockGeminiStatus(429, { retryAfter: 1, body: rateLimitBody() });
    mockGeminiOnce(geminiResponse(analysisFor(12)));

    const response = await postAnalyze(
      JSON.stringify(makeRequest({ fingerprint: "9e".repeat(32) })),
      { authorization: `Bearer ${BEARER}` },
    );

    expect(response.status).toBe(200);
    expect(abortedGeminiCalls.count).toBe(0);
    expect(levels()).toEqual(["medium", "medium", "medium", "medium"]);
    expect(counterDiff(countersBefore, await readCounters())).toEqual({
      ...SUCCESS_SYNC_COUNTERS,
      transport_retries: 3,
    });
  }, LADDER_TEST_TIMEOUT);

  it("continues to a high attempt after five fast failures", async () => {
    const countersBefore = await readCounters();
    for (let index = 0; index < 5; index += 1) {
      mockGeminiStatus(503);
    }
    mockGeminiOnce(geminiResponse(analysisFor(12)));

    const response = await postAnalyze(
      JSON.stringify(makeRequest({ fingerprint: "9f".repeat(32) })),
      { authorization: `Bearer ${BEARER}` },
    );

    expect(response.status).toBe(200);
    expect((await response.json()).warnings).toContain(
      "gemini_retry_exhausted_retried_high",
    );
    expect(levels()).toEqual(["medium", "medium", "medium", "medium", "medium", "high"]);
    expect(counterDiff(countersBefore, await readCounters())).toEqual({
      ...SUCCESS_SYNC_COUNTERS,
      analysis_attempts: 2,
      transport_retries: 4,
    });
  }, LADDER_TEST_TIMEOUT);

  it("honours the spent ladder's last Retry-After before the escalated attempt sends", async () => {
    const countersBefore = await readCounters();
    // Five rate-limit 429s asking for 30 s (300 ms at the suite's scale):
    // four pauses inside the ladder, then the fifth is honoured across the
    // attempt boundary rather than dropped with the spent ladder.
    for (let index = 0; index < 5; index += 1) {
      mockGeminiStatus(429, { retryAfter: 30, body: rateLimitBody() });
    }
    mockGeminiOnce(geminiResponse(analysisFor(12)));

    const started = performance.now();
    const response = await postAnalyze(
      JSON.stringify(makeRequest({ fingerprint: "7a".repeat(32) })),
      { authorization: `Bearer ${BEARER}` },
    );

    expect(response.status).toBe(200);
    expect((await response.json()).warnings).toContain(
      "gemini_retry_exhausted_retried_high",
    );
    expect(levels()).toEqual(["medium", "medium", "medium", "medium", "medium", "high"]);
    expect(observedGeminiCallTimes).toHaveLength(6);
    const gaps = observedGeminiCallTimes
      .slice(1)
      .map((time, index) => time - observedGeminiCallTimes[index]);
    // Every gap, the boundary one included, waited the requested 300 ms.
    for (const gap of gaps) {
      expect(gap).toBeGreaterThanOrEqual(280);
    }
    expect(performance.now() - started).toBeGreaterThanOrEqual(5 * 280);
    expect(counterDiff(countersBefore, await readCounters())).toEqual({
      ...SUCCESS_SYNC_COUNTERS,
      analysis_attempts: 2,
      transport_retries: 4,
    });
  }, LADDER_TEST_TIMEOUT);

  it("fails typed with gemini_retry_exhausted after fifteen fast failures", async () => {
    const countersBefore = await readCounters();
    for (let index = 0; index < 15; index += 1) {
      mockGeminiStatus(503);
    }

    const response = await postAnalyze(
      JSON.stringify(makeRequest({ fingerprint: "8a".repeat(32) })),
      { authorization: `Bearer ${BEARER}` },
    );

    expect(response.status).toBe(503);
    expect((await response.json()).error).toBe("gemini_retry_exhausted");
    expect(observedGeminiPayloads).toHaveLength(15);
    expect(counterDiff(countersBefore, await readCounters())).toEqual({
      analysis_attempts: 3,
      failed_gemini_retry_exhausted: 1,
      sync_analyses: 1,
      transport_retries: 12,
    });
  }, LADDER_TEST_TIMEOUT);

  it("stops at a hard-quota 429 after one call", async () => {
    const countersBefore = await readCounters();
    mockGeminiStatus(429, { body: hardQuotaBody() });

    const response = await postAnalyze(
      JSON.stringify(makeRequest({ fingerprint: "8b".repeat(32) })),
      { authorization: `Bearer ${BEARER}` },
    );

    expect(response.status).toBe(503);
    expect((await response.json()).error).toBe("gemini_quota_exhausted");
    expect(observedGeminiPayloads).toHaveLength(1);
    expect(counterDiff(countersBefore, await readCounters())).toEqual({
      analysis_attempts: 1,
      failed_gemini_quota_exhausted: 1,
      sync_analyses: 1,
    });
  });

  it("treats a non-retryable 400 as terminal after one call", async () => {
    const countersBefore = await readCounters();
    mockGeminiStatus(400, { body: { error: { code: 400, message: "bad", status: "INVALID_ARGUMENT" } } });

    const response = await postAnalyze(
      JSON.stringify(makeRequest({ fingerprint: "8c".repeat(32) })),
      { authorization: `Bearer ${BEARER}` },
    );

    expect(response.status).toBe(502);
    expect(await response.json()).toEqual({
      error: "gemini_http_error",
      detail: "status 400",
    });
    expect(observedGeminiPayloads).toHaveLength(1);
    expect(counterDiff(countersBefore, await readCounters())).toEqual({
      analysis_attempts: 1,
      failed_gemini_http_error: 1,
      sync_analyses: 1,
    });
  });

  it("treats an oversized reply as terminal after one call", async () => {
    const countersBefore = await readCounters();
    mockGeminiStatus(200, { rawBody: " ".repeat(600 * 1024) });

    const response = await postAnalyze(
      JSON.stringify(makeRequest({ fingerprint: "8d".repeat(32) })),
      { authorization: `Bearer ${BEARER}` },
    );

    expect(response.status).toBe(503);
    expect((await response.json()).error).toBe("gemini_response_oversized");
    expect(observedGeminiPayloads).toHaveLength(1);
    expect(counterDiff(countersBefore, await readCounters())).toEqual({
      analysis_attempts: 1,
      failed_other: 1,
      sync_analyses: 1,
    });
  });

  it("treats a reply that is not UTF-8 as terminal after one call", async () => {
    const countersBefore = await readCounters();
    mockGeminiStatus(200, { rawBody: new Uint8Array([0xff, 0xfe, 0x7b, 0x7d]) });

    const response = await postAnalyze(
      JSON.stringify(makeRequest({ fingerprint: "8e".repeat(32) })),
      { authorization: `Bearer ${BEARER}` },
    );

    expect(response.status).toBe(503);
    expect((await response.json()).error).toBe("gemini_response_encoding");
    expect(observedGeminiPayloads).toHaveLength(1);
    expect(counterDiff(countersBefore, await readCounters())).toEqual({
      analysis_attempts: 1,
      failed_other: 1,
      sync_analyses: 1,
    });
  });
});

describe("spend caps", () => {
  it("counts a global cap denial by profile without a model call and gives the bearer admission back", async () => {
    const countersBefore = await readCounters();
    const bearerLimiter = await bearerLimiterStub();
    const bearerBefore = await limiterUsage(bearerLimiter);
    // Pre-fill today's global limiter to its declared 60-request cap. The
    // bearer profile admits first (1 of 40), then the global profile refuses
    // — and the bearer admission is released again.
    await setLimiterUsage(globalLimiterStub(), { request_count: 60, estimated_input_tokens: 0 });

    const response = await postAnalyze(
      JSON.stringify(makeRequest({ fingerprint: "d".repeat(64), asyncSupported: true })),
      { authorization: `Bearer ${BEARER}` },
    );
    expect(response.status).toBe(429);
    expect((await response.json()).error).toBe("global_capacity_exhausted");
    expect(await limiterUsage(bearerLimiter)).toEqual(bearerBefore);
    expect(await limiterUsage(globalLimiterStub())).toEqual({ request_count: 60, estimated_input_tokens: 0 });
    expect(counterDiff(countersBefore, await readCounters())).toEqual({
      admission_releases: 1,
      cap_denials_global: 1,
    });
    // Storage is shared across the file: put the limiter back so later
    // submits are not refused by this test's pre-fill.
    await setLimiterUsage(globalLimiterStub(), null);
  });

  it("returns 404 for an unknown limiter route without touching usage", async () => {
    const bearerLimiter = await bearerLimiterStub();
    const before = await limiterUsage(bearerLimiter);
    const response = await bearerLimiter.fetch("https://usage-limiter.opencast.internal/refund", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ estimated_input_tokens: 1, profile: "bearer" }),
    });
    expect(response.status).toBe(404);
    expect((await response.json()).error).toBe("not_found");
    const wrongMethod = await bearerLimiter.fetch("https://usage-limiter.opencast.internal/release", {
      method: "GET",
    });
    expect(wrongMethod.status).toBe(405);
    expect(await limiterUsage(bearerLimiter)).toEqual(before);
  });

  it("saturates a release at zero and never recreates a wiped day object", async () => {
    const bearerLimiter = await bearerLimiterStub();
    await setLimiterUsage(bearerLimiter, { request_count: 1, estimated_input_tokens: 500 });
    const release = (tokens) =>
      bearerLimiter.fetch("https://usage-limiter.opencast.internal/release", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ estimated_input_tokens: tokens, profile: "bearer" }),
      });
    // Releasing more than was admitted clamps rather than wrapping.
    let response = await release(10_000);
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ request_count: 0, estimated_input_tokens: 0 });
    // A second release of the same admission changes nothing and writes
    // nothing: the object at zero stays at zero.
    response = await release(1);
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ request_count: 0, estimated_input_tokens: 0 });
    expect(await limiterUsage(bearerLimiter)).toEqual({ request_count: 0, estimated_input_tokens: 0 });
    // A release never schedules the object's cleanup: only an admit does.
    await setLimiterUsage(bearerLimiter, null);
    await runInDurableObject(bearerLimiter, async (_instance, state) => {
      await state.storage.deleteAlarm();
    });
    response = await release(1);
    expect(response.status).toBe(200);
    expect(
      await runInDurableObject(bearerLimiter, (_instance, state) => state.storage.getAlarm()),
    ).toBeNull();
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
