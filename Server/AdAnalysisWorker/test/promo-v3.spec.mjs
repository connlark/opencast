// Real compiled wasm, D1 and DO paths; no paid model or network access.
import { SELF, abortAllDurableObjects, env, runInDurableObject, runDurableObjectAlarm } from "cloudflare:test";
import { afterAll, afterEach, beforeAll, expect, it } from "vitest";
import fixture from "../eval/fixtures/promo-carousel.json";

const base = "https://v3.integration.test";
const path = "/v1/ad-analysis/transcript";
const headers = {
  "content-type": "application/json",
  authorization: "Bearer integration-test-bearer-token",
};
const responses = [];
const payloads = [];
const originalFetch = globalThis.fetch;
const span = {
  kind: "house_or_network_promo",
  label: "Trailer carousel",
  start_segment_id: 20,
  end_segment_id: 50,
  confidence: 0.95,
  evidence_quote: "this is Harbor Letters",
  start_quote: "I'm Mira",
  end_quote: "wherever you get podcasts",
};

function reply(spans, finishReason = "STOP") {
  return {
    candidates: [
      {
        finishReason,
        content: { parts: [{ text: JSON.stringify({ spans }) }] },
      },
    ],
    usageMetadata: {
      promptTokenCount: 100,
      candidatesTokenCount: 40,
      thoughtsTokenCount: 10,
      totalTokenCount: 150,
    },
  };
}

function request(asyncSupported = false) {
  const result = structuredClone(fixture);
  result.request_id = crypto.randomUUID();
  result.transcript.fingerprint = result.request_id
    .replaceAll("-", "")
    .repeat(2);
  result.async_supported = asyncSupported;
  return result;
}

function analyze(body) {
  return SELF.fetch(base + path, {
    method: "POST",
    headers,
    body: JSON.stringify(body),
  });
}

async function terminal(body, internal = false) {
  for (let i = 0; i < 100; i++) {
    const url = internal
      ? `https://opencast-ad-analysis.internal/internal/v1/jobs/${body.transcript.fingerprint}/poll`
      : `${base}/v1/ad-analysis/jobs/${body.transcript.fingerprint}`;
    const response = await SELF.fetch(url, {
      method: "POST",
      headers,
      body: JSON.stringify({ job_id: body.transcript.fingerprint }),
    });
    if (response.status !== 202) return response;
    await new Promise((resolve) => setTimeout(resolve, 1));
  }
  throw new Error("v3 job never completed");
}

beforeAll(() => {
  globalThis.fetch = async (input, init) => {
    expect(input.url).toBe(
      "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.8-flash:generateContent",
    );
    const payload = await input.json();
    payloads.push(payload);
    if (!responses.length) throw new Error("Unexpected paid call");
    const pending = responses.shift();
    const body = typeof pending === "function" ? await pending(input, init, payload) : pending;
    if (body instanceof Response) return body;
    if (body?.responseStatus) return new Response(JSON.stringify(body.responseBody), {status: body.responseStatus, headers: body.responseHeaders});
    return new Response(JSON.stringify(body), {
      headers: { "content-type": "application/json" },
    });
  };
});
afterEach(async () => {
  try {
    expect(responses).toHaveLength(0);
  } finally {
    responses.length = 0;
    payloads.length = 0;
    await abortAllDurableObjects();
  }
});
afterAll(() => {
  globalThis.fetch = originalFetch;
});

it("keeps auth in front of every model call", async () => {
  const response = await SELF.fetch(base + path, {
    method: "POST",
    headers: { ...headers, authorization: "Bearer wrong-token" },
    body: JSON.stringify(request()),
  });
  expect(response.status).toBe(401);
  expect(payloads).toHaveLength(0);
});

