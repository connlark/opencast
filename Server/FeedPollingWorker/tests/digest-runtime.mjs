// Semantic digests identify immutable snapshot keys, not reusable generations.
// Corrupt/stale digests must not suppress a change after history expiry.
import assert from 'node:assert/strict';
import { harness, item, rss } from './harness.mjs';

let document;
const h = await harness(() => new Response(rss(document)), { deliveryBindings: { NOTIFICATION_FEED_OBSERVATION: 'true', NOTIFICATION_CLEANUP: 'true' } });
const bucket = await h.instance.getR2Bucket('FEED_SNAPSHOTS', 'polling-runtime');
const events = async feed => (await h.first('SELECT COUNT(*) AS n FROM n_event e JOIN n_episode_release r ON r.event_id=e.event_id WHERE r.feed_id=?', feed)).n;
const poll = async (feed, next) => { document = next; await h.run('UPDATE n_feed SET due_at=0,retry_at=0,poll_failures=0,dispatch_until=0 WHERE feed_id=?', feed); await h.invoke('test/dispatch'); await h.drain(); await h.deliver(); };
// A generation that published, settled and drained, with nothing retried.
async function coherent(feed, generation, name) {
  const p = await h.first('SELECT observation_generation,snapshot_key,semantic_digest,dispatch_until,handling_failures,last_poll_outcome,last_poll_error,lease_id FROM n_feed WHERE feed_id=?', feed);
  assert.equal(p.observation_generation, generation, name);
  const manifest = JSON.parse(await (await bucket.get(p.snapshot_key)).text());
  assert.deepEqual([manifest.feed_id, manifest.generation], [feed, generation], `${name}: the pointer names this generation's immutable manifest`);
  assert.match(p.semantic_digest, new RegExp(`^${p.snapshot_key}:[0-9a-f]{64}$`), `${name}: the digest is bound to the published snapshot`);
  assert.deepEqual([p.dispatch_until, p.handling_failures, p.last_poll_error, p.lease_id], [0, 0, null, null], `${name}: settled, nothing held or failed`);
  assert.equal((await h.first("SELECT COUNT(*) AS n FROM n_observation WHERE feed_id=? AND state='published' AND drain_complete=0", feed)).n, 0, `${name}: drained`);
  const stats = await h.invoke('test/stats');
  assert.deepEqual([stats.handling_failure_total, stats.dead_letter_total], [0, 0], `${name}: a stale digest must not dead-letter`);
  return p;
}
// Inject a digest belonging to a previous immutable snapshot.
const leaveStaleDigest = (feed, digest) => h.run('UPDATE n_feed SET semantic_digest=? WHERE feed_id=?', digest, feed);
try {
  const old = ['a1', 'a2'].map((id, i) => item(id, h.now - (9 - i) * 86400)), recent = id => item(id, h.now - 60);
  const feed = await h.add('https://stale-digest.example.com/feed');
  await poll(feed, old); await poll(feed, [...old, recent('a3')]);
  const left = (await coherent(feed, 2, 'current writer')).semantic_digest;
  assert.equal(await events(feed), 1);
  // Publish a4 under a new key, then inject the previous digest.
  await poll(feed, [...old, recent('a3'), recent('a4')]);
  await coherent(feed, 3, 'changed publication'); await leaveStaleDigest(feed, left);
  assert.equal(await events(feed), 2);
  // The strongest input is the membership the stale digest describes. It is
  // now a removal and must publish; an unbound digest would call it unchanged.
  await poll(feed, [...old, recent('a3')]);
  await coherent(feed, 4, 'the stale digest cannot suppress a removal');
  assert.equal(await events(feed), 2, 'a removal is not a release');
  await poll(feed, [...old, recent('a3'), recent('a4'), recent('a5')]);
  await coherent(feed, 5, 'next release after the round trip');
  assert.equal(await events(feed), 3, 'exactly the new member alerts; the returning one is known');
  await poll(feed, [...old, recent('a3'), recent('a4'), recent('a5')]);
  assert.equal((await h.first('SELECT last_poll_outcome FROM n_feed WHERE feed_id=?', feed)).last_poll_outcome, 'unchanged', 'the gate works again once a current writer has published');
  await coherent(feed, 5, 'unchanged after the round trip');
  console.log('PASS a digest left behind by a writer that does not maintain it never suppresses a change: coherent generations, settled, exact events');

  // History expiry resets the generation to zero, so numbers repeat. Inject
  // the previous digest after expiry; it still names a different snapshot.
  const reuse = await h.add('https://generation-reuse.example.com/feed'), url = 'https://generation-reuse.example.com/feed';
  const x = ['x1', 'x2'].map((id, i) => item(id, h.now - (9 - i) * 86400)), y = [x[0], item('y2', h.now - 7 * 86400)];
  await poll(reuse, x);
  const retained = (await coherent(reuse, 1, 'first baseline')).semantic_digest;
  await h.run('UPDATE feed_subscriptions SET notifications_enabled=0,updated_at=? WHERE feed_url=?', h.now, url);
  await h.run('UPDATE n_feed SET no_interest_since=? WHERE feed_id=?', h.now - 31 * 86400, reuse);
  const delivery = await h.instance.getWorker('delivery-runtime');
  const collected = await delivery.fetch('https://delivery.invalid/observation/gc', { method: 'POST', body: JSON.stringify({ feed_id: reuse }) });
  assert.equal(collected.status, 200, await collected.text());
  assert.deepEqual(await h.first('SELECT observation_generation,snapshot_key,semantic_digest FROM n_feed WHERE feed_id=?', reuse), { observation_generation: 0, snapshot_key: null, semantic_digest: null }, 'history expiry clears the digest with the pointer');
  await leaveStaleDigest(reuse, retained);
  await h.run('UPDATE feed_subscriptions SET notifications_enabled=1,updated_at=? WHERE feed_url=?', h.now + 1, url);
  await poll(reuse, y);
  await coherent(reuse, 1, 'rebuilt baseline'); await leaveStaleDigest(reuse, retained);
  // Generation 1 again, a digest from generation 1, and the body it describes.
  await poll(reuse, x);
  await coherent(reuse, 2, 'a digest from an expired history with the same generation number');
  assert.equal(await events(reuse), 0, 'old backfill is not a release');
  console.log('PASS history expiry and a rebuilt baseline reuse a generation number without reviving its digest');
} finally { await h.instance.dispose(); }
