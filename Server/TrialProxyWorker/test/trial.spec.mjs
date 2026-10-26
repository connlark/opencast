// Workerd-local integration tests: real HTTP requests through the compiled
// wasm Worker with local D1 and the TrialLedger Durable Object, and Gemini
// stubbed by replacing the global `fetch` inside the isolate (the Worker's
// outbound calls go through it; binding traffic does not). Requires
// `build/index.js` (`yarn build:worker`).
import {
  SELF,
  env,
  runDurableObjectAlarm,
  runInDurableObject,
} from "cloudflare:test";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import carousel from "../../../Packages/OpenCastAnalysis/Tests/OpenCastAnalysisTests/Fixtures/providers/gemini-carousel-success.json";

const BASE = "https://trial.integration.test";
const BEARER = "integration-test-bearer-token";
const GEMINI_KEY = "integration-test-gemini-key";
const MODEL = "gemini-3.8-flash";
const GENERATE_URL = `https://generativelanguage.googleapis.com/v1beta/models/${MODEL}:generateContent`;
const COUNT_URL = `https://generativelanguage.googleapis.com/v1beta/models/${MODEL}:countTokens`;
const APP_ID = `${env.APPLE_TEAM_ID}.${env.APPLE_BUNDLE_ID}`;
const CANARY = "CANARY-TRANSCRIPT-91c4";
const DEVICE_BODY = JSON.parse(carousel.request.body);

const REPLY = {
  candidates: [
    {
      content: { parts: [{ text: carousel.response.body ? JSON.parse(carousel.response.body).candidates[0].content.parts[0].text : "{}" }] },
      finishReason: "STOP",
    },
  ],
  usageMetadata: {
    promptTokenCount: 2039,
    candidatesTokenCount: 377,
    thoughtsTokenCount: 10349,
    totalTokenCount: 12765,
  },
  modelVersion: MODEL,
};

const realFetch = globalThis.fetch;
let outbound = [];
let generateReplies = [];
let countReplies = [];

// A reply is built when the Worker fetches: a Response created in another
// request's context cannot be read from this one.
function reply(body, status = 200, headers = {}) {
  return () =>
    new Response(typeof body === "string" ? body : JSON.stringify(body), {
      status,
      headers: { "content-type": "application/json; charset=UTF-8", ...headers },
    });
}

function installFetchStub() {
  globalThis.fetch = async (input, init) => {
    const request = input instanceof Request ? input : new Request(input, init);
    const body = await request.clone().text();
    outbound.push({
      url: request.url,
      method: request.method,
      redirect: request.redirect,
      headers: Object.fromEntries(request.headers.entries()),
      body,
    });
    if (request.url === COUNT_URL) {
      return (countReplies.shift() ?? reply({ totalTokens: 2039 }))(request);
    }
    if (request.url === GENERATE_URL) {
      const next = generateReplies.shift();
      if (next === undefined) throw new Error("unexpected generateContent call");
      return next(request);
    }
    throw new Error(`unexpected outbound fetch: ${request.url}`);
  };
}

beforeEach(() => {
  outbound = [];
  generateReplies = [];
  countReplies = [];
  installFetchStub();
});

afterEach(() => {
  globalThis.fetch = realFetch;
  vi.useRealTimers();
  expect(generateReplies).toHaveLength(0);
});

function wrapper(request, overrides = {}) {
  return {
    feature: "ad_detection",
    run_id: crypto.randomUUID().toUpperCase(),
    window_index: 0,
    request,
    ...overrides,
  };
}

function bearerAnalyze(body, { headers = {}, query = "" } = {}) {
  return SELF.fetch(`${BASE}/v1/trial/analyze${query}`, {
    method: "POST",
    headers: {
      authorization: `Bearer ${BEARER}`,
      "content-type": "application/json",
      ...headers,
    },
    body: typeof body === "string" ? body : JSON.stringify(body),
  });
}

function ledger() {
  return env.TRIAL_LEDGER.get(env.TRIAL_LEDGER.idFromName("global"));
}

async function dumpLedger() {
  return runInDurableObject(ledger(), async (_instance, state) => {
    const tables = state.storage.sql
      .exec("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE '\\_%' ESCAPE '\\'")
      .toArray()
      .map((row) => row.name);
    const out = {};
    for (const table of tables) {
      out[table] = state.storage.sql.exec(`SELECT * FROM ${table}`).toArray();
    }
    return out;
  });
}

// Ledger storage outlives a single test here (and some tests fake the
// clock), so a test finds its reservation by the id it did not see before.
async function reservationIds() {
  return new Set(((await dumpLedger()).reservations ?? []).map((row) => row.id));
}

async function newReservation(before) {
  const fresh = ((await dumpLedger()).reservations ?? []).filter((row) => !before.has(row.id));
  expect(fresh).toHaveLength(1);
  return fresh[0];
}

async function newestReservation(action) {
  const before = await reservationIds();
  const result = await action();
  return { result, row: await newReservation(before) };
}

// ---------------------------------------------------------------- App Attest

async function sha256Bytes(value) {
  const bytes = typeof value === "string" ? new TextEncoder().encode(value) : value;
  return new Uint8Array(await crypto.subtle.digest("SHA-256", bytes));
}

function bytesToBase64(bytes) {
  return btoa(String.fromCharCode(...bytes));
}

function bytesToHex(bytes) {
  return Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
}

function concatBytes(...parts) {
  const result = new Uint8Array(parts.reduce((total, part) => total + part.length, 0));
  let offset = 0;
  for (const part of parts) {
    result.set(part, offset);
    offset += part.length;
  }
  return result;
}

function derInteger(bytes) {
  let first = 0;
  while (first < bytes.length - 1 && bytes[first] === 0) first += 1;
  let value = bytes.slice(first);
  if ((value[0] & 0x80) !== 0) value = concatBytes(Uint8Array.of(0), value);
  return concatBytes(Uint8Array.of(0x02, value.length), value);
}