it("serves the pinned v3 bundle and a complete validated break", async () => {
  responses.push(reply([span]));
  const response = await analyze(request());
  expect(response.status).toBe(200);
  const body = await response.json();
  expect(body.policy).toBe("promo_ad_breaks_v3");
  expect(body.model).toBe("gemini-3.8-flash");
  expect(body.spans).toHaveLength(1);
  expect(body.spans[0].start_boundary).toEqual({ segment_id: 20, quote: "I'm Mira" });
  expect(body.spans[0].end_boundary).toEqual({ segment_id: 50, quote: "wherever you get podcasts" });
  expect(body.warnings).toEqual([]);
  expect(body.usage.total_token_count).toBe(150);
  expect(payloads[0].systemInstruction).toBeTruthy();
  expect(payloads[0].generationConfig.thinkingConfig.thinkingLevel).toBe(
    "medium",
  );
  const input = JSON.parse(payloads[0].contents[0].parts[0].text);
  expect(input.segments[0]).not.toHaveProperty("start");
});

it("includes a short mixed boundary without inventing a word timestamp", async () => {
  const input = request();
  input.segments[1].text = `Okay, finished. ${input.segments[1].text}`;
  input.segments[1].end = 169;
  responses.push(reply([span]));
  const response = await analyze(input);
  expect(response.status).toBe(200);
  const body = await response.json();
  expect(body.spans[0].start_segment_id).toBe(20);
  expect(body.spans[0].start_time).toBe(161);
  expect(body.warnings).toEqual(["v3_short_mixed_boundary_included:20-50"]);
});

it("repairs a wrong existing boundary and accounts for both calls", async () => {
  responses.push(reply([{ ...span, start_segment_id: 10 }]), reply([span]));
  const response = await analyze(request());
  expect(response.status).toBe(200);
  const body = await response.json();
  expect(body.spans[0].start_segment_id).toBe(20);
  expect(body.warnings).toContain("v3_semantic_repair");
  expect(body.usage.total_token_count).toBe(300);
  expect(payloads[1].contents).toHaveLength(3);
});

it("does not turn a dropped bad candidate into successful empty coverage", async () => {
  responses.push(reply([{ ...span, start_segment_id: 10 }]), reply([]));
  const response = await analyze(request());
  expect(response.status).toBe(422);
  expect(await response.json()).toMatchObject({ error: "ad_analysis_incomplete", failure: { category: "validation_exhausted", retry_disposition: "explicit_retry" } });
  expect(payloads).toHaveLength(2);
});

it("can correct a nonexistent evidence quote while retaining the same break", async () => {
  responses.push(
    reply([
      {
        ...span,
        evidence_quote: "a hallucinated sentence absent from the source",
      },
    ]),
    reply([span]),
  );
  const response = await analyze(request());
  expect(response.status).toBe(200);
  const body = await response.json();
  expect(body.spans[0].start_segment_id).toBe(20);
  expect(body.spans[0].end_segment_id).toBe(50);
  expect(body.warnings).toContain("v3_semantic_repair");
  expect(payloads).toHaveLength(2);
});

it("rejects syntactically valid truncated output after one correction", async () => {
  responses.push(reply([], "MAX_TOKENS"), reply([], "MAX_TOKENS"));
  const response = await analyze(request());
  expect(response.status).toBe(422);
  expect(payloads).toHaveLength(2);
});

it("cannot erase an unknown-ID occurrence by keeping its earlier repeated trailer", async () => {
  const second = {
    ...span,
    start_segment_id: 80,
    end_segment_id: 100,
    end_quote: "the stories the harbor kept",
  };
  for (const corrected of [[span], [span, second]]) {
    responses.push(
      reply([span, { ...second, start_segment_id: 9999 }]),
      reply(corrected),
    );
    const response = await analyze(request());
    expect(response.status).toBe(corrected.length === 1 ? 422 : 200);
  }
});

it("retains an automatic skip when another window repeats it at lower confidence", async () => {
  responses.push(reply([{ ...span, confidence: 0.7 }, span]));
  const response = await analyze(request());
  expect(response.status).toBe(200);
  const body = await response.json();
  expect(
    body.spans.some(
      (s) =>
        s.start_segment_id === 20 &&
        s.end_segment_id === 50 &&
        s.confidence >= 0.8,
    ),
  ).toBe(true);
});

