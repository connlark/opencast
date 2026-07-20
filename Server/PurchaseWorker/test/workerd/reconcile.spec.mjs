// Reconciliation (Get Transaction History V2) against the fake Apple history
// host defined in vitest.workerd.config.mjs (miniflare outboundService). The
// node-fetch transport shim routes the official API client through
// globalThis.fetch, so this exercises the real client code path — including
// the ES256 bearer JWT it mints with the throwaway IAP key — and proves the
// encrypted appTransactionID round-trips into the history URL.
//
// Fake-host contract: history for identity I returns exactly one consumable
// purchase `txn-history-<I>`; identities ending in "-revoked" carry a
// revocationDate.

import { SELF } from 'cloudflare:test';
import { describe, expect, it } from 'vitest';
import jwt from 'jsonwebtoken';
import fixtures from '../fixtures/generated/fixtures.json';

const BUNDLE_ID = 'com.connor.opencast';
const HOURS20 = 'com.connor.opencast.transcription.hours20.v1';

let uniqueCounter = 0;
function uid(prefix) {
  uniqueCounter += 1;
  return `${prefix}-recon-${Date.now()}-${uniqueCounter}`;
}

function signJws(payload) {
  return jwt.sign(payload, fixtures.trusted.leafKeyPem, {
    algorithm: 'ES256',
    header: { x5c: fixtures.trusted.x5c },
  });
}

function appTransactionJws(appTransactionId) {
  return signJws({
    receiptType: 'Sandbox',
    bundleId: BUNDLE_ID,
    applicationVersion: '1',
    receiptCreationDate: Date.now(),
    originalPurchaseDate: Date.now(),
    originalApplicationVersion: '1.0',
    appTransactionId,
  });
}

async function post(path, body) {
  return SELF.fetch(`https://purchase-worker.internal${path}`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(body),
  });
}

async function bootstrap(appTransactionId) {
  const response = await post('/internal/v1/bootstrap', {
    schema_version: 1,
    install_key: uid('install'),
    app_transaction_jws: appTransactionJws(appTransactionId),
  });
  expect(response.status).toBe(200);
  return response.json();
}

describe('history reconciliation', () => {
  it('credits a purchase missed by redeem and notification, exactly once', async () => {
    const identity = uid('apptx');
    const account = await bootstrap(identity);

    const first = await post('/internal/v1/reconcile', { account_id: account.account_id });
    expect(first.status).toBe(200);
    const firstBody = await first.json();
    expect(firstBody.accounts[0].credited).toBe(1);
    expect(firstBody.accounts[0].error).toBeUndefined();

    // A second run sees the same history and credits nothing new.
    const second = await post('/internal/v1/reconcile', { account_id: account.account_id });
    const secondBody = await second.json();
    expect(secondBody.accounts[0].credited).toBe(0);

    const balance = await post('/internal/v1/balance', { account_id: account.account_id });
    expect((await balance.json()).balance.available_seconds).toBe(75_600);
  });

  it('applies revocations found in history', async () => {
    const identity = `${uid('apptx')}-revoked`;
    const account = await bootstrap(identity);
    const transactionId = `txn-history-${identity}`;

    // The purchase was credited via redeem before Apple recorded the refund.
    const redeem = await post('/internal/v1/redeem', {
      schema_version: 1,
      account_id: account.account_id,
      transaction_jws: signJws({
        transactionId,
        originalTransactionId: transactionId,
        bundleId: BUNDLE_ID,
        productId: HOURS20,
        purchaseDate: Date.now(),
        originalPurchaseDate: Date.now(),
        quantity: 1,
        type: 'Consumable',
        appAccountToken: account.app_account_token,
        inAppOwnershipType: 'PURCHASED',
        signedDate: Date.now(),
        environment: 'Sandbox',
        transactionReason: 'PURCHASE',
        storefront: 'USA',
        appTransactionId: identity,
      }),
    });
    expect((await redeem.json()).outcome).toBe('credited');

    const response = await post('/internal/v1/reconcile', { account_id: account.account_id });
    const body = await response.json();
    expect(body.accounts[0].credited).toBe(0);
    expect(body.accounts[0].refunds_applied).toBe(1);

    const balance = await post('/internal/v1/balance', { account_id: account.account_id });
    expect((await balance.json()).balance.available_seconds).toBe(3_600);

    // Reconciling again is idempotent: the refund does not re-apply.
    const again = await post('/internal/v1/reconcile', { account_id: account.account_id });
    expect((await again.json()).accounts[0].refunds_applied).toBe(0);
  });
});