function ecdsaSignatureDER(signature) {
  // WebCrypto yields raw r||s; never sniff for DER by the leading byte.
  if (signature.length !== 64) throw new Error(`unexpected signature length ${signature.length}`);
  const r = derInteger(signature.slice(0, 32));
  const s = derInteger(signature.slice(32));
  return concatBytes(Uint8Array.of(0x30, r.length + s.length), r, s);
}

function cborByteString(bytes) {
  return concatBytes(Uint8Array.of(0x58, bytes.length), bytes);
}

function cborText(value) {
  const bytes = new TextEncoder().encode(value);
  return concatBytes(Uint8Array.of(0x60 + bytes.length), bytes);
}

async function makeIdentity() {
  const keys = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
  const publicKey = new Uint8Array(await crypto.subtle.exportKey("raw", keys.publicKey));
  const identity = {
    // The app's install id: `UUID().uuidString`.
    installID: crypto.randomUUID().toUpperCase(),
    keyID: bytesToBase64(await sha256Bytes(publicKey)),
    privateKey: keys.privateKey,
    publicKey,
    counter: 0,
  };
  const now = Math.floor(Date.now() / 1000);
  await env.TRIAL_DB.prepare(
    "INSERT INTO app_attest_keys (install_id, key_id, public_key, sign_counter, app_id, environment, created_at, last_used_at) \
     VALUES (?1, ?2, ?3, 0, ?4, 'development', ?5, ?5)",
  )
    .bind(identity.installID, identity.keyID, identity.publicKey.buffer, APP_ID, now)
    .run();
  return identity;
}

async function assertion(identity, path, payload, counter) {
  const clientDataHash = await sha256Bytes(`POST\n${path}\n${bytesToHex(await sha256Bytes(payload))}`);
  const authenticatorData = new Uint8Array(37);
  authenticatorData.set(await sha256Bytes(APP_ID), 0);
  new DataView(authenticatorData.buffer).setUint32(33, counter, false);
  const nonce = await sha256Bytes(concatBytes(authenticatorData, clientDataHash));
  const raw = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, identity.privateKey, nonce));
  return bytesToBase64(
    concatBytes(
      Uint8Array.of(0xa2),
      cborText("signature"),
      cborByteString(ecdsaSignatureDER(raw)),
      cborText("authenticatorData"),
      cborByteString(authenticatorData),
    ),
  );
}

async function envelope(identity, path, payload, { installID } = {}) {
  identity.counter += 1;
  return JSON.stringify({
    install_id: installID ?? identity.installID,
    key_id: identity.keyID,
    payload,
    assertion: await assertion(identity, path, payload, identity.counter),
  });
}

function post(path, body) {
  return SELF.fetch(`${BASE}${path}`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body,
  });
}

function challengeRequest(body) {
  return SELF.fetch(`${BASE}/v1/app-attest/challenge`, {
    method: "POST",
    headers: { "content-type": "application/json", "cf-connecting-ip": "203.0.113.9" },
    body: JSON.stringify(body),
  });
}

const APP_ATTEST_TABLES = ["app_attest_challenges", "app_attest_challenge_source_buckets", "app_attest_keys"];

async function d1Rows(tables) {
  const out = {};
  for (const table of tables) {
    out[table] = (await env.TRIAL_DB.prepare(`SELECT * FROM ${table}`).all()).results;
  }
  return out;
}

// Every table of the lane's D1, the App Attest ones and the mirror alike.
async function d1Tables() {
  const { results } = await env.TRIAL_DB.prepare(
    "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE '\\_cf\\_%' ESCAPE '\\' AND name NOT LIKE 'sqlite\\_%' ESCAPE '\\'",
  ).all();
  return results.map((row) => row.name);
}

async function attestedAnalyze(identity, inner) {
  return post("/v1/trial/analyze", await envelope(identity, "/v1/trial/analyze", JSON.stringify(inner)));
}

async function attestedStatus(identity) {
  return post("/v1/trial/status", await envelope(identity, "/v1/trial/status", "{}"));
}

// ---------------------------------------------------------------- tests

// First in the file: nothing earlier is still logging in the background.
describe("a query string or key header", () => {
  it("is refused on every route without a single log line", async () => {
    const methods = ["log", "info", "warn", "error", "debug"];
    const spies = methods.map((method) => vi.spyOn(console, method));
    const canary = `canary=${crypto.randomUUID()}`;
    const routes = [
      ["GET", "/health"],
      ["POST", "/v1/trial/analyze"],
      ["GET", "/v1/trial/analyze"],
      ["POST", "/v1/trial/status"],
      ["GET", "/v1/trial/status"],
      ["POST", "/v1/app-attest/challenge"],
      ["POST", "/v1/app-attest/register"],
      ["POST", "/no-such-route"],
    ];
    for (const [method, path] of routes) {
      for (const { query, headers } of [
        { query: `?${canary}`, headers: {} },
        { query: `?alt=json&${canary}`, headers: { authorization: `Bearer ${BEARER}` } },
        { query: "?key=AIzaSyFAKE", headers: {} },
        { query: "", headers: { "x-goog-api-key": "AIzaSyFAKE", authorization: `Bearer ${BEARER}` } },
      ]) {
        const init = { method, headers: { "content-type": "application/json", ...headers } };
        if (method === "POST") init.body = JSON.stringify(wrapper(DEVICE_BODY));
        const response = await SELF.fetch(`${BASE}${path}${query}`, init);
        expect(response.status, `${method} ${path}${query}`).toBe(400);
        expect(await response.json()).toEqual({ error: "request_invalid" });
      }
    }
    const calls = spies.flatMap((spy, index) => spy.mock.calls.map((call) => [methods[index], ...call]));
    spies.forEach((spy) => spy.mockRestore());
    expect(calls).toEqual([]);
    expect(outbound).toHaveLength(0);
  });
});