it("round trips and reuses an async v3 job without another model call", async () => {
  let release;
  const gate = new Promise(resolve => { release = resolve; });
  responses.push(async () => { await gate; return reply([span]); });
  const body = request(true);
  const accepted = await analyze(body);
  expect(accepted.status).toBe(202);
  expect((await accepted.json()).job_id).toBe(body.transcript.fingerprint);
  const running = await SELF.fetch(`${base}/v1/ad-analysis/jobs/${body.transcript.fingerprint}`, {
    method: "POST", headers, body: JSON.stringify({job_id: body.transcript.fingerprint})
  });
  expect(running.status).toBe(202);
  expect((await running.json()).job_id).toBe(body.transcript.fingerprint);
  release();
  const result = await terminal(body);
  expect(result.status).toBe(200);
  expect((await result.json()).policy).toBe("promo_ad_breaks_v3");
  expect((await analyze(body)).status).toBe(200);
  expect(payloads).toHaveLength(1);
});

it("serves the same policy through the internal transcription binding", async () => {
  responses.push(reply([span]));
  const body = request(true);
  const submitted = await SELF.fetch(
    "https://opencast-ad-analysis.internal/internal/v1/analyze",
    {
      method: "POST",
      headers,
      body: JSON.stringify({
        schema_version: 1,
        account_id: "integration-v3",
        request: body,
      }),
    },
  );
  expect(submitted.status).toBe(202);
  const response = await terminal(body, true);
  expect(response.status).toBe(200);
  expect((await response.json()).policy).toBe("promo_ad_breaks_v3");
});

it("reconciles a break crossing a local window boundary without an island", async () => {
  const body = request();
  body.segments = Array.from({ length: 1000 }, (_, id) => ({
    id,
    start: id,
    end: id + 1,
    text:
      id === 720
        ? "Listen to Harbor Stories."
        : id === 820
          ? "Subscribe today."
          : id > 720 && id < 820
            ? "A story about the harbor."
            : "Boatbuilding discussion continues.",
  }));
  body.transcript.segment_count = 1000;
  body.transcript.audio_duration = 1000;
  const first = {
    ...span,
    start_segment_id: 720,
    end_segment_id: 799,
    start_quote: "Listen to Harbor Stories",
    end_quote: "A story about the harbor",
    evidence_quote: "Listen to Harbor Stories",
  };
  const windowReply = (_input, _init, payload) => {
    const window = JSON.parse(payload.contents[0].parts[0].text);
    return reply([window.segments[0].id === 0 ? first
      : { ...first, end_segment_id: 820, end_quote: "Subscribe today" }]);
  };
  responses.push(windowReply, windowReply);
  const response = await analyze(body);
  expect(response.status).toBe(200);
  const result = await response.json();
  expect(result.spans).toHaveLength(1);
  expect(result.spans[0].start_segment_id).toBe(720);
  expect(result.spans[0].end_segment_id).toBe(820);
  expect(payloads).toHaveLength(2);
});

it("bounds nine local windows to four simultaneous upstream exchanges", async () => {
  const body = request();
  body.segments = Array.from({ length: 6000 }, (_, id) => ({
    id,
    start: id,
    end: id + 1,
    text: "Boatbuilding discussion continues.",
  }));
  body.transcript.segment_count = 6000;
  body.transcript.audio_duration = 6000;
  let active = 0;
  let maximum = 0;
  let release;
  const gate = new Promise((resolve) => {
    release = resolve;
  });
  for (let i = 0; i < 9; i++)
    responses.push(async () => {
      active++;
      maximum = Math.max(maximum, active);
      if (i < 4) await gate;
      active--;
      return reply([]);
    });
  const pending = analyze(body);
  for (let i = 0; i < 100 && active < 4; i++)
    await new Promise((resolve) => setTimeout(resolve, 1));
  const initial = active;
  release();
  const response = await pending;
  expect(initial).toBe(4);
  expect(maximum).toBe(4);
  expect(response.status).toBe(200);
  expect(payloads).toHaveLength(9);
});


