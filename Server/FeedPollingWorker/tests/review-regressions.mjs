import assert from 'node:assert/strict';
import { setTimeout } from 'node:timers/promises';
import { harness, hash, item, rss } from './harness.mjs';

let behavior;
const h = await harness(request => behavior(request));
const baseline = () => new Response(rss([item('base', h.now - 100)]), { headers: { etag: '"v1"' } });
async function clock(seconds) {
  await h.invoke('clock', String(seconds));
  const worker = await h.instance.getWorker('delivery-runtime');
  await (await worker.fetch('https://delivery.invalid/clock', { method: 'POST', body: String(seconds) })).text();
}
async function due(feed) {
  await h.run('UPDATE n_feed SET due_at=0,retry_at=0,poll_failures=0,dispatch_until=0 WHERE feed_id=?', feed);
  await h.run('DELETE FROM n_poll_origin');
  await h.invoke('test/dispatch');
}
const durable = async feed => ({
  observations: (await h.first('SELECT COUNT(*) AS n FROM n_observation WHERE feed_id=?', feed)).n,
  snapshots: (await h.first('SELECT COUNT(*) AS n FROM n_snapshot WHERE feed_id=?', feed)).n,
  evidence: (await h.first('SELECT COUNT(*) AS n FROM n_observation WHERE feed_id=? AND recovery_evidence=1', feed)).n,
  objects: (await (await h.instance.getR2Bucket('FEED_SNAPSHOTS', 'polling-runtime')).list()).objects.length,
});
try {
  // A failed or deferred scan, then a matched 304, then an
  // undated release days later. A scan that reached the publisher and failed
  // keeps one evidence row for its whole failure streak; the matched 304 must
  // retire it, or it would date the later release into the past. A deferral
  // never reached the publisher and writes nothing at all.
  for (const scenario of ['failed', 'truncated', 'origin-cooldown', 'redirect-cooldown']) {
    await clock(0);
    behavior = baseline;
    const url = `https://${scenario}.example.com/feed`, feed = await h.add(url);
    await due(feed); await h.drain();
    const before = await durable(feed);
    await due(feed);
    if (scenario === 'failed') behavior = () => new Response('unavailable', { status: 503 });
    else if (scenario === 'truncated') behavior = () => new Response(rss([item('base', h.now - 100), item('undated', null)]).slice(0, -40), { headers: { etag: '"cut"' } });
    else {
      const destination = scenario === 'redirect-cooldown' ? 'https://destination.example.com' : new URL(url).origin;
      await h.run('INSERT INTO n_poll_origin(origin_key,cooldown_until,failures,updated_at) VALUES(?,?,1,?)', hash(['origin-v1', destination]), h.now + 30, h.now);
      behavior = () => new Response(null, { status: 302, headers: { location: destination + '/target' } });
    }
    await h.drain();
    const reached = scenario === 'failed' || scenario === 'truncated', after = await durable(feed);
    assert.deepEqual(after, reached ? { observations: before.observations + 1, snapshots: before.snapshots + 1, evidence: 1, objects: before.objects } : before, `${scenario}: only a scan that reached the publisher leaves evidence, and never an object`);
    if (reached) {
      // One row per failure streak: only the earliest start bounds a retry.
      await due(feed); await h.drain();
      assert.deepEqual(await durable(feed), after, `${scenario}: a repeated failure adds nothing`);
    }
    const outcome = (await h.first('SELECT last_poll_outcome,poll_failures,retry_at FROM n_feed WHERE feed_id=?', feed));
    if (scenario === 'failed' || scenario === 'truncated') {
      assert.equal(outcome.last_poll_outcome, 'publisher_failed');
      assert.ok(outcome.retry_at >= Math.floor(Date.now() / 1000) + 298, 'failed feed waits at least a normal poll interval');
      await h.run('UPDATE n_feed SET retry_at=1 WHERE feed_id=?', feed);
      assert.equal((await h.invoke('test/stats')).healthy_overdue, 0, 'a failing feed remains unhealthy after its retry deadline passes');
    } else assert.equal(outcome.poll_failures, 0, 'a deferral is not a publisher failure');
    await clock(180);
    behavior = () => new Response(null, { status: 304 });
    await due(feed); await h.drain();
    assert.equal((await durable(feed)).evidence, 0);
    assert.equal((await h.first('SELECT last_poll_outcome FROM n_feed WHERE feed_id=?', feed)).last_poll_outcome, 'not_modified');
    await clock(2 * 86400);
    behavior = () => new Response(rss([item('base', h.now - 100), item('undated', null)]), { headers: { etag: '"v2"' } });
    const sent = h.sends.length;
    await due(feed); await h.drain(); await h.deliver(true);
    assert.equal(h.sends.length, sent + 1);
    const release = await h.first('SELECT state,eligible_at FROM n_episode_release WHERE feed_id=?', feed);
    assert.notEqual(release.state, 'expired'); assert.ok(release.eligible_at >= h.now + 2 * 86400);
    assert.equal((await h.first('SELECT COUNT(*) AS n FROM n_event e JOIN n_outbox x ON x.event_id=e.event_id WHERE x.observation_id IN(SELECT observation_id FROM n_observation WHERE feed_id=?)', feed)).n, 1);
    await h.run('UPDATE n_feed SET admission_paused=1 WHERE feed_id=?', feed);
    console.log(`PASS ${scenario} -> matched 304 -> undated release two days later sends exactly once`);
  }

  // A change that was proved and claimed, then failed before publishing, is
  // durable evidence: its scan start still bounds the retried release.
  await clock(0); behavior = baseline;
  const bounded = await h.add('https://bounded.example.com/feed');
  await due(bounded); await h.drain();
  behavior = () => new Response(rss([item('base', h.now - 100), item('undated', null)]), { headers: { etag: '"v2"' } });
  await due(bounded); const [claimed] = await h.polls();
  for (let attempts = 1; attempts <= 4; attempts++) { await h.invoke('fault', 'before_put'); assert.equal((await h.consume(claimed, { attempts })).status, 500); }
  await h.invoke('test/dead-letter', claimed);
  assert.ok((await durable(bounded)).evidence >= 1, 'a claimed scan that failed after EOF is recovery evidence');
  const firstSeen = (await h.first('SELECT MIN(scan_started_at) AS t FROM n_observation WHERE feed_id=? AND recovery_evidence=1', bounded)).t;
  await clock(3600); await due(bounded); await h.drain();
  const retried = await h.first('SELECT first_observed_at,eligible_at,expires_at FROM n_episode_release WHERE feed_id=?', bounded);
  assert.deepEqual(retried, { first_observed_at: firstSeen, eligible_at: firstSeen, expires_at: firstSeen + 86400 }, 'a retry shortens, never renews, the deadline');
  await h.run('UPDATE n_feed SET admission_paused=1 WHERE feed_id=?', bounded);
  console.log('PASS a claimed scan that failed after valid EOF keeps the conservative first-observed bound');

  await clock(0); behavior = baseline;
  const storage = await h.add('https://storage.example.com/feed');
  await due(storage); await h.drain();
  // Storage trouble needs a proved change: an unchanged poll touches no R2.
  let revision = 0;
  behavior = () => new Response(rss([item('base', h.now - 100), item(`archive-${++revision}`, h.now - 30 * 86400)]), { headers: { etag: `"s${revision}"` } });
  {
    await due(storage); const [wake] = await h.polls();
    await h.invoke('fault', 'before_get');
    assert.equal((await h.consume(wake)).status, 500);
    const parked = await h.first('SELECT last_poll_outcome,poll_failures,retry_at FROM n_feed WHERE feed_id=?', storage);
    assert.deepEqual(parked, { last_poll_outcome: 'handling_failed', poll_failures: 0, retry_at: 0 });
    assert.equal((await h.invoke('test/stats')).publisher_backoff, 0);
    assert.equal((await h.consume(wake, { attempts: 2 })).status, 200, 'the redelivery finishes the step');
    await h.drain();
  }
  {
    // History is read only after the body is complete, so sixteen seconds of
    // slow storage can no longer spend the publisher's fifteen-second deadline.
    await due(storage); const [wake] = await h.polls();
    await h.invoke('fault', 'slow_get');
    assert.equal((await h.consume(wake)).outcome, 'staged');
    assert.equal((await h.first('SELECT poll_failures FROM n_feed WHERE feed_id=?', storage)).poll_failures, 0);
    await h.drain();
  }
  // A D1 failure while recording a publisher's 503 is ours, not theirs.
  behavior = () => new Response('busy', { status: 503 });
  await due(storage); const [wake] = await h.polls();
  await h.invoke('fault', 'origin_status_d1');
  assert.equal((await h.consume(wake)).status, 500);
  assert.equal((await h.first('SELECT poll_failures FROM n_feed WHERE feed_id=?', storage)).poll_failures, 0);
  await h.run('UPDATE n_feed SET admission_paused=1 WHERE feed_id=?', storage);
  console.log('PASS R2/D1 failures stay visible as handling trouble without publisher cooldown');

  const failing = await h.add('https://retry-after.example.com/feed', h.now - 90000);
  behavior = () => new Response('busy', { status: 503, headers: { 'retry-after': '31536000' } });
  await h.invoke('test/dispatch'); await h.drain();
  let stats = await h.invoke('test/stats');
  assert.equal(stats.retry_after_clamped_total, 1);
  assert.equal(stats.oldest_due_seconds, 0);
  assert.ok(stats.oldest_unhealthy_due_seconds > 90000);
  assert.ok((await h.first('SELECT MAX(cooldown_until) AS t FROM n_poll_origin')).t < Math.floor(Date.now() / 1000) + 86401);
  await h.run('UPDATE n_feed SET admission_paused=1 WHERE feed_id=?', failing);
  const dateRetry = await h.add('https://date-retry-after.example.com/feed');
  behavior = () => new Response('busy', { status: 503, headers: { 'retry-after': new Date((h.now + 365 * 86400) * 1000).toUTCString() } });
  await h.invoke('test/dispatch'); await h.drain();
  assert.equal((await h.invoke('test/stats')).retry_after_clamped_total, 2);
  assert.ok((await h.first('SELECT MAX(cooldown_until) AS t FROM n_poll_origin')).t < Math.floor(Date.now() / 1000) + 86401);
  await h.run('UPDATE n_feed SET admission_paused=1 WHERE feed_id=?', dateRetry);
  console.log('PASS Retry-After capped at 24h and unhealthy age separated from healthy age');

  behavior = baseline;
  const shared = await h.add('https://shared-isolate.example.com/feed');
  const waiting = await h.add('https://waiting.example.com/feed');
  await h.invoke('test/dispatch');
  const messages = await h.polls();
  const message = id => messages.find(w => w.feed_id === id);
  let started = false, release;
  behavior = async request => {
    if (request.url.includes('shared-isolate')) { started = true; await new Promise(resolve => release = resolve); }
    return baseline();
  };
  const first = h.consume(message(shared));
  while (!started) await setTimeout(10);
  const handling = (await h.invoke('test/stats')).handling_failure_total;
  const before = performance.now();
  assert.equal((await h.consume(message(waiting))).outcome, 'scan_busy');
  assert.ok(performance.now() - before >= 2900, 'brief contention waits inside the invocation');
  assert.equal((await h.polls()).length, 0, 'the retry is a delayed message, at least five seconds away');
  assert.equal((await h.invoke('test/stats')).handling_failure_total, handling, 'memory admission pressure is never a handling failure');
  release(); await first;
  await clock(16); await h.drain();
  assert.equal((await h.first('SELECT COUNT(*) AS n FROM n_feed WHERE feed_id IN(?,?) AND snapshot_key IS NOT NULL', shared, waiting)).n, 2);
  console.log('PASS shared-isolate scan waits three seconds then retries with 5–15s jitter');

  // Gauge shares GC's exact grace/live predicate, including current snapshots.
  await h.run('UPDATE n_snapshot SET gc_after=0');
  stats = await h.invoke('test/stats');
  assert.ok(stats.snapshot_orphan_total >= 1);
  assert.equal('suppressed' in stats, false);
  assert.ok(stats.queue_age_seconds >= 0);
  assert.equal((await h.first("SELECT COUNT(*) AS n FROM sqlite_master WHERE name='n_poll'")).n + (await h.first("SELECT COUNT(*) AS n FROM sqlite_master WHERE name='n_origin_permit'")).n, 0);
  console.log('PASS rolling failure counters and orphan/queue-age operator gauges');
} finally { await h.instance.dispose(); }
