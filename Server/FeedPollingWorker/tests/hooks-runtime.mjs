// The FeedPolling test entry's fixture hooks (entry.mjs's `fixtureHooks`, and
// its R2 hooks `r2Hooks` with the in-flight counter and the x-test-r2-gate),
// each qualified on the packaged Worker against the local topology: armed,
// it acts exactly as described there and leaves its witness; unarmed, the
// entry behaves as before.
import assert from 'node:assert/strict';
import { existsSync } from 'node:fs';
import { setTimeout as sleep } from 'node:timers/promises';
import { ALERT_WEBHOOK_URL, harness, item, rss } from './harness.mjs';
import { webhookStub } from './webhook-stub.mjs';

const report = [];
let failed = 0, passed = 0;
async function test(name, fn) {
  try { await fn(); passed++; console.log('PASS', name); }
  catch (error) { failed++; console.log('FAIL', name); console.log(error); }
}

// ---- /test/retry-delay, on the real Queue path with the shipped consumer
// adapter. A delivery fails once (the settle transaction closed before it is
// forwarded); the adapter asks for retry({ delaySeconds: 60 }).
await test('retry-delay: the adapter\'s retry(60) is witnessed; the wrapper forwards 1 s, then 60 s with the consumer default 60', async () => {
  const h = await harness(() => new Response(rss([item('base', Math.floor(Date.now() / 1000) - 100)]), { headers: { etag: '"v1"' } }), { realQueues: true, retryDelay: 60 });
  try {
    const feed = await h.add('https://hooks.example.com/retry');
    const settle = async ms => { const end = Date.now() + ms; for (;;) { if ((await h.first('SELECT COUNT(*) AS n FROM n_feed WHERE dispatch_until>0')).n === 0) return; if (Date.now() > end) throw Error('the real queue did not finish'); await sleep(100); } };
    const cycle = async () => { await h.run('UPDATE n_feed SET due_at=? WHERE feed_id=?', h.now, feed); await h.invoke('fault', 'before_settle'); await h.invoke('test/dispatch'); };
    const redelivery = ({ hooks }, retry) => hooks.batches.find(b => b.at > retry.at && b.messages.some(m => m.id === retry.id && m.attempts === retry.attempts + 1));
    await h.invoke('test/dispatch'); await settle(30000);
    await cycle(); await settle(30000);
    let metrics = await h.invoke('metrics');
    const first = metrics.hooks.retries.at(-1), again = redelivery(metrics, first);
    assert.deepEqual([first.requested, first.forwarded, first.attempts], [60, 1, 1]);
    assert.ok(again && again.at - first.at >= 1000, `redelivered ${again && again.at - first.at} ms after the retry`);
    assert.deepEqual(await h.invoke('test/retry-delay', '60'), { retry_delay_s: 60 });
    await cycle();
    const retry = await (async () => { for (let i = 0; i < 300; i++) { const r = (await h.invoke('metrics')).hooks.retries; if (r.length > metrics.hooks.retries.length) return r.at(-1); await sleep(100); } throw Error('no retry'); })();
    assert.deepEqual([retry.requested, retry.forwarded], [60, 60]);
    await sleep(5000); assert.equal(redelivery(await h.invoke('metrics'), retry), undefined, 'nothing redelivered within 5 s of a 60 s retry');
    await settle(90000);
    metrics = await h.invoke('metrics');
    const late = redelivery(metrics, retry);
    assert.ok(late && late.at - retry.at >= 60000, `redelivered ${late && late.at - retry.at} ms after the 60 s retry`);
    assert.deepEqual(await h.invoke('test/retry-delay', ''), { retry_delay_s: 1 });
    for (const bad of ['-1', '1.5', 'x', '43201']) { const r = await (await h.instance.dispatchFetch('https://polling.invalid/test/retry-delay', { method: 'POST', body: bad })).text(); assert.match(r, /whole seconds/); }
    report.push(`retry-delay: forwarded 1 s -> redelivered after ${(again.at - first.at)} ms; forwarded 60 s -> redelivered after ${(late.at - retry.at)} ms (the adapter asked 60 both times)`);
  } finally { await h.close(); }
});