describe("routes", () => {
  it("serves health with the embedded bundle version", async () => {
    const response = await SELF.fetch(`${BASE}/health`);
    expect(response.status).toBe(200);
    expect(env.TEST_BUNDLE_VERSION).toBeGreaterThanOrEqual(3);
    expect(await response.json()).toEqual({
      message: "ok",
      bundle_version: env.TEST_BUNDLE_VERSION,
      trial_model: MODEL,
    });
  });

  it("refuses unknown paths and methods", async () => {
    expect((await SELF.fetch(`${BASE}/v1beta/models/x:generateContent`, { method: "POST" })).status).toBe(404);
    const wrongMethod = await SELF.fetch(`${BASE}/v1/trial/analyze`);
    expect(wrongMethod.status).toBe(405);
    expect(await wrongMethod.json()).toEqual({ error: "method_not_allowed" });
  });

  it("issues a registration challenge with the development source key", async () => {
    const response = await challengeRequest({ install_id: crypto.randomUUID().toUpperCase(), purpose: "register" });
    expect(response.status).toBe(200);
    const body = await response.json();
    expect(Object.keys(body).sort()).toEqual(["challenge", "challenge_id"]);
  });
});

describe("the forward", () => {
  it("forwards the device's exact body with only opencast's key added", async () => {
    generateReplies.push(reply(REPLY, 200, { "x-goog-trace": "drop-me", "set-cookie": "a=b", "retry-after": "7" }));
    const response = await bearerAnalyze(wrapper(DEVICE_BODY));
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual(REPLY);
    expect(response.headers.get("content-type")).toBe("application/json; charset=UTF-8");
    expect(response.headers.get("retry-after")).toBe("7");
    expect(response.headers.get("x-goog-trace")).toBeNull();
    expect(response.headers.get("set-cookie")).toBeNull();

    const [count, generate] = outbound;
    expect(count.url).toBe(COUNT_URL);
    expect(JSON.parse(count.body)).toEqual({ generateContentRequest: { ...DEVICE_BODY, model: `models/${MODEL}` } });
    expect(generate.url).toBe(GENERATE_URL);
    expect(generate.method).toBe("POST");
    expect(generate.redirect).toBe("manual");
    expect(Object.keys(generate.headers).sort()).toEqual(["content-type", "x-goog-api-key"]);
    expect(generate.headers["x-goog-api-key"]).toBe(GEMINI_KEY);
    expect(JSON.parse(generate.body)).toEqual(DEVICE_BODY);
  });

  it("reserves money on the model's documented maximum input, whatever the count", async () => {
    // Google's documented limits for gemini-3.8-flash: 1,048,576 input
    // tokens. A count one above the body's bytes (as in the re-read's probe)
    // changes nothing: the reservation is the window's constant.
    countReplies.push(reply({ totalTokens: 10_952 }));
    generateReplies.push(reply(REPLY));
    const { result, row } = await newestReservation(() => bearerAnalyze(wrapper(DEVICE_BODY)));
    expect(result.status).toBe(200);
    const generate = outbound.find((call) => call.url === GENERATE_URL);
    expect(new TextEncoder().encode(generate.body).length).toBe(10_951);
    expect(row.input_tokens).toBe(10_952);
    expect(row.input_bound_tokens).toBe(1_048_576);
    // Today's price ($0.75 / $3.75 per million) on the limit and the cap.
    expect(row.reserved_micros).toBe(786_432 + 61_440);
  });

  it("refuses a count above the model's maximum input with nothing forwarded", async () => {
    countReplies.push(reply({ totalTokens: 1_048_577 }));
    const before = await reservationIds();
    const response = await bearerAnalyze(wrapper(DEVICE_BODY));
    expect(response.status).toBe(403);
    expect(await response.json()).toEqual({ error: "trial_run_bound" });
    expect(((await dumpLedger()).reservations ?? []).filter((row) => !before.has(row.id))).toHaveLength(0);
    expect(outbound.filter((call) => call.url === GENERATE_URL)).toHaveLength(0);
  });

  it("rebuilds tampered chargeable fields from the bundle", async () => {
    generateReplies.push(reply(REPLY));
    const tampered = structuredClone(DEVICE_BODY);
    tampered.model = "gemini-3.5-pro";
    tampered.generationConfig.maxOutputTokens = 65536;
    tampered.generationConfig.thinkingConfig = { thinkingLevel: "high", thinkingBudget: 99999 };
    expect((await bearerAnalyze(wrapper(tampered))).status).toBe(200);
    expect(JSON.parse(outbound[1].body)).toEqual(DEVICE_BODY);
  });

  it("refuses tools, key material and unknown keys with nothing forwarded", async () => {
    for (const [body, options] of [
      [wrapper({ ...DEVICE_BODY, tools: [{ googleSearch: {} }] }), {}],
      [wrapper({ ...DEVICE_BODY, cachedContent: "cachedContents/x" }), {}],
      [{ ...wrapper(DEVICE_BODY), extra: 1 }, {}],
      [wrapper(DEVICE_BODY), { query: "?key=AIzaSyFAKE" }],
      [wrapper(DEVICE_BODY), { headers: { "x-goog-api-key": "AIzaSyFAKE" } }],
    ]) {
      const response = await bearerAnalyze(body, options);
      expect(response.status).toBe(400);
      expect(await response.json()).toEqual({ error: "request_invalid" });
    }
    expect(outbound).toHaveLength(0);
  });

  it("refuses a wrong bearer and an oversized body", async () => {
    const wrong = await SELF.fetch(`${BASE}/v1/trial/analyze`, {
      method: "POST",
      headers: { authorization: "Bearer nope" },
      body: JSON.stringify(wrapper(DEVICE_BODY)),
    });
    expect(wrong.status).toBe(401);
    const huge = await bearerAnalyze("x".repeat(1_572_865));
    expect(huge.status).toBe(413);
    expect(outbound).toHaveLength(0);
  });

  it("passes provider errors back unchanged and charges as the table says", async () => {
    const unavailable = { error: { code: 503, message: "overloaded", status: "UNAVAILABLE" } };
    generateReplies.push(reply(unavailable, 503));
    const failed = await bearerAnalyze(wrapper(DEVICE_BODY));
    expect(failed.status).toBe(503);
    expect(await failed.json()).toEqual(unavailable);
    // A provider 500 is the provider's: passed through with its body (no
    // proxy-generated error answers 500).
    const internal = { error: { code: 500, message: "internal", status: "INTERNAL" } };
    generateReplies.push(reply(internal, 500));
    const failedInternally = await bearerAnalyze(wrapper(DEVICE_BODY));
    expect(failedInternally.status).toBe(500);
    expect(await failedInternally.json()).toEqual(internal);
    const limited = { error: { code: 429, message: "slow down", status: "RESOURCE_EXHAUSTED" } };
    generateReplies.push(reply(limited, 429));
    const rateLimited = await bearerAnalyze(wrapper(DEVICE_BODY));
    expect(rateLimited.status).toBe(429);
    expect(await rateLimited.json()).toEqual(limited);
    const dump = await dumpLedger();
    const settled = dump.reservations.filter((row) => row.state === "settled");
    const fiveHundred = settled.find((row) => row.outcome === "5xx");
    const rejected = settled.find((row) => row.outcome === "rejected");
    expect(fiveHundred.charged_micros).toBe(fiveHundred.reserved_micros);
    expect(rejected.charged_micros).toBe(0);
  });

  it("refuses the window when counting fails: nothing forwarded, nothing reserved", async () => {
    for (const failure of [
      reply({ error: { code: 500, message: "internal", status: "INTERNAL" } }, 500),
      reply({ error: { code: 429, message: "slow down", status: "RESOURCE_EXHAUSTED" } }, 429),
      reply("not json"),
      reply({ totalTokens: 0 }),
      () => {
        throw new Error("count unreachable");
      },
    ]) {
      countReplies.push(failure);
      const before = await reservationIds();
      const response = await bearerAnalyze(wrapper(DEVICE_BODY));
      expect(response.status).toBe(503);
      expect(await response.json()).toEqual({ error: "trial_unavailable", retry_after_seconds: 10 });
      expect(response.headers.get("retry-after")).toBe("10");
      const fresh = ((await dumpLedger()).reservations ?? []).filter((row) => !before.has(row.id));
      expect(fresh).toHaveLength(0);
    }
    expect(outbound.filter((call) => call.url === GENERATE_URL)).toHaveLength(0);
  });

  it("consumes no unit when counting fails after the flip", async () => {
    vi.useFakeTimers({ toFake: ["Date"] });
    vi.setSystemTime(new Date("2027-01-17T12:00:00Z"));
    const identity = await makeIdentity();
    countReplies.push(reply({ error: { code: 503 } }, 503));
    const refused = await attestedAnalyze(identity, wrapper(DEVICE_BODY));
    expect(refused.status).toBe(503);
    expect(await refused.json()).toEqual({ error: "trial_unavailable", retry_after_seconds: 10 });
    const status = await attestedStatus(identity);
    expect((await status.json()).units_remaining).toBe(5);
    expect(outbound.filter((call) => call.url === GENERATE_URL)).toHaveLength(0);
  });

  it("times out inside the device's budget and keeps the whole reservation", async () => {
    generateReplies.push(
      () => new Promise((resolve) => setTimeout(() => resolve(reply(REPLY)()), 6_000)),
    );
    const started = Date.now();
    const { result: response, row } = await newestReservation(() =>
      bearerAnalyze(wrapper(DEVICE_BODY, { timeout_seconds: 6 })),
    );
    expect(response.status).toBe(504);
    expect(await response.json()).toEqual({ error: "provider_timeout" });
    expect(Date.now() - started).toBeLessThan(6_000);
    expect(row.outcome).toBe("timeout");
    expect(row.charged_micros).toBe(row.reserved_micros);
  }, 15_000);
});

