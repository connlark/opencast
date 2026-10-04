// Billing lifecycle against the development fake backend:
// BILLING_REQUIRED=true, CREDIT_BACKEND derived to `dev`, synthetic App
// Attest envelopes on the charged lane, the bearer lane exempt. D1 rows
// (dev_credit_accounts / dev_credit_reservations / install_account_links)
// are the observable money state.
//
// Charge math fixture: makeRequest(segmentCount 12) declares 240 s of audio
// → ceil(240 × 7850 / 3600) = 524 credit-seconds. The default dev grant is
// 36,000 s.
import {
  abortAllDurableObjects,
  env,
  runDurableObjectAlarm,
  runInDurableObject,
} from "cloudflare:test";
import { afterAll, afterEach, beforeAll, describe, expect, it, vi } from "vitest";
import {
  ANALYZE_PATH,
  BEARER,
  BOOTSTRAP_PATH,
  GEMINI_TRUNCATED_RESPONSE,
  analysisFor,
  deviceLimiterStub,
  geminiResponse,
  globalLimiterStub,
  installFetchStub,
  jobStub,
  limiterUsage,
  makeRequest,
  makeSyntheticAppAttestIdentity,
  mockGeminiDeferred,
  mockGeminiOnce,
  observedGeminiPayloads,
  pendingGeminiResponses,
  counterDiff,
  postAnalyze,
  postEnvelope,
  readCounters,
  restoreFetchStub,
  seedSyntheticKey,
  setLimiterUsage,
  waitForCounterDelta,
  waitForTerminalPollAs,
} from "./support.mjs";

const CHARGE_12_SEGMENTS = 524;
const DEV_GRANT = 36000;

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

async function bootstrappedIdentity() {
  const identity = await makeSyntheticAppAttestIdentity();
  await seedSyntheticKey(identity);
  const response = await postEnvelope(identity, BOOTSTRAP_PATH, {
    schema_version: 1,
  });
  expect(response.status).toBe(200);
  const body = await response.json();
  identity.accountID = body.account_id;
  return { identity, bootstrap: body };
}

async function accountRow(accountID) {
  return env.TRANSCRIPT_ANALYSIS_DB.prepare(
    "SELECT available_seconds, reserved_seconds, consumed_seconds \
     FROM dev_credit_accounts WHERE account_id = ?1",
  )
    .bind(accountID)
    .first();
}

async function reservationsFor(accountID) {
  const rows = await env.TRANSCRIPT_ANALYSIS_DB.prepare(
    "SELECT job_id, reserved_seconds, state FROM dev_credit_reservations \
     WHERE account_id = ?1 ORDER BY created_at ASC, job_id ASC",
  )
    .bind(accountID)
    .all();
  return rows.results;
}