// ---- The polling loop's clock and gate, in a storage-fixture build of the
// polling Worker (worker-build --release --out-dir <dir> --features
// storage-fixture in Server/FeedPollingWorker; OPENCAST_POLLING_FIXTURE_BUILD,
// default /tmp/opencast-polling-fixture-build). /test/loop-probe stands
// where the loop's guard stands: it awaits the gate, then reads the clocks.
const POLLING_FIXTURE = process.env.OPENCAST_POLLING_FIXTURE_BUILD ?? '/tmp/opencast-polling-fixture-build';
const feedBody = () => new Response(rss([item('base', Math.floor(Date.now() / 1000) - 100)]), { headers: { etag: '"loop"' } });
await test('loop-clock: the offset moves only the loop clock; Date, performance.now() and a poll\'s own timings are untouched', async () => {
  if (!existsSync(`${POLLING_FIXTURE}/index_bg.wasm`)) throw Error(`missing the polling fixture build ${POLLING_FIXTURE}`);
  const h = await harness(feedBody, { pollingBuild: POLLING_FIXTURE });
  try {
    const probe = () => h.invoke('test/loop-probe', '');
    const before = await probe(), nodeBefore = Date.now();
    // The probe reads the loop clock between two performance.now() samples;
    // the clock can tick between any two reads, so with the offset taken off
    // the loop clock lies within that bracket, exactly: rounding x + offset is
    // monotonic in x. A bracket narrower than 130000 tells the two offsets apart.
    const bracketed = (p, offset) => p.monotonic_after_ms - p.monotonic_before_ms < 130000 && p.monotonic_before_ms + offset <= p.loop_now_ms && p.loop_now_ms <= p.monotonic_after_ms + offset;
    assert.deepEqual([before.waited, before.loop_offset_ms], [false, 0]); assert.ok(bracketed(before, 0) && !bracketed(before, 130000), JSON.stringify(before));
    assert.deepEqual(await h.invoke('test/loop-clock', '130000'), { loop_offset_ms: 130000 });
    const after = await probe(), nodeAfter = Date.now();
    assert.equal(after.loop_offset_ms, 130000); assert.ok(bracketed(after, 130000) && !bracketed(after, 0), JSON.stringify(after));
    const moved = after.monotonic_after_ms - before.monotonic_after_ms, dated = after.date_ms - before.date_ms;
    assert.ok(moved >= 0 && moved <= nodeAfter - nodeBefore + 50, `performance.now() moved ${moved} ms in ${nodeAfter - nodeBefore} ms`);
    assert.ok(dated >= 0 && dated <= nodeAfter - nodeBefore + 50 && Math.abs(after.date_ms - nodeAfter) < 1000, `Date moved ${dated} ms`);
    // A poll under the offset: its delivery timings stay in real time.
    await h.add('https://hooks.example.com/loop-clock'); await h.invoke('test/dispatch'); await h.drain();
    const delivery = (await h.invoke('metrics')).deliveries.at(-1);
    assert.ok(delivery && delivery.wall_ms < 30000 && (delivery.storage_ms ?? 0) < 30000, JSON.stringify(delivery));
    for (const bad of ['-1', 'x', 'Infinity']) assert.equal((await h.instance.dispatchFetch('https://polling.invalid/test/loop-clock', { method: 'POST', body: bad })).status, 400);
    // Many probes at each offset, so that some read the loop clock across a tick.
    const sweep = async offset => { let ticked = 0; for (let k = 0; k < 200; k++) { const p = await probe(); assert.ok(bracketed(p, offset), JSON.stringify(p)); if (p.monotonic_after_ms > p.monotonic_before_ms) ticked++; } return ticked; };
    const ticked = await sweep(130000);
    assert.deepEqual(await h.invoke('test/loop-clock', '0'), { loop_offset_ms: 0 });
    const tickedZero = await sweep(0);
    report.push(`loop-clock: loop_now within its performance.now() bracket at offset 0 and 130000, not at the other; 200 more probes at each, ${ticked} and ${tickedZero} across a tick; performance.now() moved ${moved.toFixed(1)} ms and Date ${dated} ms over ${nodeAfter - nodeBefore} ms; a poll under the offset ran ${delivery.wall_ms} ms`);
  } finally { await h.close(); }
});
await test('loop-gate: armed, the next caller waits at its boundary until released; one-shot; the shipped build has neither route', async () => {
  const h = await harness(feedBody, { pollingBuild: POLLING_FIXTURE });
  try {
    assert.deepEqual(await h.invoke('test/loop-gate', 'arm'), { gate: 'armed' });
    let resolved = null; const waiting = h.invoke('test/loop-probe', '').then(v => { resolved = Date.now(); return v; });
    await sleep(300); assert.equal(resolved, null, 'the caller waits at the armed gate');
    const released = Date.now();
    assert.deepEqual(await h.invoke('test/loop-gate', 'release'), { gate: 'open', released_waiter: true });
    const out = await waiting;
    assert.equal(out.waited, true); assert.ok(resolved >= released && resolved - released < 1000, `resumed ${resolved - released} ms after the release`);
    assert.equal((await h.invoke('test/loop-probe', '')).waited, false, 'one-shot: the next boundary passes');
    assert.deepEqual(await h.invoke('test/loop-gate', 'release'), { gate: 'open', released_waiter: false });
    assert.equal((await h.instance.dispatchFetch('https://polling.invalid/test/loop-gate', { method: 'POST', body: 'shut' })).status, 400);
    assert.deepEqual(await h.invoke('test/close-delay', '0'), { close_delay_ms: 0 });
    report.push(`loop-gate: the armed gate held its caller 300+ ms and resumed it ${resolved - released} ms after the release`);
  } finally { await h.close(); }
  const shipped = await harness(feedBody);
  try {
    for (const path of ['test/loop-clock', 'test/loop-gate', 'test/loop-probe', 'test/close-delay']) {
      const r = await shipped.instance.dispatchFetch(`https://polling.invalid/${path}`, { method: 'POST', body: '0' });
      assert.equal(r.status, 404, `${path} on the shipped build: ${r.status}`); await r.text();
    }
  } finally { await shipped.close(); }
});

