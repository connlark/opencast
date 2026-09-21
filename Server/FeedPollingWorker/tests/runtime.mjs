import assert from 'node:assert/strict';
import { writeFile } from 'node:fs/promises';
import { harness, item, rss } from './harness.mjs';

let version = 1, validators = true, hook, loseReceipt = false;
const h = await harness(async request => {
  if (hook) { const fn = hook; hook = undefined; const response = await fn(request); if (response) return response; }
  if (validators && request.headers.get('if-none-match') === `"v${version}"`) return new Response(null, { status: 304 });
  return new Response(rss([item('baseline', h.now - 100), ...(version > 1 ? Array.from({ length: 5 }, (_, i) => item(`new-${i}`, h.now - 10 + i)) : [])]), validators ? { headers: { etag: `"v${version}"` } } : {});
}, { loseReceipt: () => { const lose = loseReceipt; loseReceipt = false; return lose; } });
// Every table a poll attempt used to write. A 304 or an unchanged 200 must
// leave all of them exactly as they were.
const durable = async () => Object.fromEntries(await Promise.all(['n_observation', 'n_snapshot', 'n_snapshot_ref', 'n_episode_release', 'n_outbox', 'n_event', 'n_poll_origin', 'n_poll_stat'].map(async table => [table, (await h.first(`SELECT COUNT(*) AS n FROM ${table}`)).n])));
const objects = async () => (await (await h.instance.getR2Bucket('FEED_SNAPSHOTS', 'polling-runtime')).list()).objects.length;
// On a fifteen-minute boundary the dispatcher also admits a cleanup wakeup.
const last = async () => (await h.invoke('metrics')).recent.filter(t => t.path === '/test/consume' && t.outcome !== 'cleanup_saved').at(-1);
try {
  const feed = await h.add('https://fixture.example.com/feed.xml');
  const publicAttempt = await h.instance.dispatchFetch('https://polling.invalid/dispatch', { method: 'POST', headers: { 'x-polling-capability': 'private' } });
  assert.equal(publicAttempt.status, 404); await publicAttempt.text();
  await h.run("UPDATE n_control SET enabled=0 WHERE name='dispatcher_admission'");
  assert.equal((await h.invoke('test/dispatch')).disabled, true);
  await h.run("UPDATE n_control SET enabled=1 WHERE name='dispatcher_admission'");
  await h.invoke('fault', 'missing_events');
  const missing = await h.instance.dispatchFetch('https://polling.invalid/test/dispatch', { method: 'POST' });
  assert.equal(missing.status, 500); await missing.text();
  // Overlapping dispatchers reserve a feed once: one generation, one message.
  await Promise.all([h.invoke('test/dispatch'), h.invoke('test/dispatch')]);
  const wakes = await h.polls(); assert.equal(wakes.length, 1, JSON.stringify(wakes));
  const wake = wakes[0];
  assert.deepEqual(Object.keys(wake).sort(), ['due_at', 'environment', 'feed_id', 'generation', 'kind', 'owner_epoch', 'schema_version', 'step']);
  assert.deepEqual([wake.feed_id, wake.owner_epoch, wake.generation, wake.schema_version], [feed, 1, 1, 2]);
  // The same message delivered twice at once is one logical poll.
  await Promise.all([h.consume(wake), h.consume(wake)]);
  await h.drain();
  assert.ok(h.fetches.length <= 2, 'an equal-generation duplicate may repeat one fetch, never more');
  assert.equal((await h.first('SELECT observation_generation FROM n_feed')).observation_generation, 1);
  assert.equal((await h.first('SELECT COUNT(*) AS n FROM n_observation')).n, 1);
  assert.equal((await h.first('SELECT COUNT(*) AS n FROM n_event')).n, 0);
  assert.deepEqual(await h.first('SELECT dispatch_until,last_poll_outcome FROM n_feed'), { dispatch_until: 0, last_poll_outcome: 'published' });
  console.log('PASS private ingress, disabled controls, single reservation, duplicate delivery and quiet baseline');

  // Matched 304: a schedule update, not an observation.
  let before = await durable(), stored = await objects(), requests = h.fetches.length;
  await h.run('UPDATE n_feed SET due_at=?', h.now - 1800);
  await h.invoke('test/dispatch'); await h.drain();
  assert.equal(h.fetches.length, requests + 1);
  assert.deepEqual(await durable(), before, 'a matched 304 creates no durable row');
  assert.equal(await objects(), stored, 'a matched 304 creates no object');
  let trace = await last();
  assert.equal(trace.outcome, 'not_modified');
  assert.deepEqual([trace.put, trace.get, trace.head, trace.multipart], [0, 0, 0, 0]);
  assert.ok(trace.rows_written <= 3, `304 settle wrote ${trace.rows_written} rows`);
  let state = await h.first('SELECT observation_generation,due_at,dispatch_until,last_poll_outcome FROM n_feed');
  // The adaptive production policy, re-run on this poll: a release within two
  // days is the fifteen-minute hot floor, coalesced to one future slot.
  assert.ok(state.due_at > h.now && state.due_at <= h.now + 900, JSON.stringify(state));
  assert.deepEqual([state.observation_generation, state.dispatch_until, state.last_poll_outcome], [1, 0, 'not_modified']);
  console.log('PASS matched 304 writes only the feed schedule, coalesces an outage and keeps the 15-minute floor');

  // Semantically unchanged 200 from a publisher with no validators.
  validators = false; requests = h.fetches.length;
  for (let round = 0; round < 2; round++) {
    await h.run('UPDATE n_feed SET due_at=?', h.now);
    await h.invoke('test/dispatch'); await h.drain();
    assert.deepEqual(await durable(), before, 'an unchanged 200 creates no durable row');
    assert.equal(await objects(), stored, 'an unchanged 200 creates no object');
    trace = await last();
    assert.equal(trace.outcome, 'unchanged');
    assert.deepEqual([trace.put, trace.get, trace.head, trace.multipart], [0, 0, 0, 0]);
    assert.ok(trace.rows_written <= 3, `unchanged settle wrote ${trace.rows_written} rows`);
  }
  assert.equal(h.fetches.length, requests + 2);
  state = await h.first('SELECT observation_generation,etag,last_poll_outcome FROM n_feed');
  assert.deepEqual(state, { observation_generation: 1, etag: null, last_poll_outcome: 'unchanged' });
  validators = true;
  console.log('PASS unchanged 200 without validators writes only the feed schedule and response validators');

  version = 2; loseReceipt = true;
  await h.run('UPDATE n_feed SET due_at=?', h.now);
  await h.invoke('test/dispatch'); await h.drain();
  assert.equal((await h.first('SELECT COUNT(*) AS n FROM n_episode_release')).n, 5);
  // Keep the next phase slot out of the early-admission window: the lost
  // receipt must be retried by maintenance alone, without an RSS fetch.
  await h.run('UPDATE n_feed SET due_at=?', h.now + 7200);
  await h.run("UPDATE n_outbox SET next_attempt_at=0 WHERE state='pending'");
  requests = h.fetches.length;
  await h.invoke('test/dispatch'); await h.drain(); await h.deliver();
  assert.equal(h.fetches.length, requests);
  assert.equal((await h.first('SELECT COUNT(*) AS n FROM n_event')).n, 5);
  assert.equal(h.sends.length, 1); assert.equal(h.sends[0].opencast.episode_count, 5);
  assert.equal(h.sends[0].aps.category, 'OPENCAST_EPISODE');
  assert.equal((await h.first('SELECT observation_generation FROM n_feed')).observation_generation, 2);
  assert.equal((await h.first('SELECT dispatch_until FROM n_feed')).dispatch_until, 0);
  console.log('PASS changed 200 materializes the complete scan/preparation/drain/outbox once, fixed burst and lost receipt');

  // Acknowledged-but-lost enqueue: the reservation expires, then a new
  // generation is issued. Nothing but the feed row is the recovery source.
  await h.run('UPDATE n_feed SET due_at=?', h.now);
  await h.invoke('fault', 'lost_queue'); await h.invoke('test/dispatch');
  assert.equal((await h.polls()).length, 0);
  const reserved = await h.first('SELECT schedule_generation,dispatch_until FROM n_feed');
  await h.invoke('test/dispatch'); assert.equal((await h.polls()).length, 0, 'a live reservation is not re-dispatched');
  await h.invoke('clock', '301'); await h.invoke('test/dispatch');
  const recovered = await h.polls(); assert.equal(recovered.length, 1);
  assert.equal(recovered[0].generation, reserved.schedule_generation + 1);
  for (const message of recovered) assert.equal((await h.consume(message)).status, 200);
  assert.equal(h.fetches.length, requests + 1);
  await h.invoke('clock', '0');
  console.log('PASS acknowledged-but-lost enqueue recovers when its reservation expires');

  await h.run('UPDATE n_feed SET due_at=?', h.now);
  await h.invoke('test/dispatch');
  const obsolete = (await h.polls())[0];
  await h.run('UPDATE feed_subscriptions SET notifications_enabled=0');
  requests = h.fetches.length;
  assert.equal((await h.consume(obsolete)).outcome, 'obsolete'); await h.invoke('test/dispatch');
  assert.equal(h.fetches.length, requests);
  await h.run('UPDATE feed_subscriptions SET notifications_enabled=1');
  // Reactivation revises eligibility; an older generation or epoch stays dead.
  await h.invoke('clock', '301'); await h.invoke('test/dispatch'); await h.polls(); await h.invoke('clock', '0');
  assert.equal((await h.consume(obsolete)).outcome, 'obsolete');
  assert.equal((await h.consume({ ...obsolete, generation: obsolete.generation + 1, owner_epoch: 9 })).outcome, 'obsolete');
  for (const bad of [{ ...obsolete, schema_version: 1 }, { ...obsolete, feed_id: 'https://raw.example.com/feed' }, { ...obsolete, environment: 'production' }, { ...obsolete, url: 'x' }])
    assert.equal((await h.consume(bad)).status, 400);
  assert.equal(h.fetches.length, requests);
  console.log('PASS last-interest removal, stale generation, stale owner epoch and malformed envelopes never fetch');

  assert.equal((await h.first("SELECT COUNT(*) AS n FROM sqlite_master WHERE name='n_poll'")).n, 0);
  assert.equal((await h.first("SELECT COUNT(*) AS n FROM sqlite_master WHERE name='n_origin_permit'")).n, 0);
  console.log('PASS no per-attempt job, lease, permit or receipt row was ever created');
  await writeFile('/private/tmp/opencast-pass045-runtime.json', JSON.stringify({ status: 'passed', metrics: await h.invoke('metrics'), stats: await h.invoke('test/stats') }, null, 2));
} finally { await h.instance.dispose(); }