describe("status", () => {
  it("answers the bearer lane on GET and POST", async () => {
    for (const init of [
      { method: "GET", headers: { authorization: `Bearer ${BEARER}` } },
      { method: "POST", headers: { authorization: `Bearer ${BEARER}` }, body: "{}" },
      { method: "POST", headers: { authorization: `Bearer ${BEARER}` } },
    ]) {
      const response = await SELF.fetch(`${BASE}/v1/trial/status`, init);
      expect(response.status).toBe(200);
      expect(await response.json()).toEqual({
        mode: "open",
        units_remaining: 5,
        starts_at: "2027-01-01T00:00:00Z",
        month_paused: false,
      });
    }
  });

  it("refuses a GET without the bearer and a POST with a payload", async () => {
    expect((await SELF.fetch(`${BASE}/v1/trial/status`)).status).toBe(401);
    const payload = await SELF.fetch(`${BASE}/v1/trial/status`, {
      method: "POST",
      headers: { authorization: `Bearer ${BEARER}` },
      body: JSON.stringify({ units: 99 }),
    });
    expect(payload.status).toBe(400);
  });

  it("reads the ledger once trial mode is on", async () => {
    vi.useFakeTimers({ toFake: ["Date"] });
    vi.setSystemTime(new Date("2027-01-20T12:00:00Z"));
    const response = await SELF.fetch(`${BASE}/v1/trial/status`, {
      headers: { authorization: `Bearer ${BEARER}` },
    });
    expect(await response.json()).toEqual({
      mode: "trial",
      units_remaining: 5,
      starts_at: "2027-01-01T00:00:00Z",
      month_paused: false,
    });
  });
});

