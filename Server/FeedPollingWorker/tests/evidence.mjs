// A failed scan's first-observed bound is recorded
// only for a scan that reached the publisher, only against the checkpoint it
// read, and is never lost to a one-second boundary or the passive shadow.
// Each case asserts what the bound does to a later release, not a row count.
import assert from 'node:assert/strict';
import { setTimeout as sleep } from 'node:timers/promises';
import { harness, hash, item, rss } from './harness.mjs';

const DAY = 86400;
const until = async (predicate, label) => { for (let i = 0; i < 500; i++) { if (await predicate()) return; await sleep(10); } throw Error(`timeout: ${label}`); };
async function suite(options, body) {
  let behavior; const h = await harness(request => behavior(request), options);
  const api = {
    h, serve: fn => { behavior = fn; },
    // A delivery left in flight when an assertion fails dies with the runtime;
    // report the assertion, not that socket error.
    consume(...args) { const pending = h.consume(...args); pending.catch(() => {}); return pending; },
    baseline: () => new Response(rss([item('baseline', h.now - 10)]), { headers: { etag: '"v1"' } }),
    grown: () => new Response(rss([item('baseline', h.now - 10), item('new-undated', null)])),
    // Every polling replica and the delivery worker share one virtual clock.
    async clock(seconds) {
      for (let i = 0; i < (options.replicas ?? 1); i++) await h.invoke('clock', String(seconds), undefined, i);
      const delivery = await h.instance.getWorker('delivery-runtime');
      await (await delivery.fetch('https://delivery.invalid/clock', { method: 'POST', body: String(seconds) })).text();
    },
    async reserve(feed) { await h.invoke('test/dispatch'); const wake = (await h.polls()).find(w => w.feed_id === feed); assert.ok(wake, 'feed was not dispatched'); return wake; },
    due: feed => h.run('UPDATE n_feed SET due_at=0,retry_at=0,poll_failures=0,dispatch_until=0 WHERE feed_id=?', feed),
    evidence: (feed) => h.rows('SELECT scan_started_at,state,valid_eof FROM n_observation WHERE feed_id=? AND recovery_evidence=1', feed),
    releases: (feed) => h.rows('SELECT state,first_observed_at,eligible_at,expires_at FROM n_episode_release WHERE feed_id=?', feed),
    // The next poll, `after` seconds later, discovers one new undated item.
    async discover(feed, after) {
      await api.clock(after); behavior = api.grown; await api.due(feed);
      await h.invoke('test/dispatch'); await h.drain(); await h.deliver(true);
      const found = await api.releases(feed); assert.equal(found.length, 1, JSON.stringify(found)); return found[0];
    },
  };
  behavior = api.baseline;
  try { await body(api); } finally { await h.instance.dispose(); }
}
// A release that kept its whole window: observed when found, delivered once.
function renewed(api, release, after) {
  assert.notEqual(release.state, 'expired', JSON.stringify(release));
  assert.ok(release.first_observed_at >= api.h.now + after, `first observed when found: ${JSON.stringify(release)}`);
  assert.equal(release.expires_at, release.eligible_at + DAY);
  assert.deepEqual([api.h.events.length, api.h.sends.length], [1, 1], 'exactly one event and one send');
}

// H1 scenario A. Execution A holds its publisher response while a duplicate of
// the same generation, or a newer generation issued after A's reservation
// expired, settles an unchanged body. A then sees truncated XML. The success
// proved absence after A began, so A's failure must bound nothing: a bound here
// would make the next undated release, a day later, born expired.
const cases = {};
for (const newer of [false, true]) cases[newer ? 'late-failure-newer-generation' : 'late-failure-duplicate'] = async () => {
  await suite({ replicas: 2 }, async api => {
    const { h } = api, feed = await h.add('https://late-failure.example.com/feed');
    await h.consume(await api.reserve(feed));
    await api.clock(20); await api.due(feed);
    const stale = await api.reserve(feed);
    let release, entered = false;
    api.serve(async () => { entered = true; await new Promise(resolve => release = resolve); return new Response('<rss><channel><item>truncated'); });
    const held = api.consume(stale); await until(() => entered, 'held publisher response');
    let winner = stale;
    if (newer) { await api.clock(20 + 301); winner = await api.reserve(feed); assert.ok(winner.generation > stale.generation); }
    api.serve(api.baseline);
    assert.equal((await h.consume(winner, { replica: 1 })).outcome, 'unchanged');
    release();
    const failed = await held;
    assert.equal(failed.status, 200, failed.text);
    assert.deepEqual(await api.evidence(feed), [], 'a failure that lands after a committed success is not evidence');
    assert.equal((await h.first('SELECT last_poll_outcome FROM n_feed WHERE feed_id=?', feed)).last_poll_outcome, 'unchanged', 'the stale failure cannot move the schedule either');
    renewed(api, await api.discover(feed, 25 * 3600), 25 * 3600);
  });
  console.log(`PASS a failed scan landing after ${newer ? 'a newer generation' : 'its duplicate'} settled leaves no bound: the next undated release keeps its window and sends once`);
};