// ---- The key-scoped R2 hooks, on a changed scan's read of the previous
// snapshot's manifest (n_feed.snapshot_key, the key it names).
await test('slow_get:<ms>:<prefix> and hang_get:<prefix>: only a get of a matching key is delayed or has its body held; a non-matching prefix stays armed', async () => {
  let version = 1;
  const items = () => Array.from({ length: version }, (_, k) => item(`e${k}`, Math.floor(Date.now() / 1000) - 1000 + k));
  const h = await harness(() => new Response(rss(items()), { headers: { etag: `"r2-${version}"` } }));
  try {
    const feed = await h.add('https://hooks.example.com/r2');
    const poll = async () => { await h.run('UPDATE n_feed SET due_at=? WHERE feed_id=?', Math.floor(Date.now() / 1000) - 1, feed); await h.invoke('test/dispatch'); await h.drain(); };
    const snapshot = async () => (await h.first('SELECT snapshot_key FROM n_feed WHERE feed_id=?', feed)).snapshot_key;
    const r2 = async () => (await h.invoke('metrics')).hooks.r2;
    await poll(); const first = await snapshot(); assert.ok(first, 'the baseline published a snapshot');
    version = 2; await h.invoke('fault', `slow_get:1500:${first}`);
    const began = Date.now(); await poll(); const wall = Date.now() - began;
    let records = await r2();
    assert.equal(records.length, 1, JSON.stringify(records));
    const slow = records[0];
    assert.deepEqual([slow.hook, slow.key, slow.ms], ['slow_get', first, 1500]);
    assert.ok(slow.end - slow.start >= 1500 && wall >= 1500, `delayed ${slow.end - slow.start} ms, poll ${wall} ms`);
    assert.equal(await h.invoke('fault-state'), '', 'one-shot');
    const second = await snapshot(); assert.notEqual(second, first);
    version = 3; await h.invoke('fault', 'slow_get:1500:no-such-prefix/');
    await poll(); assert.equal((await r2()).length, 1, 'no get matched'); assert.equal(await h.invoke('fault-state'), 'slow_get:1500:no-such-prefix/');
    await h.invoke('fault', 'none');
    const third = await snapshot();
    version = 4; await h.invoke('fault', `hang_get:${third}`);
    let done = false; const pending = poll().then(() => { done = true; });
    const held = await (async () => { for (let i = 0; i < 400; i++) { const r = (await r2()).find(x => x.hook === 'hang_get'); if (r) return r; await sleep(25); } throw Error('the hang_get never fired'); })();
    assert.equal(held.key, third); assert.equal(await h.invoke('fault-state'), 'hang_get_active');
    await sleep(300); assert.equal(done, false, 'the body read waits');
    await h.invoke('release-hang'); await pending;
    records = await r2(); const after = records.find(x => x.hook === 'hang_get');
    assert.ok(after.released - after.held >= 300, `held ${after.released - after.held} ms`);
    assert.notEqual(await snapshot(), third, 'the held scan then published');
    report.push(`R2 hooks: slow_get delayed the manifest get ${slow.end - slow.start} ms (poll ${wall} ms); a non-matching prefix fired nothing; hang_get held the body ${after.released - after.held} ms until release-hang`);
  } finally { await h.close(); }
});