describe("App Attest", () => {
  it("accepts an envelope, refuses its replay and a wrong install", async () => {
    const identity = await makeIdentity();
    const body = await envelope(identity, "/v1/trial/status", "{}");
    const first = await post("/v1/trial/status", body);
    expect(first.status).toBe(200);
    expect(await first.json()).toEqual({
      mode: "open",
      units_remaining: 5,
      starts_at: "2027-01-01T00:00:00Z",
      month_paused: false,
    });
    const replay = await post("/v1/trial/status", body);
    expect(replay.status).toBe(401);
    expect(await replay.json()).toEqual({ error: "invalid_counter" });
    const wrongInstall = await post(
      "/v1/trial/status",
      await envelope(identity, "/v1/trial/status", "{}", { installID: crypto.randomUUID().toUpperCase() }),
    );
    expect(wrongInstall.status).toBe(401);
    expect(await wrongInstall.json()).toEqual({ error: "unknown_key" });
    // An assertion over the same payload bytes for the status route does
    // not open the analyze route: only the path differs.
    identity.counter += 1;
    const payload = JSON.stringify(wrapper(DEVICE_BODY));
    const crossRoute = await post(
      "/v1/trial/analyze",
      JSON.stringify({
        install_id: identity.installID,
        key_id: identity.keyID,
        payload,
        assertion: await assertion(identity, "/v1/trial/status", payload, identity.counter),
      }),
    );
    expect(crossRoute.status).toBe(401);
    expect(await crossRoute.json()).toEqual({ error: "invalid_signature" });
    expect(outbound).toHaveLength(0);
  });

  it("refuses a missing assertion and a key from another environment", async () => {
    const identity = await makeIdentity();
    const missing = await post(
      "/v1/trial/status",
      JSON.stringify({ install_id: identity.installID, key_id: identity.keyID, payload: "{}" }),
    );
    expect(missing.status).toBe(401);
    expect(await missing.json()).toEqual({ error: "missing_assertion" });
    await env.TRIAL_DB.prepare("UPDATE app_attest_keys SET environment = 'production' WHERE install_id = ?1")
      .bind(identity.installID)
      .run();
    const wrongEnvironment = await attestedStatus(identity);
    expect(wrongEnvironment.status).toBe(401);
    expect(await wrongEnvironment.json()).toEqual({ error: "invalid_environment" });
  });

  it("counts units per install, across that install's keys", async () => {
    vi.useFakeTimers({ toFake: ["Date"] });
    vi.setSystemTime(new Date("2027-01-16T12:00:00Z"));
    const first = await makeIdentity();
    // A rotated key under the same install id.
    const keys = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
    const publicKey = new Uint8Array(await crypto.subtle.exportKey("raw", keys.publicKey));
    const second = {
      installID: first.installID,
      keyID: bytesToBase64(await sha256Bytes(publicKey)),
      privateKey: keys.privateKey,
      publicKey,
      counter: 0,
    };
    const now = Math.floor(Date.now() / 1000);
    await env.TRIAL_DB.prepare(
      "INSERT INTO app_attest_keys (install_id, key_id, public_key, sign_counter, app_id, environment, created_at, last_used_at) \
       VALUES (?1, ?2, ?3, 0, ?4, 'development', ?5, ?5)",
    )
      .bind(second.installID, second.keyID, second.publicKey.buffer, APP_ID, now)
      .run();
    for (const identity of [first, first, first, second, second]) {
      generateReplies.push(reply(REPLY));
      expect((await attestedAnalyze(identity, wrapper(DEVICE_BODY))).status).toBe(200);
    }
    const exhausted = await attestedAnalyze(second, wrapper(DEVICE_BODY));
    expect(exhausted.status).toBe(403);
    expect(await exhausted.json()).toEqual({ error: "trial_exhausted" });
  });

  it("refuses a second window while the first is in flight", async () => {
    const identity = await makeIdentity();
    let release;
    const gate = new Promise((resolve) => (release = resolve));
    generateReplies.push(async () => {
      await gate;
      return reply(REPLY)();
    });
    const first = attestedAnalyze(identity, wrapper(DEVICE_BODY));
    // Wait until the first window has been admitted and forwarded.
    while (!outbound.some((call) => call.url === GENERATE_URL)) {
      await new Promise((resolve) => setTimeout(resolve, 10));
    }
    const second = await attestedAnalyze(identity, wrapper(DEVICE_BODY));
    expect(second.status).toBe(409);
    const busy = await second.json();
    expect(busy.error).toBe("trial_busy");
    expect(busy.retry_after_seconds).toBeGreaterThanOrEqual(1);
    expect(busy.retry_after_seconds).toBeLessThanOrEqual(10);
    expect(second.headers.get("retry-after")).toBe(String(busy.retry_after_seconds));
    release();
    expect((await first).status).toBe(200);
  });

  it("counts lifetime units per install after the flip", async () => {
    vi.useFakeTimers({ toFake: ["Date"] });
    vi.setSystemTime(new Date("2027-01-15T12:00:00Z"));
    const identity = await makeIdentity();
    for (let run = 0; run < 5; run += 1) {
      generateReplies.push(reply(REPLY));
      expect((await attestedAnalyze(identity, wrapper(DEVICE_BODY))).status).toBe(200);
    }
    const status = await attestedStatus(identity);
    expect(await status.json()).toEqual({
      mode: "trial",
      units_remaining: 0,
      starts_at: "2027-01-01T00:00:00Z",
      month_paused: false,
    });
    const exhausted = await attestedAnalyze(identity, wrapper(DEVICE_BODY));
    expect(exhausted.status).toBe(403);
    expect(await exhausted.json()).toEqual({ error: "trial_exhausted" });
  });
});

