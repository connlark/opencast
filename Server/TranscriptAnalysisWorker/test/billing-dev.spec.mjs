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
} from "cloudflare:test";
import { afterAll, afterEach, beforeAll, describe, expect, it } from "vitest";
import {
  ANALYZE_PATH,
  BEARER,
  BOOTSTRAP_PATH,
  GEMINI_TRUNCATED_RESPONSE,
  analysisFor,
  geminiResponse,
  installFetchStub,
  jobStub,
  makeRequest,
  makeSyntheticAppAttestIdentity,
  mockGeminiDeferred,
  mockGeminiOnce,
  observedGeminiPayloads,
  pendingGeminiResponses,
  postAnalyze,
  postEnvelope,
  restoreFetchStub,
  seedSyntheticKey,
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
    const identity = await makeSyntheticAppAttestIdentity();
    await seedSyntheticKey(identity);

    const response = await postEnvelope(
      identity,
      ANALYZE_PATH,
      makeRequest({ fingerprint: "1b".repeat(32), asyncSupported: true }),
    );
    expect(response.status).toBe(403);
    expect((await response.json()).error).toBe("bootstrap_required");
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
  });

  it("releases on failure and a restart under the same fingerprint mints a fresh tan- id", async () => {
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
  });
});

describe("insufficient balance", () => {
  it("returns the typed 402 with charge and balance, consuming nothing", async () => {
    const { identity } = await bootstrappedIdentity();
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

describe("terminal billing repair machinery", () => {
  it("releases a watchdogged billed run through the terminal-billing path", async () => {
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
  });

  it("retries a failed settle on the alarm and lands it after repair", async () => {
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
  });

  it("keeps a failed record while its release pends, blocks billed restarts, and frees them after abandonment", async () => {
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

    // Drive the alarm retries to the abandonment budget (terminal attempt
    // plus three alarm retries = BILLING_MAX_ATTEMPTS).
    const stub = jobStub(request.transcript.fingerprint);
    for (let attempt = 0; attempt < 3; attempt += 1) {
      expect(await runDurableObjectAlarm(stub)).toBe(true);
    }

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
