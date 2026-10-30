import { env, createExecutionContext } from 'cloudflare:test';
import { expect, it } from 'vitest';
import { DELETE_PATH, seedInstall, counts } from '../install-delete-support.mjs';
import { postEnvelope } from '../app-attest-support.mjs';

async function seedLinkedInstall() {
  const identity = await seedInstall();
  await env.PURCHASE_TEST_DB.prepare('INSERT INTO install_account_links (install_key, account_id, last_verified_at, created_at) VALUES (?1, ?2, 1, 1)')
    .bind(identity.installID, 'shared-account').run();
  return identity;
}
async function purchaseLink(identity) {
  return env.PURCHASE_TEST_DB.prepare('SELECT account_id FROM install_account_links WHERE install_key = ?1')
    .bind(identity.installID).first();
}

it('unlinks the raw install audit entry before deleting local rows', async () => {
  const a = await seedLinkedInstall();
  const b = await seedLinkedInstall();
  expect((await postEnvelope(a, DELETE_PATH, {})).status).toBe(200);
  expect(await purchaseLink(a)).toBeNull();
  expect(await purchaseLink(b)).not.toBeNull();
  expect(await counts(a)).toEqual([0, 0, 0, 0]);
  expect(await counts(b)).toEqual([2, 1, 1, 1]);
});

it('keeps all local rows when PurchaseWorker unlink fails and permits retry', async () => {
  const a = await seedLinkedInstall();
  await env.PURCHASE_TEST_DB.exec("CREATE TRIGGER fail_unlink BEFORE DELETE ON install_account_links BEGIN SELECT RAISE(ABORT, 'injected unlink failure'); END");
  try {
    const response = await postEnvelope(a, DELETE_PATH, {});
    expect(response.status).toBe(503);
    expect(await response.json()).toEqual({ error: 'deregistration_unavailable' });
    expect(await counts(a)).toEqual([2, 1, 1, 1]);
    expect(await purchaseLink(a)).not.toBeNull();
  } finally {
    await env.PURCHASE_TEST_DB.exec('DROP TRIGGER fail_unlink');
  }
  expect((await postEnvelope(a, DELETE_PATH, {})).status).toBe(200);
});

it('rolls back the local batch after a successful unlink and retries idempotently', async () => {
  const a = await seedLinkedInstall();
  await env.TRANSCRIPTION_DB.exec("CREATE TRIGGER fail_local_delete BEFORE DELETE ON install_account_links BEGIN SELECT RAISE(ABORT, 'injected local failure'); END");
  try {
    const response = await postEnvelope(a, DELETE_PATH, {});
    expect(response.status).toBeGreaterThanOrEqual(500);
    expect(await counts(a)).toEqual([2, 1, 1, 1]);
    expect(await purchaseLink(a)).toBeNull();
  } finally {
    await env.TRANSCRIPTION_DB.exec('DROP TRIGGER fail_local_delete');
  }
  expect((await postEnvelope(a, DELETE_PATH, {})).status).toBe(200);
  expect(await counts(a)).toEqual([0, 0, 0, 0]);
});

// Pause real cross-worker traffic without changing the production handler.
import worker from '../../build/index.js';
import jwt from 'jsonwebtoken';

it.each(['after reply', 'before upsert'])('fences a bootstrap paused %s across install deletion', async (phase) => {
  const identity = await seedLinkedInstall();
  const paused = Promise.withResolvers();
  const resume = Promise.withResolvers();
  let compensationCalls = 0;
  const gateway = new worker(createExecutionContext(), {
    ...env,
    PURCHASE_WORKER: {
      constructor: env.PURCHASE_WORKER.constructor,
      async fetch(request) {
        if (new URL(request.url).pathname === '/internal/v1/bootstrap') {
          if (phase === 'before upsert') {
            paused.resolve();
            await resume.promise;
          }
          const response = await env.PURCHASE_WORKER.fetch(request);
          expect(response.status).toBe(200);
          if (phase === 'after reply') {
            paused.resolve();
            await resume.promise;
          }
          return response;
        }
        compensationCalls += 1;
        return env.PURCHASE_WORKER.fetch(request);
      },
    },
  });
  const jws = jwt.sign({
    receiptType: 'Sandbox', bundleId: 'com.connor.opencast',
    applicationVersion: '1', versionExternalIdentifier: 1,
    receiptCreationDate: Date.now(), originalPurchaseDate: Date.now(),
    originalApplicationVersion: '1.0', appTransactionId: crypto.randomUUID(),
  }, env.TEST_TRUSTED_LEAF_KEY_PEM, {
    algorithm: 'ES256', header: { x5c: JSON.parse(env.TEST_TRUSTED_X5C) },
  });
  const bootstrap = postEnvelope(identity, '/v1/remote-transcription/account/bootstrap', {
    schema_version: 1, app_transaction_jws: jws,
  }, (url, init) => gateway.fetch(new Request(url, init)));
  try {
    await Promise.race([paused.promise, bootstrap.then(response => {
      throw new Error(`bootstrap completed before the pause: ${response.status}`);
    })]);
    expect((await postEnvelope(identity, DELETE_PATH, {})).status).toBe(200);
    expect(await counts(identity)).toEqual([0, 0, 0, 0]);
    expect(await purchaseLink(identity)).toBeNull();
  } finally {
    resume.resolve();
  }
  const response = await bootstrap;
  expect(response.status).toBe(401);
  expect(await response.json()).toEqual({ error: 'unknown_key' });
  expect(await counts(identity)).toEqual([0, 0, 0, 0]);
  expect(await purchaseLink(identity)).toBeNull();
  expect(compensationCalls).toBe(1);
});
