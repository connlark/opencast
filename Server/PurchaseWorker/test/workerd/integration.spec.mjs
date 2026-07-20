// Workerd integration matrix: the real worker + PurchaseAccount DO + D1,
// exercising the official Apple library against minted Apple-shaped chains
// (offline verification; the W1 spike proved the online OCSP path).
// JWS fixtures are signed in-test with the minted leaf key so every test can
// use a fresh Apple identity.

import { SELF, env, evictDurableObject, runInDurableObject } from 'cloudflare:test';
import { describe, expect, it } from 'vitest';
import jwt from 'jsonwebtoken';
import fixtures from '../fixtures/generated/fixtures.json';

const BUNDLE_ID = 'com.connor.opencast';
const HOURS20 = 'com.connor.opencast.transcription.hours20.v1';
const HOURS100 = 'com.connor.opencast.transcription.hours100.v1';
const CATALOG_SHA256 = 'c2b007bc37825865aa679166a6fa7d1b0d74c141999f459c12e056f3c7134ec5';

let uniqueCounter = 0;
function uid(prefix) {
  uniqueCounter += 1;
  return `${prefix}-${Date.now()}-${uniqueCounter}`;
}

function signJws(payload, { chain = fixtures.trusted, x5c = null } = {}) {
  return jwt.sign(payload, chain.leafKeyPem, {
    algorithm: 'ES256',
    header: { x5c: x5c ?? chain.x5c },
  });
}

function appTransactionJws(appTransactionId, payloadOverrides = {}, signOptions = {}) {
  return signJws(
    {
      receiptType: 'Sandbox',
      bundleId: BUNDLE_ID,
      applicationVersion: '1',
      versionExternalIdentifier: 1,
      receiptCreationDate: Date.now(),
      originalPurchaseDate: Date.now(),
      originalApplicationVersion: '1.0',
      appTransactionId,
      ...payloadOverrides,
    },
    signOptions,
  );
}

function transactionJws(fields, signOptions = {}) {
  return signJws(
    {
      transactionId: fields.transactionId,
      originalTransactionId: fields.transactionId,
      webOrderLineItemId: '0',
      bundleId: BUNDLE_ID,
      productId: fields.productId ?? HOURS20,
      purchaseDate: Date.now(),
      originalPurchaseDate: Date.now(),
      quantity: fields.quantity ?? 1,
      type: 'Consumable',
      inAppOwnershipType: 'PURCHASED',
      signedDate: Date.now(),
      environment: 'Sandbox',
      transactionReason: 'PURCHASE',
      storefront: 'USA',
      storefrontId: '143441',
      price: 990,
      currency: 'USD',
      ...(fields.appAccountToken ? { appAccountToken: fields.appAccountToken } : {}),
      ...(fields.appTransactionId ? { appTransactionId: fields.appTransactionId } : {}),
      ...(fields.extra ?? {}),
    },
    signOptions,
  );
}

function notificationJws(fields) {
  return signJws({
    notificationType: fields.type,
    ...(fields.subtype ? { subtype: fields.subtype } : {}),
    notificationUUID: fields.uuid,
    data: {
      bundleId: BUNDLE_ID,
      bundleVersion: '1',
      environment: 'Sandbox',
      ...(fields.signedTransactionInfo
        ? { signedTransactionInfo: fields.signedTransactionInfo }
        : {}),
    },
    version: '2.0',
    signedDate: Date.now(),
  });
}

async function post(path, body) {
  return SELF.fetch(`https://purchase-worker.internal${path}`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(body),
  });
}

async function bootstrap(appTransactionId, installKey = uid('install')) {
  const response = await post('/internal/v1/bootstrap', {
    schema_version: 1,
    install_key: installKey,
    app_transaction_jws: appTransactionJws(appTransactionId),
  });
  expect(response.status).toBe(200);
  return response.json();
}

async function snapshot(accountId) {
  const response = await post('/internal/v1/snapshot', { account_id: accountId });
  expect(response.status).toBe(200);
  return response.json();
}