function responseError(status, retryAfter, message = "temporary overload") {
  return {responseStatus: status, responseBody: {error: {code: status, message, status: "RESOURCE_EXHAUSTED"}},
    responseHeaders: {"content-type": "application/json", ...(retryAfter == null ? {} : {"retry-after": String(retryAfter)})}};
}
function longRequest(count = 6000) {
  const body = request();
  body.segments = Array.from({length: count}, (_, id) => ({id, start: id, end: id + 1, text: "Boatbuilding discussion continues."}));
  body.transcript.segment_count = count;
  body.transcript.audio_duration = count;
  return body;
}

it("recovers a retryable 429 with admissible Retry-After and keeps unknown usage charged", async () => {
  responses.push(responseError(429, 0), reply([span]));
  const response = await analyze(request());
  expect(response.status).toBe(200);
  const result = await response.json();
  expect(payloads).toHaveLength(2);
  expect(result.accounting).toMatchObject({request_count: 1, dispatched_attempts: 2, unknown_attempts: 1});
  expect(result.accounting.reported_usage.prompt_token_count).toBe(100);
  expect(result.accounting.dispatched_input_tokens).toBeGreaterThan(100);
});

it.each(["http", "transport"])("recovers a transient %s failure within the initial transport budget", async (kind) => {
  responses.push(kind === "http" ? responseError(503, 0) : () => { throw new TypeError("mock transport failure"); }, reply([span]));
  const response = await analyze(request());
  expect(response.status).toBe(200);
  expect((await response.json()).accounting.dispatched_attempts).toBe(2);
}, 10000);

it("refuses a backoff that cannot fit its admitted bound", async () => {
  responses.push(responseError(429, 11));
  const response = await analyze(request());
  expect(response.status).toBe(503);
  expect(await response.json()).toMatchObject({error: "analysis_deadline_exhausted", accounting: {dispatched_attempts: 1, unknown_attempts: 1}});
  expect(payloads).toHaveLength(1);
});

it("stops at hard billing quota without a transport retry", async () => {
  responses.push(responseError(429, 0, "You exceeded your current quota, please check your plan and billing details"));
  const response = await analyze(request());
  expect(response.status).toBe(503);
  expect(await response.json()).toMatchObject({error: "gemini_quota_exhausted", failure: {category: "capacity"}});
  expect(payloads).toHaveLength(1);
});

it("observes a later terminal window while the first bodies stall and aborts issued fetches", async () => {
  let aborted = 0;
  let started = 0;
  let releaseFailure;
  const gate = new Promise(resolve => { releaseFailure = resolve; });
  for (let i = 0; i < 3; i++) responses.push((input, init) => {
    started++;
    const signal = init?.signal ?? input.signal;
    return new Response(new ReadableStream({
      start(controller) {
        signal.addEventListener("abort", () => { aborted++; controller.error(new Error("aborted")); }, {once: true});
      }
    }));
  });
  responses.push(async () => {
    started++;
    await gate;
    return responseError(429, 0, "You exceeded your current quota, please check your plan and billing details");
  });
  const pending = analyze(longRequest());
  for (let i = 0; i < 1000 && started < 4; i++) await new Promise(resolve => setTimeout(resolve, 1));
  expect(started).toBe(4);
  releaseFailure();
  const result = await pending;
  expect(result.status).toBe(503);
  expect(payloads).toHaveLength(4);
  expect(aborted).toBe(3);
  expect(await result.json()).toMatchObject({accounting: {request_count: 1, dispatched_attempts: 4, unknown_attempts: 4}});
}, 10000);