// The genuine case is kept. Two concurrent duplicates both fail with no success
// between them. The second one's schedule write is stale, but its start is
// still true evidence: the retry an hour later is bounded by the earliest
// start. The deadline is shortened, never renewed, and the alert sends once.
cases['genuine-failure'] = async () => {
await suite({ replicas: 2 }, async api => {
  const { h } = api, feed = await h.add('https://genuine-failure.example.com/feed');
  await h.consume(await api.reserve(feed));
  await api.clock(20); await api.due(feed);
  const wake = await api.reserve(feed), releases = [];
  api.serve(async () => { await new Promise(resolve => releases.push(resolve)); return new Response('<rss><channel><item>truncated'); });
  const started = h.now + 20;
  const duplicates = [api.consume(wake), api.consume(wake, { replica: 1, attempts: 2 })];
  await until(() => releases.length === 2, 'both duplicates fetching');
  releases.forEach(resolve => resolve());
  assert.deepEqual((await Promise.all(duplicates)).map(r => r.outcome), ['publisher_failed', 'publisher_failed']);
  const kept = await api.evidence(feed), earliest = Math.min(...kept.map(row => row.scan_started_at));
  assert.ok(kept.length >= 1 && kept.every(row => row.valid_eof === 0 && row.state === 'staging'), JSON.stringify(kept));
  assert.ok(Math.abs(earliest - started) <= 5, JSON.stringify(kept));
  assert.equal((await h.first('SELECT poll_failures FROM n_feed WHERE feed_id=?', feed)).poll_failures, 1, 'one generation is one publisher failure');
  const found = await api.discover(feed, 3600);
  assert.equal(found.first_observed_at, earliest, 'the retry is bounded by the failed scan');
  assert.equal(found.expires_at, earliest + DAY);
  assert.deepEqual([h.events.length, h.sends.length], [1, 1]);
  assert.deepEqual(await api.evidence(feed), [], 'the publication retired the streak');
});
console.log('PASS a genuine failed scan still bounds its retry: shortened, never renewed, sent once');
};

// H1 scenario B. The isolate's one scan permit is held by another feed. This
// feed's delivery is cancelled while it waits: no publisher request was ever
// made, so it has seen nothing and bounds nothing. Cancelled mid-fetch instead,
// its start is evidence, and the redelivery that settles retires it.
cases['cancel-before-publisher'] = async () => {
await suite({}, async api => {
  const { h } = api, feed = await h.add('https://cancel-before-fetch.example.com/feed');
  await h.consume(await api.reserve(feed));
  const busy = await h.add('https://holds-the-permit.example.com/feed');
  await h.run('UPDATE n_feed SET due_at=? WHERE feed_id=?', h.now + 9999, feed);
  const holder = await api.reserve(busy);
  let release, entered = false;
  api.serve(async () => { entered = true; await new Promise(resolve => release = resolve); return api.baseline(); });
  const holding = api.consume(holder); await until(() => entered, 'permit holder fetching');
  await api.clock(20); await api.due(feed);
  const wake = await api.reserve(feed), requests = h.fetches.length;
  const waiting = api.consume(wake, { headers: { 'x-test-execution': 'waiting' } });
  await sleep(300); await h.invoke('abort', 'waiting');
  assert.equal((await waiting).status, 503, 'a cancelled delivery is not acknowledged');
  assert.equal(h.fetches.length, requests, 'cancelled before any publisher request');
  assert.deepEqual(await api.evidence(feed), [], 'a scan that never reached the publisher bounds nothing');
  release(); await holding;
  await h.run('UPDATE n_feed SET due_at=?,dispatch_until=0 WHERE feed_id=?', h.now + 40 * DAY, busy);
  renewed(api, await api.discover(feed, 25 * 3600), 25 * 3600);
});
console.log('PASS cancellation while waiting for the scan permit leaves no bound: the next undated release keeps its window and sends once');
};

cases['cancel-mid-fetch'] = async () => {
await suite({}, async api => {
  const { h } = api, feed = await h.add('https://cancel-mid-fetch.example.com/feed');
  await h.consume(await api.reserve(feed));
  await api.clock(20); await api.due(feed);
  const wake = await api.reserve(feed);
  let entered = false;
  api.serve(async () => { entered = true; await new Promise(() => {}); });
  const pending = api.consume(wake, { headers: { 'x-test-execution': 'fetching' } });
  await until(() => entered, 'publisher request sent'); await h.invoke('abort', 'fetching');
  assert.equal((await pending).status, 503);
  const kept = await api.evidence(feed);
  assert.equal(kept.length, 1, 'a scan cancelled after its request was sent keeps its start');
  api.serve(api.baseline);
  assert.equal((await h.consume(wake, { attempts: 2 })).outcome, 'unchanged');
  assert.deepEqual(await api.evidence(feed), [], 'the redelivered settle proved absence and retired it');
});
console.log('PASS cancellation after the publisher request keeps one bound, and the redelivery retires it');
};