async function sendNotification(type, uuid, signedTransactionInfo, subtype) {
  return post('/internal/v1/notifications', {
    signedPayload: notificationJws({ type, uuid, signedTransactionInfo, subtype }),
  });
}

describe('bootstrap and free grant', () => {
  it('creates the account, one free hour, token, and catalog exactly once', async () => {
    const identity = uid('apptx');
    const first = await bootstrap(identity);
    expect(first.balance).toEqual({ available_seconds: 3600, reserved_seconds: 0, debt_seconds: 0 });
    expect(first.catalog).toHaveLength(2);
    expect(first.catalog_sha256).toBe(CATALOG_SHA256);
    expect(first.app_account_token).toMatch(/^[0-9a-f-]{36}$/);

    // Reinstall / second device: same identity, different install key.
    const second = await bootstrap(identity);
    expect(second.account_id).toBe(first.account_id);
    expect(second.app_account_token).toBe(first.app_account_token);
    expect(second.balance.available_seconds).toBe(3600);

    const snap = await snapshot(first.account_id);
    const grants = snap.ledger.filter((entry) => entry.operation === 'grant');
    expect(grants).toHaveLength(1);
    expect(grants[0].idempotency_key).toBe('grant:free_grant_v1');
  });

  it('issues one grant under concurrent bootstrap of the same identity', async () => {
    const identity = uid('apptx');
    const results = await Promise.all(
      Array.from({ length: 4 }, () => bootstrap(identity)),
    );
    const accountIds = new Set(results.map((result) => result.account_id));
    expect(accountIds.size).toBe(1);
    const snap = await snapshot(results[0].account_id);
    expect(snap.ledger.filter((entry) => entry.operation === 'grant')).toHaveLength(1);
    expect(snap.buckets.available).toBe(3600);
  });

  it('migrates a schema-v1 available-plus-debt account exactly once', async () => {
    const account = await bootstrap(uid('apptx'));
    const stub = env.PURCHASE_ACCOUNT.get(
      env.PURCHASE_ACCOUNT.idFromName(account.account_id),
    );
    await runInDurableObject(stub, (_instance, state) => {
      state.storage.sql.exec(
        `UPDATE account_state
         SET schema_version = 1, status = 'refund_debt', debt = 1000
         WHERE id = 1`,
      );
    });
    await evictDurableObject(stub);

    const migrated = await snapshot(account.account_id);
    expect(migrated.schema_version).toBe(2);
    expect(migrated.status).toBe('active');
    expect(migrated.buckets).toEqual({
      available: 2_600,
      reserved: 0,
      consumed: 0,
      debt: 0,
    });
    const migrationEntries = migrated.ledger.filter(
      (entry) => entry.reason_code === 'refund_debt_normalization_v2',
    );
    expect(migrationEntries).toHaveLength(1);

    await evictDurableObject(stub);
    const restarted = await snapshot(account.account_id);
    expect(
      restarted.ledger.filter(
        (entry) => entry.reason_code === 'refund_debt_normalization_v2',
      ),
    ).toHaveLength(1);
    expect(restarted.buckets).toEqual(migrated.buckets);
  });

  it('rejects wrong bundle, wrong environment, rogue chain, short chain, and garbage', async () => {
    const cases = [
      appTransactionJws(uid('apptx'), { bundleId: 'com.evil.app' }),
      appTransactionJws(uid('apptx'), { receiptType: 'Production' }),
      appTransactionJws(uid('apptx'), {}, { chain: fixtures.rogue }),
      appTransactionJws(uid('apptx'), {}, { x5c: fixtures.trusted.x5c.slice(0, 2) }),
      'not-a-jws',
      appTransactionJws(uid('apptx'), { appTransactionId: '' }),
    ];
    const expected = [
      'invalid_app_transaction',
      'environment_mismatch',
      'invalid_app_transaction',
      'invalid_app_transaction', // INVALID_CHAIN_LENGTH surfaces as INVALID_CERTIFICATE (A5)
      'invalid_app_transaction',
      'invalid_app_transaction',
    ];
    for (const [index, jws] of cases.entries()) {
      const response = await post('/internal/v1/bootstrap', {
        schema_version: 1,
        install_key: uid('install'),
        app_transaction_jws: jws,
      });
      expect(response.status, `case ${index}`).toBe(400);
      const body = await response.json();
      expect(body.error, `case ${index}`).toBe(expected[index]);
    }
  });
});