/// Terminal billing runs after the terminal record write (deliver-then-
/// bill), so money assertions poll briefly for a row in the wanted state.
/// Rows within one second sort unstably, so lookup is by state, never index.
async function waitForReservationState(accountID, state) {
  for (let attempt = 0; attempt < 200; attempt += 1) {
    const rows = await reservationsFor(accountID);
    const match = rows.find((row) => row.state === state);
    if (match) {
      return match;
    }
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
  throw new Error(`no reservation for ${accountID} became ${state}`);
}

describe("bootstrap (dev fake)", () => {
  it("creates an install-keyed account with the grant, idempotently", async () => {
    const { identity, bootstrap } = await bootstrappedIdentity();
    expect(bootstrap.account_id).toMatch(/^acct-/);
    expect(bootstrap.balance).toEqual({
      available_seconds: DEV_GRANT,
      reserved_seconds: 0,
      debt_seconds: 0,
    });

    const again = await postEnvelope(identity, BOOTSTRAP_PATH, {
      schema_version: 1,
    });
    expect(again.status).toBe(200);
    expect((await again.json()).account_id).toBe(bootstrap.account_id);
  });
});

describe("charged lane fails closed before bootstrap", () => {
  it("refuses an async analyze with bootstrap_required", async () => {
    const countersBefore = await readCounters();
    const identity = await makeSyntheticAppAttestIdentity();
    await seedSyntheticKey(identity);

    const response = await postEnvelope(
      identity,
      ANALYZE_PATH,
      makeRequest({ fingerprint: "1b".repeat(32), asyncSupported: true }),
    );
    expect(response.status).toBe(403);
    expect((await response.json()).error).toBe("bootstrap_required");
    expect(counterDiff(countersBefore, await readCounters())).toEqual({
      bootstrap_required_denials: 1,
    });
  });
});

describe("billed work requires the job lane", () => {
  it("refuses a billed sync analyze with async_required, touching no money", async () => {
    // The sync exchange has no durable record to repair from: a client
    // disconnect between reserve and settle would strand the hold forever
    // (PurchaseWorker has no reservation expiry). The refusal precedes the
    // account-link check so a legacy caller gets one clear signal.
    const { identity } = await bootstrappedIdentity();
    const response = await postEnvelope(
      identity,
      ANALYZE_PATH,
      makeRequest({ fingerprint: "2a".repeat(32) }),
    );
    expect(response.status).toBe(400);
    expect((await response.json()).error).toBe("async_required");
    expect((await reservationsFor(identity.accountID)).length).toBe(0);
    expect(await accountRow(identity.accountID)).toEqual({
      available_seconds: DEV_GRANT,
      reserved_seconds: 0,
      consumed_seconds: 0,
    });
  });
});

describe("async lane lifecycle", () => {
  it("settles on completion and serves cache hits without a second charge", async () => {
    const countersBefore = await readCounters();
    const { identity } = await bootstrappedIdentity();
    const request = makeRequest({
      fingerprint: "3a".repeat(32),
      asyncSupported: true,
    });
    mockGeminiOnce(geminiResponse(analysisFor(12)));
    const submitted = await postEnvelope(identity, ANALYZE_PATH, request);
    expect(submitted.status).toBe(202);

    const completed = await waitForTerminalPollAs(
      identity,
      request.transcript.fingerprint,
    );
    expect(completed.status).toBe(200);
    await waitForReservationState(identity.accountID, "settled");
    const retained = await runInDurableObject(jobStub(request.transcript.fingerprint), async (_instance, state) => JSON.parse(await state.storage.get("job")));
    expect(retained.purge_at - retained.billing.retry_deadline).toBe(84600);


    const settledCounters = {
      analysis_attempts: 1,
      candidates_tokens: 40,
      charged_credit_seconds: CHARGE_12_SEGMENTS,
      jobs_completed: 1,
      jobs_started: 1,
      prompt_tokens: 120,
      settled_jobs: 1,
      thoughts_tokens: 300,
      total_tokens: 460,
    };
    expect(await waitForCounterDelta(countersBefore, "settled_jobs", 1)).toEqual(
      settledCounters,
    );

    // Idempotent resubmit inside the TTL: the completed result serves with
    // no new reservation because the first subject already paid.
    const resubmit = await postEnvelope(identity, ANALYZE_PATH, request);
    expect(resubmit.status).toBe(200);
    expect((await reservationsFor(identity.accountID)).length).toBe(1);
    expect(await accountRow(identity.accountID)).toEqual({
      available_seconds: DEV_GRANT - CHARGE_12_SEGMENTS,
      reserved_seconds: 0,
      consumed_seconds: CHARGE_12_SEGMENTS,
    });
    // A cache hit starts no run and moves no money.
    expect(counterDiff(countersBefore, await readCounters())).toEqual(settledCounters);
  });

  it("releases on failure and a restart under the same fingerprint mints a fresh tan- id", async () => {
    const countersBefore = await readCounters();
    const { identity } = await bootstrappedIdentity();
    const request = makeRequest({
      fingerprint: "3b".repeat(32),
      asyncSupported: true,
    });

    mockGeminiOnce(GEMINI_TRUNCATED_RESPONSE);
    mockGeminiOnce(GEMINI_TRUNCATED_RESPONSE);
    mockGeminiOnce(GEMINI_TRUNCATED_RESPONSE);
    const submitted = await postEnvelope(identity, ANALYZE_PATH, request);
    expect(submitted.status).toBe(202);
    const failed = await waitForTerminalPollAs(
      identity,
      request.transcript.fingerprint,
    );
    expect(failed.status).toBe(502);
    const released = await waitForReservationState(
      identity.accountID,
      "released",
    );
    // Three attempts' spend is recorded even though the run failed, and
    // the release returns the full hold.
    expect(
      await waitForCounterDelta(countersBefore, "released_credit_seconds", CHARGE_12_SEGMENTS),
    ).toMatchObject({
      analysis_attempts: 3,
      candidates_tokens: 3 * 32768,
      jobs_failed_upstream: 1,
      jobs_started: 1,
      released_credit_seconds: CHARGE_12_SEGMENTS,
    });

    // The same fingerprint restarts a fresh run, which must reserve under a
    // NEW billing id (the released one is permanently dead in
    // PurchaseWorker's ledger). The restart may briefly see the typed
    // fail-closed 503 while the released reservation's DO bookkeeping
    // (pending-clear write) lands behind the D1 state asserted above.
    mockGeminiOnce(geminiResponse(analysisFor(12)));
    let resubmitted = null;
    for (let attempt = 0; attempt < 100; attempt += 1) {
      resubmitted = await postEnvelope(identity, ANALYZE_PATH, request);
      if (resubmitted.status !== 503) {
        break;
      }
      await new Promise((resolve) => setTimeout(resolve, 10));
    }
    expect(resubmitted.status).toBe(202);
    const completed = await waitForTerminalPollAs(
      identity,
      request.transcript.fingerprint,
    );
    expect(completed.status).toBe(200);
    const settled = await waitForReservationState(
      identity.accountID,
      "settled",
    );
    expect((await reservationsFor(identity.accountID)).length).toBe(2);
    expect(settled.job_id).toMatch(/^tan-/);
    expect(settled.job_id).not.toBe(released.job_id);
    expect(await accountRow(identity.accountID)).toEqual({
      available_seconds: DEV_GRANT - CHARGE_12_SEGMENTS,
      reserved_seconds: 0,
      consumed_seconds: CHARGE_12_SEGMENTS,
    });
    // The restart is a second started run (the transient 503s above, if
    // any, count under billing_unavailable and are not asserted).
    expect(await waitForCounterDelta(countersBefore, "settled_jobs", 1)).toMatchObject({
      analysis_attempts: 4,
      charged_credit_seconds: CHARGE_12_SEGMENTS,
      jobs_completed: 1,
      jobs_failed_upstream: 1,
      jobs_started: 2,
      released_credit_seconds: CHARGE_12_SEGMENTS,
      settled_jobs: 1,
    });
  });
});

describe("insufficient balance", () => {
  it("returns the typed 402 with charge and balance, consuming no money and no admission", async () => {
    const countersBefore = await readCounters();
    const { identity } = await bootstrappedIdentity();
    const deviceLimiter = await deviceLimiterStub(identity);
    const globalBefore = await limiterUsage(globalLimiterStub());
    const request = makeRequest({
      fingerprint: "4a".repeat(32),
      asyncSupported: true,
    });
    request.transcript.audio_duration = 100000;
    const expectedCharge = Math.ceil((100000 * 7850) / 3600);

    const response = await postEnvelope(identity, ANALYZE_PATH, request);
    expect(response.status).toBe(402);
    expect(await response.json()).toEqual({
      error: "insufficient_transcription_seconds",
      charge_seconds: expectedCharge,
      balance: {
        available_seconds: DEV_GRANT,
        reserved_seconds: 0,
        debt_seconds: 0,
      },
    });

    expect((await reservationsFor(identity.accountID)).length).toBe(0);
    expect(await accountRow(identity.accountID)).toEqual({
      available_seconds: DEV_GRANT,
      reserved_seconds: 0,
      consumed_seconds: 0,
    });
    // The refusal is not a run: both admissions were given back, so the
    // per-device object is untouched and the global object reads as before.
    expect(await limiterUsage(deviceLimiter)).toEqual({
      request_count: 0,
      estimated_input_tokens: 0,
    });
    expect(await limiterUsage(globalLimiterStub())).toEqual(globalBefore);
    expect(counterDiff(countersBefore, await readCounters())).toEqual({
      admission_releases: 1,
      reserve_denied_insufficient: 1,
    });
  });

  it("prices by the server-authoritative duration, not the declared one", async () => {
    const { identity } = await bootstrappedIdentity();
    const request = makeRequest({
      fingerprint: "4c".repeat(32),
      asyncSupported: true,
    });
    // Understate the declared duration; the last segment end (240 s ×
    // stretched to 100,000 s) is authoritative — underpricing is denied.
    request.transcript.audio_duration = 1;
    request.segments[request.segments.length - 1].end = 100000;

    const response = await postEnvelope(identity, ANALYZE_PATH, request);
    expect(response.status).toBe(402);
    expect((await response.json()).charge_seconds).toBe(
      Math.ceil((100000 * 7850) / 3600),
    );
  });
});


/// An unaffordable request: 100,000 s of audio prices at 218,056
/// credit-seconds against the 36,000 s dev grant.
function unaffordableRequest(fingerprint) {
  const request = makeRequest({ fingerprint, asyncSupported: true });
  request.transcript.audio_duration = 100000;
  return request;
}
const UNAFFORDABLE_CHARGE = Math.ceil((100000 * 7850) / 3600);

async function grantDevCredit(accountID, availableSeconds) {
  await env.TRANSCRIPT_ANALYSIS_DB.prepare(
    "UPDATE dev_credit_accounts SET available_seconds = ?1 WHERE account_id = ?2",
  )
    .bind(availableSeconds, accountID)
    .run();
}

async function refuseForCredit(identity, request, times) {
  for (let index = 0; index < times; index += 1) {
    const response = await postEnvelope(identity, ANALYZE_PATH, request);
    expect(response.status, `refusal ${index + 1}`).toBe(402);
    expect((await response.json()).error).toBe("insufficient_transcription_seconds");
  }
}

/// A funded submit whose mocked run completes; returns the started job's
/// terminal poll so the caller can assert on it.
async function runFunded(identity, request) {
  mockGeminiOnce(geminiResponse(analysisFor(request.segments.length)));
  const submitted = await postEnvelope(identity, ANALYZE_PATH, request);
  expect(submitted.status).toBe(202);
  const completed = await waitForTerminalPollAs(identity, request.transcript.fingerprint);
  expect(completed.status).toBe(200);
  await waitForReservationState(identity.accountID, "settled");
}

describe("admission accounting (credit refusals give their admissions back)", () => {
  it("keeps thirteen credit refusals at 402 and never reaches a cap denial", async () => {
    // The 2026-10-02 incident shape: the twelve-request per-device cap was
    // filled by refusals and the thirteenth submit got a 429. Now every
    // refusal unwinds, so the thirteenth is just another 402.
    const countersBefore = await readCounters();
    const { identity } = await bootstrappedIdentity();
    const deviceLimiter = await deviceLimiterStub(identity);
    const globalBefore = await limiterUsage(globalLimiterStub());
    const request = unaffordableRequest("8a".repeat(32));

    await refuseForCredit(identity, request, 13);

    expect(await limiterUsage(deviceLimiter)).toEqual({ request_count: 0, estimated_input_tokens: 0 });
    expect(await limiterUsage(globalLimiterStub())).toEqual(globalBefore);
    const diff = counterDiff(countersBefore, await readCounters());
    expect(diff).toEqual({
      admission_releases: 13,
      reserve_denied_insufficient: 13,
    });
    expect(Object.keys(diff).filter((name) => name.startsWith("cap_denials"))).toEqual([]);
    expect((await reservationsFor(identity.accountID)).length).toBe(0);
  });

  it("admits a buyer the same day after twelve refusals", async () => {
    const countersBefore = await readCounters();
    const { identity } = await bootstrappedIdentity();
    const deviceLimiter = await deviceLimiterStub(identity);
    const request = unaffordableRequest("8b".repeat(32));

    await refuseForCredit(identity, request, 12);
    expect(await limiterUsage(deviceLimiter)).toEqual({ request_count: 0, estimated_input_tokens: 0 });

    // Top up (the dev-fake equivalent of a purchase landing) and run.
    await grantDevCredit(identity.accountID, UNAFFORDABLE_CHARGE + 1);
    await runFunded(identity, request);

    // Exactly the started run is charged against the device's day.
    const usage = await limiterUsage(deviceLimiter);
    expect(usage.request_count).toBe(1);
    expect(usage.estimated_input_tokens).toBeGreaterThan(0);
    expect(await waitForCounterDelta(countersBefore, "settled_jobs", 1)).toMatchObject({
      admission_releases: 12,
      reserve_denied_insufficient: 12,
      jobs_started: 1,
      jobs_completed: 1,
      charged_credit_seconds: UNAFFORDABLE_CHARGE,
    });
  });

  it("has no hidden refusal ceiling: forty-one refusals, then a funded submit runs", async () => {
    // The bearer cap is 40 and a proposed refusal ceiling was 40; neither
    // bounds credit checks on the App Attest lane. Refusals are free of
    // quota, so the forty-second attempt, now funded, starts a run.
    const countersBefore = await readCounters();
    const { identity } = await bootstrappedIdentity();
    const deviceLimiter = await deviceLimiterStub(identity);
    const request = unaffordableRequest("8c".repeat(32));

    await refuseForCredit(identity, request, 41);
    expect(await limiterUsage(deviceLimiter)).toEqual({ request_count: 0, estimated_input_tokens: 0 });

    await grantDevCredit(identity.accountID, UNAFFORDABLE_CHARGE + 1);
    await runFunded(identity, request);
    expect((await limiterUsage(deviceLimiter)).request_count).toBe(1);
    expect(await waitForCounterDelta(countersBefore, "settled_jobs", 1)).toMatchObject({
      admission_releases: 41,
      reserve_denied_insufficient: 41,
      jobs_started: 1,
    });
  });

  it("leaves global headroom untouched by unfunded identities while started runs still hit both caps", async () => {
    const countersBefore = await readCounters();
    const unfunded = await Promise.all([
      bootstrappedIdentity(),
      bootstrappedIdentity(),
      bootstrappedIdentity(),
    ]);
    const globalBefore = await limiterUsage(globalLimiterStub());

    // Three identities without credit, two refusals each: the global object
    // reads exactly as before, requests and tokens alike.
    for (const [index, { identity }] of unfunded.entries()) {
      await refuseForCredit(identity, unaffordableRequest(`9${index}`.repeat(32)), 2);
      expect(await limiterUsage(await deviceLimiterStub(identity))).toEqual({
        request_count: 0,
        estimated_input_tokens: 0,
      });
    }
    expect(await limiterUsage(globalLimiterStub())).toEqual(globalBefore);

    // A started run charges its estimate against both scopes.
    const { identity: runner } = await bootstrappedIdentity();
    const runnerLimiter = await deviceLimiterStub(runner);
    const runRequest = makeRequest({ fingerprint: "9a".repeat(32), asyncSupported: true });
    await runFunded(runner, runRequest);
    const runnerUsage = await limiterUsage(runnerLimiter);
    expect(runnerUsage.request_count).toBe(1);
    const globalAfterRun = await limiterUsage(globalLimiterStub());
    expect(globalAfterRun.request_count).toBe(globalBefore.request_count + 1);
    expect(globalAfterRun.estimated_input_tokens).toBe(
      globalBefore.estimated_input_tokens + runnerUsage.estimated_input_tokens,
    );

    // The device cap still applies to a funded caller: at twelve, the
    // thirteenth is refused before anything is acquired, so nothing is
    // released and the global object is untouched.
    await setLimiterUsage(runnerLimiter, { request_count: 12, estimated_input_tokens: 0 });
    const deviceCapped = await postEnvelope(
      runner,
      ANALYZE_PATH,
      makeRequest({ fingerprint: "9b".repeat(32), asyncSupported: true }),
    );
    expect(deviceCapped.status).toBe(429);
    expect((await deviceCapped.json()).error).toBe("daily_request_cap_exceeded");
    expect(await limiterUsage(globalLimiterStub())).toEqual(globalAfterRun);

    // The global cap still applies too — and a global refusal gives the
    // caller's already-confirmed admission back.
    const { identity: latecomer } = await bootstrappedIdentity();
    const latecomerLimiter = await deviceLimiterStub(latecomer);
    await setLimiterUsage(globalLimiterStub(), { request_count: 60, estimated_input_tokens: 0 });
    const globalCapped = await postEnvelope(
      latecomer,
      ANALYZE_PATH,
      makeRequest({ fingerprint: "9c".repeat(32), asyncSupported: true }),
    );
    expect(globalCapped.status).toBe(429);
    expect((await globalCapped.json()).error).toBe("global_capacity_exhausted");
    expect(await limiterUsage(latecomerLimiter)).toEqual({ request_count: 0, estimated_input_tokens: 0 });
    expect(await limiterUsage(globalLimiterStub())).toEqual({ request_count: 60, estimated_input_tokens: 0 });
    expect((await reservationsFor(latecomer.accountID)).length).toBe(0);

    await setLimiterUsage(globalLimiterStub(), null);
    expect(await waitForCounterDelta(countersBefore, "settled_jobs", 1)).toMatchObject({
      // six credit refusals plus the per-device release after the global refusal
      admission_releases: 7,
      reserve_denied_insufficient: 6,
      cap_denials_app_attest: 1,
      cap_denials_global: 1,
      jobs_started: 1,
    });
  });

  it("unwinds the caller admission when the global limiter call throws", async () => {
    const countersBefore = await readCounters();
    const { identity } = await bootstrappedIdentity();
    const deviceLimiter = await deviceLimiterStub(identity);
    // Break the global object's storage so its admit throws (an unknown
    // outcome, not a refusal): the caller's confirmed admission is released,
    // the global object is left alone, and no cap denial is counted.
    await runInDurableObject(globalLimiterStub(), (_instance, state) => {
      state.storage.sql.exec("DROP TABLE IF EXISTS daily_usage;");
    });
    let response;
    try {
      response = await postEnvelope(
        identity,
        ANALYZE_PATH,
        makeRequest({ fingerprint: "9d".repeat(32), asyncSupported: true }),
      );
    } finally {
      await setLimiterUsage(globalLimiterStub(), null);
    }
    expect(response.status).toBeGreaterThanOrEqual(500);
    expect(await limiterUsage(deviceLimiter)).toEqual({ request_count: 0, estimated_input_tokens: 0 });
    expect((await reservationsFor(identity.accountID)).length).toBe(0);
    expect(await waitForCounterDelta(countersBefore, "admission_releases", 1)).toEqual({
      admission_releases: 1,
    });
  });

  it("unwinds both scopes when the credit backend fails at reserve", async () => {
    const countersBefore = await readCounters();
    const { identity } = await bootstrappedIdentity();
    const deviceLimiter = await deviceLimiterStub(identity);
    const globalBefore = await limiterUsage(globalLimiterStub());
    // Hide the reservations table: the dev fake's reserve fails with an
    // internal error, which the lane maps to the fail-closed 503.
    await env.TRANSCRIPT_ANALYSIS_DB.prepare(
      "ALTER TABLE dev_credit_reservations RENAME TO dev_credit_reservations_hidden",
    ).run();
    let response;
    try {
      response = await postEnvelope(
        identity,
        ANALYZE_PATH,
        makeRequest({ fingerprint: "9e".repeat(32), asyncSupported: true }),
      );
    } finally {
      await env.TRANSCRIPT_ANALYSIS_DB.prepare(
        "ALTER TABLE dev_credit_reservations_hidden RENAME TO dev_credit_reservations",
      ).run();
    }
    expect(response.status).toBe(503);
    expect((await response.json()).error).toBe("billing_unavailable");
    expect(await limiterUsage(deviceLimiter)).toEqual({ request_count: 0, estimated_input_tokens: 0 });
    expect(await limiterUsage(globalLimiterStub())).toEqual(globalBefore);
    expect(counterDiff(countersBefore, await readCounters())).toEqual({
      admission_releases: 1,
      billing_unavailable: 1,
    });
  });

  it("does not start a run when the Running record cannot be written", async () => {
    const countersBefore = await readCounters();
    const { identity } = await bootstrappedIdentity();
    const deviceLimiter = await deviceLimiterStub(identity);
    const globalBefore = await limiterUsage(globalLimiterStub());
    const request = makeRequest({ fingerprint: "9f".repeat(32), asyncSupported: true });
    const stub = jobStub(request.transcript.fingerprint);
    await runInDurableObject(stub, (_instance, state) => {
      const original = state.storage.put.bind(state.storage);
      state.storage.put = async (...args) => {
        state.storage.put = original;
        throw new Error("injected record write failure");
      };
    });

    const response = await postEnvelope(identity, ANALYZE_PATH, request);
    expect(response.status).toBeGreaterThanOrEqual(500);
    // Nothing started: no record, both admissions back, the hold released
    // directly (nothing referenced it), no jobs_started.
    expect(await runInDurableObject(stub, (_instance, state) => state.storage.get("job"))).toBeUndefined();
    expect(await limiterUsage(deviceLimiter)).toEqual({ request_count: 0, estimated_input_tokens: 0 });
    expect(await limiterUsage(globalLimiterStub())).toEqual(globalBefore);
    expect((await waitForReservationState(identity.accountID, "released")).reserved_seconds).toBe(CHARGE_12_SEGMENTS);
    expect(await accountRow(identity.accountID)).toEqual({
      available_seconds: DEV_GRANT,
      reserved_seconds: 0,
      consumed_seconds: 0,
    });
    expect(await waitForCounterDelta(countersBefore, "admission_releases", 1)).toEqual({
      admission_releases: 1,
    });

    // The same fingerprint starts cleanly afterwards.
    await runFunded(identity, request);
  });

  it("repairs a Running record whose heartbeat alarm could not be set", async () => {
    const countersBefore = await readCounters();
    const { identity } = await bootstrappedIdentity();
    const deviceLimiter = await deviceLimiterStub(identity);
    const globalBefore = await limiterUsage(globalLimiterStub());
    const request = makeRequest({ fingerprint: "9a9b".repeat(16), asyncSupported: true });
    const stub = jobStub(request.transcript.fingerprint);
    await runInDurableObject(stub, (_instance, state) => {
      const original = state.storage.setAlarm.bind(state.storage);
      state.storage.setAlarm = async (...args) => {
        state.storage.setAlarm = original;
        throw new Error("injected alarm failure");
      };
    });

    const response = await postEnvelope(identity, ANALYZE_PATH, request);
    expect(response.status).toBeGreaterThanOrEqual(500);
    // The written Running record was repaired into a terminal failure that
    // carries the release through the shared billing path, so a later
    // submit cannot attach to a job that never launched.
    const stored = await runInDurableObject(stub, async (_instance, state) =>
      JSON.parse(await state.storage.get("job")),
    );
    expect(stored.state).toBe("failed_transient");
    expect(stored.billing.billing_id).toMatch(/^tan-/);
    expect((await waitForReservationState(identity.accountID, "released")).reserved_seconds).toBe(CHARGE_12_SEGMENTS);
    expect(await limiterUsage(deviceLimiter)).toEqual({ request_count: 0, estimated_input_tokens: 0 });
    expect(await limiterUsage(globalLimiterStub())).toEqual(globalBefore);
    const diff = await waitForCounterDelta(countersBefore, "released_credit_seconds", CHARGE_12_SEGMENTS);
    expect(diff).toEqual({
      admission_releases: 1,
      released_credit_seconds: CHARGE_12_SEGMENTS,
    });
    expect(diff.jobs_started).toBeUndefined();

    // A resubmit starts a fresh run instead of attaching to the zombie.
    await runFunded(identity, request);
    expect(await waitForCounterDelta(countersBefore, "settled_jobs", 1)).toMatchObject({
      jobs_started: 1,
      jobs_completed: 1,
    });
  });

  it("counts a partial cleanup as failure, still releases the other scope, and keeps the 402", async () => {
    const countersBefore = await readCounters();
    const { identity } = await bootstrappedIdentity();
    const deviceLimiter = await deviceLimiterStub(identity);
    const globalBefore = await limiterUsage(globalLimiterStub());
    // Make the caller's limiter refuse to write a decrement: its admit
    // (count 0 → 1) lands, its release (→ 0) throws. The global release must
    // still run and the client must still see the typed refusal.
    await runInDurableObject(deviceLimiter, (_instance, state) => {
      const sql = state.storage.sql;
      const original = sql.exec.bind(sql);
      sql.exec = (query, ...bindings) => {
        if (query.includes("INSERT INTO daily_usage") && bindings[0] === 0) {
          sql.exec = original;
          throw new Error("injected release write failure");
        }
        return original(query, ...bindings);
      };
    });

    const response = await postEnvelope(identity, ANALYZE_PATH, unaffordableRequest("9c9d".repeat(16)));
    expect(response.status).toBe(402);
    expect((await response.json()).error).toBe("insufficient_transcription_seconds");
    // The caller scope stays charged (observable, counted); the global one
    // was given back.
    expect(await limiterUsage(deviceLimiter)).toEqual(expect.objectContaining({ request_count: 1 }));
    expect(await limiterUsage(globalLimiterStub())).toEqual(globalBefore);
    expect(counterDiff(countersBefore, await readCounters())).toEqual({
      admission_release_failures: 1,
      reserve_denied_insufficient: 1,
    });
  });

  it("serializes concurrent identical submits: one acquisition per started run, one release per refusal", async () => {
    const countersBefore = await readCounters();
    const globalBefore = await limiterUsage(globalLimiterStub());
    // Two unfunded identities race the same fingerprint: both refused, both
    // released, nothing charged.
    const [{ identity: first }, { identity: second }] = await Promise.all([
      bootstrappedIdentity(),
      bootstrappedIdentity(),
    ]);
    const refusedRequest = unaffordableRequest("9e9f".repeat(16));
    const refusals = await Promise.all([
      postEnvelope(first, ANALYZE_PATH, refusedRequest),
      postEnvelope(second, ANALYZE_PATH, refusedRequest),
    ]);
    expect(refusals.map((response) => response.status)).toEqual([402, 402]);
    expect(await limiterUsage(await deviceLimiterStub(first))).toEqual({ request_count: 0, estimated_input_tokens: 0 });
    expect(await limiterUsage(await deviceLimiterStub(second))).toEqual({ request_count: 0, estimated_input_tokens: 0 });
    expect(await limiterUsage(globalLimiterStub())).toEqual(globalBefore);

    // Two funded identities race the same content: one starts, the other
    // attaches, and exactly one acquisition is charged per scope.
    const [{ identity: starter }, { identity: joiner }] = await Promise.all([
      bootstrappedIdentity(),
      bootstrappedIdentity(),
    ]);
    const runRequest = makeRequest({ fingerprint: "9f9a".repeat(16), asyncSupported: true });
    // Hold the model call so the second submit meets a Running record (and
    // attaches) rather than a completed result.
    const deferred = mockGeminiDeferred(geminiResponse(analysisFor(12)));
    const submits = await Promise.all([
      postEnvelope(starter, ANALYZE_PATH, runRequest),
      postEnvelope(joiner, ANALYZE_PATH, runRequest),
    ]);
    expect(submits.map((response) => response.status)).toEqual([202, 202]);
    await deferred.started;
    deferred.release();
    const completed = await waitForTerminalPollAs(starter, runRequest.transcript.fingerprint);
    expect(completed.status).toBe(200);
    const starterUsage = await limiterUsage(await deviceLimiterStub(starter));
    const joinerUsage = await limiterUsage(await deviceLimiterStub(joiner));
    expect([starterUsage.request_count, joinerUsage.request_count].sort()).toEqual([0, 1]);
    expect((await limiterUsage(globalLimiterStub())).request_count).toBe(globalBefore.request_count + 1);
    expect(await waitForCounterDelta(countersBefore, "settled_jobs", 1)).toMatchObject({
      admission_releases: 2,
      reserve_denied_insufficient: 2,
      jobs_started: 1,
      jobs_completed: 1,
    });
  });

  it("keeps a seeded pre-deploy capped object capped and restores behaviour on a fresh day", async () => {
    const countersBefore = await readCounters();
    const { identity } = await bootstrappedIdentity();
    // A day object filled before the fix (refusals that leaked) keeps its
    // stored usage through object re-initialization: no reset, no repair.
    await setLimiterUsage(await deviceLimiterStub(identity), { request_count: 12, estimated_input_tokens: 600_000 });
    await abortAllDurableObjects();
    // Stubs do not survive the abort; address the revived object afresh.
    const deviceLimiter = await deviceLimiterStub(identity);
    expect(await limiterUsage(deviceLimiter)).toEqual({ request_count: 12, estimated_input_tokens: 600_000 });

    const capped = await postEnvelope(identity, ANALYZE_PATH, unaffordableRequest("9b9c".repeat(16)));
    expect(capped.status).toBe(429);
    expect((await capped.json()).error).toBe("daily_request_cap_exceeded");
    expect(await limiterUsage(deviceLimiter)).toEqual({ request_count: 12, estimated_input_tokens: 600_000 });
    expect(counterDiff(countersBefore, await readCounters())).toEqual({
      cap_denials_app_attest: 1,
    });

    // The next UTC day mints fresh objects: an unfunded probe is a 402
    // again, and a funded submit runs.
    const tomorrowIndex = Math.floor(Date.now() / 86_400_000) + 1;
    vi.useFakeTimers({ toFake: ["Date"] });
    try {
      vi.setSystemTime(tomorrowIndex * 86_400_000 + 3_600_000);
      const probe = await postEnvelope(identity, ANALYZE_PATH, unaffordableRequest("9b9c".repeat(16)));
      expect(probe.status).toBe(402);
      const tomorrowDevice = await deviceLimiterStub(identity, tomorrowIndex);
      expect(await limiterUsage(tomorrowDevice)).toEqual({ request_count: 0, estimated_input_tokens: 0 });
      mockGeminiOnce(geminiResponse(analysisFor(12)));
      const funded = await postEnvelope(
        identity,
        ANALYZE_PATH,
        makeRequest({ fingerprint: "9d9e".repeat(16), asyncSupported: true }),
      );
      expect(funded.status).toBe(202);
      expect((await limiterUsage(tomorrowDevice)).request_count).toBe(1);
      expect((await limiterUsage(globalLimiterStub(tomorrowIndex))).request_count).toBe(1);
      const completed = await waitForTerminalPollAs(identity, "9d9e".repeat(16));
      expect(completed.status).toBe(200);
      await waitForReservationState(identity.accountID, "settled");
    } finally {
      vi.useRealTimers();
      await setLimiterUsage(globalLimiterStub(tomorrowIndex), null);
    }
    // Today's leaked object is still capped: deployment repairs nothing
    // before rollover.
    expect(await limiterUsage(deviceLimiter)).toEqual({ request_count: 12, estimated_input_tokens: 600_000 });
    await setLimiterUsage(deviceLimiter, null);
  });
});

describe("terminal billing repair machinery", () => {
  it("releases a watchdogged billed run through the terminal-billing path", async () => {
    const countersBefore = await readCounters();
    const { identity } = await bootstrappedIdentity();
    const request = makeRequest({
      fingerprint: "7a".repeat(32),
      asyncSupported: true,
    });
    const deferred = mockGeminiDeferred(geminiResponse(analysisFor(12)));
    const submitted = await postEnvelope(identity, ANALYZE_PATH, request);
    expect(submitted.status).toBe(202);
    await deferred.started;
    await waitForReservationState(identity.accountID, "reserved");

    // Eviction mid-run: the revived DO's watchdog alarm must turn the job
    // into a transient failure AND release the run's reservation.
    await abortAllDurableObjects();
    const stub = jobStub(request.transcript.fingerprint);
    expect(await runDurableObjectAlarm(stub)).toBe(true);

    const reservation = await waitForReservationState(
      identity.accountID,
      "released",
    );
    expect(reservation.reserved_seconds).toBe(CHARGE_12_SEGMENTS);
    expect(await accountRow(identity.accountID)).toEqual({
      available_seconds: DEV_GRANT,
      reserved_seconds: 0,
      consumed_seconds: 0,
    });
    const failed = await waitForTerminalPollAs(
      identity,
      request.transcript.fingerprint,
    );
    expect(failed.status).toBe(503);
    expect((await failed.json()).error).toBe("job_failed_transient");
    deferred.release();
    expect(
      await waitForCounterDelta(countersBefore, "released_credit_seconds", CHARGE_12_SEGMENTS),
    ).toEqual({
      jobs_failed_transient: 1,
      jobs_started: 1,
      released_credit_seconds: CHARGE_12_SEGMENTS,
    });
  });

  it("retries a failed settle on the alarm and lands it after repair", async () => {
    const countersBefore = await readCounters();
    const { identity } = await bootstrappedIdentity();
    const request = makeRequest({
      fingerprint: "7b".repeat(32),
      asyncSupported: true,
    });
    const deferred = mockGeminiDeferred(geminiResponse(analysisFor(12)));
    const submitted = await postEnvelope(identity, ANALYZE_PATH, request);
    expect(submitted.status).toBe(202);
    await deferred.started;
    await waitForReservationState(identity.accountID, "reserved");

    // Sabotage the fake's account buckets so the settle CANNOT apply: the
    // guarded UPDATE (reserved_seconds >= charge) matches nothing. The
    // terminal-path attempt is then guaranteed to fail and park the record
    // with a pending settle for the alarm retries.
    await env.TRANSCRIPT_ANALYSIS_DB.prepare(
      "UPDATE dev_credit_accounts SET reserved_seconds = 0 WHERE account_id = ?1",
    )
      .bind(identity.accountID)
      .run();
    deferred.release();

    // Deliver-then-bill: the result serves even while the settle pends.
    const completed = await waitForTerminalPollAs(
      identity,
      request.transcript.fingerprint,
    );
    expect(completed.status).toBe(200);
    expect(
      (await waitForReservationState(identity.accountID, "reserved")).state,
    ).toBe("reserved");

    // One alarm-driven retry against the still-broken books also fails...
    const stub = jobStub(request.transcript.fingerprint);
    expect(await runDurableObjectAlarm(stub)).toBe(true);
    // ...then the books are repaired and the next retry settles for real.
    await env.TRANSCRIPT_ANALYSIS_DB.prepare(
      "UPDATE dev_credit_accounts SET reserved_seconds = ?1 WHERE account_id = ?2",
    )
      .bind(CHARGE_12_SEGMENTS, identity.accountID)
      .run();
    expect(await runDurableObjectAlarm(stub)).toBe(true);

    const settled = await waitForReservationState(
      identity.accountID,
      "settled",
    );
    expect(settled.reserved_seconds).toBe(CHARGE_12_SEGMENTS);
    expect(await accountRow(identity.accountID)).toEqual({
      available_seconds: DEV_GRANT - CHARGE_12_SEGMENTS,
      reserved_seconds: 0,
      consumed_seconds: CHARGE_12_SEGMENTS,
    });
    // Two failed attempts (terminal path + one alarm retry), then the
    // landed settle.
    expect(await waitForCounterDelta(countersBefore, "settled_jobs", 1)).toMatchObject({
      billing_retries: 2,
      charged_credit_seconds: CHARGE_12_SEGMENTS,
      jobs_completed: 1,
      settled_jobs: 1,
    });
  });

  it("keeps a failed record while its release pends, blocks billed restarts, and frees them after abandonment", async () => {
    const countersBefore = await readCounters();
    const { identity } = await bootstrappedIdentity();
    const request = makeRequest({
      fingerprint: "7c".repeat(32),
      asyncSupported: true,
    });
    const deferred = mockGeminiDeferred(GEMINI_TRUNCATED_RESPONSE);
    const submitted = await postEnvelope(identity, ANALYZE_PATH, request);
    expect(submitted.status).toBe(202);
    await deferred.started;
    await waitForReservationState(identity.accountID, "reserved");

    // Sabotage so the terminal release cannot apply, then fail the run
    // (all three model attempts truncated).
    await env.TRANSCRIPT_ANALYSIS_DB.prepare(
      "UPDATE dev_credit_accounts SET reserved_seconds = 0 WHERE account_id = ?1",
    )
      .bind(identity.accountID)
      .run();
    mockGeminiOnce(GEMINI_TRUNCATED_RESPONSE);
    mockGeminiOnce(GEMINI_TRUNCATED_RESPONSE);
    deferred.release();

    // The failure serves WITHOUT purging while the release pends — purging
    // would truncate the retry budget and strand the hold. A second poll
    // proves the record survived its own serve.
    const failed = await waitForTerminalPollAs(
      identity,
      request.transcript.fingerprint,
    );
    expect(failed.status).toBe(502);
    const again = await postEnvelope(
      identity,
      `/v1/transcript-analysis/jobs/${request.transcript.fingerprint}`,
      { job_id: request.transcript.fingerprint },
    );
    expect(again.status).toBe(502);

    // A billed restart is refused while the release is unresolved: its own
    // reserve needs the same unreachable backend, and refusing preserves
    // the pending action's full alarm retry budget.
    const blocked = await postEnvelope(identity, ANALYZE_PATH, request);
    expect(blocked.status).toBe(503);
    expect((await blocked.json()).error).toBe("billing_unavailable");
    expect(counterDiff(countersBefore, await readCounters())).toMatchObject({
      billing_unavailable: 1,
      jobs_failed_upstream: 1,
    });

    // Drive the alarm retries to the abandonment budget (terminal attempt
    // plus three alarm retries = BILLING_MAX_ATTEMPTS).
    const stub = jobStub(request.transcript.fingerprint);
    for (let attempt = 0; attempt < 3; attempt += 1) {
      expect(await runDurableObjectAlarm(stub)).toBe(true);
    }
    // Four failed attempts, then the release is abandoned (the operator
    // signal the dashboard escalates on).
    expect(await waitForCounterDelta(countersBefore, "release_abandoned", 1)).toMatchObject({
      billing_retries: 4,
      release_abandoned: 1,
    });

    // Abandonment clears the pending action (loudly, server-side), so the
    // same fingerprint restarts under a fresh tan- id and settles clean.
    mockGeminiOnce(geminiResponse(analysisFor(12)));
    const resubmitted = await postEnvelope(identity, ANALYZE_PATH, request);
    expect(resubmitted.status).toBe(202);
    const completed = await waitForTerminalPollAs(
      identity,
      request.transcript.fingerprint,
    );
    expect(completed.status).toBe(200);
    const settled = await waitForReservationState(
      identity.accountID,
      "settled",
    );
    const rows = await reservationsFor(identity.accountID);
    expect(rows.length).toBe(2);
    const stranded = rows.find((row) => row.state === "reserved");
    expect(stranded).toBeTruthy();
    expect(settled.job_id).not.toBe(stranded.job_id);
  });
});

describe("bearer lane exemption", () => {
  it("analyzes uncharged with billing required (probe lane)", async () => {
    const billingRows = () =>
      env.TRANSCRIPT_ANALYSIS_DB.prepare(
        "SELECT \
           (SELECT COUNT(*) FROM dev_credit_reservations) AS reservations, \
           (SELECT COUNT(*) FROM dev_credit_accounts) AS accounts, \
           (SELECT COUNT(*) FROM install_account_links) AS links",
      ).first();
    const before = await billingRows();

    mockGeminiOnce(geminiResponse(analysisFor(12)));
    const response = await postAnalyze(
      JSON.stringify(makeRequest({ fingerprint: "5a".repeat(32) })),
      { authorization: `Bearer ${BEARER}` },
    );
    expect(response.status).toBe(200);

    // The bearer probe lane bills nothing even with BILLING_REQUIRED on: no
    // reservation, no account, no link appears.
    expect(await billingRows()).toEqual(before);
  });
});