describe("App Attest identifiers", () => {
  const refusedShape = async (response) => {
    expect(response.status).toBe(400);
    expect(await response.json()).toEqual({ error: "request_invalid" });
  };

  it("refuses a challenge for an install id that is not the app's UUID, storing nothing", async () => {
    const before = await d1Rows(APP_ATTEST_TABLES);
    for (const install_id of [
      CANARY,
      `${CANARY} ${"transcript ".repeat(80)}`,
      "6F9619FF-8B86-D011-B42D-00CF4FC964F",
      "6F9619FF8B86D011B42D00CF4FC964FF1234",
      "6F9619FF-8B86-D011-B42D-00CF4FC964FG",
      "",
    ]) {
      await refusedShape(await challengeRequest({ install_id, purpose: "register" }));
    }
    expect(await d1Rows(APP_ATTEST_TABLES)).toEqual(before);
    for (const install_id of [crypto.randomUUID().toUpperCase(), crypto.randomUUID()]) {
      expect((await challengeRequest({ install_id, purpose: "register" })).status).toBe(200);
    }
  });

  it("refuses malformed registration identifiers before any lookup or write", async () => {
    const installID = crypto.randomUUID().toUpperCase();
    const issued = await (await challengeRequest({ install_id: installID, purpose: "register" })).json();
    const valid = {
      install_id: installID,
      key_id: bytesToBase64(await sha256Bytes(CANARY)),
      challenge_id: issued.challenge_id,
      challenge: issued.challenge,
      attestation_object: btoa(CANARY),
    };
    const before = await d1Rows(APP_ATTEST_TABLES);
    for (const override of [
      { install_id: CANARY },
      { key_id: CANARY },
      { key_id: bytesToBase64(new Uint8Array(31)) },
      { key_id: `${bytesToBase64(await sha256Bytes(CANARY))}AAAA` },
      { challenge_id: CANARY },
      { challenge_id: `${issued.challenge_id}A` },
      { challenge: CANARY },
    ]) {
      await refusedShape(await post("/v1/app-attest/register", JSON.stringify({ ...valid, ...override })));
    }
    expect(await d1Rows(APP_ATTEST_TABLES)).toEqual(before);
    // Well-formed identifiers reach the verifier, which refuses the object.
    const attempt = await post("/v1/app-attest/register", JSON.stringify(valid));
    expect(attempt.status).toBe(401);
  });

  it("refuses an envelope whose install id is not the app's UUID", async () => {
    const identity = await makeIdentity();
    for (const installID of [CANARY, identity.installID.slice(1)]) {
      await refusedShape(
        await post("/v1/trial/status", await envelope(identity, "/v1/trial/status", "{}", { installID })),
      );
    }
    // The install id is matched exactly as registered.
    expect((await attestedStatus(identity)).status).toBe(200);
    expect(outbound).toHaveLength(0);
  });
});

describe("App Attest envelope errors", () => {
  it("answers a bodyless POST on both envelope routes with invalid_json", async () => {
    for (const path of ["/v1/trial/analyze", "/v1/trial/status"]) {
      const response = await SELF.fetch(`${BASE}${path}`, { method: "POST" });
      expect(response.status, path).toBe(400);
      expect(await response.json()).toEqual({ error: "invalid_json" });
    }
    expect(outbound).toHaveLength(0);
  });

  it("keeps AppAttestCore's 401 codes for a malformed envelope key id", async () => {
    const identity = await makeIdentity();
    for (const [keyID, code] of [
      [CANARY, "invalid_attestation_format"],
      [bytesToBase64(new Uint8Array(31)), "invalid_key_id"],
    ]) {
      const response = await post(
        "/v1/trial/status",
        JSON.stringify({ install_id: identity.installID, key_id: keyID, payload: "{}", assertion: "AA==" }),
      );
      expect(response.status, keyID).toBe(401);
      expect(await response.json()).toEqual({ error: code });
    }
  });
});

describe("failure paths", () => {
  it("never forwards when the ledger's transaction rolls back after a successful callback", async () => {
    await runInDurableObject(ledger(), (_instance, state) => {
      const original = state.storage.transactionSync.bind(state.storage);
      let remaining = 2;
      state.storage.transactionSync = (callback) => {
        if (remaining === 0) return original(callback);
        remaining -= 1;
        if (remaining === 0) state.storage.transactionSync = original;
        return original(() => {
          callback();
          throw new Error("injected rollback");
        });
      };
    });
    const before = (await dumpLedger()).reservations?.length ?? 0;
    const response = await bearerAnalyze(wrapper(DEVICE_BODY));
    expect(response.status).toBe(503);
    expect(await response.json()).toEqual({ error: "trial_unavailable" });
    expect(outbound.filter((call) => call.url === GENERATE_URL)).toHaveLength(0);
    expect((await dumpLedger()).reservations?.length ?? 0).toBe(before);
  });

  it("passes a bodyless refusal back and charges nothing", async () => {
    generateReplies.push(() => new Response(null, { status: 429, headers: { "retry-after": "3" } }));
    const { result: refusal, row: rejected } = await newestReservation(() =>
      bearerAnalyze(wrapper(DEVICE_BODY)),
    );
    expect(refusal.status).toBe(429);
    expect(await refusal.text()).toBe("");
    expect(refusal.headers.get("retry-after")).toBe("3");
    expect([rejected.outcome, rejected.charged_micros]).toEqual(["rejected", 0]);
    generateReplies.push(() => new Response(null, { status: 200 }));
    const { result: ok, row: empty } = await newestReservation(() => bearerAnalyze(wrapper(DEVICE_BODY)));
    expect(ok.status).toBe(200);
    expect(empty.outcome).toBe("no_usage");
    expect(empty.charged_micros).toBe(empty.reserved_micros);
  });

  it("answers unreachable and oversized replies itself and keeps the reservation", async () => {
    generateReplies.push(() => {
      throw new Error("network down");
    });
    const { result: unreachable, row: lost } = await newestReservation(() =>
      bearerAnalyze(wrapper(DEVICE_BODY)),
    );
    expect(unreachable.status).toBe(502);
    expect(await unreachable.json()).toEqual({ error: "provider_unreachable" });
    expect([lost.outcome, lost.charged_micros]).toEqual(["unreachable", lost.reserved_micros]);
    generateReplies.push(reply("x".repeat(2 * 1024 * 1024 + 1)));
    const { result: oversized, row: big } = await newestReservation(() =>
      bearerAnalyze(wrapper(DEVICE_BODY)),
    );
    expect(oversized.status).toBe(502);
    expect(await oversized.json()).toEqual({ error: "provider_body_too_large" });
    expect([big.outcome, big.charged_micros]).toEqual(["body_too_large", big.reserved_micros]);
  });

  it("names the allowed methods per route", async () => {
    for (const [method, path, allow] of [
      ["GET", "/v1/trial/analyze", "POST"],
      ["PUT", "/v1/trial/status", "GET, POST"],
      ["POST", "/health", "GET"],
    ]) {
      const response = await SELF.fetch(`${BASE}${path}`, { method });
      expect(response.status).toBe(405);
      expect(response.headers.get("allow")).toBe(allow);
    }
  });
});

