// Purchase-backend billing matrix: the compiled gateway with
// CREDIT_BACKEND=purchase against the compiled PurchaseWorker
// (auxiliary worker), synthetic App Attest envelopes on the charged lane.
// AppTransaction JWS fixtures are signed in-test with the throwaway chain
// minted by the PurchaseWorker fixture tooling (leaf key + x5c via
// bindings). Money assertions read the bootstrap balance (the gateway's own
// probe surface) and PurchaseWorker's D1 reservation_index.
//
// Charge math fixture: makeRequest(segmentCount 12) declares 240 s of audio
// → ceil(240 × 7850 / 3600) = 524 credit-seconds. A fresh account holds the
// 3,600 s free grant with a 10,800 s debt cap (14,400 s headroom).
import { env } from "cloudflare:test";
import { afterAll, afterEach, beforeAll, describe, expect, it } from "vitest";
import jwt from "jsonwebtoken";
import {
  ANALYZE_PATH,
  BEARER,
  BOOTSTRAP_PATH,
  GEMINI_TRUNCATED_RESPONSE,
  analysisFor,
  geminiResponse,
  installFetchStub,
  makeRequest,
  makeSyntheticAppAttestIdentity,
  mockGeminiOnce,
  observedGeminiPayloads,
  pendingGeminiResponses,
  postAnalyze,
  postEnvelope,
  restoreFetchStub,
  seedSyntheticKey,
  waitForTerminalPollAs,
} from "../support.mjs";

const BUNDLE_ID = "com.connor.opencast";
const CHARGE_12_SEGMENTS = 524;
const FREE = 3600;

let uniqueCounter = 0;
function uid(prefix) {
  uniqueCounter += 1;
  return `${prefix}-taw-${Date.now()}-${uniqueCounter}`;
}

function signJws(payload, { keyPem, x5c } = {}) {
  return jwt.sign(payload, keyPem ?? env.TEST_TRUSTED_LEAF_KEY_PEM, {
    algorithm: "ES256",
    header: { x5c: x5c ?? JSON.parse(env.TEST_TRUSTED_X5C) },
  });
}

function appTransactionJws(appTransactionId, overrides = {}, signOptions = {}) {
  return signJws(
    {
      receiptType: "Sandbox",
      bundleId: BUNDLE_ID,
      applicationVersion: "1",
      versionExternalIdentifier: 1,
      receiptCreationDate: Date.now(),
      originalPurchaseDate: Date.now(),
      originalApplicationVersion: "1.0",
      appTransactionId,
      ...overrides,
    },
    signOptions,
  );
}

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

async function bootstrapAs(identity, appTransactionId) {
  return postEnvelope(identity, BOOTSTRAP_PATH, {
    schema_version: 1,
    app_transaction_jws: appTransactionJws(appTransactionId),
  });
}

/// Fresh install + fresh Apple identity, bootstrapped through the real
/// PurchaseWorker: the account starts at the 3,600 s free grant.
async function bootstrappedIdentity() {
  const identity = await makeSyntheticAppAttestIdentity();
  await seedSyntheticKey(identity);
  identity.appTransactionID = uid("apptx");
  const response = await bootstrapAs(identity, identity.appTransactionID);
  expect(response.status).toBe(200);
  const body = await response.json();
  expect(body.account_id).toMatch(/^pacct-/);
  identity.accountID = body.account_id;
  return { identity, bootstrap: body };
}

/// Balance probe: re-bootstrap the same identity (idempotent server-side).
async function balanceOf(identity) {
  const response = await bootstrapAs(identity, identity.appTransactionID);
  expect(response.status).toBe(200);
  return (await response.json()).balance;
}