// ---- hold_service_body: the outbox step's FeedEvents POST, its reply's
// status at once and its body later; the step waits for the body.
await test('hold_service_body:<ms>: the FeedEvents reply\'s body arrives <ms> after its headers; the outbox step waits for it, then delivers', async () => {
  let version = 1;
  const items = () => Array.from({ length: version }, (_, k) => item(`s${k}`, Math.floor(Date.now() / 1000) - 50 + k));
  const h = await harness(() => new Response(rss(items()), { headers: { etag: `"svc-${version}"` } }));
  try {
    const feed = await h.add('https://hooks.example.com/service');
    await h.invoke('test/dispatch'); await h.drain();
    version = 2; await h.run('UPDATE n_feed SET due_at=? WHERE feed_id=?', Math.floor(Date.now() / 1000) - 1, feed);
    const events = h.events.length;
    await h.invoke('fault', 'hold_service_body:1500');
    await h.invoke('test/dispatch'); await h.drain();
    const [record] = (await h.invoke('metrics')).hooks.service;
    assert.ok(record && record.body - record.headers >= 1500 && record.headers - record.sent < 1500, JSON.stringify(record));
    assert.equal(h.events.length, events + 1, 'one new event POSTed');
    assert.equal(await h.invoke('fault-state'), '', 'one-shot');
    const accepted = await h.first("SELECT COUNT(*) AS n FROM n_outbox WHERE state='accepted'");
    assert.ok(accepted.n >= 1, 'the outbox row was accepted after the held body');
    report.push(`hold_service_body: headers ${(record.headers - record.sent)} ms after the POST, body ${(record.body - record.headers)} ms after the headers`);
  } finally { await h.close(); }
});

// ---- The alert-webhook stub: its ledger, and a body delayed past the
// Worker's 10 s alert send timer, which covers the send (status and
// headers), not the body.
await test('webhook stub: a repeated idempotency-key is answered 409 idempotency_conflict; a body delayed past the 10 s send timer still delivers', async () => {
  const stub = webhookStub({ bodyDelayMs: 300 });
  const post = key => stub.handle(new Request(ALERT_WEBHOOK_URL, { method: 'POST', headers: { 'idempotency-key': key, 'content-type': 'application/json' }, body: JSON.stringify({ recipient: 'r', draft: {} }) }));
  const read = async response => ({ status: response.status, delay: response.headers.get('x-test-body-delay-ms'), body: await response.json() });
  const first = await read(await post('k1')), replay = await read(await post('k1')), other = await read(await post('k2'));
  assert.deepEqual([first.status, first.body, first.delay, replay.status, replay.body, other.status], [200, { aggregate_status: 'accepted' }, '300', 409, { error: { code: 'idempotency_conflict' } }, 200]);
  assert.deepEqual(stub.ledger.map(e => [e.key, e.replay, e.status]), [['k1', false, 200], ['k1', true, 409], ['k2', false, 200]]);
  assert.equal(await stub.handle(new Request('https://elsewhere.example.com/')), null);
  const credential = 'alert_credential_fixture', recipient = 'alert_recipient_fixture';
  const live = webhookStub({ bodyDelayMs: 11000 });
  const h = await harness(async request => (await live.handle(request)) ?? new Response(rss([]), { headers: { 'content-type': 'application/rss+xml' } }),
    { environment: 'production', alertSecrets: { ALERT_WEBHOOK_URL, ALERT_CREDENTIAL: credential, ALERT_RECIPIENT: recipient } });
  try {
    const began = Date.now(), rollup = await h.invoke('test/dispatch'), wall = Date.now() - began;
    assert.equal(rollup.alerting, true);
    const metrics = await h.invoke('metrics'), [entry] = live.ledger, [line] = metrics.alert_deliveries, [held] = metrics.hooks.outbound;
    assert.ok(entry?.key && held?.url === ALERT_WEBHOOK_URL && held.body - held.headers >= 11000, JSON.stringify({ entry, held }));
    assert.deepEqual([line.kind, line.status, line.delivered], ['armed', 200, true], JSON.stringify(line));
    assert.ok(wall >= 11000, `the tick waited ${wall} ms for the body`);
    report.push(`webhook stub: replay answered 409 idempotency_conflict; the armed alert's body ${(held.body - held.headers).toFixed(0)} ms after its headers in the isolate (past the 10 s send timer), delivered, tick ${wall} ms`);
  } finally { await h.close(); }
});

