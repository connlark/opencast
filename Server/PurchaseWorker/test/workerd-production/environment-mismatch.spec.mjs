import { SELF, env } from 'cloudflare:test';
import { describe, expect, it } from 'vitest';
import jwt from 'jsonwebtoken';
import fixtures from '../fixtures/generated/fixtures.json';

function signSandboxNotification(uuid, chain = fixtures.trusted) {
  return jwt.sign(
    {
      notificationType: 'ONE_TIME_CHARGE',
      notificationUUID: uuid,
      data: {
        bundleId: 'com.connor.opencast',
        bundleVersion: '1',
        environment: 'Sandbox',
      },
      version: '2.0',
      signedDate: Date.now(),
    },
    chain.leafKeyPem,
    { algorithm: 'ES256', header: { x5c: chain.x5c } },
  );
}

async function notify(signedPayload) {
  return SELF.fetch('https://purchase-worker.internal/internal/v1/notifications', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ signedPayload }),
  });
}

describe('production notification environment mismatch', () => {
  it('verifies, records, and alerts a sandbox payload without touching money', async () => {
    const uuid = `production-mismatch-${Date.now()}`;
    const response = await notify(signSandboxNotification(uuid));
    expect(response.status).toBe(200);
    expect(await response.json()).toMatchObject({
      state: 'recorded',
      environment_mismatch: true,
    });

    const receipt = await env.PURCHASE_DB
      .prepare(
        `SELECT state, environment, error_code FROM notification_receipts
         WHERE notification_uuid = ?1`,
      )
      .bind(uuid)
      .first();
    expect(receipt).toEqual({
      state: 'recorded',
      environment: 'Sandbox',
      error_code: 'environment_mismatch',
    });
    const counters = await env.PURCHASE_DB
      .prepare(
        `SELECT name, value FROM purchase_ops_counters
         WHERE name IN ('notification_environment_mismatch', 'pushover_alerts_sent')
         ORDER BY name`,
      )
      .all();
    expect(counters.results).toEqual([
      { name: 'notification_environment_mismatch', value: 1 },
      { name: 'pushover_alerts_sent', value: 1 },
    ]);
    expect(Number((await env.PURCHASE_DB.prepare('SELECT COUNT(*) AS count FROM transaction_index').first()).count)).toBe(0);
    expect(Number((await env.PURCHASE_DB.prepare('SELECT COUNT(*) AS count FROM purchase_accounts').first()).count)).toBe(0);

    const replay = await notify(signSandboxNotification(uuid));
    expect(await replay.json()).toMatchObject({ state: 'recorded', duplicate: true });
    const alertCount = await env.PURCHASE_DB
      .prepare("SELECT value FROM purchase_ops_counters WHERE name = 'pushover_alerts_sent'")
      .first('value');
    expect(Number(alertCount)).toBe(1);
  });

  it('does not record or alert an untrusted sandbox-shaped payload', async () => {
    const before = await env.PURCHASE_DB
      .prepare("SELECT value FROM purchase_ops_counters WHERE name = 'pushover_alerts_sent'")
      .first('value');
    const response = await notify(
      signSandboxNotification(`rogue-${Date.now()}`, fixtures.rogue),
    );
    expect(response.status).toBe(400);
    expect((await response.json()).error).toBe('notification_invalid');
    const after = await env.PURCHASE_DB
      .prepare("SELECT value FROM purchase_ops_counters WHERE name = 'pushover_alerts_sent'")
      .first('value');
    expect(Number(after)).toBe(Number(before));
  });
});
