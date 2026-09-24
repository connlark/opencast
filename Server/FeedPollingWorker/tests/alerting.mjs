import assert from 'node:assert/strict';
import { harness } from './harness.mjs';

const credential = 'pgk_production_fixture';
const recipient = 'pgr_production_fixture';
let responseStatus = 200;
const h = await harness(request => {
  if (request.url === 'https://alerts.example.com/v1/notifications') {
    const body = responseStatus === 200
      ? { aggregate_status: 'accepted' }
      : responseStatus === 409
        ? { error: { code: 'idempotency_conflict' } }
        : { error: { code: 'fixture_rate_limited' } };
    return new Response(JSON.stringify(body), { status: responseStatus, headers: { 'content-type': 'application/json' } });
  }
  return new Response('<rss><channel><title>Fixture</title></channel></rss>', { headers: { 'content-type': 'application/rss+xml' } });
}, { environment: 'production', alertSecrets: { ALERT_CREDENTIAL: credential, ALERT_RECIPIENT: recipient } });

try {
  let rollup = await h.invoke('test/dispatch');
  assert.equal(rollup.alerting, true);
  assert.equal(h.alerts.length, 1, 'the armed self-test sends once');
  assert.equal(h.alerts[0].headers.authorization, `Bearer ${credential}`);
  assert.equal(h.alerts[0].body.recipient, recipient);
  assert.equal(h.alerts[0].body.draft.schema_version, 1);

  for (let i = 0; i < 50; i++) await h.add(`https://stalled-${i}.example.com/feed`, h.now - 600);
  rollup = await h.invoke('test/dispatch');
  assert.equal(rollup.stall_state, 'stalled');
  assert.equal(h.alerts.length, 2, 'stall onset sends once');
  assert.match(h.alerts[1].body.draft.title, /Feed polling stalled \(production\)/);
  assert.match(h.alerts[1].body.draft.body, /Healthy overdue: 50/);
  assert.equal(h.alerts[1].headers['idempotency-key'], `feed-polling-stall-production-${rollup.stall_since}`);

  responseStatus = 409;
  await h.invoke('clock', '60');
  await h.run('UPDATE n_poll_dispatch SET stall_alerted_at=0');
  await h.invoke('test/dispatch');
  assert.ok((await h.first('SELECT stall_alerted_at FROM n_poll_dispatch')).stall_alerted_at > 0, 'an idempotency replay settles the onset');
  assert.equal(h.alerts.length, 3, 'the replay is sent once');
  await h.invoke('test/dispatch');
  assert.equal(h.alerts.length, 3, 'a settled idempotency replay does not re-fire');

  responseStatus = 429;
  await h.run('UPDATE n_poll_dispatch SET stall_alerted_at=0');
  await h.invoke('test/dispatch');
  assert.equal((await h.first('SELECT stall_alerted_at FROM n_poll_dispatch')).stall_alerted_at, 0, 'a failed send remains retryable');
  const retryKey = h.alerts[2].headers['idempotency-key'];
  responseStatus = 200;
  await h.invoke('test/dispatch');
  assert.equal(h.alerts[3].headers['idempotency-key'], retryKey, 'the retry keeps the onset idempotency key');

  await h.invoke('test/dispatch');
  assert.equal(h.alerts.length, 5, 'a second tick does not re-fire onset');
  await h.invoke('clock', '3660');
  rollup = await h.invoke('test/dispatch');
  assert.equal(h.alerts.length, 6, 'hourly reminder sends');
  assert.match(h.alerts[5].headers['idempotency-key'], /^feed-polling-stall-production-\d+-1$/);

  await h.run("UPDATE n_feed SET last_poll_at=?,last_poll_outcome='unchanged'", h.now + 3600);
  responseStatus = 429;
  rollup = await h.invoke('test/dispatch');
  assert.equal(rollup.stall_state, 'stalled', 'a failed recovery remains retryable');
  assert.equal(h.alerts.length, 7);
  responseStatus = 200;
  rollup = await h.invoke('test/dispatch');
  assert.equal(rollup.stall_state, 'clear');
  assert.equal(h.alerts.length, 8, 'recovery retries after a failed send');
  assert.match(h.alerts[7].body.draft.title, /Feed polling recovered \(production\)/);
  console.log('PASS Alert webhook armed, onset, hourly and recovery transitions');
} finally {
  await h.instance.dispose();
}
