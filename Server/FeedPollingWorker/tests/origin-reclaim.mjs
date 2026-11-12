import assert from 'node:assert/strict';
import { setTimeout as sleep } from 'node:timers/promises';
import { harness, hash, item, rss } from './harness.mjs';

// The publisher origin slot dies with the scan permit that took it. A
// cancelled Queue invocation is never polled again, so without that the
// origin slot its scan holds would stay occupied on that isolate. A
// one-shot outbound gate stands in for it: it holds feed A's publisher
// response while later requests answer. That invocation stays live (its
// publisher deadline runs on performance.now(), which /clock does not move),
// so each case drives its reclaim well inside that deadline, checks that A is
// still held after it, and disposes A through the test cancellation path
// (x-test-execution + /abort) at its end. ORIGIN_CASES=<names> runs a subset;
// OPENCAST_POLLING_FIXTURE_BUILD names the storage-fixture build to run on.
// Cases (a) and (b) assert the delivery outcome alone up to their first
// corresponding origin entry (a base build refuses it consumer_busy there);
// their later checks and cases (c) to (f) read the isolate's slot table
// through the fixture build's /origin-slots readout, so they need that build.
const ALL = ['redelivery', 'age', 'redirect', 'clean', 'isolates', 'unrouted'];
const CASES = (process.env.ORIGIN_CASES ?? ALL.join(',')).split(',');
const BUILD = process.env.OPENCAST_POLLING_FIXTURE_BUILD;
if (CASES.some(name => !['redelivery', 'age'].includes(name)) && !BUILD) throw Error('origin-reclaim.mjs: cases (c) to (f) read /origin-slots: set OPENCAST_POLLING_FIXTURE_BUILD');
let behavior;
// Two isolates stand in for the two Queue consumers; replica 0 unless named.
const h = await harness(request => behavior(request), { logs: true, replicas: 2, ...(BUILD ? { pollingBuild: BUILD } : {}) });
const v1 = () => new Response(rss([item('base', h.now - 100)]), { headers: { etag: '"v1"' } });
behavior = v1;
const originKey = url => hash(['origin-v1', new URL(url).origin]).slice(0, 16);
const until = async (predicate, what) => { for (let i = 0; i < 1000; i++) { if (await predicate()) return; await sleep(10); } throw Error(`timeout: ${what}`); };
const since = mark => h.logs.slice(mark);
const outcomes = (mark, reason) => since(mark).filter(e => e.event === 'poll_outcome' && (reason === undefined || e.reason === reason));
const settledOutcome = outcome => ['unchanged', 'not_modified', 'published'].includes(outcome);
const requestsTo = host => h.fetches.filter(url => new URL(url).hostname === host).length;
const readout = (replica = 0) => h.invoke('test/origin-slots', '', undefined, replica);
// The table as [origin, owner_live] pairs, and one host's 16-hex origin key.
const table = async (replica = 0) => (await readout(replica)).slots.map(slot => [slot.origin, slot.owner_live]);
const key = host => originKey(`https://${host}`);