// Makes the ledger's next `count` setAlarm calls reject, as a storage
// failure would; returns a reader for how many were refused.
async function failNextSetAlarms(count) {
  return runInDurableObject(ledger(), (_instance, state) => {
    const original = state.storage.setAlarm.bind(state.storage);
    const injected = { refused: 0 };
    state.storage.setAlarm = (...args) => {
      if (injected.refused < count) {
        injected.refused += 1;
        if (injected.refused === count) state.storage.setAlarm = original;
        return Promise.reject(new Error("injected setAlarm failure"));
      }
      return original(...args);
    };
    return () => injected.refused;
  });
}

describe("alarm scheduling", () => {
  it("fails the alarm when no next alarm could be set, and the retry arms it", async () => {
    await runInDurableObject(ledger(), (_instance, state) => state.storage.setAlarm(Date.now() + 60_000));
    const refused = await failNextSetAlarms(2);
    await expect(runDurableObjectAlarm(ledger())).rejects.toThrow();
    expect(refused()).toBe(2);
    expect(await runInDurableObject(ledger(), (_instance, state) => state.storage.getAlarm())).toBeNull();
    // The runtime retries a failed alarm; with scheduling back, the retry
    // leaves the next one armed.
    const before = Date.now();
    await runInDurableObject(ledger(), (instance) => instance.alarm());
    const next = await runInDurableObject(ledger(), (_instance, state) => state.storage.getAlarm());
    expect(next).toBeGreaterThan(before);
    expect(next).toBeLessThanOrEqual(Date.now() + 3_600_000);
  });

  it("still answers an admission whose re-arm failed, and its settlement arms it", async () => {
    await runInDurableObject(ledger(), (_instance, state) => state.storage.deleteAlarm());
    const log = vi.spyOn(console, "log");
    const refused = await failNextSetAlarms(1);
    generateReplies.push(reply(REPLY));
    expect((await bearerAnalyze(wrapper(DEVICE_BODY))).status).toBe(200);
    expect(refused()).toBe(1);
    const lines = log.mock.calls.map((call) => call.join(" "));
    log.mockRestore();
    expect(lines).toContain(JSON.stringify({ event: "trial_ledger_error", stage: "alarm_rearm_failed", kind: "storage" }));
    // No further admission: the same window's settlement stored the alarm.
    const alarm = await runInDurableObject(ledger(), (_instance, state) => state.storage.getAlarm());
    expect(alarm).toBeGreaterThan(Date.now() - 1_000);
    expect(alarm).toBeLessThanOrEqual(Date.now() + 3_600_000);
  });

  it("retries in the background when neither the admission nor the settlement could arm", async () => {
    await runInDurableObject(ledger(), (_instance, state) => state.storage.deleteAlarm());
    const refused = await failNextSetAlarms(2);
    generateReplies.push(reply(REPLY));
    expect((await bearerAnalyze(wrapper(DEVICE_BODY))).status).toBe(200);
    expect(refused()).toBe(2);
    // No request follows; the object's own retry stores it within seconds.
    let alarm = null;
    for (let attempt = 0; attempt < 40 && alarm === null; attempt += 1) {
      await new Promise((resolve) => setTimeout(resolve, 100));
      alarm = await runInDurableObject(ledger(), (_instance, state) => state.storage.getAlarm());
    }
    expect(alarm).toBeGreaterThan(Date.now() - 5_000);
    expect(alarm).toBeLessThanOrEqual(Date.now() + 3_600_000);
  });
});

describe("object schema", () => {
  it("drops a retired column from an earlier object's tables and keeps the rows", async () => {
    // Its own instance: the shared `global` ledger is left alone.
    const stub = env.TRIAL_LEDGER.get(env.TRIAL_LEDGER.idFromName("schema-migration"));
    const { columns, rows } = await runInDurableObject(stub, (instance, state) => {
      const sql = state.storage.sql;
      sql.exec("DROP TABLE reservations");
      sql.exec(`CREATE TABLE reservations (
        id TEXT PRIMARY KEY, subject TEXT NOT NULL, lane TEXT NOT NULL, run_id TEXT NOT NULL,
        window_index INTEGER NOT NULL, feature TEXT NOT NULL, model TEXT NOT NULL, mode TEXT NOT NULL,
        month TEXT NOT NULL, spill_month TEXT, day INTEGER NOT NULL, input_tokens INTEGER NOT NULL,
        input_estimated INTEGER NOT NULL, max_output_tokens INTEGER NOT NULL,
        input_price INTEGER NOT NULL, output_price INTEGER NOT NULL,
        reserved_micros INTEGER NOT NULL, charged_micros INTEGER NOT NULL, state TEXT NOT NULL,
        outcome TEXT, created_at INTEGER NOT NULL, deadline INTEGER NOT NULL, finalized_at INTEGER)`);
      sql.exec(`INSERT INTO reservations VALUES ('old', 'bearer:x', 'bearer', 'r', 0, 'ad_detection',
        '${MODEL}', 'open', '2026-10', NULL, 20385, 2039, 0, 16384, 750000, 3750000, 63000, 32013,
        'settled', 'usage', 1, 2, 3)`);
      // A new instance over the same storage, as after a restart or a
      // deploy, runs the schema step again.
      new instance.constructor(state, env);
      return {
        columns: sql.exec("PRAGMA table_info(reservations)").toArray().map((row) => row.name),
        rows: sql.exec("SELECT id, input_tokens, charged_micros FROM reservations").toArray(),
      };
    });
    expect(columns).not.toContain("input_estimated");
    expect(columns).toContain("max_output_tokens");
    expect(rows).toEqual([{ id: "old", input_tokens: 2039, charged_micros: 32013 }]);
  });
});