/// Async terminal billing runs after the terminal record write; poll the
/// balance until the reservation resolves.
async function waitForBalance(identity, expected) {
  let last = null;
  for (let attempt = 0; attempt < 100; attempt += 1) {
    last = await balanceOf(identity);
    if (JSON.stringify(last) === JSON.stringify(expected)) {
      return;
    }
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  expect(last).toEqual(expected);
}

async function reservationIndexRows(accountID) {
  const rows = await env.PURCHASE_TEST_DB.prepare(
    "SELECT job_id FROM reservation_index WHERE account_id = ?1 ORDER BY created_at ASC, job_id ASC",
  )
    .bind(accountID)
    .all();
  return rows.results.map((row) => row.job_id);
}

describe("bootstrap through PurchaseWorker", () => {
  it("verifies the JWS, grants once, links install and audit rows", async () => {
    const { identity, bootstrap } = await bootstrappedIdentity();
    expect(bootstrap.balance).toEqual({
      available_seconds: FREE,
      reserved_seconds: 0,
      debt_seconds: 0,
    });

    // Idempotent: a second bootstrap is the same account, no second grant.
    const again = await bootstrapAs(identity, identity.appTransactionID);
    expect(again.status).toBe(200);
    const againBody = await again.json();
    expect(againBody.account_id).toBe(identity.accountID);
    expect(againBody.balance.available_seconds).toBe(FREE);

    // Gateway-side link (authoritative for charged routes).
    const link = await env.TRANSCRIPT_ANALYSIS_DB.prepare(
      "SELECT account_id FROM install_account_links WHERE install_id = ?1",
    )
      .bind(identity.installID)
      .first();
    expect(link.account_id).toBe(identity.accountID);

    // PurchaseWorker's write-only audit copy carries the namespaced
    // install_key (surfaces.md §1) — disjoint from RTW's raw install ids.
    const audit = await env.PURCHASE_TEST_DB.prepare(
      "SELECT account_id FROM install_account_links WHERE install_key = ?1",
    )
      .bind(`tan:${identity.installID}`)
      .first();
    expect(audit.account_id).toBe(identity.accountID);
  });

  it("converges two installs of the same Apple identity on one account", async () => {
    const appTransactionID = uid("apptx");
    const first = await makeSyntheticAppAttestIdentity();
    await seedSyntheticKey(first);
    const second = await makeSyntheticAppAttestIdentity();
    await seedSyntheticKey(second);

    const firstResponse = await bootstrapAs(first, appTransactionID);
    const secondResponse = await bootstrapAs(second, appTransactionID);
    expect(firstResponse.status).toBe(200);
    expect(secondResponse.status).toBe(200);
    const firstAccount = (await firstResponse.json()).account_id;
    const secondAccount = (await secondResponse.json()).account_id;
    expect(secondAccount).toBe(firstAccount);
  });

  it("mirrors PurchaseWorker's refusal of a rogue-signed JWS and links nothing", async () => {
    const identity = await makeSyntheticAppAttestIdentity();
    await seedSyntheticKey(identity);
    const response = await postEnvelope(identity, BOOTSTRAP_PATH, {
      schema_version: 1,
      app_transaction_jws: appTransactionJws(uid("apptx"), {}, {
        keyPem: env.TEST_ROGUE_LEAF_KEY_PEM,
        x5c: JSON.parse(env.TEST_ROGUE_X5C),
      }),
    });
    expect(response.status).toBeGreaterThanOrEqual(400);
    const link = await env.TRANSCRIPT_ANALYSIS_DB.prepare(
      "SELECT COUNT(*) AS n FROM install_account_links WHERE install_id = ?1",
    )
      .bind(identity.installID)
      .first();
    expect(link.n).toBe(0);
  });
});

describe("charged runs against the real ledger", () => {
  it("refuses a billed sync analyze with async_required (no durable record, no charge)", async () => {
    const { identity } = await bootstrappedIdentity();
    const response = await postEnvelope(
      identity,
      ANALYZE_PATH,
      makeRequest({ fingerprint: "6a".repeat(32) }),
    );
    expect(response.status).toBe(400);
    expect((await response.json()).error).toBe("async_required");
    expect((await reservationIndexRows(identity.accountID)).length).toBe(0);
  });

  it("reserves and settles a delivered async run", async () => {
    const { identity } = await bootstrappedIdentity();
    const request = makeRequest({
      fingerprint: "6b".repeat(32),
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

    await waitForBalance(identity, {
      available_seconds: FREE - CHARGE_12_SEGMENTS,
      reserved_seconds: 0,
      debt_seconds: 0,
    });
    const jobs = await reservationIndexRows(identity.accountID);
    expect(jobs.length).toBe(1);
    expect(jobs[0]).toMatch(/^tan-/);
  });

  it("settles an overdraft into debt under the shared cap", async () => {
    const { identity } = await bootstrappedIdentity();
    const request = makeRequest({
      fingerprint: "6c".repeat(32),
      asyncSupported: true,
    });
    // One declared audio-hour → 7,850 credit-seconds: above the 3,600 s
    // grant but inside the 14,400 s headroom, so the reserve admits and the
    // settle converts the accepted shortfall to debt.
    request.transcript.audio_duration = 3600;
    mockGeminiOnce(geminiResponse(analysisFor(12)));
    const submitted = await postEnvelope(identity, ANALYZE_PATH, request);
    expect(submitted.status).toBe(202);
    const completed = await waitForTerminalPollAs(
      identity,
      request.transcript.fingerprint,
    );
    expect(completed.status).toBe(200);

    await waitForBalance(identity, {
      available_seconds: 0,
      reserved_seconds: 0,
      debt_seconds: 7850 - FREE,
    });
  });

  it("refuses a charge beyond headroom with the typed 402", async () => {
    const { identity } = await bootstrappedIdentity();
    const request = makeRequest({
      fingerprint: "6d".repeat(32),
      asyncSupported: true,
    });
    request.transcript.audio_duration = 100000;
    const response = await postEnvelope(identity, ANALYZE_PATH, request);
    expect(response.status).toBe(402);
    expect(await response.json()).toEqual({
      error: "insufficient_transcription_seconds",
      charge_seconds: Math.ceil((100000 * 7850) / 3600),
      balance: {
        available_seconds: FREE,
        reserved_seconds: 0,
        debt_seconds: 0,
      },
    });
    expect((await reservationIndexRows(identity.accountID)).length).toBe(0);
  });

  it("maps a stale install link to bootstrap_required, and a re-bootstrap repairs it", async () => {
    // A link minted against a different backend (e.g. the dev fake before a
    // CREDIT_BACKEND flip) names an account PurchaseWorker does not know.
    // The typed 403 tells the client to re-bootstrap — which re-points the
    // link — instead of wedging every submit behind a dead-end 503.
    const identity = await makeSyntheticAppAttestIdentity();
    await seedSyntheticKey(identity);
    const now = Math.floor(Date.now() / 1000);
    await env.TRANSCRIPT_ANALYSIS_DB.prepare(
      "INSERT INTO install_account_links (install_id, account_id, created_at, updated_at) \
       VALUES (?1, 'acct-stale-dev-link', ?2, ?2)",
    )
      .bind(identity.installID, now)
      .run();

    const request = makeRequest({
      fingerprint: "6f".repeat(32),
      asyncSupported: true,
    });
    const refused = await postEnvelope(identity, ANALYZE_PATH, request);
    expect(refused.status).toBe(403);
    expect((await refused.json()).error).toBe("bootstrap_required");

    identity.appTransactionID = uid("apptx");
    const repaired = await bootstrapAs(identity, identity.appTransactionID);
    expect(repaired.status).toBe(200);
    identity.accountID = (await repaired.json()).account_id;

    mockGeminiOnce(geminiResponse(analysisFor(12)));
    const submitted = await postEnvelope(identity, ANALYZE_PATH, request);
    expect(submitted.status).toBe(202);
    const completed = await waitForTerminalPollAs(
      identity,
      request.transcript.fingerprint,
    );
    expect(completed.status).toBe(200);
  });

  it("mints a fresh tan- id when a failed async job restarts (released ids are dead)", async () => {
    const { identity } = await bootstrappedIdentity();
    const request = makeRequest({
      fingerprint: "6e".repeat(32),
      asyncSupported: true,
    });

    mockGeminiOnce(GEMINI_TRUNCATED_RESPONSE);
    mockGeminiOnce(GEMINI_TRUNCATED_RESPONSE);
    mockGeminiOnce(GEMINI_TRUNCATED_RESPONSE);
    const submitted = await postEnvelope(identity, ANALYZE_PATH, request);
    expect(submitted.status).toBe(202);
    // The failure poll serves the terminal error and purges the record.
    let terminal = null;
    for (let attempt = 0; attempt < 200; attempt += 1) {
      terminal = await postEnvelope(
        identity,
        `/v1/transcript-analysis/jobs/${request.transcript.fingerprint}`,
        { job_id: request.transcript.fingerprint },
      );
      if (terminal.status !== 202) {
        break;
      }
      await new Promise((resolve) => setTimeout(resolve, 5));
    }
    expect(terminal.status).toBe(502);
    await waitForBalance(identity, {
      available_seconds: FREE,
      reserved_seconds: 0,
      debt_seconds: 0,
    });

    mockGeminiOnce(geminiResponse(analysisFor(12)));
    // The restart may briefly see the typed fail-closed 503 while the
    // released reservation's DO bookkeeping (pending-clear write) lands —
    // the balance restore above is visible a beat earlier.
    let resubmitted = null;
    for (let attempt = 0; attempt < 100; attempt += 1) {
      resubmitted = await postEnvelope(identity, ANALYZE_PATH, request);
      if (resubmitted.status !== 503) {
        break;
      }
      await new Promise((resolve) => setTimeout(resolve, 10));
    }
    expect(resubmitted.status).toBe(202);
    await waitForBalance(identity, {
      available_seconds: FREE - CHARGE_12_SEGMENTS,
      reserved_seconds: 0,
      debt_seconds: 0,
    });

    // Two distinct billing ids in PurchaseWorker's global index: the
    // released one is permanently dead (`reserve:<id>` ledger key), so the
    // restart HAD to mint fresh — and both stay disjoint from RTW's
    // `job-` namespace by the tan- prefix.
    const jobs = await reservationIndexRows(identity.accountID);
    expect(jobs.length).toBe(2);
    expect(jobs[0]).toMatch(/^tan-/);
    expect(jobs[1]).toMatch(/^tan-/);
    expect(jobs[0]).not.toBe(jobs[1]);
  });
});

describe("bearer lane exemption (purchase backend)", () => {
  it("analyzes uncharged: no account, no reservation anywhere", async () => {
    const countRows = async () => {
      const reservations = await env.PURCHASE_TEST_DB.prepare(
        "SELECT COUNT(*) AS n FROM reservation_index",
      ).first();
      const accounts = await env.PURCHASE_TEST_DB.prepare(
        "SELECT COUNT(*) AS n FROM purchase_accounts",
      ).first();
      return { reservations: reservations.n, accounts: accounts.n };
    };
    const before = await countRows();

    mockGeminiOnce(geminiResponse(analysisFor(12)));
    const response = await postAnalyze(
      JSON.stringify(makeRequest({ fingerprint: "5f".repeat(32) })),
      { authorization: `Bearer ${BEARER}` },
    );
    expect(response.status).toBe(200);
    expect(await countRows()).toEqual(before);
  });
});
