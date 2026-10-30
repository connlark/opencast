import { SELF, env } from 'cloudflare:test';
import { expect, it } from 'vitest';

const url = 'https://purchase.internal/internal/v1/install-links/delete';
const post = (body) => SELF.fetch(url, {
  method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body),
});

it('deletes only the selected audit link and is idempotent', async () => {
  const installKey = `tan:${crypto.randomUUID()}`;
  const otherKey = crypto.randomUUID();
  for (const key of [installKey, otherKey]) {
    await env.PURCHASE_DB.prepare(
      'INSERT INTO install_account_links (install_key, account_id, last_verified_at, created_at) VALUES (?1, ?2, 1, 1)',
    ).bind(key, 'shared-account').run();
  }
  const first = await post({ install_key: installKey });
  expect(first.status).toBe(200);
  expect(await first.json()).toEqual({ deleted: 1 });
  const again = await post({ install_key: installKey });
  expect(again.status).toBe(200);
  expect(await again.json()).toEqual({ deleted: 0 });
  expect(await env.PURCHASE_DB.prepare(
    'SELECT account_id FROM install_account_links WHERE install_key = ?1',
  ).bind(otherKey).first()).toEqual({ account_id: 'shared-account' });
});

it('rejects invalid bodies and non-POST methods', async () => {
  for (const body of [null, [], {}, { install_key: 1 }, { install_key: '' },
    { install_key: 'a'.repeat(201) }, { install_key: 'é'.repeat(101) }]) {
    const response = await post(body);
    expect(response.status).toBe(400);
    expect(await response.json()).toEqual({ error: 'invalid_request' });
  }
  expect((await SELF.fetch(url, { method: 'POST', body: '{' })).status).toBe(400);
  expect((await SELF.fetch(url)).status).toBe(405);
  expect((await post({ install_key: 'é'.repeat(100) })).status).toBe(200);
});