it("retains validation failure on repeated polls/submits and accepts an explicit bounded correction", async () => {
  const body = request(true);
  body.job_handle_version = 1;
  responses.push(reply([{...span, start_segment_id: 10}]), reply([]));
  const accepted = await (await analyze(body)).json();
  expect(accepted.job_id).toBe(`a3.20260911b.${body.transcript.fingerprint}`);
  const poll = () => SELF.fetch(`${base}/v1/ad-analysis/jobs/${accepted.job_id}`, {
    method: "POST", headers, body: JSON.stringify({job_id: accepted.job_id})
  });
  let failed;
  for (let i = 0; i < 1000; i++) {
    failed = await poll();
    if (failed.status !== 202) break;
    await new Promise(resolve => setTimeout(resolve, 1));
  }
  expect(failed.status).toBe(422);
  const failedStub = env.AD_ANALYSIS_JOB.getByName(`ad-analysis:v3:2026-09-11.2-recovery:flash38-medium:w800:r1:job:${body.transcript.fingerprint}`);
  const failedRecord = await runInDurableObject(failedStub, async (_instance, state) => JSON.parse(await state.storage.get("job")));
  expect(failedRecord.purge_at - Math.floor(Date.now() / 1000)).toBeGreaterThanOrEqual(1795);
  expect(failedRecord.purge_at - Math.floor(Date.now() / 1000)).toBeLessThanOrEqual(1800);
  expect(await failed.json()).toMatchObject({failure: {category: "validation_exhausted", retry_disposition: "explicit_retry", policy_revision: "2026-09-11.2-recovery"}, accounting: {request_count: 1, dispatched_attempts: 2}});
  expect((await poll()).status).toBe(422);
  expect((await analyze(body)).status).toBe(422);
  expect(payloads).toHaveLength(2);
  body.retry_failed = true;
  responses.push(reply([span]));
  expect((await analyze(body)).status).toBe(202);
  for (let i = 0; i < 1000; i++) {
    failed = await poll();
    if (failed.status !== 202) break;
    await new Promise(resolve => setTimeout(resolve, 1));
  }
  expect(failed.status).toBe(200);
  expect(payloads).toHaveLength(3);
  const completedStub = env.AD_ANALYSIS_JOB.getByName(`ad-analysis:v3:2026-09-11.2-recovery:flash38-medium:w800:r1:job:${body.transcript.fingerprint}`);
  const completedRecord = await runInDurableObject(completedStub, async (_instance, state) => JSON.parse(await state.storage.get("job")));
  expect(completedRecord.purge_at - Math.floor(Date.now() / 1000)).toBeGreaterThanOrEqual(86395);
  expect(completedRecord.purge_at - Math.floor(Date.now() / 1000)).toBeLessThanOrEqual(86400);

});

it("polls a retained revision-A record while new submissions select isolated revision B", async () => {
  const body = request(true);
  body.job_handle_version = 1;
  const fingerprint = body.transcript.fingerprint;
  const oldHandle = `a3.20260911a.${fingerprint}`;
  const old = env.AD_ANALYSIS_JOB.getByName(`ad-analysis:v3:2026-09-11.1-word-boundaries:flash38-medium:w800:r1:job:${fingerprint}`);
  await runInDurableObject(old, async (_instance, state) => {
    await state.storage.put("job", JSON.stringify({state: "completed", job_id: fingerprint, subjects: [], content_hash: "", purge_at: Math.floor(Date.now()/1000) + 600,
      result_json: JSON.stringify({policy: "promo_ad_breaks_v3", policy_revision: "2026-09-11.1-word-boundaries", spans: []})}));
  });
  const poll = id => SELF.fetch(`${base}/v1/ad-analysis/jobs/${id}`, {method: "POST", headers, body: JSON.stringify({job_id: id})});
  expect((await (await poll(oldHandle)).json()).policy_revision).toBe("2026-09-11.1-word-boundaries");
  expect(payloads).toHaveLength(0);
  responses.push(reply([span]));
  expect((await (await analyze(body)).json()).job_id).toBe(`a3.20260911b.${fingerprint}`);
  for (let i = 0; i < 1000; i++) {
    if ((await poll(`a3.20260911b.${fingerprint}`)).status !== 202) break;
    await new Promise(resolve => setTimeout(resolve, 1));
  }
  expect((await (await poll(oldHandle)).json()).policy_revision).toBe("2026-09-11.1-word-boundaries");
  expect((await poll(fingerprint)).status).toBe(409); // legacy ID cannot choose between bundles
  expect((await poll(`a3.unknown.${fingerprint}`)).status).toBe(404);
  await runInDurableObject(old, async (_instance, state) => {
    const record = JSON.parse(await state.storage.get("job"));
    record.subjects = ["another-subject"];
    record.content_hash = "another-content";
    await state.storage.put("job", JSON.stringify(record));
  });
  expect((await poll(oldHandle)).status).toBe(404);
  expect(payloads).toHaveLength(1);
});