describe('redeem', () => {
  it('credits a verified consumable exactly once; duplicates return the applied result', async () => {
    const identity = uid('apptx');
    const account = await bootstrap(identity);
    const transactionId = uid('txn');
    const jws = transactionJws({
      transactionId,
      appAccountToken: account.app_account_token,
      appTransactionId: identity,
    });

    const first = await post('/internal/v1/redeem', {
      schema_version: 1,
      account_id: account.account_id,
      transaction_jws: jws,
    });
    expect(first.status).toBe(200);
    const firstBody = await first.json();
    expect(firstBody.outcome).toBe('credited');
    expect(firstBody.credited_seconds).toBe(72_000);
    expect(firstBody.balance.available_seconds).toBe(75_600);

    const duplicate = await post('/internal/v1/redeem', {
      schema_version: 1,
      account_id: account.account_id,
      transaction_jws: jws,
    });
    const duplicateBody = await duplicate.json();
    expect(duplicateBody.outcome).toBe('already_credited');
    expect(duplicateBody.balance.available_seconds).toBe(75_600);
  });

  it('rejects unknown products, missing token, and another account token', async () => {
    const accountA = await bootstrap(uid('apptx'));
    const accountB = await bootstrap(uid('apptx'));

    const wrongProduct = await post('/internal/v1/redeem', {
      schema_version: 1,
      account_id: accountA.account_id,
      transaction_jws: transactionJws({
        transactionId: uid('txn'),
        productId: 'com.connor.opencast.transcription.hours1000.v1',
        appAccountToken: accountA.app_account_token,
      }),
    });
    expect(wrongProduct.status).toBe(400);
    expect((await wrongProduct.json()).error).toBe('invalid_product');

    const missingToken = await post('/internal/v1/redeem', {
      schema_version: 1,
      account_id: accountA.account_id,
      transaction_jws: transactionJws({ transactionId: uid('txn') }),
    });
    expect(missingToken.status).toBe(409);
    expect((await missingToken.json()).error).toBe('app_account_token_mismatch');

    const foreignToken = await post('/internal/v1/redeem', {
      schema_version: 1,
      account_id: accountA.account_id,
      transaction_jws: transactionJws({
        transactionId: uid('txn'),
        appAccountToken: accountB.app_account_token,
      }),
    });
    expect(foreignToken.status).toBe(409);
    expect((await foreignToken.json()).error).toBe('app_account_token_mismatch');
  });

  it('multiplies the grant by quantity', async () => {
    const account = await bootstrap(uid('apptx'));
    const response = await post('/internal/v1/redeem', {
      schema_version: 1,
      account_id: account.account_id,
      transaction_jws: transactionJws({
        transactionId: uid('txn'),
        productId: HOURS100,
        quantity: 2,
        appAccountToken: account.app_account_token,
      }),
    });
    const body = await response.json();
    expect(body.credited_seconds).toBe(720_000);
  });

  it('unknown account is 404', async () => {
    const response = await post('/internal/v1/redeem', {
      schema_version: 1,
      account_id: 'pacct-missing',
      transaction_jws: transactionJws({ transactionId: uid('txn') }),
    });
    expect(response.status).toBe(404);
  });
});

describe('redeem/notification race', () => {
  it('credits exactly once when redeem and ONE_TIME_CHARGE arrive concurrently', async () => {
    const identity = uid('apptx');
    const account = await bootstrap(identity);
    const transactionId = uid('txn');
    const jws = transactionJws({
      transactionId,
      appAccountToken: account.app_account_token,
      appTransactionId: identity,
    });

    const [redeemResponse, notificationResponse] = await Promise.all([
      post('/internal/v1/redeem', {
        schema_version: 1,
        account_id: account.account_id,
        transaction_jws: jws,
      }),
      sendNotification('ONE_TIME_CHARGE', uid('uuid'), jws),
    ]);
    expect(redeemResponse.status).toBe(200);
    expect(notificationResponse.status).toBe(200);

    const snap = await snapshot(account.account_id);
    expect(snap.buckets.available).toBe(75_600);
    expect(snap.ledger.filter((entry) => entry.operation === 'grant')).toHaveLength(2); // free + one purchase
    expect(snap.transactions).toHaveLength(1);
  });
});

