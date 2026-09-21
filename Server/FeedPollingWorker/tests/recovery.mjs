import assert from 'node:assert/strict';
import { setTimeout } from 'node:timers/promises';
import { writeFile } from 'node:fs/promises';
import { harness, item, rss } from './harness.mjs';
let behavior;
// Two isolates stand in for the two Queue consumers of the deployed config.
const CONSUMERS = 2;
const h = await harness(request => behavior(request), { replicas: CONSUMERS });
const normal = () => new Response(rss([item('baseline', h.now - 10)]), { headers: { etag: '"v1"' } });
behavior = normal;
const advance = async seconds => { for (let i = 0; i < CONSUMERS; i++) await h.invoke('clock', String(seconds), undefined, i); };
const until = async predicate => { for (let i = 0; i < 500; i++) { if (await predicate()) return; await setTimeout(10); } throw Error('condition timeout'); };
const generation = async feed => (await h.first('SELECT observation_generation FROM n_feed WHERE feed_id=?', feed)).observation_generation;
const counters = async () => Object.fromEntries(await Promise.all(['n_observation', 'n_snapshot', 'n_event', 'n_outbox'].map(async t => [t, (await h.first(`SELECT COUNT(*) AS n FROM ${t}`)).n])));
// Earlier cases may leave other feeds due; take this feed's message only.
const wakeFor = async feed => { await h.invoke('test/dispatch'); const wake = (await h.polls()).find(w => w.feed_id === feed); assert.ok(wake, 'feed was not dispatched'); return wake; };
const scratch = async () => (await (await h.instance.getR2Bucket('FEED_SNAPSHOTS', 'polling-runtime')).list({ prefix: 'scratch/' })).objects.length;
try {
  // Publisher safety without a D1 permit: six feeds on one origin, delivered to
  // both consumers at once. An isolate admits one request per origin, so the
  // origin never sees more than one request per consumer.
  const feeds = [];
  for (let i = 0; i < 6; i++) feeds.push(await h.add(`https://concentrated.example.com/feed-${i}`));
  await h.invoke('test/dispatch'); const wakes = await h.polls(); assert.equal(wakes.length, 6);
  let active = 0, peak = 0; const releases = [];
  behavior = async () => { active++; peak = Math.max(peak, active); await new Promise(resolve => releases.push(resolve)); active--; return normal(); };
  const calls = wakes.map((wake, i) => h.consume(wake, { replica: i % CONSUMERS }));
  await until(() => active === CONSUMERS);
  await setTimeout(3500);
  assert.equal(active, CONSUMERS, 'waiting deliveries never start a third request');
  behavior = async () => { active++; peak = Math.max(peak, active); await setTimeout(20); active--; return normal(); };
  releases.splice(0).forEach(fn => fn());
  const first = await Promise.all(calls);
  assert.ok(first.every(r => r.status === 200), JSON.stringify(first));
  assert.ok(first.some(r => ['scan_busy', 'origin_deferred'].includes(r.outcome)), 'contention defers through a delayed message, not a D1 permit');
  await advance(20);
  for (let round = 0; round < 40 && (await h.first('SELECT COUNT(*) AS n FROM n_feed WHERE snapshot_key IS NULL AND feed_id IN(SELECT value FROM json_each(?))', JSON.stringify(feeds))).n; round++) {
    const pending = (await Promise.all(Array.from({ length: CONSUMERS }, (_, i) => h.invoke('wakeups', undefined, undefined, i)))).flat();
    await Promise.all(pending.map((wake, i) => h.consume(wake, { replica: i % CONSUMERS })));
    await advance(20 * (round + 2));
  }
  assert.ok(peak <= CONSUMERS, `origin saw ${peak} concurrent requests from ${CONSUMERS} consumers`);
  for (const feed of feeds) assert.equal(await generation(feed), 1);
  assert.equal((await h.first("SELECT COUNT(*) AS n FROM sqlite_master WHERE name IN('n_origin_permit','n_poll')")).n, 0);
  await advance(0);
  console.log(`PASS queue-local origin bound: peak ${peak} concurrent requests across ${CONSUMERS} consumers, no permit rows, deferrals complete`);

  // Retry-After is shared schedule state: a second consumer holding an
  // already-dispatched message for the same origin does not fetch.
  const limited = [await h.add('https://limited.example.com/a'), await h.add('https://limited.example.com/b')];
  behavior = () => new Response('busy', { status: 503, headers: { 'retry-after': '600' } });
  // A feed from the section above may reach its first phase slot here too.
  await h.invoke('test/dispatch'); const [one, two] = (await h.polls()).filter(w => limited.includes(w.feed_id));
  assert.ok(one && two);
  let requests = h.fetches.length;
  assert.equal((await h.consume(one, { replica: 0 })).outcome, 'publisher_failed');
  assert.equal((await h.consume(two, { replica: 1 })).outcome, 'origin_cooldown');
  assert.equal(h.fetches.length, requests + 1, 'the other consumer honors the cooldown without a request');
  const cooled = await h.rows('SELECT retry_at,dispatch_until,last_poll_outcome FROM n_feed WHERE feed_id IN(?,?) ORDER BY last_poll_outcome', ...limited);
  assert.ok(cooled.every(f => f.retry_at >= h.now + 300 && f.dispatch_until === 0), JSON.stringify(cooled));
  assert.ok(cooled.find(f => f.last_poll_outcome === 'origin_cooldown').retry_at >= h.now + 599);
  await h.run('UPDATE n_feed SET retry_at=0 WHERE feed_id IN(?,?)', ...limited);
  await h.invoke('test/dispatch'); assert.equal((await h.polls()).filter(w => limited.includes(w.feed_id)).length, 0, 'the dispatcher does not admit a cooling origin');
  console.log('PASS Retry-After cooldown is honored across both consumers and by admission');

  // Redirects cannot use a free origin to bypass the destination's cooldown.
  const redirected = await h.add('https://redirect.example.com/feed');
  behavior = request => new URL(request.url).hostname === 'redirect.example.com'
    ? new Response(null, { status: 302, headers: { location: 'https://blocked.example.com/feed' } })
    : new Response('busy', { status: 503, headers: { 'retry-after': '600' } });
  await h.invoke('test/dispatch'); await h.drain();
  const cooldown = await h.first('SELECT MAX(cooldown_until) AS until FROM n_poll_origin'); assert.ok(cooldown.until >= h.now + 600);
  assert.equal((await h.first('SELECT lease_id FROM n_feed WHERE feed_id=?', redirected)).lease_id, null);
  requests = h.fetches.length;
  await h.invoke('test/dispatch'); await h.drain(); assert.equal(h.fetches.length, requests);
  await h.run('UPDATE n_feed SET retry_at=0,poll_failures=0 WHERE feed_id=?', redirected);
  await h.invoke('test/dispatch'); await h.drain();
  assert.equal(h.fetches.filter(url => url.includes('blocked.example.com')).length, 1, 'a later poll stops at the cooling destination');
  assert.equal((await h.first('SELECT last_poll_outcome FROM n_feed WHERE feed_id=?', redirected)).last_poll_outcome, 'origin_cooldown');
  const backoff = await h.invoke('test/stats'); assert.ok(backoff.publisher_backoff >= 1); assert.ok(backoff.origin_cooldowns >= 2);
  console.log('PASS redirect destinations share the origin cooldown and Retry-After');

  // Separate healthy hosts remain available while the failed origin cools down.
  behavior = normal; const healthy = await h.add('https://healthy.example.com/feed');
  await h.invoke('test/dispatch'); await h.drain();
  assert.equal(await generation(healthy), 1);
  console.log('PASS healthy origin progresses through another origin cooldown');

  // A stale generation or owner epoch arriving between fetch and commit cannot
  // publish; a crash on either side of publication redelivers and finishes once.
  for (const fault of ['stale_generation', 'stale_epoch', 'before_publish', 'after_publish']) {
    const name = fault.replaceAll('_', '-'), feed = await h.add(`https://${name}.example.com/feed`);
    await h.invoke('test/dispatch'); await h.invoke('fault', fault); await h.drain();
    // A crash is redelivered by the Queue and finishes within the drain; a
    // fenced generation or epoch cannot, until a newer generation is issued.
    assert.equal(await generation(feed), fault.startsWith('stale') ? 0 : 1, fault);
    if (fault.startsWith('stale')) assert.equal((await h.first('SELECT snapshot_key FROM n_feed WHERE feed_id=?', feed)).snapshot_key, null, 'a fenced commit leaves no pointer');
    // The redelivery after a crash on either side of publication never
    // fetches again once the pointer moved.
    if (fault === 'after_publish') {
      assert.equal(h.fetches.filter(url => url.includes(name)).length, 1);
      assert.equal((await h.first('SELECT COUNT(*) AS n FROM n_observation WHERE feed_id=? AND recovery_evidence=1', feed)).n, 0, 'a crash after publication leaves no first-observed bound');
    }
    if (fault.startsWith('stale')) {
      // Only a newer generation, issued once the reservation expires, recovers.
      await h.run('UPDATE n_feed SET lease_until=0 WHERE feed_id=? AND lease_id IS NOT NULL', feed);
      await advance(301); await h.invoke('test/dispatch'); await h.drain(); await advance(0);
    }
    assert.equal(await generation(feed), 1, fault);
    assert.equal((await h.first("SELECT COUNT(*) AS n FROM n_observation WHERE feed_id=? AND state='published'", feed)).n, 1, fault);
    await h.run('UPDATE n_feed SET due_at=? WHERE feed_id=?', h.now + 7200, feed);
  }
  console.log('PASS stale generation/owner epoch fences and pre/post publication crash recovery');

  // Crash before the Queue acknowledgement of an unchanged poll.
  behavior = () => new Response(null, { status: 304 });
  for (const fault of ['before_settle', 'after_settle', 'stale_settle']) {
    await h.run('UPDATE n_feed SET due_at=?,retry_at=0 WHERE feed_id=?', h.now, healthy);
    // These share a second with the previous success as often as not: what
    // orders a crash against a settle is the success token, never the clock.
    const wake = await wakeFor(healthy);
    const before = await counters(), requests = h.fetches.length;
    await h.invoke('fault', fault);
    const crashed = await h.consume(wake);
    if (fault === 'stale_settle') { assert.equal(crashed.outcome, 'obsolete'); assert.ok((await h.first('SELECT due_at FROM n_feed WHERE feed_id=?', healthy)).due_at <= h.now, 'a stale generation cannot move the schedule'); await h.run('UPDATE n_feed SET dispatch_until=0 WHERE feed_id=?', healthy); continue; }
    assert.equal(crashed.status, 500, fault);
    const redelivered = await h.consume(wake, { attempts: 2 });
    assert.equal(redelivered.outcome, fault === 'after_settle' ? 'obsolete' : 'not_modified', fault);
    assert.equal(h.fetches.length, requests + (fault === 'after_settle' ? 1 : 2), 'at most one duplicate conditional fetch');
    // A crashed scan keeps only its start, as the bound a retry may not renew;
    // the redelivered settle retires it. Nothing is published, sent or receipted.
    const after = await counters(), bound = fault === 'before_settle' ? 1 : 0;
    assert.deepEqual(after, { ...before, n_observation: before.n_observation + bound, n_snapshot: before.n_snapshot + bound }, 'redelivery creates no published observation, event or receipt');
    assert.equal((await h.first('SELECT COUNT(*) AS n FROM n_observation WHERE feed_id=? AND recovery_evidence=1', healthy)).n, 0, 'the settle retired the crashed attempt');
    assert.ok((await h.first('SELECT due_at FROM n_feed WHERE feed_id=?', healthy)).due_at > h.now);
  }
  assert.ok((await h.invoke('test/stats')).redelivery_total >= 2);
  console.log('PASS crash before acknowledgement redelivers, settles once and cannot move a newer generation');

  // A crash after the settle committed proved absence at that moment. It must
  // leave no first-observed bound: on a slow feed the next poll is a day away,
  // and a bound from the crash would make its new undated release born expired.
  assert.equal((await h.first('SELECT COUNT(*) AS n FROM n_observation WHERE feed_id=? AND recovery_evidence=1', healthy)).n, 0);
  await advance(25 * 3600);
  behavior = () => new Response(rss([item('baseline', h.now - 10), item('undated-after-crash', null)]), { headers: { etag: '"v2"' } });
  await h.run('UPDATE n_feed SET due_at=0,retry_at=0,dispatch_until=0 WHERE feed_id=?', healthy);
  await h.invoke('test/dispatch'); await h.drain();
  const late = await h.first('SELECT state,first_observed_at,eligible_at,expires_at FROM n_episode_release WHERE feed_id=?', healthy);
  assert.ok(late && late.state !== 'expired', JSON.stringify(late));
  assert.ok(late.first_observed_at >= h.now + 25 * 3600 && late.expires_at === late.eligible_at + 86400, JSON.stringify(late));
  await h.run('UPDATE n_feed SET due_at=? WHERE feed_id=?', h.now + 40 * 86400, healthy);
  await advance(0); behavior = normal;
  console.log('PASS a crash after a committed settle leaves no bound: a release a day later keeps its full window');

  const cancellation = await h.add('https://cancel.example.com/cancel-fetch');
  let release, entered = false;
  behavior = async () => { entered = true; await new Promise(resolve => release = resolve); return normal(); };
  await h.run('UPDATE n_feed SET due_at=? WHERE feed_id=?', h.now + 7200, healthy);
  const cancelledWake = await wakeFor(cancellation);
  const pending = h.consume(cancelledWake, { headers: { 'x-test-execution': 'cancel' } });
  await until(() => entered); await h.invoke('abort', 'cancel');
  assert.equal((await pending).status, 503, 'a cancelled delivery is not acknowledged');
  assert.equal(await generation(cancellation), 0);
  release(); await setTimeout(50);
  assert.equal(await generation(cancellation), 0);
  assert.equal(await scratch(), 0);
  behavior = normal;
  assert.equal((await h.consume(cancelledWake, { attempts: 2 })).outcome, 'published');
  assert.equal(await generation(cancellation), 1);
  console.log('PASS native request cancellation holds nothing durable, late response cannot publish, redelivery completes');

  const revoked = await h.add('https://revoked.example.com/feed');
  let oldRelease, oldEntered = false;
  behavior = async () => { oldEntered = true; await new Promise(resolve => oldRelease = resolve); return new Response(null, { status: 302, headers: { location: 'https://revoked.example.com/late-hop' } }); };
  const revokedWake = await wakeFor(revoked);
  const oldCall = h.consume(revokedWake);
  await until(() => oldEntered);
  await h.run("UPDATE feed_subscriptions SET notifications_enabled=0 WHERE feed_url='https://revoked.example.com/feed'");
  oldRelease(); await oldCall;
  assert.equal(h.fetches.filter(url => url.includes('/late-hop')).length, 0, 'revoked execution cannot follow another redirect');
  assert.equal(await generation(revoked), 0);
  behavior = normal;
  console.log('PASS revocation rejects a late same-origin redirect hop');

  // Exhausted handling is visible, backs off without blaming the publisher,
  // never hot-loops, and recovers by itself or by explicit repair.
  const exhausted = await h.add('https://exhausted.example.com/feed');
  const wake = await wakeFor(exhausted);
  for (let attempts = 1; attempts <= 4; attempts++) { await h.invoke('fault', 'before_put'); assert.equal((await h.consume(wake, { attempts })).status, 500); }
  await h.invoke('test/dead-letter', wake);
  const parked = await h.first('SELECT handling_failures,poll_failures,retry_at,dispatch_until,last_poll_outcome FROM n_feed WHERE feed_id=?', exhausted);
  assert.deepEqual([parked.handling_failures, parked.poll_failures, parked.dispatch_until, parked.last_poll_outcome], [1, 0, 0, 'dead_letter']);
  assert.ok(parked.retry_at >= h.now + 299);
  let stats = await h.invoke('test/stats');
  assert.ok(stats.dead_lettered >= 1 && stats.dead_letter_total >= 1 && stats.handling_failure_total >= 4);
  await h.invoke('test/dead-letter', wake);
  assert.equal((await h.first('SELECT handling_failures FROM n_feed WHERE feed_id=?', exhausted)).handling_failures, 1, 'a repeated dead letter is fenced by its settled generation');
  await h.invoke('test/dispatch'); assert.equal((await h.polls()).length, 0, 'no hot loop while backing off');
  await h.invoke('test/repair', { feed_id: exhausted }); await h.invoke('test/dispatch'); await h.drain();
  assert.equal(await generation(exhausted), 1);
  assert.equal((await h.first('SELECT handling_failures FROM n_feed WHERE feed_id=?', exhausted)).handling_failures, 0);
  console.log('PASS exhausted work dead-letters into a visible bounded backoff and explicit repair recovers it');
  stats = await h.invoke('test/stats');
  assert.ok(stats.stale_commit_total >= 2, 'rejected stale commits must be counted');
  assert.equal(stats.counter_window, 'rolling_24_hours');
  assert.equal((await h.first("SELECT COUNT(*) AS n FROM sqlite_master WHERE name IN('n_origin_permit','n_poll')")).n, 0);
  await writeFile('/private/tmp/opencast-pass045-recovery.json', JSON.stringify({ status: 'passed', origin_peak: peak, consumers: CONSUMERS, stats, metrics: await h.invoke('metrics') }, null, 2));
} finally { await h.instance.dispose(); }