it("denies a repair before another provider hit when global input capacity is exhausted", async () => {
  const day = Math.floor(Date.now()/86400000);
  const global = env.AD_ANALYSIS_USAGE_LIMITER.getByName(`ad-analysis:v1:usage:${day}:global`);
  const charged = await runInDurableObject(global, async (_instance, state) =>
    state.storage.sql.exec("SELECT COALESCE(SUM(input_tokens),0) AS tokens FROM accounted_runs").one().tokens);
  const previous = await runInDurableObject(global, async (_instance, state) =>
    state.storage.sql.exec("SELECT * FROM daily_usage WHERE id = 1").toArray());
  try {
  const occupied = await global.fetch("https://usage-limiter.opencast.internal/admit", {
    method: "POST", body: JSON.stringify({profile: "global", estimated_input_tokens: 8000000 - charged - 5000})
  });
  expect(occupied.status).toBe(200);
  responses.push(reply([{...span, start_segment_id: 10}]));
  const response = await analyze(request());
  expect(response.status).toBe(429);
  const result = await response.json();
  expect(result.failure.category).toBe("capacity");
  expect(result.accounting).toMatchObject({request_count: 1, dispatched_attempts: 1, unknown_attempts: 0});
  expect(result.accounting.reported_usage.prompt_token_count).toBe(100);
  expect(payloads).toHaveLength(1);
  } finally {
    await runInDurableObject(global, async (_instance, state) => {
      state.storage.sql.exec("DELETE FROM daily_usage WHERE id = 1");
      for (const row of previous) state.storage.sql.exec(
        "INSERT INTO daily_usage (id, request_count, estimated_input_tokens) VALUES (1, ?, ?)",
        row.request_count, row.estimated_input_tokens);
    });
  }
});

it("persists one atomic caller/global charge and releases a crashed unstarted hold idempotently", async () => {
  const day = Math.floor(Date.now()/86400000);
  const global = env.AD_ANALYSIS_USAGE_LIMITER.getByName(`ad-analysis:v1:usage:${day}:global`);
  const identity = {run_id: "run-idempotent-123", subject: "caller-for-accounting", profile: "app_attest_key", day,
    legacy_caller: {request_count: 0, estimated_input_tokens: 0}};
  const account = operation => global.fetch("https://usage-limiter.opencast.internal/account", {
    method: "POST", body: JSON.stringify({...identity, operation})
  });
  const admit = {operation: "admit", execution_tokens: 10000, expires_at: Math.floor(Date.now()/1000)+600};
  expect((await account(admit)).status).toBe(200);
  expect((await account(admit)).status).toBe(200);
  expect((await account({operation: "reserve", attempt: 0, input_tokens: 1000})).status).toBe(200);
  const finished = await (await account({operation: "finish"})).json();
  expect(finished).toMatchObject({request_count: 0, dispatched_attempts: 0, released_input_tokens: 1000, reserved_input_tokens: 0});
  expect(await (await account({operation: "finish"})).json()).toEqual(finished);
  const totals = await runInDurableObject(global, async (_instance, state) =>
    state.storage.sql.exec("SELECT COUNT(*) AS runs, SUM(request_count) AS requests, SUM(input_tokens) AS tokens FROM accounted_runs WHERE subject = 'caller-for-accounting'").one());
  expect(totals).toEqual({runs: 1, requests: 0, tokens: 0});
  expect((await account({operation: "dispatch", attempt: 0})).status).toBe(503);
  expect(payloads).toHaveLength(0);
});