// ---- stall: a ReadClaim held forever on the wire (its 4 s statement cap
// expires in the Worker), and a 2 s synchronous stall of the Worker's isolate
// starting 3 s after the hold's fire: the expiry, due inside the stall, runs
// only once the stall ends. A held claim with no stall is the control.
await test('stall:3000:2000 after a held read\'s fire: the 4 s cap expires only when the stall ends; the stamps are measured on both clocks', async () => {
  const h = await harness(() => new Response(rss([item('st', Math.floor(Date.now() / 1000) - 100)]), { headers: { etag: '"stall"' } }));
  try {
    const ts = h.storage.testStorage('polling-runtime'), alias = h.storage.alias('polling-runtime');
    const claimed = async stall => {
      const feed = await h.add(`https://hooks.example.com/stall-${stall ? 'on' : 'off'}`);
      await h.invoke('test/dispatch'); const [wake] = (await h.polls()).filter(w => w.feed_id === feed);
      const arm = ts({ op: 'arm', kind: 'statement', action: 'hold-forever', match: 'SELECT f.origin_key' });
      const s = stall && h.storage.proxy.controls.stall(alias, { after: arm.arming, start_ms: 3000, ms: 2000, run: async ms => h.invoke('test/stall', String(ms)) });
      const result = await h.consume(wake);
      const w = await (async () => { for (let i = 0; i < 200; i++) { const v = ts({ op: 'witness' }), f = v.fires.find(x => x.arming === arm.arming), o = f && v.operations.find(y => y.id === f.op); if (o?.close) return { v, f, o }; await sleep(25); } throw Error('no close'); })();
      ts({ op: 'expect', fire: w.f.id, outcome: 'discarded' });
      const g = s && w.v.fires.find(x => x.arming === s.arming);
      return { status: result.status, text: result.text, f: w.f, o: w.o, g };
    };
    const off = await claimed(false), on = await claimed(true);
    assert.equal(off.status, 500); assert.equal(on.status, 500);
    const offSpan = off.o.close - off.o.Z_relay, onSpan = on.o.close - on.o.Z_relay, g = on.g.stall;
    assert.ok(offSpan >= 4000 && offSpan <= 4500 + 250, `no stall: close - Z_relay ${offSpan}`);
    assert.ok(g.start - on.f.at >= 3000 && g.start - on.f.at < 3000 + 250, `the stall began ${g.start - on.f.at} ms after the fire`);
    assert.ok(g.end - g.start >= 2000 && g.worker.elapsed >= 2000, `stalled ${g.end - g.start} ms, the isolate measured ${g.worker.elapsed}`);
    // The cap was due before the stall ended; it ran after it.
    assert.ok(on.o.Z_relay + 4000 < g.end && on.o.close >= g.end - 50, `expiry due ${on.o.Z_relay + 4000 - g.start} ms into the stall, close ${on.o.close - g.end} ms after its end`);
    report.push(`stall: control close - Z_relay ${offSpan.toFixed(1)} ms; stalled ${(g.end - g.start).toFixed(1)} ms from ${(g.start - on.f.at).toFixed(1)} ms after the fire, close - Z_relay ${onSpan.toFixed(1)} ms (${(onSpan - offSpan).toFixed(1)} ms later), close ${(on.o.close - g.end).toFixed(1)} ms after the stall`);
  } finally { await h.close(); }
});

