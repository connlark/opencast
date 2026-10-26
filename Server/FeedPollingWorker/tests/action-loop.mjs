// The consume's bounded action loop (F-A): each case runs the polling Worker
// on its own PostgreSQL clone through the wire proxy. The cases that cross a
// boundary on purpose run the storage-fixture build (its loop clock); the
// others run the shipped build. A boundary is held deterministically by a
// hold on the next fresh claim, the completed boundary's first statement.
import assert from 'node:assert/strict';
import { existsSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { profileCPU } from './cpu.mjs';
import { CLAIM, POLLING_FIXTURE, oneAction as gateAction, stopAfter as claimStop } from './action-boundary.mjs';
import { setTimeout as sleep } from 'node:timers/promises';
import { harness, hash, item, rss } from './harness.mjs';

let passed = 0, failed = 0;
const report = [];
// LOOP_CASES=chained-publication,loop-clock-guard runs only the cases whose names start with those names.
const only = process.env.LOOP_CASES?.split(',');
async function test(name, run) {
  if (only && !only.some(id => name.startsWith(id))) return;
  try { await run(); passed++; console.log(`PASS ${name}`); }
  catch (error) {
    failed++;
    const errors = error.body ? [error.body, error.teardown] : [error];
    console.log(`FAIL ${name}: ${errors.map(e => e?.stack ?? e?.message ?? e).join('\n  then teardown: ')}`);
  }
}
// h.close() after a body: a body failure is never masked by the teardown it causes.
async function within(h, body) {
  let failure;
  try { return await body(); } catch (error) { failure = error; throw error; }
  finally {
    try { await h.close(); } catch (teardown) { if (!failure) throw teardown; failure.body = failure; }
  }
}
const fixture = options => {
  if (!existsSync(`${POLLING_FIXTURE}/index_bg.wasm`)) throw Error(`missing the polling fixture build ${POLLING_FIXTURE}`);
  return { pollingBuild: POLLING_FIXTURE, ...options };
};
const lines = (h, handler, from = 0) => h.logs.slice(from).filter(e => e.event === 'storage_phases' && e.handler === handler);
async function line(h, handler, from) {
  for (let i = 0; i < 200; i++) { const found = lines(h, handler, from); if (found.length) return found.at(-1); await sleep(10); }
  throw Error(`no storage_phases line for ${handler}`);
}
// A feed URL whose opaque id falls in the provenance cohort (first hex nibble
// below 4), so every one of its consumes writes a storage_phases line.
const cohort = base => { for (let i = 0; ; i++) { const url = `${base}-${i}`; if (parseInt(hash(['feed-v1', url])[0], 16) < 4) return url; } };
// The boundary renewal, by its first statement.
const RENEW = 'UPDATE n_feed SET dispatch_until=$2 WHERE';
const first = op => op.sql ?? op.statements?.[0] ?? '';
const operations = (ts, from = 0) => ts({ op: 'witness' }).operations.slice(from);
async function fired(ts, arming) {
  for (let i = 0; i < 2000; i++) { const f = ts({ op: 'witness' }).fires.find(x => x.arming === arming); if (f) return f; await sleep(5); }
  throw Error(`arming ${arming} never fired`);
}
const t0 = () => Math.floor(Date.now() / 1000);
// A feed with a `base`-row baseline, then `count` new episodes: its next scan
// stages a preparation. Returns the feed; its dispatch wake is pending.
async function changedFeed(h, name, setItems, { count = 3, base = 5 } = {}) {
  const t = t0();
  const feed = await h.add(cohort(`https://loop.example.com/${name}`));
  const baseline = Array.from({ length: base }, (_, i) => item(`base${i}`, t - 86_400 - i));
  setItems(baseline);
  await h.invoke('test/dispatch'); await h.drain();
  setItems([...Array.from({ length: count }, (_, i) => item(`n${i + 1}`, t - 60 - i)), ...baseline]);
  await h.run('UPDATE n_feed SET due_at=0,retry_at=0,dispatch_until=0 WHERE feed_id=?', feed);
  await h.invoke('test/dispatch');
  return feed;
}
const wakeOf = async (h, feed) => (await h.polls()).filter(w => w.feed_id === feed);
// One delivery, its storage_phases line and the proxy operations it ran.
async function deliver(h, ts, wake, options = {}) {
  const from = h.logs.length, ops = operations(ts).length;
  const result = await h.consume(wake, options);
  const row = await line(h, 'consume', from);
  return { ...result, row, ops: operations(ts, ops), from };
}
// One delivery stopped after its `n`-th action (action-boundary.mjs), with its line and operations.
async function stopAfter(h, ts, wake, n, options = {}) {
  const from = h.logs.length, ops = operations(ts).length;
  const result = await claimStop(h, wake, n, options);
  return { ...result, row: await line(h, 'consume', from), ops: operations(ts, ops) };
}
const count = (ops, prefix) => ops.filter(o => first(o).startsWith(prefix)).length;
// The chain of `feed` delivered until no wake is due; each delivery recorded.
async function chain(h, ts, feed, limit = 80) {
  const out = [];
  for (let i = 0; i < limit; i++) {
    const wakes = await wakeOf(h, feed);
    if (!wakes.length) return out;
    for (const wake of wakes) out.push(await deliver(h, ts, wake));
  }
  throw Error('the chain did not settle');
}

await test('chained-publication: a small changed feed with a five-row baseline publishes and POSTs to FeedEvents within two deliveries (one per action on the base); the boundaries from the proxy trace and the durable state, not the action list', async () => {
  let items = [];
  const h = await harness(() => new Response(rss(items)), { logs: true });
  await within(h, async () => {
    const ts = h.storage.testStorage('polling-runtime');
    const feed = await changedFeed(h, 'chained', next => { items = next; });
    const posted = h.events.length;
    const deliveries = [];
    let through = null;
    for (let i = 0; i < 40 && through === null; i++) {
      const [wake] = await wakeOf(h, feed);
      assert.ok(wake, `the chain reached its FeedEvents POST: ${deliveries.map(d => d.outcome)}`);
      deliveries.push(await deliver(h, ts, wake));
      if (h.events.length > posted) through = deliveries.length;
    }
    assert.ok(through !== null && through <= 2, `deliveries from wake 0 through the FeedEvents POST: ${through} (${deliveries.map(d => d.outcome)})`);
    deliveries.push(...await chain(h, ts, feed));
    // The proxy trace: every action opened by a claim and a renewal, and the
    // publication's own statements inside the first delivery.
    const ops = deliveries[0].ops;
    assert.ok(count(ops, CLAIM) >= 8 && count(ops, RENEW) >= count(ops, CLAIM), `claims ${count(ops, CLAIM)}, renewals ${count(ops, RENEW)}`);
    // The durable state: published, drained, three outbox rows accepted, settled.
    const observation = await h.first("SELECT observation_id,snapshot_key,candidate_count,candidate_cursor,drain_complete FROM n_observation WHERE feed_id=? AND state='published' ORDER BY scan_started_at DESC LIMIT 1", feed);
    assert.deepEqual([observation?.candidate_count, observation?.candidate_cursor, observation?.drain_complete], [3, 3, 1], JSON.stringify(observation));
    const outbox = await h.rows('SELECT state FROM n_outbox WHERE observation_id=?', observation.observation_id);
    assert.deepEqual(outbox.map(r => r.state), ['accepted', 'accepted', 'accepted']);
    assert.equal((await h.first('SELECT dispatch_until FROM n_feed WHERE feed_id=?', feed)).dispatch_until, 0, 'settled');
    // The R2 checkpoint the publication committed resolves to its candidates.
    const bucket = await h.instance.getR2Bucket('FEED_SNAPSHOTS', 'polling-runtime');
    const manifest = JSON.parse(await (await bucket.get(observation.snapshot_key)).text());
    assert.equal(manifest.candidate_pages.reduce((n, p) => n + p.count, 0), 3);
    // poll_published belongs to the delivery whose line follows it.
    const published = h.logs.findIndex((e, i) => i >= deliveries[0].from && e.event === 'poll_published' && e.feed_id === feed);
    assert.ok(published >= deliveries[0].from && published < h.logs.indexOf(deliveries[0].row), 'poll_published inside the first delivery');
    report.push(`chained-publication: ${through} delivery through the POST (${deliveries.map(d => d.outcome).join(', ')}); first delivery ${count(ops, CLAIM)} claims, ${count(ops, RENEW)} renewals`);
  });
});

await test('loop-clock-guard: the loop clock: at offset 0 two drains run in one delivery; with the offset moved past 140,000 ms after the first completed action, exactly one action runs and one guard continuation is yielded; Date and the leases unshifted', async () => {
  let items = [];
  const h = await harness(() => new Response(rss(items)), fixture({ logs: true }));
  await within(h, async () => {
    const ts = h.storage.testStorage('polling-runtime');
    // Two published observations' worth of pages: 250 candidates, three pages.
    const feed = await changedFeed(h, 'loop-clock', next => { items = next; }, { count: 250 });
    // To the published, undrained observation: the scan, its phases and the
    // publication in one delivery, stopped at the boundary before the first drain.
    let at = null;
    for (let i = 0; i < 20 && !at; i++) {
      const [wake] = await wakeOf(h, feed);
      assert.ok(wake, 'the chain reached its publication');
      const state = await h.first("SELECT COUNT(*) AS n FROM n_observation WHERE feed_id=? AND state='published' AND drain_complete=0", feed);
      if (state.n) { at = wake; break; }
      await stopAfter(h, ts, wake, 1);
    }
    assert.ok(at, 'a published, undrained observation');
    const cursor = async () => (await h.first("SELECT candidate_cursor FROM n_observation WHERE feed_id=? AND state='published' ORDER BY scan_started_at DESC LIMIT 1", feed)).candidate_cursor;
    // (a) the gate armed at the first completed boundary, the clock moved past
    // the guard while the delivery waits there, then released.
    const lease = await h.first('SELECT lease_until,lease_id FROM n_feed WHERE feed_id=?', feed);
    const before = await cursor();
    await h.invoke('test/loop-clock', '0');
    assert.deepEqual(await h.invoke('test/loop-gate', 'arm'), { gate: 'armed' });
    const from = h.logs.length, opsAt = operations(ts).length;
    const dateBefore = Date.now();
    const running = h.consume(at);
    running.catch(() => {});
    // The delivery is at the gate once its first drain committed and its
    // storage has been quiet for 300 ms.
    for (let i = 0, quiet = 0, seen = -1; ; i++) {
      assert.ok(i < 2000, 'the delivery reached its first completed boundary');
      const n = operations(ts, opsAt).length;
      if ((await cursor()) > before && n === seen) { if ((quiet += 25) >= 300) break; } else quiet = 0;
      seen = n; await sleep(25);
    }
    await h.invoke('test/loop-clock', '141000');
    assert.deepEqual(await h.invoke('test/loop-gate', 'release'), { gate: 'open', released_waiter: true });
    const one = await running;
    await h.invoke('test/loop-clock', '0');
    const row = await line(h, 'consume', from);
    const ops = operations(ts, opsAt);
    assert.deepEqual([one.status, one.outcome], [200, 'guard'], one.text);
    assert.equal(count(ops, CLAIM), 2, 'the first action\'s claim and the boundary\'s fresh claim');
    assert.equal(count(ops, RENEW), 2, 'the first action\'s renewal and the guard continuation\'s');
    assert.deepEqual(row.sent && [row.sent.step, row.sent.delay_s, row.sent.result], [at.step + 1, 0, 'ok'], JSON.stringify(row.sent));
    assert.equal(await cursor(), 100, 'one page drained');
    // Date and the leases did not move with the loop clock.
    assert.ok(Math.abs(Date.now() - dateBefore) < 30000, 'Date unshifted');
    assert.deepEqual(await h.first('SELECT lease_until,lease_id FROM n_feed WHERE feed_id=?', feed), lease);
    // (b) at offset 0: two drains in one delivery.
    const [next] = await wakeOf(h, feed);
    assert.equal(next?.step, at.step + 1, 'the guard\'s continuation');
    const two = await stopAfter(h, ts, next, 2);
    assert.equal(two.outcome, 'guard');
    assert.equal(await cursor(), 250, 'two more pages drained in one delivery');
    report.push(`loop-clock-guard: offset past the guard after action 1 -> ${count(ops, CLAIM)} claims, outcome ${one.outcome}; offset 0 -> two drains, cursor 250`);
  });
});

// One delivery of exactly one action on either tree (the loop gate: action-boundary.mjs).
async function oneAction(h, ts, wake) {
  const from = h.logs.length, at = operations(ts).length;
  const result = await gateAction(h, wake);
  return { ...result, row: await line(h, 'consume', from), ops: operations(ts, at) };
}
// Deliveries of one action each until `ready()` holds; returns the next wake.
async function until(h, ts, feed, ready, limit = 30) {
  for (let i = 0; i < limit; i++) {
    const [wake] = await wakeOf(h, feed);
    assert.ok(wake, 'the chain is still running');
    if (await ready()) return wake;
    await oneAction(h, ts, wake);
  }
  throw Error('the chain never reached its seeded state');
}
const staging = (h, feed) => async () => (await h.first("SELECT COUNT(*) AS n FROM n_observation WHERE feed_id=? AND state='staging' AND valid_eof=1", feed)).n > 0;
const publishedAt = (h, feed, cursor) => async () => (await h.first("SELECT COUNT(*) AS n FROM n_observation WHERE feed_id=? AND state='published' AND candidate_count>0 AND candidate_cursor=?", feed, cursor)).n > 0;

for (const [label, candidates, expected] of [['seven full pages', 700, { actions: 12, outcome: 'action_bound' }], ['the small companion', 8, { actions: 8, outcome: 'settled' }]]) {
  await test(`action-bound (${label}): a pre-staged scan of ${candidates} candidates; the first delivery runs ${expected.actions} actions and ends ${expected.outcome}${candidates > 100 ? '; the next starts with a drain and six maturity-only drains precede outbox work; every outbox row is POSTed' : ''}`, async () => {
    let items = [];
    const h = await harness(() => new Response(rss(items)), fixture({ logs: true }));
    await within(h, async () => {
      const ts = h.storage.testStorage('polling-runtime');
      const feed = await changedFeed(h, `bound-${candidates}`, next => { items = next; }, { count: candidates });
      const wake = await until(h, ts, feed, staging(h, feed));
      // The scan is done: its next slot pushed out of the dispatcher's 30 s
      // lookahead, so the chain ends at its settle and never runs on into a scan.
      await h.run('UPDATE n_feed SET due_at=? WHERE feed_id=?', t0() + 86_400, feed);
      const posted = h.events.length;
      const one = await deliver(h, ts, wake);
      assert.deepEqual([one.status, one.outcome], [200, expected.outcome], one.text);
      assert.equal(count(one.ops, CLAIM), expected.actions, `actions (one claim each): ${count(one.ops, CLAIM)}`);
      const observation = await h.first("SELECT observation_id,candidate_count,candidate_cursor,drain_complete FROM n_observation WHERE feed_id=? AND state='published' ORDER BY scan_started_at DESC LIMIT 1", feed);
      assert.deepEqual([observation?.candidate_count, observation?.candidate_cursor, observation?.drain_complete], [candidates, candidates, 1], JSON.stringify(observation));
      const outboxed = async () => (await h.first('SELECT COUNT(*) AS n FROM n_outbox WHERE observation_id=?', observation.observation_id)).n;
      if (candidates > 100) {
        assert.deepEqual([one.row.sent?.step, one.row.sent?.delay_s], [wake.step + 1, 0], JSON.stringify(one.row.sent));
        assert.equal(await outboxed(), 100, 'the last page drain matured one hundred');
        const [next] = await wakeOf(h, feed);
        const two = await deliver(h, ts, next);
        assert.equal(two.row.action[0]?.name, 'drain', JSON.stringify(two.row.action.map(a => a.name)));
        assert.equal(await outboxed(), candidates, 'six maturity-only drains outboxed the rest');
        assert.equal(two.row.posts?.n, 60, `six outbox actions after them: ${JSON.stringify(two.row.posts)}`);
        await h.drain();
      }
      const accepted = (await h.first("SELECT COUNT(*) AS n FROM n_outbox WHERE observation_id=? AND state='accepted'", observation.observation_id)).n;
      assert.deepEqual([accepted, h.events.length - posted], [candidates, candidates], 'every outbox row POSTed once');
      report.push(`action-bound (${label}): first delivery ${count(one.ops, CLAIM)} actions, ${one.outcome}; ${accepted} POSTed`);
    });
  });
}

await test('action-bound-control (two pages, 200 candidates): deliveries from a pre-staged scan to settlement (29 on the base)', async () => {
  let items = [];
  const h = await harness(() => new Response(rss(items)), fixture({ logs: true }));
  await within(h, async () => {
    const ts = h.storage.testStorage('polling-runtime');
    const feed = await changedFeed(h, 'bound-control', next => { items = next; }, { count: 200 });
    const wake = await until(h, ts, feed, staging(h, feed));
    const deliveries = [await deliver(h, ts, wake), ...await chain(h, ts, feed)];
    const accepted = (await h.first("SELECT COUNT(*) AS n FROM n_outbox x JOIN n_observation o ON o.observation_id=x.observation_id WHERE o.feed_id=? AND x.state='accepted'", feed)).n;
    assert.equal(accepted, 200);
    assert.ok(deliveries.length <= 4, `deliveries to settlement: ${deliveries.length} (${deliveries.map(d => d.outcome)})`);
    report.push(`action-bound-control: ${deliveries.length} deliveries from the pre-staged scan to settlement (${deliveries.map(d => d.outcome).join(', ')})`);
  });
});

await test('one-delivery-tail: a published observation stopped after its first page, its earliest 95 releases expired, not scan-due: last drain, a maturity-only drain, outbox and settle in ONE delivery; every intended POST, then settled', async () => {
  let items = [];
  const h = await harness(() => new Response(rss(items)), fixture({ logs: true }));
  await within(h, async () => {
    const ts = h.storage.testStorage('polling-runtime');
    const feed = await changedFeed(h, 'tail', next => { items = next; }, { count: 101 });
    const wake = await until(h, ts, feed, publishedAt(h, feed, 100));
    const t = t0();
    await h.run("UPDATE n_episode_release SET expires_at=? WHERE event_id IN (SELECT event_id FROM n_episode_release WHERE feed_id=? AND state='ready' ORDER BY eligible_at,episode_id LIMIT 95)", t - 1, feed);
    await h.run('UPDATE n_feed SET due_at=? WHERE feed_id=?', t + 86_400, feed);
    const posted = h.events.length;
    const one = await deliver(h, ts, wake);
    assert.deepEqual([one.status, one.outcome], [200, 'settled'], one.text);
    assert.deepEqual(one.row.action.map(a => a.name), ['drain', 'drain', 'outbox', 'settle']);
    assert.equal(one.row.sent, null, 'no continuation');
    const states = Object.fromEntries((await h.rows('SELECT state,COUNT(*) AS n FROM n_episode_release WHERE feed_id=? GROUP BY state', feed)).map(r => [r.state, Number(r.n)]));
    assert.deepEqual([states.expired, states.outboxed], [95, 6], JSON.stringify(states));
    assert.equal((await h.first("SELECT COUNT(*) AS n FROM n_outbox x JOIN n_observation o ON o.observation_id=x.observation_id WHERE o.feed_id=? AND x.state='accepted'", feed)).n, 6);
    assert.equal(h.events.length - posted, 6, 'every intended POST');
    assert.equal((await h.first('SELECT dispatch_until FROM n_feed WHERE feed_id=?', feed)).dispatch_until, 0);
    assert.equal((await wakeOf(h, feed)).length, 0);
    report.push(`one-delivery-tail: one delivery ${one.row.action.map(a => a.name).join(' -> ')}, ${h.events.length - posted} POSTs, settled`);
  });
});

const stale = async h => Number((await h.first('SELECT COALESCE(SUM(stale_commits),0) AS n FROM n_poll_stat')).n);
// A terminal delivery: no continuation, nothing due, and no action after the
// one that ended it (the last claim is followed by at most its own renewal).
function terminal(d, wakes) {
  assert.equal(d.status, 200, d.text);
  assert.equal(d.row.sent, null, `no continuation: ${JSON.stringify(d.row.sent)}`);
  assert.equal(wakes.length, 0, 'nothing due');
  const ops = d.ops.map(first), last = ops.findLastIndex(x => x.startsWith(CLAIM));
  const renewals = ops.map((x, i) => [x, i]).filter(([x, i]) => i > last && x.startsWith(RENEW)).map(([, i]) => i);
  assert.ok(renewals.length === 0 || (renewals.length === 1 && renewals[0] === last + 1), `after the last claim (${last}) renewals at ${renewals}`);
}
// [label, the delivery's outcome, the fault, the scan's own result]
const terminals = [
  ['published, settled (a baseline scan publishes itself)', 'published', null, 'published'],
  ['lost_fence (the baseline publication loses its fence)', 'obsolete', 'stale_generation', 'lost_fence'],
  ['unchanged, settled', 'unchanged', null, 'unchanged'],
  ['not_modified, settled', 'not_modified', null, 'not_modified'],
  ['unchanged, not settled (the settle loses its fence)', 'obsolete', 'stale_settle', 'unchanged'],
  ['not_modified, not settled (the 304\'s settle loses its fence)', 'obsolete', 'stale_settle', 'not_modified'],
  ['publisher_failed', 'publisher_failed', null, 'publisher_failed'],
  ['origin_cooldown, its settlement rejected proxy-side', 'origin_cooldown', null, 'origin_deferred'],
];
for (const [label, outcome, fault, result] of terminals) {
  await test(`terminal (${outcome}): a terminal result ends the delivery with no send and no further action: ${label}`, async () => {
    const t = t0();
    let reply = () => new Response(rss([item('base', t - 86_400)]), { headers: { etag: '"t18"' } });
    const h = await harness(request => reply(request), { logs: true });
    await within(h, async () => {
      const ts = h.storage.testStorage('polling-runtime');
      const feed = await h.add(cohort(`https://loop.example.com/terminal-${outcome}-${fault ?? 'plain'}`));
      await h.invoke('test/dispatch');
      const baseline = outcome === 'published' || label.startsWith('lost_fence');
      if (!baseline) {
        await h.drain();
        await h.run('UPDATE n_feed SET due_at=0,retry_at=0,dispatch_until=0 WHERE feed_id=?', feed);
        await h.invoke('test/dispatch');
        if (outcome === 'not_modified' || label.startsWith('not_modified')) reply = request => request.headers.get('if-none-match') === '"t18"' ? new Response(null, { status: 304, headers: { etag: '"t18"' } }) : new Response('unexpected', { status: 500 });
        // No ETag: an equal one takes the 304 shortcut (not_modified).
        if (outcome === 'unchanged' || label.startsWith('unchanged')) reply = () => new Response(rss([item('base', t - 86_400)]));
        if (outcome === 'publisher_failed') reply = () => new Response('gone', { status: 500 });
        // A cooldown recorded before the request defers the origin: the
        // scan answers origin_deferred, here beyond a minute, so it settles.
        if (outcome === 'origin_cooldown') await h.run('INSERT INTO n_poll_origin(origin_key,cooldown_until,failures,last_status,updated_at) SELECT origin_key,?,1,429,? FROM n_feed WHERE feed_id=? ON CONFLICT(origin_key) DO UPDATE SET cooldown_until=excluded.cooldown_until', t + 600, t, feed);
      }
      const [wake] = await wakeOf(h, feed);
      if (fault) await h.invoke('fault', fault);
      let arm;
      if (outcome === 'origin_cooldown') arm = ts({ op: 'arm', kind: 'statement', action: 'side-write-first', side: 'stale_generation', match: 'UPDATE n_feed SET retry_at=GREATEST(retry_at,$2)' });
      const staleBefore = await stale(h);
      const d = await deliver(h, ts, wake);
      assert.equal(d.outcome, outcome, d.text);
      terminal(d, await wakeOf(h, feed));
      // Exactly the one action that ended it: one claim, one action in the line.
      assert.equal(count(d.ops, CLAIM), 1, `claims ${count(d.ops, CLAIM)}`);
      assert.equal(d.row.action.length, 1, JSON.stringify(d.row.action.map(a => [a.name, a.result])));
      assert.deepEqual([d.row.action[0].name, d.row.action[0].result], ['scan', result], 'the scan result the case names');
      if (arm) {
        assert.ok(ts({ op: 'witness' }).fires.some(f => f.arming === arm.arming), 'the settlement was rejected proxy-side');
        assert.equal(await stale(h), staleBefore + 1, 'fence.rejected stepped StaleCommits');
      }
      report.push(`terminal ${label}: ${d.outcome}, ${count(d.ops, CLAIM)} claim(s), no send`);
    });
  });
}

await test('obsolete-claim (control): an obsolete initial claim: no action, no send, obsolete', async () => {
  const t = t0();
  const h = await harness(() => new Response(rss([item('base', t - 86_400)])), { logs: true });
  await within(h, async () => {
    const ts = h.storage.testStorage('polling-runtime');
    const feed = await h.add(cohort('https://loop.example.com/obsolete-claim'));
    await h.invoke('test/dispatch');
    const [wake] = await wakeOf(h, feed);
    await h.run('UPDATE n_feed SET schedule_generation=schedule_generation+1 WHERE feed_id=?', feed);
    const d = await deliver(h, ts, wake);
    assert.deepEqual([d.status, d.outcome], [200, 'obsolete'], d.text);
    assert.deepEqual(d.ops.map(first).filter(x => !x.startsWith('INSERT INTO n_poll_stat')).map(x => x.slice(0, 28)), [CLAIM.slice(0, 28)], 'the claim alone');
    terminal(d, await wakeOf(h, feed));
  });
});
for (const [label, invalidate] of [
  ['a new dispatch generation', feed => ['UPDATE n_feed SET schedule_generation=schedule_generation+1 WHERE feed_id=?', feed]],
  ['an epoch change', feed => ['UPDATE n_feed SET epoch=epoch+1 WHERE feed_id=?', feed]],
  ['admission_paused', feed => ['UPDATE n_feed SET admission_paused=1 WHERE feed_id=?', feed]],
]) {
  await test(`invalidation-at-gate (${label}): an invalidation between two actions, at the loop gate: the fresh claim has no row, no action runs, no send, StaleCommits stepped, obsolete`, async () => {
    let items = [];
    const h = await harness(() => new Response(rss(items)), fixture({ logs: true }));
    await within(h, async () => {
      const ts = h.storage.testStorage('polling-runtime');
      const feed = await changedFeed(h, `invalidation-${label.replace(/\W+/g, '-')}`, next => { items = next; }, { count: 150 });
      const wake = await until(h, ts, feed, publishedAt(h, feed, 0));
      const cursor = async () => (await h.first("SELECT candidate_cursor FROM n_observation WHERE feed_id=? AND state='published' ORDER BY scan_started_at DESC LIMIT 1", feed)).candidate_cursor;
      await h.invoke('test/loop-clock', '0');
      await h.invoke('test/loop-gate', 'arm');
      const from = h.logs.length, at = operations(ts).length, staleBefore = await stale(h);
      const running = h.consume(wake);
      running.catch(() => {});
      for (let i = 0, quiet = 0, seen = -1; ; i++) {
        assert.ok(i < 2000, `the delivery reached its first completed boundary: cursor ${await cursor()}`);
        const n = operations(ts, at).length;
        if ((await cursor()) === 100 && n === seen) { if ((quiet += 25) >= 300) break; } else quiet = 0;
        seen = n; await sleep(25);
      }
      await h.run(...invalidate(feed));
      assert.equal((await h.invoke('test/loop-gate', 'release')).released_waiter, true, 'the delivery waited at the gate');
      const result = await running;
      const row = await line(h, 'consume', from), ops = operations(ts, at);
      assert.deepEqual([result.status, result.outcome], [200, 'obsolete'], result.text);
      assert.equal(row.sent, null);
      assert.equal(await cursor(), 100, 'no second drain');
      const tail = ops.map(first), k2 = tail.findLastIndex(x => x.startsWith(CLAIM));
      assert.deepEqual(tail.slice(k2 + 1).map(x => x.slice(0, 30)), ['INSERT INTO n_poll_stat(bucket,stale_commits)'.slice(0, 30)], `after the fresh claim: ${JSON.stringify(tail.slice(k2 + 1))}`);
      assert.equal(await stale(h), staleBefore + 1);
      assert.equal((await wakeOf(h, feed)).length, 0, 'no send');
      report.push(`invalidation-at-gate (${label}): the fresh claim read no row; obsolete, StaleCommits +1, cursor held at 100`);
    });
  });
}

const READ_DRAIN = 'SELECT o.*,s.sha256,s.bytes FROM n_observation o';
const reservation = async (h, feed) => Number((await h.first('SELECT dispatch_until FROM n_feed WHERE feed_id=?', feed)).dispatch_until);

await test('boundary-renewal: an acknowledged fenced UPDATE of dispatch_until before the second action\'s first statement, no continuation send between them, the durable row at now + 300 then; the dispatcher still counts the feed live and leaves it out of Repairs past the previous reservation', async () => {
  let items = [];
  const h = await harness(() => new Response(rss(items)), fixture({ logs: true }));
  await within(h, async () => {
    const ts = h.storage.testStorage('polling-runtime');
    const feed = await changedFeed(h, 'renewal', next => { items = next; }, { count: 150 });
    const wake = await until(h, ts, feed, publishedAt(h, feed, 0));
    const at = operations(ts).length, from = h.logs.length;
    const one = ts({ op: 'arm', kind: 'statement', action: 'hold-request', match: READ_DRAIN });
    const running = h.consume(wake); running.catch(() => {});
    const f1 = await fired(ts, one.arming);
    const previous = await reservation(h, feed);
    // Durable time moves on, so the next renewal is told apart from this one.
    await h.invoke('clock', '60');
    const two = ts({ op: 'arm', kind: 'statement', action: 'hold-request', match: READ_DRAIN });
    ts({ op: 'release', fire: f1.id });
    const f2 = await fired(ts, two.arming);
    const renewed = await reservation(h, feed), now = previous + 1;
    const view = await h.first('SELECT (dispatch_until>?) AS live,(dispatch_until>0 AND dispatch_until<=?) AS lapsed FROM n_feed WHERE feed_id=?', now, now, feed);
    const sentMeanwhile = (await wakeOf(h, feed)).length;
    ts({ op: 'release', fire: f2.id });
    const result = await running;
    await h.invoke('clock', '0');
    assert.equal(result.status, 200, result.text);
    assert.equal(sentMeanwhile, 0, 'no continuation send between the actions');
    assert.ok(renewed >= previous + 60 && renewed <= previous + 62, `the reservation renewed to now + 300: ${previous} -> ${renewed}`);
    assert.deepEqual([Boolean(view.live), Boolean(view.lapsed)], [true, false], `at ${now}: ${JSON.stringify(view)}`);
    // The trace: claim, renewal (acknowledged, UPDATE 1), then the second action's first statement.
    const ops = operations(ts, at), held = ops.findIndex(o => o.id === f2.op);
    const before = ops.slice(0, held).map(first), renewal = ops[before.findLastIndex(x => x.startsWith(RENEW))];
    assert.ok(before.findLastIndex(x => x.startsWith(RENEW)) > before.findLastIndex(x => x.startsWith(CLAIM)), 'the renewal follows the fresh claim');
    assert.ok(renewal.tags.includes('UPDATE 1') && renewal.ended != null && renewal.ended <= ops[held].started, JSON.stringify({ tags: renewal.tags, ended: renewal.ended, next: ops[held].started }));
    void from;
    report.push(`boundary-renewal: reservation ${previous} -> ${renewed} before action 2; at ${now} live ${Boolean(view.live)}, in Repairs ${Boolean(view.lapsed)}`);
  });
});

await test('yield-renewal-lost-fence (control): a yield\'s renewal after a completed drain under a lost fence: zero rows, obsolete, no send, StaleCommits stepped, the drain\'s progress kept', async () => {
  let items = [];
  const h = await harness(() => new Response(rss(items)), fixture({ logs: true }));
  await within(h, async () => {
    const ts = h.storage.testStorage('polling-runtime');
    const feed = await changedFeed(h, 'yield-renewal-fence', next => { items = next; }, { count: 150 });
    const wake = await until(h, ts, feed, publishedAt(h, feed, 0));
    // The drain's own checkpoint write held: once released the action has
    // completed, and the next renewal is the yield's on either tree (without the
    // loop, proceed()'s; on the loop the guard yields at the boundary, which
    // renews nothing before it).
    await h.invoke('test/loop-clock', '0');
    const hold = ts({ op: 'arm', kind: 'statement', action: 'hold-request', match: 'WITH r AS (SELECT * FROM unnest($5::text[]' });
    const at = operations(ts).length, from = h.logs.length, staleBefore = await stale(h);
    const running = h.consume(wake); running.catch(() => {});
    const fire = await fired(ts, hold.arming);
    const arm = ts({ op: 'arm', kind: 'statement', action: 'side-write-first', side: 'stale_generation', match: RENEW });
    await h.invoke('test/loop-clock', '141000');
    ts({ op: 'release', fire: fire.id });
    const result = await running;
    await h.invoke('test/loop-clock', '0');
    const row = await line(h, 'consume', from);
    const renewal = operations(ts, at).find(o => o.id === ts({ op: 'witness' }).fires.find(f => f.arming === arm.arming)?.op);
    assert.ok(renewal, 'the yield\'s renewal met the lost fence');
    assert.ok(renewal.tags.includes('UPDATE 0'), JSON.stringify(renewal.tags));
    assert.deepEqual([result.status, result.outcome, row.sent], [200, 'obsolete', null], result.text);
    assert.equal(row.action[0]?.name, 'drain');
    assert.equal((await h.first("SELECT candidate_cursor FROM n_observation WHERE feed_id=? AND state='published' AND candidate_count>0", feed)).candidate_cursor, 100, 'the completed drain stands');
    assert.equal(await stale(h), staleBefore + 1);
    assert.equal((await wakeOf(h, feed)).length, 0, 'no send');
    report.push('yield-renewal-lost-fence: a completed drain (cursor 100), then its yield\'s renewal UPDATE 0: obsolete, no send, StaleCommits +1');
  });
});

await test('boundary-renewal-lost-fence: the boundary renewal under a lost fence: the generation bumped after the fresh claim and before the renewal: zero rows, the obsolete exit before any second action', async () => {
  let items = [];
  const h = await harness(() => new Response(rss(items)), fixture({ logs: true }));
  await within(h, async () => {
    const ts = h.storage.testStorage('polling-runtime');
    const feed = await changedFeed(h, 'renewal-fence', next => { items = next; }, { count: 150 });
    const wake = await until(h, ts, feed, publishedAt(h, feed, 0));
    const arm = ts({ op: 'arm', kind: 'statement', action: 'hold-request', match: RENEW, skip: 1 });
    const at = operations(ts).length, from = h.logs.length, staleBefore = await stale(h);
    const running = h.consume(wake); running.catch(() => {});
    const fire = await fired(ts, arm.arming);
    const ops = operations(ts, at).map(first);
    assert.ok(ops.at(-2).startsWith(CLAIM), `the fresh claim succeeded just before: ${ops.slice(-3)}`);
    await h.run('UPDATE n_feed SET schedule_generation=schedule_generation+1 WHERE feed_id=?', feed);
    ts({ op: 'release', fire: fire.id });
    const result = await running, row = await line(h, 'consume', from);
    assert.deepEqual([result.status, result.outcome, row.sent], [200, 'obsolete', null], result.text);
    const renewal = operations(ts, at).find(o => o.id === fire.op);
    assert.ok(renewal.tags.includes('UPDATE 0'), JSON.stringify(renewal.tags));
    assert.equal((await h.first("SELECT candidate_cursor FROM n_observation WHERE feed_id=? AND state='published' AND candidate_count>0", feed)).candidate_cursor, 100, 'no second drain');
    assert.equal(await stale(h), staleBefore + 1);
    report.push('boundary-renewal-lost-fence: the k=2 renewal held, the generation bumped, released: UPDATE 0, obsolete before action 2');
  });
});

const PREPARE_CHECKPOINT = 'UPDATE n_observation SET preparation_key=$2';
const DRAIN_CHECKPOINT = 'WITH r AS (SELECT * FROM unnest($5::text[]';
const SCAN_FIRST = 'SELECT canonical_url,etag,last_modified';
// The staging preparation's durable pointer: its key, the phase that key's JSON names, its failures and wait.
async function preparation(h, feed) {
  const row = await h.first("SELECT preparation_key,processing_failures,processing_next_at,state FROM n_observation WHERE feed_id=? AND valid_eof=1 AND state='staging' ORDER BY scan_started_at DESC LIMIT 1", feed);
  const bucket = await h.instance.getR2Bucket('FEED_SNAPSHOTS', 'polling-runtime');
  const object = row?.preparation_key ? await bucket.get(row.preparation_key) : null;
  return { ...row, phase: object ? JSON.parse(await object.text()).phase : null };
}
// Delivers `feed`'s chain until a delivery answers `status`; returns it.
async function deliverUntilStatus(h, ts, feed, status, limit = 30) {
  for (let i = 0; i < limit; i++) {
    const [wake] = await wakeOf(h, feed);
    assert.ok(wake, `a delivery answered ${status}`);
    const d = await deliver(h, ts, wake);
    if (d.status === status) return { ...d, wake };
  }
  throw Error(`no delivery answered ${status}`);
}
async function settleFires(ts, fires) {
  for (const fire of fires) {
    for (let i = 0; i < 300 && !ts({ op: 'witness' }).operations.find(o => o.id === fire.op)?.close; i++) await sleep(10);
    const state = ts({ op: 'witness' }).fires.find(f => f.id === fire.id);
    if (state?.discarded != null) ts({ op: 'expect', fire: fire.id, outcome: 'discarded' });
  }
}

await test('failed-checkpoint (control): the phase-3 input pointer and the 300 s wait: the checkpoint after phase-3 work fails before it commits; the pointer still names phase-3, the wait is now + 300; after /clock moves durable time past it the next delivery resumes at phase-3', async () => {
  let items = [];
  const h = await harness(() => new Response(rss(items)), { logs: true });
  await within(h, async () => {
    const ts = h.storage.testStorage('polling-runtime');
    const feed = await changedFeed(h, 'failed-checkpoint', next => { items = next; });
    // The scan's checkpoint names phase-0; the fifth write, phase-3's, names phase-4.
    const arm = ts({ op: 'arm', kind: 'statement', action: 'close-before', match: PREPARE_CHECKPOINT, skip: 4 });
    const failed = await deliverUntilStatus(h, ts, feed, 500);
    assert.ok(ts({ op: 'witness' }).fires.some(f => f.arming === arm.arming), 'the checkpoint failed before it committed');
    const after = await preparation(h, feed), t = t0();
    assert.deepEqual([after.phase, after.processing_failures, after.state], [3, 1, 'staging'], JSON.stringify({ after, actions: failed.row.action.map(a => [a.name, a.result, a.status]), primary: failed.row.primary?.op, rows: await h.rows('SELECT state,valid_eof,processing_failures,scan_started_at FROM n_observation WHERE feed_id=?', feed) }));
    assert.ok(after.processing_next_at >= t + 295 && after.processing_next_at <= t + 300, `wait ${after.processing_next_at - t}`);
    await h.invoke('clock', '301');
    const resumed = await deliver(h, ts, failed.wake, { attempts: 2 });
    await h.invoke('clock', '0');
    assert.equal(resumed.status, 200, resumed.text);
    const first = resumed.row.recovery.first_action;
    assert.deepEqual([first?.name, first?.start_checkpoint?.phase, first?.start_checkpoint?.status], ['prepare', 3, 'committed'], JSON.stringify(resumed.row.recovery));
    report.push(`failed-checkpoint: failed at the phase-4 checkpoint write; pointer phase ${after.phase}, wait ${after.processing_next_at - t} s; resumed at phase ${first.start_checkpoint.phase} (${resumed.outcome})`);
  });
});

await test('unknown-checkpoint (control): hold-commit-reply on the same checkpoint: the server commits, the client reads Unknown; the installed output pointer, naming phase-4, is durable; no rollback to phase-3 and no readback', async () => {
  let items = [];
  const h = await harness(() => new Response(rss(items)), { logs: true });
  await within(h, async () => {
    const ts = h.storage.testStorage('polling-runtime');
    const feed = await changedFeed(h, 'unknown-checkpoint', next => { items = next; });
    const arm = ts({ op: 'arm', kind: 'statement', action: 'hold-commit-reply', forever: true, match: PREPARE_CHECKPOINT, skip: 4 });
    const failed = await deliverUntilStatus(h, ts, feed, 500);
    const fire = ts({ op: 'witness' }).fires.find(f => f.arming === arm.arming);
    assert.ok(fire, 'the COMMIT reply was held');
    const op = ts({ op: 'witness' }).operations.find(o => o.id === fire.op);
    assert.deepEqual([op?.commit_tag, op?.commit_relayed], ['COMMIT', false], JSON.stringify(op));
    const after = await preparation(h, feed);
    assert.equal(after.phase, 4, `the output pointer is durable: ${JSON.stringify(after)}`);
    const last = failed.row.recovery.last_action;
    assert.deepEqual([last?.name, last?.end_checkpoint?.phase, last?.end_checkpoint?.status], ['prepare', 4, 'unknown'], JSON.stringify(failed.row.recovery));
    assert.equal(failed.row.ops.readbacks, 0, 'no readback');
    await settleFires(ts, [fire]);
    report.push(`unknown-checkpoint: COMMIT unrelayed, the line reads phase-4 unknown, the durable pointer names phase ${after.phase}`);
  });
});

await test('idle-preparation (control): a non-poisoned failed preparation (failures 3 -> 4) then a delivery before its retry time: one idle prepare action, no phase work or checkpoint, the remaining wait yielded', async () => {
  let items = [];
  const h = await harness(() => new Response(rss(items)), fixture({ logs: true }));
  await within(h, async () => {
    const ts = h.storage.testStorage('polling-runtime');
    const feed = await changedFeed(h, 'idle-preparation', next => { items = next; });
    const wake = await until(h, ts, feed, staging(h, feed));
    await h.run("UPDATE n_observation SET processing_failures=3 WHERE feed_id=? AND state='staging' AND valid_eof=1", feed);
    await h.invoke('fault', 'before_put');
    const failed = await deliver(h, ts, wake);
    assert.equal(failed.status, 500, failed.text);
    const after = await preparation(h, feed), t = t0();
    assert.equal(after.processing_failures, 4);
    const idle = await deliver(h, ts, wake, { attempts: 2 });
    assert.deepEqual([idle.status, idle.outcome], [200, 'staged'], idle.text);
    assert.deepEqual(idle.row.action.map(a => [a.name, a.result, a.status]), [['prepare', 'idle', 'yielded']], JSON.stringify(idle.row.action));
    assert.equal(count(idle.ops, PREPARE_CHECKPOINT), 0, 'no checkpoint');
    assert.equal(count(idle.ops, CLAIM), 1, 'one action');
    const wait = idle.row.sent?.delay_s;
    assert.ok(wait >= 290 && wait <= after.processing_next_at - t, `the remaining wait ${wait}`);
    const unchanged = await preparation(h, feed);
    assert.deepEqual([unchanged.preparation_key, unchanged.processing_failures], [after.preparation_key, 4]);
    report.push(`idle-preparation: one idle prepare action, wait ${wait} s, no checkpoint`);
  });
});

await test('poisoned-preparation (control): processing_failures 9 and a phase failing before its checkpoint commit: the tenth failure, the poisoned preparation abandoned, the 500, the lease released, the baseline kept; the redelivery routes from the new claim', async () => {
  let items = [];
  const h = await harness(() => new Response(rss(items)), fixture({ logs: true }));
  await within(h, async () => {
    const ts = h.storage.testStorage('polling-runtime');
    const feed = await changedFeed(h, 'poisoned-preparation', next => { items = next; });
    const wake = await until(h, ts, feed, staging(h, feed));
    const baseline = (await h.first('SELECT snapshot_key FROM n_feed WHERE feed_id=?', feed)).snapshot_key;
    await h.run("UPDATE n_observation SET processing_failures=9 WHERE feed_id=? AND state='staging' AND valid_eof=1", feed);
    await h.invoke('fault', 'before_put');
    const failed = await deliver(h, ts, wake);
    assert.equal(failed.status, 500, failed.text);
    assert.equal((await h.first("SELECT COUNT(*) AS n FROM n_observation WHERE feed_id=? AND state='abandoned' AND processing_failures=10", feed)).n, 1);
    const fed = await h.first('SELECT lease_id,snapshot_key FROM n_feed WHERE feed_id=?', feed);
    assert.deepEqual([fed.lease_id, fed.snapshot_key], [null, baseline]);
    const again = await deliver(h, ts, wake, { attempts: 2 });
    assert.equal(again.status, 200, again.text);
    assert.equal(again.row.action[0]?.name, 'scan', JSON.stringify(again.row.action.map(a => a.name)));
    report.push(`poisoned-preparation: abandoned at 10 failures, lease released, baseline kept; the redelivery scanned (${again.outcome})`);
  });
});

await test('guard-crossing: an outbox action started at loop time 130 s with its first service body held 30 s completes at 160 s; the loop yields guard; the outbox\'s accepted rows and POSTs stand', async () => {
  let items = [];
  const h = await harness(() => new Response(rss(items)), fixture({ logs: true }));
  await within(h, async () => {
    const ts = h.storage.testStorage('polling-runtime');
    const feed = await changedFeed(h, 'guard-crossing', next => { items = next; }, { count: 30 });
    const wake = await until(h, ts, feed, publishedAt(h, feed, 0));
    await h.invoke('test/loop-clock', '0');
    const arm = ts({ op: 'arm', kind: 'statement', action: 'hold-request', match: CLAIM, skip: 1 });
    const from = h.logs.length, at = operations(ts).length, posted = h.events.length;
    const running = h.consume(wake); running.catch(() => {});
    const fire = await fired(ts, arm.arming);
    await h.invoke('test/loop-clock', '130000');
    await h.invoke('fault', 'hold_service_body:30000');
    ts({ op: 'release', fire: fire.id });
    const result = await running;
    await h.invoke('test/loop-clock', '0');
    const row = await line(h, 'consume', from), ops = operations(ts, at);
    assert.deepEqual([result.status, result.outcome], [200, 'guard'], result.text);
    assert.deepEqual(row.action.map(a => a.name), ['drain', 'outbox']);
    const held = (await h.invoke('metrics')).hooks.service.at(-1);
    assert.ok(held?.ms === 30000 && held.body - held.headers >= 30000, JSON.stringify(held));
    assert.equal(count(ops, CLAIM), 3, 'the third claim found the guard passed');
    assert.equal((await h.first("SELECT COUNT(*) AS n FROM n_outbox x JOIN n_observation o ON o.observation_id=x.observation_id WHERE o.feed_id=? AND x.state='accepted'", feed)).n, 10);
    assert.equal(h.events.length - posted, 10);
    assert.deepEqual([row.sent?.delay_s, row.sent?.result], [0, 'ok']);
    report.push(`guard-crossing: drain, then an outbox started at loop 130 s held ${held.body - held.headers} ms; guard; 10 accepted`);
  });
});

await test('drain-then-scan: drain then scan in one delivery when the scan is due after the drain', async () => {
  let items = [];
  const h = await harness(() => new Response(rss(items)), fixture({ logs: true }));
  await within(h, async () => {
    const ts = h.storage.testStorage('polling-runtime');
    const feed = await changedFeed(h, 'drain-scan', next => { items = next; }, { count: 30 });
    const wake = await until(h, ts, feed, publishedAt(h, feed, 0));
    await h.run('UPDATE n_feed SET due_at=0,retry_at=0 WHERE feed_id=?', feed);
    const d = await deliver(h, ts, wake);
    assert.deepEqual([d.status, d.outcome], [200, 'unchanged'], d.text);
    assert.deepEqual(d.row.action.map(a => a.name), ['drain', 'outbox', 'outbox', 'outbox', 'scan']);
    const names = d.ops.map(first);
    assert.ok(names.findIndex(x => x.startsWith(SCAN_FIRST)) > names.findLastIndex(x => x.startsWith(DRAIN_CHECKPOINT)), 'the scan after the drain');
  });
});

await test('scan-guard: the 65 s scan guard: past 65 s of loop time the outbox actions continue but the due scan yields guard; the next delivery scans', async () => {
  let items = [];
  const h = await harness(() => new Response(rss(items)), fixture({ logs: true }));
  await within(h, async () => {
    const ts = h.storage.testStorage('polling-runtime');
    const feed = await changedFeed(h, 'scan-guard', next => { items = next; }, { count: 30 });
    const wake = await until(h, ts, feed, publishedAt(h, feed, 0));
    await h.run('UPDATE n_feed SET due_at=0,retry_at=0 WHERE feed_id=?', feed);
    await h.invoke('test/loop-clock', '0');
    const arm = ts({ op: 'arm', kind: 'statement', action: 'hold-request', match: CLAIM, skip: 1 });
    const from = h.logs.length, at = operations(ts).length;
    const running = h.consume(wake); running.catch(() => {});
    const fire = await fired(ts, arm.arming);
    await h.invoke('test/loop-clock', '70000');
    ts({ op: 'release', fire: fire.id });
    const result = await running;
    await h.invoke('test/loop-clock', '0');
    const row = await line(h, 'consume', from);
    assert.deepEqual([result.status, result.outcome], [200, 'guard'], result.text);
    assert.deepEqual(row.action.map(a => a.name), ['drain', 'outbox', 'outbox', 'outbox']);
    assert.equal(count(operations(ts, at), SCAN_FIRST), 0, 'no scan started');
    const [next] = await wakeOf(h, feed);
    const scanned = await deliver(h, ts, next);
    assert.deepEqual([scanned.outcome, scanned.row.action[0]?.name], ['unchanged', 'scan']);
  });
});

await test('counter-reset: the action counter restarts on redelivery: an attempt failing at its eighth action, then its retry runs twelve', async () => {
  let items = [];
  const h = await harness(() => new Response(rss(items)), fixture({ logs: true }));
  await within(h, async () => {
    const ts = h.storage.testStorage('polling-runtime');
    const feed = await changedFeed(h, 'counter-reset', next => { items = next; }, { count: 700 });
    const wake = await until(h, ts, feed, staging(h, feed));
    const arm = ts({ op: 'arm', kind: 'statement', action: 'close-before', match: DRAIN_CHECKPOINT, skip: 2 });
    const failed = await deliver(h, ts, wake);
    assert.ok(ts({ op: 'witness' }).fires.some(f => f.arming === arm.arming));
    assert.equal(failed.status, 500, failed.text);
    assert.equal(count(failed.ops, CLAIM), 8, 'five phases, two drains, the failing third');
    const retry = await deliver(h, ts, wake, { attempts: 2 });
    assert.deepEqual([retry.status, retry.outcome], [200, 'action_bound'], retry.text);
    assert.equal(count(retry.ops, CLAIM), 12, 'the retry starts at k = 1');
    assert.equal(retry.row.recovery.first_action?.start_checkpoint?.candidate_cursor, 200);
  });
});

// The dispatcher's view of `feed` at durable time `now` (postgres/dispatch.rs):
// the global and per-origin live counts it is part of, and Repairs membership.
async function dispatcherView(h, feed, now) {
  const origin = "substring(canonical_url from '^[^:]+://[^/?]*')";
  const row = await h.first(`SELECT (SELECT COUNT(*) FROM n_feed WHERE dispatch_until>?) AS live,(SELECT COUNT(*) FROM n_feed g WHERE g.dispatch_until>? AND substring(g.canonical_url from '^[^:]+://[^/?]*')=(SELECT ${origin} FROM n_feed WHERE feed_id=?)) AS origin_live,(dispatch_until>?) AS mine,(dispatch_until>0 AND dispatch_until<=?) AS lapsed,dispatch_until,schedule_generation,handling_failures FROM n_feed WHERE feed_id=?`, now, now, feed, now, now, feed);
  return { live: Number(row.live), origin_live: Number(row.origin_live), mine: Boolean(row.mine), in_repairs: Boolean(row.lapsed), dispatch_until: Number(row.dispatch_until), generation: Number(row.schedule_generation), handling_failures: Number(row.handling_failures) };
}

await test('dead-letter-overlap (control): the dead-letter interaction: the original message exhausted while its repaired same-generation chain is active clears the shared reservation and steps handling_failures, the repaired chain\'s next claim is obsolete, its progress kept; with the repaired chain already settled, no step, no resurrection, the dispatcher\'s view unchanged', async () => {
  let items = [];
  const h = await harness(() => new Response(rss(items)), fixture({ logs: true }));
  await within(h, async () => {
    const ts = h.storage.testStorage('polling-runtime');
    // (1) active: the repaired chain held at its first completed boundary.
    const feed = await changedFeed(h, 'dead-letter-active', next => { items = next; }, { count: 150 });
    const original = await until(h, ts, feed, publishedAt(h, feed, 0));
    await h.invoke('clock', '301');
    await h.invoke('test/dispatch');
    const [repaired] = await wakeOf(h, feed);
    assert.deepEqual([repaired?.generation, repaired?.step], [original.generation, 0], 'repaired in the same generation at step 0');
    // The repaired chain after its first action (a drain), its reservation
    // live: on the loop held at the gate of its first completed boundary, on a
    // build without the loop between its delivery and the continuation it sent.
    await h.invoke('test/loop-clock', '0');
    await h.invoke('test/loop-gate', 'arm');
    const at = operations(ts).length;
    let ended = null;
    const running = h.consume(repaired).then(r => { ended = r; return r; }); running.catch(() => {});
    for (let quiet = 0, seen = -1; ended === null;) {
      const n = operations(ts, at).length;
      if (n > 0 && n === seen) { if ((quiet += 25) >= 500) break; } else quiet = 0;
      seen = n; await sleep(25);
    }
    const now = t0() + 301, before = await dispatcherView(h, feed, now);
    assert.deepEqual([before.mine, before.in_repairs], [true, false], JSON.stringify(before));
    await h.invoke('test/dead-letter', original);
    const after = await dispatcherView(h, feed, now);
    const from = h.logs.length;
    let result;
    if (ended === null) {
      assert.equal((await h.invoke('test/loop-gate', 'release')).released_waiter, true);
      result = await running;
    } else {
      await h.invoke('test/loop-gate', 'release');
      const [next] = await wakeOf(h, feed);
      assert.ok(next, 'the repaired chain\'s continuation');
      result = await h.consume(next);
    }
    assert.deepEqual([after.dispatch_until, after.generation, after.handling_failures], [0, before.generation, before.handling_failures + 1], JSON.stringify({ before, after }));
    assert.deepEqual([after.live, after.origin_live, after.mine, after.in_repairs], [before.live - 1, before.origin_live - 1, false, false], JSON.stringify({ before, after }));
    assert.deepEqual([result.status, result.outcome], [200, 'obsolete'], result.text);
    assert.equal((await line(h, 'consume', from)).sent, null);
    assert.equal((await h.first("SELECT candidate_cursor FROM n_observation WHERE feed_id=? AND state='published' AND candidate_count>0", feed)).candidate_cursor, 100, 'the repaired chain\'s first drain stands');
    // (2) settled: the repaired chain ran to its settlement first.
    const other = await changedFeed(h, 'dead-letter-settled', next => { items = next; }, { count: 30 });
    const late = await until(h, ts, other, publishedAt(h, other, 0));
    await h.invoke('clock', '602');
    await h.invoke('test/dispatch');
    const [again] = await wakeOf(h, other);
    assert.deepEqual([again?.generation, again?.step], [late.generation, 0]);
    // The repaired chain delivered to its settlement (one delivery on the loop).
    const settled = [await deliver(h, ts, again), ...await chain(h, ts, other)].at(-1);
    assert.equal(settled.status, 200, settled.text);
    const t = t0() + 602, quiet = await dispatcherView(h, other, t);
    assert.equal(quiet.dispatch_until, 0, `settled: ${settled.outcome}`);
    await h.invoke('test/dead-letter', late);
    const unchanged = await dispatcherView(h, other, t);
    await h.invoke('clock', '0');
    assert.deepEqual(unchanged, quiet, 'no handling_failures step, no reservation resurrection, the live counts and Repairs unchanged');
    report.push(`dead-letter-overlap: active -> reservation 0, handling_failures ${before.handling_failures} -> ${after.handling_failures}, live ${before.live} -> ${after.live}, repaired chain obsolete; settled -> view unchanged (${settled.outcome})`);
  });
});

await test('busy-after-actions: a 429 after earlier successful actions: the yield carries the busy delay and the earlier actions\' progress stands', async () => {
  let items = [];
  const t = t0();
  let hold;
  const h = await harness(request => {
    if (request.url.includes('busy-holder') && hold) return new Promise(resolve => { hold.push(resolve); setTimeout(() => resolve(new Response(rss([item('base', t - 86_400)]))), 30_000); });
    return new Response(rss(items));
  }, fixture({ logs: true }));
  await within(h, async () => {
    const ts = h.storage.testStorage('polling-runtime');
    const feed = await changedFeed(h, 'busy-after', next => { items = next; }, { count: 30 });
    const wake = await until(h, ts, feed, publishedAt(h, feed, 0));
    await h.run('UPDATE n_feed SET due_at=0,retry_at=0 WHERE feed_id=?', feed);
    // Another feed's scan holds this isolate's scan permit, its publisher slow.
    const holder = await h.add(cohort('https://loop.example.com/busy-holder'));
    await h.invoke('test/dispatch'); await h.drain();
    await h.run('UPDATE n_feed SET due_at=0,retry_at=0,dispatch_until=0 WHERE feed_id=?', holder);
    await h.invoke('test/dispatch');
    const [held] = await wakeOf(h, holder);
    hold = [];
    const fetched = h.fetches.length;
    const owner = h.consume(held); owner.catch(() => {});
    for (let i = 0; i < 400 && h.fetches.length === fetched; i++) await sleep(25);
    assert.ok(h.fetches.length > fetched, 'the holder\'s publisher request is in flight');
    const busyBefore = Number((await h.first('SELECT COALESCE(SUM(scan_busy),0) AS n FROM n_poll_stat')).n);
    const d = await deliver(h, ts, wake);
    for (const resolve of hold) resolve(new Response(rss([item('base', t - 86_400)])));
    await owner;
    assert.deepEqual([d.status, d.outcome], [200, 'scan_busy'], d.text);
    assert.deepEqual(d.row.action.map(a => [a.name, a.result]), [['drain', 'continued'], ['outbox', 'continued'], ['outbox', 'continued'], ['outbox', 'continued'], ['scan', 'scan_busy']]);
    assert.ok(d.row.sent?.delay_s >= 5 && d.row.sent.delay_s <= 15, JSON.stringify(d.row.sent));
    assert.equal(Number((await h.first('SELECT COALESCE(SUM(scan_busy),0) AS n FROM n_poll_stat')).n), busyBefore + 1);
    assert.equal((await h.first("SELECT COUNT(*) AS n FROM n_outbox x JOIN n_observation o ON o.observation_id=x.observation_id WHERE o.feed_id=? AND x.state='accepted'", feed)).n, 30, 'the earlier actions\' progress stands');
    report.push(`busy-after-actions: drain + 3 outbox then scan_busy, delay ${d.row.sent.delay_s} s, 30 accepted`);
  });
});

const PARSER = fileURLToPath(new URL('../storage_phases/', import.meta.url));
const digest = id => createHash('sha256').update(id).digest('hex').slice(0, 16);
// The real-Queue harness settles once no feed holds a reservation.
async function quiet(h, ms) {
  const end = Date.now() + ms;
  for (;;) { if (Number((await h.first('SELECT COUNT(*) AS n FROM n_feed WHERE dispatch_until>0')).n) === 0) return; if (Date.now() > end) throw Error('the real queue did not settle'); await sleep(250); }
}
async function waitFor(what, ms, probe) {
  const end = Date.now() + ms;
  for (;;) { const v = await probe(); if (v) return v; if (Date.now() > end) throw Error(`timed out: ${what}`); await sleep(250); }
}
const baselineItems = t => Array.from({ length: 5 }, (_, i) => item(`base${i}`, t - 86_400 - i));

await test('outer-cancellation (control, real time): the outer cancellation: an outbox\'s service body held past 200 s; the outer Delay cancels with no storage race in flight, the release bookkeeping records cancelled, the outbox state is unchanged, 503; the real Queue\'s 60 s retry resumes from the fresh claim', async () => {
  let items = [];
  const h = await harness(() => new Response(rss(items)), { logs: true, realQueues: true, retryDelay: 60 });
  await within(h, async () => {
    const t = t0();
    const feed = await h.add(cohort('https://loop.example.com/outer-cancellation'));
    items = baselineItems(t);
    await h.invoke('test/dispatch'); await quiet(h, 60_000);
    assert.deepEqual(await h.invoke('test/retry-delay', '60'), { retry_delay_s: 60 });
    items = [item('n1', t - 60), item('n2', t - 50), item('n3', t - 40), ...baselineItems(t)];
    await h.run('UPDATE n_feed SET due_at=0,retry_at=0,dispatch_until=0 WHERE feed_id=?', feed);
    await h.invoke('test/dispatch'); await quiet(h, 120_000);
    // The pre-seeded outbox: the publication's three rows due again, the scan
    // a day off, so the measured attempt's first action is the outbox on either tree.
    await h.run("UPDATE n_outbox SET state='pending',next_attempt_at=? WHERE observation_id IN (SELECT observation_id FROM n_observation WHERE feed_id=?)", t0(), feed);
    await h.run('UPDATE n_feed SET due_at=? WHERE feed_id=?', t0() + 86_400, feed);
    await h.invoke('fault', 'hold_service_body:215000');
    const from = h.logs.length, started = Date.now();
    await h.invoke('test/dispatch');
    const mine = () => lines(h, 'consume', from).filter(r => r.chain?.feed === feed);
    const cancelled = await waitFor('the cancelled attempt', 260_000, () => mine().find(r => r.outcome === 'cancelled'));
    const atCancel = await h.rows("SELECT x.state FROM n_outbox x JOIN n_observation o ON o.observation_id=x.observation_id WHERE o.feed_id=?", feed);
    const released = await h.first('SELECT last_poll_outcome FROM n_feed WHERE feed_id=?', feed);
    assert.deepEqual(atCancel.map(r => r.state), ['pending', 'pending', 'pending'], 'the outbox state unchanged by the cancelled attempt');
    assert.equal(released.last_poll_outcome, 'cancelled', 'ReleaseAttempt cancelled');
    assert.equal(cancelled.summary.races.dropped, 0, 'no storage race in flight at the cancellation');
    assert.deepEqual(cancelled.action.map(a => a.name), ['outbox'], 'the measured attempt is the outbox alone');
    await quiet(h, 200_000);
    const wall = Date.now() - started;
    const metrics = await h.invoke('metrics');
    const retry = metrics.hooks.retries.find(r => digest(r.id) === cancelled.chain.message_digest);
    assert.deepEqual([retry?.requested, retry?.forwarded], [60, 60], JSON.stringify(metrics.hooks.retries));
    const arrival = metrics.hooks.batches.find(b => b.at > retry.at && b.messages.some(m => m.id === retry.id && m.attempts === retry.attempts + 1));
    assert.ok(arrival && arrival.at - retry.at >= 60_000, `redelivered ${arrival && arrival.at - retry.at} ms after the retry`);
    const resumed = mine().find(r => r.chain.message_digest === cancelled.chain.message_digest && r.chain.attempts === cancelled.chain.attempts + 1);
    assert.equal(resumed?.recovery.first_action?.name, 'outbox', JSON.stringify(resumed?.recovery));
    assert.equal(Number((await h.first("SELECT COUNT(*) AS n FROM n_outbox x JOIN n_observation o ON o.observation_id=x.observation_id WHERE o.feed_id=? AND x.state='accepted'", feed)).n), 3);
    const program = 'import json,sys\nimport storage_phases_parse as p\nrows=[json.loads(l) for l in sys.stdin if l.strip()]\nprint(json.dumps(p.recovery(rows[0],rows[1])))';
    const reading = JSON.parse(execFileSync('python3', ['-B', '-c', program], { cwd: PARSER, input: [cancelled, resumed].map(r => JSON.stringify(r)).join('\n') }).toString());
    assert.ok(wall <= 300_000, `the fixture target: recovered in ${wall} ms`);
    report.push(`outer-cancellation: cancelled at ${cancelled.wall_ms} ms (last action outbox), retry requested/forwarded 60/60, redelivered ${arrival.at - retry.at} ms later, resumed at outbox; parser retry_wait ${JSON.stringify(reading.retry_wait)}; recovered in ${wall} ms`);
  });
});

await test('repair-overlap (control, real time): expiry during a retry: an attempt cancelled at the step deadline, durable time past its reservation, the minute dispatcher repairs it in the same generation at step 0; the repaired delivery held at its first action until the original message\'s retry has claimed too; both hold valid claims, the durable effects are once, the transport may repeat, the chains converge', async () => {
  let items = [];
  const h = await harness(() => new Response(rss(items)), fixture({ logs: true }));
  await within(h, async () => {
    const ts = h.storage.testStorage('polling-runtime');
    const feed = await changedFeed(h, 'repair-overlap', next => { items = next; }, { count: 30 });
    // To a due outbox: the delivery under test starts with the outbox action on either tree.
    const wake = await until(h, ts, feed, async () => Number((await h.first("SELECT COUNT(*) AS n FROM n_outbox x JOIN n_observation o ON o.observation_id=x.observation_id WHERE o.feed_id=? AND x.state='pending'", feed)).n) === 30);
    await h.invoke('fault', 'hold_service_body:215000');
    const cancelled = await deliver(h, ts, wake);
    assert.deepEqual([cancelled.status, cancelled.row.outcome], [503, 'cancelled'], cancelled.text);
    const reserved = await reservation(h, feed);
    await h.invoke('clock', '301');
    assert.ok(t0() + 301 > reserved, 'durable time past the reservation');
    await h.invoke('test/dispatch');
    const [repaired] = await wakeOf(h, feed);
    assert.deepEqual([repaired?.generation, repaired?.step], [wake.generation, 0], 'the same generation at step 0');
    const posted = h.events.length;
    const barrier = ts({ op: 'arm', kind: 'statement', action: 'hold-request', match: 'SELECT r.* FROM n_episode_release r' });
    const at = operations(ts).length, from = h.logs.length;
    const two = h.consume(repaired); two.catch(() => {});
    const fire = await fired(ts, barrier.arming);
    const retry = h.consume(wake, { attempts: 2 }); retry.catch(() => {});
    await waitFor('the retry\'s claim', 3000, () => operations(ts, at).some(o => o.id !== fire.op && first(o).startsWith(CLAIM) && o.started > fire.at));
    ts({ op: 'release', fire: fire.id });
    const [a, b] = await Promise.all([two, retry]);
    await h.drain();
    await h.invoke('clock', '0');
    const rows = lines(h, 'consume', from).filter(r => r.chain?.feed === feed);
    assert.deepEqual([a.status, b.status], [200, 200], `${a.text} ${b.text}`);
    assert.ok(rows.filter(r => r.action.length > 0).length >= 2, 'both deliveries held valid claims and ran actions');
    const events = await h.rows("SELECT event_id FROM n_outbox x JOIN n_observation o ON o.observation_id=x.observation_id WHERE o.feed_id=? AND x.state='accepted'", feed);
    assert.equal(events.length, 30, 'every outbox row accepted once');
    const delivered = Number((await h.first(`SELECT COUNT(*) AS n FROM n_event WHERE event_id IN (${events.map(() => '?').join(',')})`, ...events.map(e => e.event_id))).n);
    assert.equal(delivered, 30, 'one FeedEvents event each');
    assert.equal(await reservation(h, feed), 0, 'the chains converged at a settlement');
    report.push(`repair-overlap: repaired at step 0 in generation ${repaired.generation}; outcomes ${a.outcome} / ${b.outcome}; POSTs after the repair ${h.events.length - posted} for 30 rows (the transport repeat); 30 accepted, 30 events`);
  });
});

// The real-Queue harness has one consumer slot (Miniflare's broker dispatches
// one batch at a time and ignores maxConcurrency), so the test is the
// two-slot consumer: two replicas (two isolates, as production's two
// concurrent invocations) take the deliveries it hands them.
await test('two-slot-fairness (measurement, declared target): the test as the two-slot consumer on two replicas: A and B each hold a slot on a 90 s service body, armed in turn; C, a due scan sent while both bodies are unreleased and delivered the moment a slot frees, starts its first action within 200 s of its send', async () => {
  const items = {};
  const h = await harness(request => new Response(rss(items[request.url] ?? [])), { logs: true, replicas: 2 });
  await within(h, async () => {
    const t = t0();
    const feeds = {};
    for (const name of ['a', 'b', 'c']) {
      const url = cohort(`https://fair-${name}.example.com/feed`);
      items[url] = baselineItems(t);
      feeds[name] = await h.add(url);
      feeds[`${name}_url`] = url;
    }
    await h.invoke('test/dispatch'); await h.drain();
    // A and B publish three new episodes each, their whole chains delivered;
    // their outbox rows are then made pending again, A due and B not yet.
    for (const name of ['a', 'b']) items[feeds[`${name}_url`]] = [item(`${name}1`, t - 60), item(`${name}2`, t - 50), item(`${name}3`, t - 40), ...baselineItems(t)];
    await h.run('UPDATE n_feed SET due_at=0,retry_at=0,dispatch_until=0 WHERE feed_id IN (?,?)', feeds.a, feeds.b);
    await h.invoke('test/dispatch'); await h.drain();
    const reseed = (feed, at) => h.run("UPDATE n_outbox SET state='pending',next_attempt_at=? WHERE observation_id IN (SELECT observation_id FROM n_observation WHERE feed_id=?)", at, feed);
    await h.run('UPDATE n_feed SET due_at=? WHERE feed_id IN (?,?,?)', t + 86_400, feeds.a, feeds.b, feeds.c);
    await reseed(feeds.a, t); await reseed(feeds.b, t + 86_400);
    const service = async replica => (await h.invoke('metrics', undefined, undefined, replica)).hooks.service;
    const record = {}, from = h.logs.length;
    const send = async name => { const sent = Date.now(); await h.invoke('test/dispatch'); const [wake] = (await h.polls()).filter(w => w.feed_id === feeds[name]); assert.ok(wake, `${name} dispatched`); record[name] = { send: sent, wake }; return wake; };
    const start = (name, replica) => { record[name].replica = replica; record[name].start = Date.now(); const running = h.consume(record[name].wake, { replica }).then(r => { record[name].end = Date.now(); return { name, replica, r }; }); running.catch(() => {}); return running; };
    // A on slot 0: its hold armed at its dispatch, observed consumed (request sent, body held).
    await h.invoke('fault', 'hold_service_body:90000', undefined, 0);
    await send('a'); const a = start('a', 0);
    await waitFor('A\'s hold consumed', 30_000, async () => { const s = await service(0); return s.length === 1 && s[0].headers && s[0].body === null; });
    // B on slot 1, five seconds after A, its hold armed only now.
    await sleep(Math.max(0, record.a.send + 5000 - Date.now()));
    await h.invoke('fault', 'hold_service_body:90000', undefined, 1); await reseed(feeds.b, t0());
    await send('b'); const b = start('b', 1);
    await waitFor('B\'s hold consumed', 30_000, async () => { const s = await service(1); return s.length === 1 && s[0].headers && s[0].body === null && (await service(0))[0].body === null; });
    // C: due now, sent while both bodies are unreleased; the first slot to free takes it.
    await h.run('UPDATE n_feed SET due_at=? WHERE feed_id=?', t0() - 1, feeds.c);
    await send('c');
    const freed = await Promise.race([a, b]);
    const c = await start('c', freed.replica);
    const done = await Promise.all([a, b]);
    for (const { r } of [...done, c]) assert.equal(r.status, 200, r.text);
    await h.drain();
    const rows = lines(h, 'consume', from);
    for (const name of ['a', 'b', 'c']) {
      const mine = rows.filter(r => r.chain?.feed === feeds[name]), first = mine[0];
      Object.assign(record[name], { admission_ms: first?.recovery.admission_ms ?? null, chain: mine.length, outcomes: mine.map(r => r.outcome) });
      record[name].first_action_ms = record[name].admission_ms === null ? null : record[name].start + record[name].admission_ms - record[name].send;
      record[name].occupancy_ms = record[name].end - record[name].start;
    }
    const held = [(await service(0))[0], (await service(1))[0]].map(s => s.body - s.headers);
    assert.ok(held.every(ms => ms >= 90_000), `both slots held: ${held}`);
    assert.ok(record.c.first_action_ms !== null && record.c.first_action_ms <= 200_000, `C's first action ${record.c.first_action_ms} ms after its send`);
    report.push(`two-slot-fairness: holds ${held} ms; ${['a', 'b', 'c'].map(n => `${n} (slot ${record[n].replica}): start ${record[n].start - record[n].send} ms after send, first action ${record[n].first_action_ms} ms, occupancy ${record[n].occupancy_ms} ms, ${record[n].chain} deliveries ${record[n].outcomes}`).join('; ')}; C took slot ${freed.replica}, freed by ${freed.name}`);
  });
});

// Each storage_phases line after `from` with the fixture build's cost line logged just before it.
const costed = (h, from) => h.logs.slice(from).flatMap((e, i, all) => e.event === 'storage_phases' && all[i - 1]?.event === 'storage_phases_cost' ? [{ row: e, cost: all[i - 1] }] : []);
await test('loop-maxima: the loop\'s runtime maxima: a twelve-action delivery\'s line within 8,192 bytes on the fixture cost line, no overflow, the compact model at 6,349; sampled active CPU of complete twelve-action (action-bound) and four-action (one-delivery-tail) deliveries against the 100,000 ms policy', async () => {
  const width = Number(execFileSync('python3', ['-B', 'compact_width.py'], { cwd: PARSER }).toString().trim());
  assert.equal(width, 6349);
  const samples = [];
  for (let run = 0; run < 3; run++) {
    for (const shape of ['bound', 'tail']) {
      let items = [];
      const h = await harness(() => new Response(rss(items)), fixture({ logs: true }));
      await within(h, async () => {
        const ts = h.storage.testStorage('polling-runtime');
        const feed = await changedFeed(h, `maxima-${shape}-${run}`, next => { items = next; }, { count: shape === 'bound' ? 700 : 101 });
        const wake = shape === 'bound' ? await until(h, ts, feed, staging(h, feed)) : await until(h, ts, feed, publishedAt(h, feed, 100));
        if (shape === 'tail') {
          const t = t0();
          await h.run("UPDATE n_episode_release SET expires_at=? WHERE event_id IN (SELECT event_id FROM n_episode_release WHERE feed_id=? AND state='ready' ORDER BY eligible_at,episode_id LIMIT 95)", t - 1, feed);
          await h.run('UPDATE n_feed SET due_at=? WHERE feed_id=?', t + 86_400, feed);
        }
        const from = h.logs.length;
        const stop = await profileCPU(await h.instance.getInspectorURL(), 'polling-runtime');
        const d = await deliver(h, ts, wake);
        const cpu = await stop();
        // A sample counts only for the workload it names: twelve actions ending
        // action_bound, or the four-action tail ending settled with its six POSTs.
        if (shape === 'bound') {
          assert.deepEqual([d.status, d.outcome, count(d.ops, CLAIM)], [200, 'action_bound', 12], d.text);
        } else {
          assert.deepEqual([d.status, d.outcome, d.row.action.map(a => a.name)], [200, 'settled', ['drain', 'drain', 'outbox', 'settle']], d.text);
          assert.equal((await h.first("SELECT COUNT(*) AS n FROM n_outbox x JOIN n_observation o ON o.observation_id=x.observation_id WHERE o.feed_id=? AND x.state='accepted'", feed)).n, 6);
        }
        const [cost] = costed(h, from).filter(x => x.row.chain?.feed === feed);
        assert.ok(cost, 'the delivery\'s cost line');
        assert.equal(h.logs.slice(from).filter(e => e.event === 'storage_phases_overflow').length, 0, 'no overflow');
        assert.ok(cost.cost.bytes <= 8192, `${cost.cost.bytes} bytes`);
        samples.push({ shape, actions: count(d.ops, CLAIM), outcome: d.outcome, bytes: cost.cost.bytes, bytes_policy: cost.row.bytes_policy, build_us: cost.cost.build_us, sampled_active_ms: Math.round(cpu.sampled_active_ms), profile_ms: Math.round(cpu.profile_duration_ms), wall_ms: d.row.wall_ms });
      });
    }
  }
  const worst = Math.max(...samples.map(s => s.sampled_active_ms));
  assert.ok(worst <= 100_000, `the CPU policy: ${worst} ms`);
  report.push(`loop-maxima: compact model ${width}; ${samples.map(s => `${s.shape} ${s.actions} actions ${s.outcome}: ${s.bytes} B (${s.bytes_policy}), active ${s.sampled_active_ms} ms of ${s.profile_ms} ms, wall ${s.wall_ms}`).join('; ')}; worst active ${worst} ms against 100,000`);
});

process.on('exit', () => { for (const line of report) console.log(`REPORT ${line}`); console.log(`${passed} passed, ${failed} failed`); });
if (failed) process.exitCode = 1;