// One-shot: the next request to `host` waits until released; every other
// request, and every later one to `host`, answers at once.
function gate(host) {
  let armed = true, entered = false, release;
  const held = new Promise(resolve => { release = resolve; });
  const previous = behavior;
  behavior = async request => {
    if (armed && new URL(request.url).hostname === host) { armed = false; entered = true; await held; }
    return previous(request);
  };
  return { entered: () => entered, release: () => release() };
}
// Baselined feeds of one origin made due again, and their wakes.
async function due(urls) {
  const feeds = [];
  for (const url of urls) feeds.push(await h.add(url));
  await h.invoke('test/dispatch');
  for (const wake of (await h.polls()).filter(w => feeds.includes(w.feed_id))) assert.equal((await h.consume(wake)).status, 200);
  for (const feed of feeds) await h.run('UPDATE n_feed SET due_at=0,dispatch_until=0 WHERE feed_id=?', feed);
  await h.invoke('test/dispatch');
  const wakes = await h.polls();
  return feeds.map(feed => { const wake = wakes.find(w => w.feed_id === feed); assert.ok(wake, 'feed was not dispatched'); return wake; });
}
// A's delivery reaches its publisher request on `host` and is held there,
// owning both scan permits and (on the base) its origin slot.
async function hold(wake, host, message, execution) {
  const g = gate(host);
  const headers = { 'x-poll-message-id': message, 'x-test-execution': execution };
  let settled = false;
  const pending = h.consume(wake, { headers }).then(r => { settled = true; return r; }, error => { settled = true; return { status: 0, error }; });
  await until(() => g.entered(), 'A reaches its publisher request');
  await until(async () => (await h.invoke('test/stats')).active_permits === 2, 'A owns both permits');
  return { g, pending, headers, execution, settled: () => settled, at: performance.now() };
}
async function dispose(held) {
  await h.invoke('abort', held.execution);
  const result = await held.pending;
  held.g.release();
  assert.equal(result.status, 503, 'the held original is cancelled, not acknowledged');
}
// The deferral line of an origin_deferred outcome lands before it is classified.
async function landed(result, mark) {
  await sleep(250);
  if (result.outcome === 'origin_deferred') await until(() => outcomes(mark).some(e => e.outcome === 'origin_deferred'), 'the deferral line');
}
// The first corresponding entry passes the origin slot: no consumer_busy, the
// publisher requested, the delivery settled; and the original still held.
function passed(name, result, mark, host, before, held) {
  const busy = outcomes(mark, 'consumer_busy');
  assert.deepEqual(busy, [], `${name}: the first corresponding origin entry was refused consumer_busy (outcome ${result.outcome}): ${JSON.stringify(busy)}`);
  assert.equal(result.status, 200, result.text);
  assert.ok(settledOutcome(result.outcome), `${name}: outcome ${result.outcome}`);
  assert.equal(requestsTo(host), before + 1, `${name}: the publisher was requested once`);
  assert.equal(held.settled(), false, `${name}: the original was still held when the slot was passed`);
  assert.ok(performance.now() - held.at < 12_000, `${name}: inside the original's 15 s publisher deadline`);
}
const reclaimed = (mark, host, reason) => since(mark).filter(e => e.event === 'origin_slot_reclaimed' && e.origin === key(host) && (reason === undefined || e.reason === reason));
const anyReclaimed = mark => since(mark).filter(e => e.event === 'origin_slot_reclaimed');
// Post-change (fixture build): the held original's slot is gone while it is
// still held; its disposal is then one origin stale release (its guard found
// its slot gone) and its two permits' drops two permit stale releases.
async function reclaimedWhileHeld(name, held) {
  if (!BUILD) return;
  const before = await readout();
  assert.deepEqual(before.slots, [], `${name}: the table is empty while the original is still held`);
  assert.equal(held.settled(), false);
  const permits = (await h.invoke('test/stats')).stale_releases;
  await dispose(held);
  assert.equal((await readout()).origin_stale_releases, before.origin_stale_releases + 1, `${name}: the original's late guard drop is an origin stale release`);
  assert.equal((await h.invoke('test/stats')).stale_releases, permits + 2);
  assert.deepEqual((await readout()).slots, []);
}
const results = {};