describe('notifications', () => {
  it('credits ONE_TIME_CHARGE via the account token and replays are duplicates', async () => {
    const account = await bootstrap(uid('apptx'));
    const transactionId = uid('txn');
    const jws = transactionJws({
      transactionId,
      appAccountToken: account.app_account_token,
    });
    const uuid = uid('uuid');

    const first = await sendNotification('ONE_TIME_CHARGE', uuid, jws);
    expect(first.status).toBe(200);
    expect((await first.json()).state).toBe('processed');

    const replay = await post('/internal/v1/notifications', {
      signedPayload: notificationJws({ type: 'ONE_TIME_CHARGE', uuid, signedTransactionInfo: jws }),
    });
    expect((await replay.json()).duplicate).toBe(true);

    const snap = await snapshot(account.account_id);
    expect(snap.buckets.available).toBe(75_600);
  });

  it('records unmatched charges for identities that never bootstrapped', async () => {
    const jws = transactionJws({ transactionId: uid('txn') });
    const response = await sendNotification('ONE_TIME_CHARGE', uid('uuid'), jws);
    expect(response.status).toBe(200);
    expect((await response.json()).state).toBe('unmatched');
  });

  it('applies full refund after consumption as debt and reverses it', async () => {
    const identity = uid('apptx');
    const account = await bootstrap(identity);
    const transactionId = uid('txn');
    const jws = transactionJws({
      transactionId,
      appAccountToken: account.app_account_token,
      appTransactionId: identity,
    });
    await post('/internal/v1/redeem', {
      schema_version: 1,
      account_id: account.account_id,
      transaction_jws: jws,
    });

    // Consume most of the balance so the refund creates debt.
    const jobId = uid('job');
    await post('/internal/v1/reserve', {
      account_id: account.account_id,
      job_id: jobId,
      seconds: 70_000,
    });
    await post('/internal/v1/settle', { job_id: jobId });

    const refundJws = transactionJws({
      transactionId,
      appAccountToken: account.app_account_token,
      extra: { revocationDate: Date.now(), revocationReason: 0 },
    });
    const refund = await sendNotification('REFUND', uid('uuid'), refundJws);
    expect((await refund.json()).state).toBe('processed');

    const afterRefund = await snapshot(account.account_id);
    // 75600 - 70000 = 5600 available before refund; revoking the 72000 lot
    // removes its remaining available and books the consumed rest as debt.
    expect(afterRefund.buckets.available).toBe(0);
    expect(afterRefund.buckets.debt).toBe(66_400);
    expect(afterRefund.status).toBe('refund_debt');

    const reversal = await sendNotification('REFUND_REVERSED', uid('uuid'), refundJws);
    expect((await reversal.json()).state).toBe('processed');
    const afterReversal = await snapshot(account.account_id);
    expect(afterReversal.buckets.available).toBe(5_600);
    expect(afterReversal.buckets.debt).toBe(0);
  });

  it('nets an old refund against a newer purchase that was already credited', async () => {
    const identity = uid('apptx');
    const account = await bootstrap(identity);
    const oldTransactionId = uid('txn-old');
    const oldJws = transactionJws({
      transactionId: oldTransactionId,
      appAccountToken: account.app_account_token,
      appTransactionId: identity,
    });
    await post('/internal/v1/redeem', {
      schema_version: 1,
      account_id: account.account_id,
      transaction_jws: oldJws,
    });

    const jobId = uid('job');
    await post('/internal/v1/reserve', {
      account_id: account.account_id,
      job_id: jobId,
      seconds: 25_000,
    });
    await post('/internal/v1/settle', { job_id: jobId });

    const newTransactionId = uid('txn-new');
    await post('/internal/v1/redeem', {
      schema_version: 1,
      account_id: account.account_id,
      transaction_jws: transactionJws({
        transactionId: newTransactionId,
        productId: HOURS100,
        appAccountToken: account.app_account_token,
        appTransactionId: identity,
      }),
    });

    const refundJws = transactionJws({
      transactionId: oldTransactionId,
      appAccountToken: account.app_account_token,
      extra: { revocationDate: Date.now(), revocationReason: 0 },
    });
    const refundResponse = await sendNotification('REFUND', uid('uuid'), refundJws);
    expect((await refundResponse.json()).state).toBe('processed');

    const snap = await snapshot(account.account_id);
    expect(snap.schema_version).toBe(2);
    expect(snap.status).toBe('active');
    expect(snap.buckets).toEqual({
      available: 338_600,
      reserved: 0,
      consumed: 25_000,
      debt: 0,
    });
    expect(snap.ledger.slice(-2).map((entry) => entry.operation)).toEqual([
      'refund',
      'debt_repayment',
    ]);
    expect(snap.ledger.at(-1).transaction_id).toBe(newTransactionId);
  });

  it('applies prorated refunds with floor math', async () => {
    const identity = uid('apptx');
    const account = await bootstrap(identity);
    const transactionId = uid('txn');
    const jws = transactionJws({
      transactionId,
      appAccountToken: account.app_account_token,
    });
    await post('/internal/v1/redeem', {
      schema_version: 1,
      account_id: account.account_id,
      transaction_jws: jws,
    });

    const refundJws = transactionJws({
      transactionId,
      appAccountToken: account.app_account_token,
      extra: {
        revocationDate: Date.now(),
        revocationReason: 0,
        revocationType: 'REFUND_PRORATED',
        revocationPercentage: 33_333,
      },
    });
    const refund = await sendNotification('REFUND', uid('uuid'), refundJws);
    expect((await refund.json()).state).toBe('processed');
    const snap = await snapshot(account.account_id);
    // floor(72000 × 33333 / 100000) = 23999 revoked from available.
    expect(snap.buckets.available).toBe(3_600 + 72_000 - 23_999);
    expect(snap.buckets.debt).toBe(0);
  });

  it('records REFUND_DECLINED, CONSUMPTION_REQUEST, TEST, and unknown types without money changes', async () => {
    const account = await bootstrap(uid('apptx'));
    const jws = transactionJws({
      transactionId: uid('txn'),
      appAccountToken: account.app_account_token,
    });

    for (const [type, expected] of [
      ['REFUND_DECLINED', 'recorded'],
      ['CONSUMPTION_REQUEST', 'recorded'],
      ['TEST', 'recorded'],
      ['SOME_FUTURE_TYPE', 'unsupported'],
    ]) {
      const response = await sendNotification(type, uid('uuid'), type === 'TEST' ? undefined : jws);
      expect(response.status, type).toBe(200);
      expect((await response.json()).state, type).toBe(expected);
    }
    const snap = await snapshot(account.account_id);
    expect(snap.buckets.available).toBe(3_600);
  });

  it('rejects tampered payloads before reading any field', async () => {
    const response = await post('/internal/v1/notifications', {
      signedPayload: 'garbage.payload.signature',
    });
    expect(response.status).toBe(400);
    expect((await response.json()).error).toBe('notification_invalid');
  });
});