it("merges out-of-order successful windows deterministically", async () => {
  const body = longRequest(1600);
  const ids = [50, 1000, 1500];
  for (const id of ids) body.segments[id].text = "This episode is brought to you by Seed Sponsor. Purchase today.";
  let releaseFirst;
  const gate = new Promise(resolve => { releaseFirst = resolve; });
  const completed = [];
  const windowReply = async (_input, _init, payload) => {
    const window = JSON.parse(payload.contents[0].parts[0].text);
    const index = window.segments[0].id / 680;
    const id = ids[index];
    if (index === 0) await gate;
    completed.push(index);
    if (index === 2) releaseFirst();
    return reply([{kind: "host_read_ad", label: `Sponsor ${index}`, start_segment_id:id, end_segment_id:id,
      confidence:0.95, evidence_quote:"brought to you by Seed Sponsor", start_quote:"This episode", end_quote:"Purchase today"}]);
  };
  responses.push(windowReply, windowReply, windowReply);
  const response = await analyze(body);
  expect(response.status).toBe(200);
  expect(completed[0]).not.toBe(0);
  const result = await response.json();
  expect(result.spans.map(span => span.start_segment_id)).toEqual(ids);
  expect(result.accounting).toMatchObject({request_count:1, dispatched_attempts:3, unknown_attempts:0});
});

it("times out a stalled response body, aborts its fetch, and bounds recovery", async () => {
  let aborted = false;
  responses.push((input, init) => new Response(new ReadableStream({
    start(controller) {
      const signal = init?.signal ?? input.signal;
      signal.addEventListener("abort", () => { aborted = true; controller.error(new Error("aborted")); }, {once:true});
    }
  })), reply([span]));
  const start = performance.now();
  const response = await analyze(request());
  expect(response.status).toBe(200);
  expect(aborted).toBe(true);
  expect(performance.now() - start).toBeGreaterThanOrEqual(59_000);
  expect(payloads).toHaveLength(2);
  expect(await response.json()).toMatchObject({accounting:{request_count:1, dispatched_attempts:2, unknown_attempts:1}});
}, 90_000);

it("keeps an interrupted revision-A job addressable after revision B is selected", async () => {
  const fingerprint = crypto.randomUUID().replaceAll("-", "").repeat(2);
  const handle = `a3.20260911a.${fingerprint}`;
  const old = env.AD_ANALYSIS_JOB.getByName(`ad-analysis:v3:2026-09-11.1-word-boundaries:flash38-medium:w800:r1:job:${fingerprint}`);
  await runInDurableObject(old, async (_instance, state) => {
    await state.storage.put("job", JSON.stringify({state:"running",job_id:fingerprint,subjects:[],content_hash:"",started_at:Math.floor(Date.now()/1000),deadline_at:Math.floor(Date.now()/1000)+600}));
    await state.storage.setAlarm(Date.now()+1000);
  });
  const poll = () => SELF.fetch(`${base}/v1/ad-analysis/jobs/${handle}`, {method:"POST",headers,body:JSON.stringify({job_id:handle})});
  expect((await poll()).status).toBe(202);
  await abortAllDurableObjects();
  const revived = env.AD_ANALYSIS_JOB.getByName(`ad-analysis:v3:2026-09-11.1-word-boundaries:flash38-medium:w800:r1:job:${fingerprint}`);
  expect(await runDurableObjectAlarm(revived)).toBe(true);
  const failed = await poll();
  expect(failed.status).toBe(503);
  expect(await failed.json()).toMatchObject({error:"job_failed_transient",failure:{category:"interrupted_job",retry_disposition:"bounded_retry"}});
  expect(payloads).toHaveLength(0);
});