try {
  if (CASES.includes('redelivery')) {
    // (a) A's redelivery (attempt 2, same message) reclaims the permits its
    // cancelled attempt left, and with them that attempt's origin slot.
    const host = 'redelivered.example.com';
    const [wake] = await due([`https://${host}/a`]);
    const held = await hold(wake, host, 'origin-a', 'held-a');
    const before = requestsTo(host), mark = h.logs.length;
    const retried = await h.consume(wake, { attempts: 2, headers: { 'x-poll-message-id': 'origin-a' } });
    await landed(retried, mark);
    assert.equal(since(mark).filter(e => e.event === 'scan_permit_reclaimed' && e.reason === 'redelivered').length, 2, 'the redelivery reclaims both permits of the earlier attempt');
    passed('redelivery', retried, mark, host, before, held);
    assert.equal(reclaimed(mark, host, 'permit_reclaimed').length, 1, 'origin_slot_reclaimed (permit_reclaimed) for the held slot');
    results.redelivery = { outcome: retried.outcome, reclaimed: reclaimed(mark, host) };
    if (BUILD) await reclaimedWhileHeld('redelivery', held); else await dispose(held);
    console.log('PASS (a) a redelivery reclaims its earlier attempt\'s origin slot with the permit and passes the origin while the original is held');
  }

  if (CASES.includes('age')) {
    // (b) No redelivery: past the 240 s reclaim a second feed B of the same
    // origin reclaims the permits and, with them, A's origin slot.
    const host = 'aged.example.com';
    const [wakeA, wakeB] = await due([`https://${host}/a`, `https://${host}/b`]);
    const held = await hold(wakeA, host, 'origin-aged-a', 'held-aged');
    await h.invoke('clock', '241');
    try {
      const before = requestsTo(host), mark = h.logs.length;
      const second = await h.consume(wakeB, { headers: { 'x-poll-message-id': 'origin-aged-b' } });
      await landed(second, mark);
      assert.equal(since(mark).filter(e => e.event === 'scan_permit_reclaimed' && e.reason === undefined).length, 2, 'B\'s acquisition reclaims both aged permits');
      passed('age', second, mark, host, before, held);
      assert.equal(reclaimed(mark, host, 'permit_reclaimed').length, 1, 'origin_slot_reclaimed (permit_reclaimed) for the held slot');
      results.age = { outcome: second.outcome, reclaimed: reclaimed(mark, host) };
    } finally {
      await h.invoke('clock', '0');
    }
    if (BUILD) await reclaimedWhileHeld('age', held); else await dispose(held);
    console.log('PASS (b) past 240 s a second feed of the origin reclaims the permit and the origin slot and passes the origin while the original is held');
  }

  if (CASES.includes('redirect')) {
    // (c) A redirect O -> P -> O inside one scan, read at each request
    // barrier: only the pending request's origin is held, under one owner.
    const [o, p] = ['hop-o.example.com', 'hop-p.example.com'];
    const [wake] = await due([`https://${o}/feed`]);
    const barriers = [], previous = behavior;
    behavior = async request => {
      const url = new URL(request.url);
      if (url.hostname === o || url.hostname === p) barriers.push({ at: `${url.hostname}${url.pathname}`, slots: (await readout()).slots });
      if (url.hostname === o && url.pathname === '/feed') return new Response(null, { status: 302, headers: { location: `https://${p}/feed` } });
      if (url.hostname === p) return new Response(null, { status: 302, headers: { location: `https://${o}/back` } });
      return previous(request);
    };
    const mark = h.logs.length, stale = (await readout()).origin_stale_releases;
    let result;
    try { result = await h.consume(wake); } finally { behavior = previous; }
    assert.equal(result.status, 200, result.text);
    assert.deepEqual(barriers.map(b => b.at), [`${o}/feed`, `${p}/feed`, `${o}/back`]);
    assert.deepEqual(barriers.map(b => b.slots.map(s => [s.origin, s.owner_live])), [[[key(o), true]], [[key(p), true]], [[key(o), true]]], 'at each request only its origin is held');
    assert.equal(new Set(barriers.map(b => b.slots[0].owner)).size, 1, 'one owner across the hops');
    assert.deepEqual(await table(), [], 'the table is empty at the end');
    assert.equal((await readout()).origin_stale_releases, stale);
    assert.deepEqual(anyReclaimed(mark), []);
    assert.deepEqual(outcomes(mark, 'consumer_busy'), []);
    results.redirect = { outcome: result.outcome, barriers };
    console.log('PASS (c) a redirect O -> P -> O holds only the pending request\'s origin at each barrier and leaves the table empty');
  }

  if (CASES.includes('clean')) {
    // (d) Every ordinary end frees its slot itself: zero slots before any
    // successor runs, with no reclaim warning and no stale release.
    const clean = async (name, run) => {
      const mark = h.logs.length, stale = (await readout()).origin_stale_releases;
      const detail = await run();
      assert.deepEqual(await table(), [], `${name}: zero slots before a successor`);
      assert.deepEqual(anyReclaimed(mark), [], `${name}: no reclaim warning`);
      assert.deepEqual(outcomes(mark, 'consumer_busy'), [], `${name}: no consumer_busy of any cause`);
      assert.equal((await readout()).origin_stale_releases, stale, `${name}: the guard found its own slot`);
      results[`clean_${name}`] = detail;
      console.log(`PASS (d) ${name}: zero slots, no reclaim warning`);
    };
    await clean('completion', async () => {
      const [wake] = await due(['https://complete.example.com/feed']);
      const result = await h.consume(wake);
      assert.ok(settledOutcome(result.outcome), result.outcome);
      return result.outcome;
    });
    await clean('signal_cancellation', async () => {
      const host = 'cancel.example.com';
      const [wake] = await due([`https://${host}/feed`]);
      const held = await hold(wake, host, 'origin-cancel', 'cancel-d');
      assert.deepEqual(await table(), [[key(host), true]], 'the held request holds its slot');
      await dispose(held);
      return 'cancelled';
    });
    await clean('read_origin_failure', async () => {
      // The 302 hops to another origin; the hop gives up the first slot, takes
      // the destination's, and its ReadOrigin (the next storage operation,
      // armed at the first request's barrier) fails.
      const [host, next] = ['readfail.example.com', 'readfail-next.example.com'];
      const [wake] = await due([`https://${host}/feed`]);
      const previous = behavior;
      behavior = async request => {
        if (new URL(request.url).hostname === host) { await h.invoke('fault', 'd1'); return new Response(null, { status: 302, headers: { location: `https://${next}/feed` } }); }
        return previous(request);
      };
      const mark = h.logs.length;
      let result;
      try { result = await h.consume(wake); } finally { behavior = previous; }
      assert.notEqual(result.status, 200, 'a storage failure is handling trouble');
      assert.equal(requestsTo(next), 0, 'no request after the failed origin read');
      await until(() => outcomes(mark).some(e => e.outcome === 'storage_error'), 'the storage_error line');
      const witness = since(mark).find(e => e.event === 'storage_phases' && e.handler === 'consume');
      return { status: result.status, primary: witness?.primary ?? null };
    });
    await clean('cooldown_refusal', async () => {
      const host = 'cooling.example.com';
      const [first, second] = await due([`https://${host}/a`, `https://${host}/b`]);
      const previous = behavior;
      behavior = () => new Response('busy', { status: 503, headers: { 'retry-after': '600' } });
      let failed;
      try { failed = await h.consume(first); } finally { behavior = previous; }
      assert.equal(failed.outcome, 'publisher_failed');
      assert.deepEqual(await table(), [], 'the failed request freed its slot');
      const mark = h.logs.length, requests = requestsTo(host);
      const refused = await h.consume(second);
      assert.equal(refused.outcome, 'origin_cooldown');
      assert.equal(requestsTo(host), requests, 'the cooldown refusal sent no request');
      await until(() => outcomes(mark, 'publisher_cooldown').length === 1, 'the publisher_cooldown line');
      return refused.outcome;
    });
  }

  if (CASES.includes('isolates')) {
    // (e) Two isolates: a redelivery on B cannot reclaim A's state; A stays
    // unavailable before its own threshold and recovers through its own
    // later acquisition and entry.
    const host = 'isolated.example.com';
    const [wakeA, wakeLater] = await due([`https://${host}/a`, `https://${host}/later`]);
    const held = await hold(wakeA, host, 'origin-isolated', 'held-isolated');
    const isolateA = (await readout(0)).isolate;
    assert.deepEqual(await table(0), [[key(host), true]], 'A holds its slot');
    const mark = h.logs.length, before = requestsTo(host);
    const elsewhere = await h.consume(wakeA, { attempts: 2, replica: 1, headers: { 'x-poll-message-id': 'origin-isolated' } });
    await landed(elsewhere, mark);
    assert.equal(elsewhere.status, 200, elsewhere.text);
    assert.ok(settledOutcome(elsewhere.outcome), `the redelivery on B settles on its own table: ${elsewhere.outcome}`);
    assert.equal(requestsTo(host), before + 1);
    assert.deepEqual(since(mark).filter(e => e.event === 'scan_permit_reclaimed' || e.event === 'origin_slot_reclaimed'), [], 'nothing of A\'s is reclaimed from B');
    assert.deepEqual(await table(1), [], 'B\'s table is empty after its scan');
    assert.equal((await h.invoke('test/stats')).active_permits, 2, 'A still owns both permits');
    assert.deepEqual(await table(0), [[key(host), true]], 'A\'s slot is untouched');
    await h.invoke('clock', '100');
    try {
      const early = await h.consume(wakeLater);
      assert.equal(early.outcome, 'scan_busy', 'A stays unavailable before its own reclaim threshold');
      assert.deepEqual(await table(0), [[key(host), true]]);
      await h.invoke('clock', '241');
      const mark2 = h.logs.length, before2 = requestsTo(host);
      const recovered = await h.consume(wakeLater);
      await landed(recovered, mark2);
      passed('isolates', recovered, mark2, host, before2, held);
      const lines = reclaimed(mark2, host, 'permit_reclaimed');
      assert.equal(lines.length, 1);
      assert.equal(lines[0].isolate, isolateA, 'reclaimed on A, by A\'s own acquisition');
      results.isolates = { elsewhere: elsewhere.outcome, early: early.outcome, recovered: recovered.outcome, reclaimed: lines };
    } finally {
      await h.invoke('clock', '0');
    }
    await reclaimedWhileHeld('isolates', held);
    console.log('PASS (e) a redelivery on another isolate leaves A\'s slot; A recovers through its own reclaim and entry');
  }

  if (CASES.includes('unrouted')) {
    // (f) A redelivery that ends obsolete or settled never enters an origin:
    // the eager removal inside the redelivery reclaim alone frees the slot,
    // with its warning, before any successor runs.
    for (const end of ['obsolete', 'settled']) {
      const host = `${end}-held.example.com`;
      const [wake] = await due([`https://${host}/feed`]);
      const held = await hold(wake, host, `origin-${end}`, `held-${end}`);
      assert.deepEqual(await table(), [[key(host), true]]);
      if (end === 'obsolete') await h.run('UPDATE n_feed SET schedule_generation=schedule_generation+1 WHERE feed_id=?', wake.feed_id);
      else await h.run('UPDATE n_feed SET due_at=? WHERE feed_id=?', h.now + 86400, wake.feed_id);
      const mark = h.logs.length, before = requestsTo(host);
      const retried = await h.consume(wake, { attempts: 2, headers: { 'x-poll-message-id': `origin-${end}` } });
      assert.equal(retried.outcome, end);
      assert.equal(requestsTo(host), before, `${end}: the redelivery requested nothing`);
      assert.deepEqual(await table(), [], `${end}: the slot is gone with the permit, before any successor`);
      await until(() => reclaimed(mark, host, 'permit_reclaimed').length === 1, `${end}: the origin_slot_reclaimed line`);
      results[`unrouted_${end}`] = { outcome: retried.outcome, reclaimed: reclaimed(mark, host) };
      await reclaimedWhileHeld(end, held);
      console.log(`PASS (f) a ${end} redelivery frees its earlier attempt's origin slot and warns, entering no origin`);
    }
  }
  const counts = {};
  for (const e of h.logs.filter(e => e.event === 'poll_outcome')) { const k = `${e.outcome}:${e.reason ?? ''}`; counts[k] = (counts[k] ?? 0) + 1; }
  console.log(`POLL_OUTCOMES ${JSON.stringify(counts)}`);
  console.log(`RESULTS ${JSON.stringify(results)}`);
} finally {
  await h.instance.dispose();
}