describe('credit seam (reserve/settle/release)', () => {
  it('admits overdraft within the cap, blocks beyond it, and repays debt first', async () => {
    const account = await bootstrap(uid('apptx'));

    const tooBig = await post('/internal/v1/reserve', {
      account_id: account.account_id,
      job_id: uid('job'),
      seconds: 14_401,
    });
    expect(tooBig.status).toBe(409);
    expect((await tooBig.json()).error).toBe('insufficient_credits');

    const jobId = uid('job');
    const reserve = await post('/internal/v1/reserve', {
      account_id: account.account_id,
      job_id: jobId,
      seconds: 5_000,
    });
    expect(reserve.status).toBe(200);
    const reserveBody = await reserve.json();
    expect(reserveBody.balance.reserved_seconds).toBe(5_000);

    // Duplicate reserve attaches to the existing reservation.
    const duplicate = await post('/internal/v1/reserve', {
      account_id: account.account_id,
      job_id: jobId,
      seconds: 5_000,
    });
    expect((await duplicate.json()).already_existed).toBe(true);

    const settle = await post('/internal/v1/settle', { job_id: jobId });
    expect(settle.status).toBe(200);
    const settleBody = await settle.json();
    expect(settleBody.balance).toEqual({
      available_seconds: 0,
      reserved_seconds: 0,
      debt_seconds: 1_400,
    });

    // A purchase repays debt before adding available time.
    const redeem = await post('/internal/v1/redeem', {
      schema_version: 1,
      account_id: account.account_id,
      transaction_jws: transactionJws({
        transactionId: uid('txn'),
        appAccountToken: account.app_account_token,
      }),
    });
    const redeemBody = await redeem.json();
    expect(redeemBody.balance).toEqual({
      available_seconds: 70_600,
      reserved_seconds: 0,
      debt_seconds: 0,
    });
  });

  it('settle of an unknown job is 404; release of an unknown job is a no-op', async () => {
    const settle = await post('/internal/v1/settle', { job_id: uid('job') });
    expect(settle.status).toBe(404);
    expect((await settle.json()).error).toBe('reservation_not_found');

    const release = await post('/internal/v1/release', { job_id: uid('job') });
    expect(release.status).toBe(200);
  });

  it('release returns reserved seconds and settling a released reservation conflicts', async () => {
    const account = await bootstrap(uid('apptx'));
    const jobId = uid('job');
    await post('/internal/v1/reserve', {
      account_id: account.account_id,
      job_id: jobId,
      seconds: 1_000,
    });
    const release = await post('/internal/v1/release', { job_id: jobId });
    expect(release.status).toBe(200);
    expect((await release.json()).balance.reserved_seconds).toBe(0);

    const settle = await post('/internal/v1/settle', { job_id: jobId });
    expect(settle.status).toBe(409);
    expect((await settle.json()).error).toBe('reservation_conflict');
  });

  it('balance for an unknown account is 404', async () => {
    const response = await post('/internal/v1/balance', { account_id: 'pacct-nope' });
    expect(response.status).toBe(404);
    expect((await response.json()).error).toBe('account_not_found');
  });
});