describe("content-free", () => {
  it("keeps no request text, run id or install id in storage, the mirror or the logs", async () => {
    const log = vi.spyOn(console, "log");
    const identity = await makeIdentity();
    const runID = `CANARY-RUN-${crypto.randomUUID()}`;
    const body = structuredClone(DEVICE_BODY);
    body.contents[0].parts[0].text = body.contents[0].parts[0].text.replace("Repairing", CANARY);
    generateReplies.push(reply({ ...REPLY, candidates: [{ content: { parts: [{ text: CANARY }] } }] }));
    expect((await attestedAnalyze(identity, wrapper(body, { run_id: runID }))).status).toBe(200);
    // Bad bodies must not leak through error paths either, nor through the
    // unauthenticated registration routes.
    await attestedAnalyze(identity, { ...wrapper(body, { run_id: runID }), [CANARY]: CANARY });
    await bearerAnalyze(`{"feature":"${CANARY}"`);
    await challengeRequest({ install_id: CANARY, purpose: "register" });
    const registering = crypto.randomUUID().toUpperCase();
    const issued = await (await challengeRequest({ install_id: registering, purpose: "register" })).json();
    await post(
      "/v1/app-attest/register",
      JSON.stringify({
        install_id: registering,
        key_id: bytesToBase64(await sha256Bytes(CANARY)),
        challenge_id: issued.challenge_id,
        challenge: issued.challenge,
        attestation_object: btoa(CANARY),
      }),
    );

    const dump = JSON.stringify(await dumpLedger());
    for (const canary of [CANARY, runID, identity.installID]) {
      expect(dump).not.toContain(canary);
    }
    // The mirror flush runs after the response; give it a moment.
    const tables = await d1Tables();
    expect(tables).toEqual(expect.arrayContaining([...APP_ATTEST_TABLES, "trial_run", "trial_day"]));
    let d1 = {};
    for (let attempt = 0; attempt < 50 && !(d1.trial_run ?? []).length; attempt += 1) {
      d1 = await d1Rows(tables);
      await new Promise((resolve) => setTimeout(resolve, 20));
    }
    expect(d1.trial_run.length).toBeGreaterThan(0);
    expect(d1.app_attest_challenges.length).toBeGreaterThan(0);
    for (const [table, rows] of Object.entries(d1)) {
      const text = JSON.stringify(rows);
      for (const canary of [CANARY, runID]) {
        expect(text, table).not.toContain(canary);
      }
      // The registered key row is the one place an install id is kept.
      if (table !== "app_attest_keys") expect(text, table).not.toContain(identity.installID);
    }
    const lines = log.mock.calls.map((call) => call.join(" "));
    const forwards = lines
      .filter((line) => line.includes('"event":"trial_forward"'))
      .map((line) => JSON.parse(line));
    expect(forwards.some((event) => event.outcome === "2xx" && event.admitted && event.count === "counted")).toBe(true);
    for (const line of lines) {
      for (const canary of [CANARY, runID, identity.installID]) {
        expect(line).not.toContain(canary);
      }
    }
    log.mockRestore();
  });

  it("arms the alarm at an absolute time within the hour and keeps it armed", async () => {
    generateReplies.push(reply(REPLY));
    const before = Date.now();
    expect((await bearerAnalyze(wrapper(DEVICE_BODY))).status).toBe(200);
    const alarm = await runInDurableObject(ledger(), (_instance, state) => state.storage.getAlarm());
    expect(alarm).toBeGreaterThan(before);
    expect(alarm).toBeLessThanOrEqual(Date.now() + 3_600_000);
    expect(await runDurableObjectAlarm(ledger())).toBe(true);
    const next = await runInDurableObject(ledger(), (_instance, state) => state.storage.getAlarm());
    expect(next).toBeGreaterThan(before);
    expect(next).toBeLessThanOrEqual(Date.now() + 3_600_000);
  });
});

// Last: it spends the dev lane's daily backstop (60 windows) for the day.
describe("open-mode backstop", () => {
  it("pauses at the daily backstop, alerts once and keeps the alarm armed", async () => {
    let paused;
    for (let attempt = 0; attempt < 70 && !paused; attempt += 1) {
      const identity = await makeIdentity();
      generateReplies.push(reply(REPLY));
      const response = await attestedAnalyze(identity, wrapper(DEVICE_BODY));
      if (response.status === 503) {
        paused = await response.json();
        generateReplies.pop();
      } else {
        expect(response.status).toBe(200);
      }
    }
    expect(paused).toEqual({ error: "trial_paused" });
    const { alerts } = await dumpLedger();
    expect(alerts.filter((row) => row.kind === "backstop")).toHaveLength(1);
    const alarm = await runInDurableObject(ledger(), (_instance, state) => state.storage.getAlarm());
    expect(alarm).toBeGreaterThan(Date.now() - 1_000);
    expect(alarm).toBeLessThanOrEqual(Date.now() + 3_600_000);
  }, 60_000);
});