// ---- The R2 hooks of the concurrent page uploads (entry.mjs's `r2Hooks`, armed
// by /test/r2-hooks), the per-invocation in-flight counter and the gate
// (x-test-r2-gate), on /test/r2-probe: bucket calls made through an
// invocation's instrumented bucket exactly as the Worker's own calls are.
async function r2Harness() {
  const h = await harness(() => new Response('unused', { status: 404 }));
  const bucket = await h.instance.getR2Bucket('FEED_SNAPSHOTS', 'polling-runtime');
  // Its rejection is handled here and still reaches whoever awaits it.
  const probe = (body, headers = {}) => {
    const p = (async () => {
      const r = await h.instance.dispatchFetch('https://polling.invalid/test/r2-probe', { method: 'POST', body: JSON.stringify(body), headers });
      const text = await r.text();
      try { return { status: r.status, ...JSON.parse(text) }; } catch { throw Error(`r2-probe ${r.status}: ${text}`); }
    })();
    p.catch(() => {});
    return p;
  };
  const gated = key => ({ 'x-test-execution': key, 'x-test-r2-gate': '1' });
  const arm = body => h.invoke('test/r2-hooks', body), state = () => h.invoke('test/r2-state'), hooks = async () => (await h.invoke('metrics')).r2hooks;
  const exists = async key => !!(await bucket.head(key));
  const until = async (what, check) => { for (let i = 0; i < 500; i++) { const v = await check(); if (v) return v; await sleep(20); } throw Error(`never: ${what}`); };
  // A probe still running after ms, or its reply.
  const pending = (p, ms = 300) => Promise.race([p.then(r => ({ settled: r })), sleep(ms).then(() => ({ settled: null }))]);
  return { h, probe, gated, arm, state, hooks, exists, until, pending };
}
const ms = r => r.end - r.start;
await test('r2 hooks: key selection, independent operations, uniform and ordinal delays, failure ordinals; the in-flight counter returns to 0 after a success and a rejection', async () => {
  const { h, probe, arm, state, hooks, exists } = await r2Harness();
  try {
    // Unarmed: calls are made and nothing is recorded.
    let r = await probe({ serial: true, ops: [{ op: 'put', key: 'u/a' }, { op: 'head', key: 'u/a' }] });
    assert.deepEqual([r.status, r.results.map(x => x.ok), r.calls.put, r.calls.head, r.in_flight, r.in_flight_peak], [200, [true, true], 1, 1, 0, 1], JSON.stringify(r));
    let s = await state();
    assert.deepEqual([s.armed, s.fired, s.logged, s.ordinals], [null, [], 0, {}]);
    // Every call is counted in flight: the multipart calls (create, part,
    // complete) and the abort through a resumed handle, which the multipart
    // counters leave out.
    r = await probe({ serial: true, ops: [{ op: 'multipart', key: 'u/mp' }, { op: 'resume_abort', key: 'u/ra' }] });
    assert.deepEqual([r.results.map(x => x.ok), r.calls.multipart, r.flights, r.in_flight, r.in_flight_peak], [[true, true], 4, 5, 0, 1], JSON.stringify(r));
    // prefix / skip_prefix select; the failure ordinals count selected calls only.
    await arm({ log: true, put: { prefix: 'sel/', skip_prefix: 'sel/skip/', fail: [1, 3] } });
    const keys = ['other/a', 'sel/a', 'sel/skip/a', 'sel/b', 'sel/c', 'sel/d'];
    r = await probe({ serial: true, ops: keys.map(key => ({ op: 'put', key })) });
    assert.deepEqual(r.results.map(x => x.ok), [true, false, true, true, false, true], JSON.stringify(r.results));
    assert.deepEqual(r.results.filter(x => !x.ok).map(x => x.error), ['fixture:r2_put_1', 'fixture:r2_put_3']);
    assert.deepEqual([r.calls.put, r.in_flight, r.in_flight_peak], [6, 0, 1], 'the counter returns to 0 after each success and each rejection');
    let w = await hooks();
    assert.deepEqual(w.ordinals, { put: 4 }, 'unmatched and skipped keys are not counted');
    assert.deepEqual(w.fired.map(f => [f.hook, f.op, f.k, f.key]), [['fail', 'put', 1, 'sel/a'], ['fail', 'put', 3, 'sel/c']]);
    assert.deepEqual(w.log.map(e => [e.key, e.ok, e.end > e.start]), keys.map((key, i) => [key, ![1, 4].includes(i), true]));
    assert.deepEqual(await Promise.all(keys.map(exists)), [true, false, true, true, false, true], 'a failed call is never made');
    // Rejections at once: both counted in flight, then 0.
    await arm({ put: { fail: [1, 2] } });
    r = await probe({ ops: [{ op: 'put', key: 'rej/1' }, { op: 'put', key: 'rej/2' }] });
    assert.deepEqual([r.results.map(x => x.ok), r.in_flight, r.in_flight_peak], [[false, false], 0, 2], JSON.stringify(r));
    // PUT and HEAD configured independently; a uniform delay.
    await arm({ put: { delay_ms: 400 }, head: { fail: [1] } });
    r = await probe({ serial: true, ops: [{ op: 'put', key: 'ind/a' }, { op: 'head', key: 'ind/a' }, { op: 'head', key: 'ind/a' }, { op: 'put', key: 'ind/b' }] });
    assert.deepEqual(r.results.map(x => x.ok), [true, false, true, true]);
    assert.equal(r.results[1].error, 'fixture:r2_head_1');
    assert.ok(ms(r.results[0]) >= 400 && ms(r.results[3]) >= 400 && ms(r.results[2]) < 400, `PUTs delayed, the HEAD not: ${r.results.map(ms)}`);
    w = await hooks();
    assert.deepEqual([w.ordinals, w.fired.map(f => [f.hook, f.op, f.k])], [{ put: 2, head: 2 }, [['fail', 'head', 1]]]);
    // Ordinal delays cycle; the unconfigured PUT is not delayed.
    await arm({ head: { delays_ms: [600, 0, 300] } });
    r = await probe({ serial: true, ops: [...Array(4)].map(() => ({ op: 'head', key: 'ind/a' })).concat([{ op: 'put', key: 'ind/c' }]) });
    const d = r.results.map(ms);
    assert.ok(d[0] >= 600 && d[1] < 300 && d[2] >= 300 && d[2] < 600 && d[3] >= 600 && d[4] < 300, `delays_ms [600, 0, 300] by ordinal, then the PUT: ${d}`);
    report.push(`r2 hooks: prefix/skip_prefix selected 4 of 6 PUTs and failed ordinals 1 and 3; PUT delay_ms 400 beside HEAD fail [1], HEAD delays_ms [600, 0, 300] measured ${d.slice(0, 4).join('/')} ms, the PUT ${d[4]} ms; in flight 0 after successes and rejections`);
  } finally { await h.close(); }
});
await test('r2 hooks: reply and request holds, release, stop and disarm; the in-flight counter counts multipart calls; overlapping invocations count and release independently', async () => {
  const { h, probe, gated, arm, state, hooks, exists, until, pending } = await r2Harness();
  try {
    // Reply holds: the first two PUTs are made (their objects exist), their replies held.
    await arm({ log: true, put: { hold: 2 } });
    let p = probe({ ops: ['h/1', 'h/2', 'h/3'].map(key => ({ op: 'put', key })) });
    await until('two replies held, the third returned', async () => { const s = await state(); return s.held === 2 && s.ordinals.put === 3; });
    assert.deepEqual(await Promise.all(['h/1', 'h/2', 'h/3'].map(exists)), [true, true, true], 'a reply hold follows the call');
    assert.equal((await pending(p)).settled, null, 'the probe waits on its held replies');
    const released = await h.invoke('test/r2-release', {});
    assert.equal(released.released, 2);
    let r = await p;
    assert.deepEqual([r.results.map(x => x.ok), r.in_flight, r.in_flight_peak], [[true, true, true], 0, 3]);
    let w = await hooks();
    assert.deepEqual(w.fired.map(f => [f.k, f.stage, !!f.released, !!f.settled]), [[1, 'reply', true, true], [2, 'reply', true, true]]);
    assert.deepEqual([w.held, w.released], [0, 2]);
    // Still armed: only ordinals 1 and 2 were held.
    assert.ok((await pending(probe({ ops: [{ op: 'put', key: 'h/4' }] }), 5000)).settled, 'the 4th PUT is not held');
    // A request hold: the call is not made until the release.
    await arm({ put: { hold_request: [1] } });
    p = probe({ ops: [{ op: 'put', key: 'hr/1' }] });
    await until('the request held', async () => (await state()).held === 1);
    assert.equal(await exists('hr/1'), false, 'a request hold precedes the call');
    assert.equal((await h.invoke('test/r2-release', {})).released, 1);
    assert.equal((await p).results[0].ok, true);
    assert.equal(await exists('hr/1'), true, 'made after the release');
    assert.equal((await hooks()).fired[0].stage, 'request');
    // stop: the hold ends; the next selected call is not held.
    await arm({ put: { hold: 5 } });
    p = probe({ ops: [{ op: 'put', key: 's/1' }] });
    await until('held', async () => (await state()).held === 1);
    assert.equal((await h.invoke('test/r2-release', { stop: true })).released, 1);
    assert.equal((await p).results[0].ok, true);
    assert.ok((await pending(probe({ ops: [{ op: 'put', key: 's/2' }] }), 5000)).settled, 'after stop, the 2nd PUT is not held');
    // Disarm: a held call stays held until a release; new calls are untouched.
    await arm({ put: { hold: 1, delay_ms: 2000 } });
    p = probe({ ops: [{ op: 'put', key: 'd/1' }] });
    await until('held', async () => (await state()).held === 1);
    await arm({});
    const s = await state();
    assert.deepEqual([s.armed, s.held], [null, 1], 'disarmed with the call still held');
    r = await probe({ ops: [{ op: 'put', key: 'd/2' }] });
    assert.ok(r.results[0].ok && ms(r.results[0]) < 2000, `disarmed: neither held nor delayed (${ms(r.results[0])} ms)`);
    assert.equal((await pending(p)).settled, null, 'the earlier call is still held');
    assert.equal((await h.invoke('test/r2-release', {})).released, 1);
    assert.equal((await p).results[0].ok, true);
    // Multipart calls are in flight beside a held PUT of the same invocation.
    await arm({ put: { hold: 1 } });
    p = probe({ ops: [{ op: 'put', key: 'mp/held' }, { op: 'multipart', key: 'mp/upload' }] }, gated('mp'));
    let gate = await until('the multipart completed beside the held PUT', async () => { const g = (await state()).executions.mp; return g?.calls.multipart === 3 && g.in_flight === 1 && g; });
    assert.deepEqual([gate.in_flight, gate.in_flight_peak, gate.unsettled], [1, 2, 1], `create, part and complete each in flight beside the held PUT: ${JSON.stringify(gate)}`);
    assert.deepEqual(await h.invoke('test/r2-release', { execution: 'mp' }), { execution: 'mp', requested: true });
    r = await p;
    assert.deepEqual([r.status, r.calls.multipart, r.in_flight_peak], [200, 3, 2]);
    gate = (await state()).executions.mp;
    assert.deepEqual([gate.released, gate.drained.in_flight, gate.drained.unsettled], [1, 0, 0]);
    // Two invocations at once: each counts and releases only its own calls.
    await arm({ put: { hold: 5 } });
    const pa = probe({ ops: ['A/1', 'A/2'].map(key => ({ op: 'put', key })) }, gated('A'));
    const pb = probe({ ops: ['B/1', 'B/2', 'B/3'].map(key => ({ op: 'put', key })) }, gated('B'));
    await until('five held', async () => (await state()).held === 5);
    let ex = (await state()).executions;
    assert.deepEqual([ex.A.in_flight, ex.A.unsettled, ex.B.in_flight, ex.B.unsettled], [2, 2, 3, 3], JSON.stringify(ex));
    await h.invoke('test/r2-release', { execution: 'A' });
    const ra = await pa;
    ex = (await state()).executions;
    assert.deepEqual([ra.status, ra.in_flight_peak, ex.A.released, ex.A.drained.in_flight], [200, 2, 2, 0]);
    assert.deepEqual([ex.B.in_flight, ex.B.unsettled, ex.B.released, (await state()).held], [3, 3, 0, 3], 'B untouched by A\'s release');
    assert.equal((await pending(pb)).settled, null);
    await h.invoke('test/r2-release', { execution: 'B' });
    const rb = await pb;
    ex = (await state()).executions;
    assert.deepEqual([rb.status, rb.in_flight_peak, ex.B.released, ex.B.drained.in_flight, (await state()).held], [200, 3, 3, 0, 0]);
    report.push(`r2 hooks: reply holds left their objects made, a request hold its object absent until the release; stop ended a hold, disarm left a held call held; a multipart upload's 3 calls ran in flight beside a held PUT (peak 2); invocations A and B held 2 and 3 at once and each release freed only its own`);
  } finally { await h.close(); }
});
await test('r2 gate: a continuation released through the gate runs in its own request, live or after its operation was cancelled, and is counted there', async () => {
  const { h, probe, gated, arm, state, hooks, until, pending } = await r2Harness();
  try {
    // Live: the held PUT is released by its own request; its HEAD follows.
    await arm({ log: true, put: { hold: 1 } });
    let p = probe({ ops: [{ op: 'put', key: 'g/live', then: 'head' }] }, gated('live'));
    await until('held', async () => (await state()).held === 1);
    assert.equal((await state()).executions.live.result, null);
    await h.invoke('test/r2-release', { execution: 'live' });
    let r = await p;
    let gate = (await state()).executions.live, { log } = await hooks();
    assert.deepEqual([r.status, r.results[0].ok, gate.released, gate.drained.in_flight, gate.drained.unsettled, gate.drained.calls_after_release.head], [200, true, 1, 0, 0, 1], JSON.stringify(gate));
    const head = key => log.find(e => e.op === 'head' && e.key === key), put = key => log.find(e => e.op === 'put' && e.key === key);
    assert.ok(head('g/live').start > put('g/live').end && head('g/live').start > gate.released_seq);
    // Cancelled: the operation returns 503 at once, the request stays open;
    // the continuation it did not drop runs after the release, in that
    // request, and its HEAD is counted there: the gate would show a late call.
    await arm({ log: true, put: { hold: 1 } });
    p = probe({ ops: [{ op: 'put', key: 'g/dropped', then: 'head' }] }, gated('dropped'));
    await until('held', async () => (await state()).held === 1);
    await h.invoke('abort', 'dropped');
    const result = await until('the cancelled result', async () => (await state()).executions.dropped.result);
    assert.equal(result.status, 503);
    assert.equal(JSON.parse(result.text).cancelled, true);
    assert.equal((await pending(p)).settled, null, 'the cancelled request stays open while its call is held');
    await h.invoke('test/r2-release', { execution: 'dropped' });
    r = await p;
    gate = (await state()).executions.dropped; ({ log } = await hooks());
    assert.deepEqual([r.status, gate.released, gate.drained.in_flight, gate.drained.unsettled, gate.drained.calls_after_release.head], [503, 1, 0, 0, 1], JSON.stringify(gate));
    assert.ok(head('g/dropped')?.ok && head('g/dropped').start > put('g/dropped').end && head('g/dropped').start > gate.released_seq, 'the late HEAD followed the release in the cancelled request');
    report.push(`r2 gate: a live held PUT released by its own request continued to its HEAD; a cancelled operation answered 503 while its request stayed open, and the continuation it left running made its HEAD after the release in that request (calls after the release ${JSON.stringify(gate.drained.calls_after_release)}), in flight 0 at the close`);
  } finally { await h.close(); }
});

for (const line of report) console.log('REPORT', line);
console.log(`${passed} passed, ${failed} failed`);
process.exitCode = failed ? 1 : 0;