describe('operations floor', () => {
  it('records accumulating liability snapshots from authoritative account DO totals', async () => {
    const baselineResponse = await post('/internal/v1/liability-snapshot', {});
    expect(baselineResponse.status).toBe(200);
    const baseline = await baselineResponse.json();
    expect(baseline.complete).toBe(true);

    await bootstrap(uid('liability-available'));
    const debtAccount = await bootstrap(uid('liability-debt'));
    const debtJob = uid('liability-job');
    expect((await post('/internal/v1/reserve', {
      account_id: debtAccount.account_id,
      job_id: debtJob,
      seconds: 5_000,
    })).status).toBe(200);
    expect((await post('/internal/v1/settle', { job_id: debtJob })).status).toBe(200);

    const response = await post('/internal/v1/liability-snapshot', {});
    expect(response.status).toBe(200);
    const snapshot = await response.json();
    expect(snapshot.complete).toBe(true);
    expect(snapshot.account_count).toBe(baseline.account_count + 2);
    expect(snapshot.accounts_sampled).toBe(snapshot.account_count);
    expect(snapshot.outstanding_seconds).toBe(baseline.outstanding_seconds + 3_600);
    expect(snapshot.debt_seconds).toBe(baseline.debt_seconds + 1_400);

    const rows = await env.PURCHASE_DB
      .prepare('SELECT COUNT(*) AS count FROM liability_snapshots')
      .first();
    expect(Number(rows.count)).toBeGreaterThanOrEqual(2);
    const counter = await env.PURCHASE_DB
      .prepare("SELECT value FROM purchase_ops_counters WHERE name = 'liability_snapshot_runs'")
      .first();
    expect(Number(counter.value)).toBeGreaterThanOrEqual(2);
  });
});
