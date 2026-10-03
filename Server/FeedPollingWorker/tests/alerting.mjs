import assert from 'node:assert/strict';
import { ALERT_WEBHOOK_URL, harness } from './harness.mjs';

const credential = 'alert_credential_fixture';
const recipient = 'alert_recipient_fixture';
let responseStatus = 200;
const h = await harness(request => {
  if (request.url === ALERT_WEBHOOK_URL) {
    const body = responseStatus === 200
      ? { aggregate_status: 'accepted' }
      : responseStatus === 409
        ? { error: { code: 'idempotency_conflict' } }
        : { error: { code: 'fixture_rate_limited' } };
    return new Response(JSON.stringify(body), { status: responseStatus, headers: { 'content-type': 'application/json' } });
  }
  return new Response('<rss><channel><title>Fixture</title></channel></rss>', { headers: { 'content-type': 'application/rss+xml' } });
}, { environment: 'production', alertSecrets: { ALERT_WEBHOOK_URL, ALERT_CREDENTIAL: credential, ALERT_RECIPIENT: recipient } });

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
  assert.match(h.alerts[1].body.draft.body, /late_600: 0/);
  assert.doesNotMatch(h.alerts[1].body.draft.body, /Redeploy/);

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
  console.log('PASS alert webhook armed, onset, hourly and recovery transitions');

  const at = h.now + 3660;
  await h.invoke('freeze', String(at)); await h.invoke('clock', '0');
  await h.run('UPDATE n_feed SET due_at=?', at + 7200);
  const late = [];
  for (let i = 0; i < 16; i++) late.push(await h.add(`https://late-${i}.example.com/feed`, at - 700));
  await h.run("UPDATE n_feed SET snapshot_key='fixture-scanned' WHERE feed_id IN(SELECT value FROM json_each(?))", JSON.stringify(late.slice(1)));
  await h.run('UPDATE n_feed SET admission_paused=1 WHERE feed_id=?', late[1]);
  await h.run("UPDATE feed_subscriptions SET notifications_enabled=0 WHERE feed_url='https://late-2.example.com/feed'");
  await h.run('UPDATE n_feed SET poll_failures=1 WHERE feed_id=?', late[3]);
  await h.run('UPDATE n_feed SET handling_failures=1 WHERE feed_id=?', late[4]);
  await h.run('UPDATE n_feed SET retry_at=? WHERE feed_id=?', at + 100, late[5]);
  await h.run("UPDATE n_feed SET origin_key='fixture-cooling',due_at=? WHERE feed_id=?", at - 20000, late[6]);
  await h.run("INSERT INTO n_poll_origin(origin_key,cooldown_until,failures,updated_at) VALUES('fixture-cooling',?,1,?)", at + 100, at);
  rollup = await h.invoke('test/dispatch');
  assert.equal(rollup.late_600, 9, 'only healthy, eligible, previously scanned feeds count');
  assert.equal(rollup.late_baselines, 1, 'baseline lateness is reported separately');
  assert.equal(rollup.stall_state, 'clear', 'nine late feeds do not trigger onset');
  assert.equal(rollup.oldest_due_seconds, 700, 'cooling origin is excluded from maximum age');
  const stats = await h.invoke('test/stats');
  assert.equal(stats.oldest_due_seconds, rollup.oldest_due_seconds);
  assert.equal(stats.late_600, rollup.late_600);
  await h.run('UPDATE n_feed SET retry_at=0 WHERE feed_id=?', late[5]);
  rollup = await h.invoke('test/dispatch');
  assert.equal(rollup.late_600, 10);
  assert.equal(rollup.stall_state, 'stalled', 'lateness alerts despite ongoing completions');
  const alertsAtOnset = h.alerts.length;
  await h.run('UPDATE n_feed SET due_at=? WHERE feed_id IN(SELECT value FROM json_each(?))', at + 7200, JSON.stringify(late.slice(5, 15)));
  rollup = await h.invoke('test/dispatch');
  assert.equal(rollup.late_600, 1);
  assert.equal(rollup.stall_state, 'stalled', 'a trickle of completions cannot clear remaining lateness');
  assert.equal(h.alerts.length, alertsAtOnset);
  await h.run('UPDATE n_feed SET due_at=?', at + 7200);
  rollup = await h.invoke('test/dispatch');
  assert.equal(rollup.late_600, 0);
  assert.equal(rollup.stall_state, 'clear');
  console.log('PASS lateness threshold, health exclusions, baseline separation and trickle-completion hysteresis');
} finally {
  await h.instance.dispose();
}

// A webhook URL that is not HTTPS would carry the bearer credential in clear,
// so it leaves alerting off rather than sending.
const plain = await harness(request => {
  if (request.url.startsWith('http://alerts.example.com/')) throw new Error('sent over plain HTTP');
  return new Response('<rss><channel><title>Fixture</title></channel></rss>', { headers: { 'content-type': 'application/rss+xml' } });
}, { environment: 'production', alertSecrets: { ALERT_WEBHOOK_URL: 'http://alerts.example.com/v1/notifications', ALERT_CREDENTIAL: credential, ALERT_RECIPIENT: recipient } });
try {
  const rollup = await plain.invoke('test/dispatch');
  assert.equal(rollup.alerting, false);
  assert.equal(plain.alerts.length, 0);
  assert.equal((await plain.invoke('test/stats')).alerting, false);
  console.log('PASS a non-HTTPS alert webhook leaves alerting off');
} finally {
  await plain.instance.dispose();
}