// A feed that has never published has no checkpoint: the success token is NULL
// on both sides of the fence, and its failed first scan still bounds the retry.
cases['first-scan-failure'] = async () => {
await suite({}, async api => {
  const { h } = api, feed = await h.add('https://first-scan.example.com/feed');
  api.serve(() => new Response('<rss><channel><item>truncated'));
  assert.equal((await h.consume(await api.reserve(feed))).outcome, 'publisher_failed');
  assert.equal((await api.evidence(feed)).length, 1, 'a scan with no checkpoint to read still records its bound');
  api.serve(api.baseline); await api.clock(400); await api.due(feed);
  await h.invoke('test/dispatch'); await h.drain();
  assert.equal((await h.first('SELECT observation_generation FROM n_feed WHERE feed_id=?', feed)).observation_generation, 1);
  assert.deepEqual(await api.evidence(feed), [], 'the quiet baseline retired it');
  assert.deepEqual(await api.releases(feed), [], 'a baseline releases nothing');
});
console.log('PASS a first scan that fails before any checkpoint exists records its bound, and the baseline retires it');
};

// M1. Seconds cannot order two executions. The feed's next phase slot falls
// inside the early-admission window, so its next generation is dispatched and
// fails in the same second its previous success committed.
cases['same-second'] = async () => {
await suite({}, async api => {
  const { h } = api;
  await h.invoke('freeze', String(h.now));
  let url;
  for (let i = 0; ; i++) {
    assert.ok(i < 100000, 'no feed with a phase slot inside the early-admission window');
    url = `https://same-second.example.com/feed-${i}`;
    const seed = parseInt(hash(['feed-v1', url]).slice(0, 8), 16);
    const phase = ((seed % 900 - Math.floor(seed / 65536) % 30) % 900 + 900) % 900, delta = ((phase - h.now % 900) + 900) % 900;
    if (delta > 0 && delta <= 30) break;
  }
  const feed = await h.add(url);
  assert.equal((await h.consume(await api.reserve(feed))).outcome, 'published');
  const wake = await api.reserve(feed);
  await h.invoke('fault', 'before_settle');
  assert.equal((await h.consume(wake)).status, 500);
  const kept = await api.evidence(feed), success = await h.first('SELECT last_success_at FROM n_feed WHERE feed_id=?', feed);
  assert.equal(kept.length, 1, 'a settle that never committed is a failed scan, whatever the clock says');
  assert.equal(kept[0].scan_started_at, success.last_success_at, 'the case under test: same second as the previous success');
  assert.equal((await h.consume(wake, { attempts: 2 })).outcome, 'unchanged');
  assert.deepEqual(await api.evidence(feed), []);
  await h.invoke('freeze', '');
});
console.log('PASS a scan that fails in the same second as the previous success still records its bound');
};

// M2. Two messages for one origin share an isolate. B reads its claim while A
// is fetching, then waits for the scan permit. A is answered 503 with
// Retry-After and commits the cooldown. B must see it: the cooldown is read
// immediately before the request, not with the claim.
cases['waiting-claimant'] = async () => {
await suite({}, async api => {
  const { h } = api, a = await h.add('https://waiting-claimant.example.com/a'), b = await h.add('https://waiting-claimant.example.com/b');
  await h.invoke('test/dispatch'); const wakes = await h.polls();
  let release, entered = false;
  api.serve(async request => {
    if (!request.url.endsWith('/a')) return api.baseline();
    entered = true; await new Promise(resolve => release = resolve);
    return new Response('busy', { status: 503, headers: { 'retry-after': '600' } });
  });
  const first = api.consume(wakes.find(w => w.feed_id === a)); await until(() => entered, 'A fetching');
  const second = api.consume(wakes.find(w => w.feed_id === b)); await sleep(300);
  release();
  assert.deepEqual((await Promise.all([first, second])).map(r => r.outcome), ['publisher_failed', 'origin_cooldown']);
  assert.deepEqual(h.fetches, ['https://waiting-claimant.example.com/a'], 'the waiting claimant made no request after the cooldown committed');
  const waited = await h.first('SELECT retry_at,poll_failures,dispatch_until FROM n_feed WHERE feed_id=?', b);
  assert.ok(waited.retry_at >= h.now + 599 && waited.poll_failures === 0 && waited.dispatch_until === 0, JSON.stringify(waited));
});
console.log('PASS a claimant that waited for the scan permit honors a cooldown committed while it waited');
};

// `node evidence.mjs <case>` runs one case; each builds its own isolated runtime.
const only = process.argv[2];
if (only) assert.ok(cases[only], `unknown case: ${only}; one of ${Object.keys(cases).join(', ')}`);
for (const [name, run] of Object.entries(cases)) if (!only || only === name) await run();
