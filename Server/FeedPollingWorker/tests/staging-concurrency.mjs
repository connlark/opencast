// Concurrent snapshot staging: a changed scan uploads each phase's snapshot
// pages (spool, identity, fingerprint, item keys) in bounded concurrent
// windows of UPLOAD_WINDOW, keeps every page reserved before its upload and
// recorded after it, and hands preparation the same ordered lists as a
// sequential upload would. Each case baselines a feed, changes it, and
// isolates the changed scan with stopAfter(.., 1) (action-boundary.mjs) on the
// storage-fixture build, then drives the R2 hooks of tests/entry.mjs
// (/test/r2-hooks): held replies, per-page delays, a failing page. No case
// asserts a wall time. The assertions are lettered (a)-(h).
//
// STAGING_CASES=<names> runs the cases whose names start with those names.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { existsSync } from 'node:fs';
import { setTimeout as sleep } from 'node:timers/promises';
import { POLLING_FIXTURE, stopAfter } from './action-boundary.mjs';
import { harness, hash, item, rss } from './harness.mjs';

// Server/NotificationsWorker/src/observation/store.rs.
const UPLOAD_WINDOW = 6;
const MiB = 1024 * 1024;
const HASH_BYTES = 32, ITEM_KEY_BYTES = 65;

let passed = 0, failed = 0;
const report = [];
const only = process.env.STAGING_CASES?.split(',');
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
    try { await h.close(); } catch (teardown) { if (!failure) throw teardown; failure.teardown = teardown; failure.body = failure; }
  }
}
if (!existsSync(`${POLLING_FIXTURE}/index_bg.wasm`)) throw Error(`missing the polling fixture build ${POLLING_FIXTURE}`);
// A feed URL whose opaque id falls in the provenance cohort (first hex nibble
// below 4), so each of its consumes writes a storage_phases line.
const cohort = base => { for (let i = 0; ; i++) { const url = `${base}-${i}`; if (parseInt(hash(['feed-v1', url])[0], 16) < 4) return url; } };
const sha256 = bytes => createHash('sha256').update(bytes).digest('hex');
const t0 = () => Math.floor(Date.now() / 1000);

// One harness per case: its publisher serves `served[url]`, 404 otherwise.
async function open() {
  const served = new Map();
  const h = await harness(request => served.has(request.url) ? new Response(served.get(request.url)) : new Response('missing', { status: 404 }), { pollingBuild: POLLING_FIXTURE, logs: true });
  h.served = served;
  h.bucket = await h.instance.getR2Bucket('FEED_SNAPSHOTS', 'polling-runtime');
  return h;
}
// A feed published from `base` old items, then changed by `fresh` new recent
// items: its pending wake is the changed scan's. `title(i)` names the base
// items (a long quoted title makes a spool spill past the 5 MiB buffer).
async function changedFeed(h, name, { base, fresh, title = i => `Episode ${name} ${i}` }) {
  const t = t0(), url = cohort(`https://staging.example.com/${name}`);
  const baseline = Array.from({ length: base }, (_, i) => item(`${name}-base-${i}`, t - 30 * 86_400 - i * 60, title(i)));
  h.served.set(url, rss(baseline));
  const feed = await h.add(url);
  await h.invoke('test/dispatch'); await h.drain();
  assert.equal((await h.first('SELECT observation_generation FROM n_feed WHERE feed_id=?', feed)).observation_generation, 1, `${name}: the baseline published`);
  const news = Array.from({ length: fresh }, (_, i) => item(`${name}-new-${i}`, t - 60 - i, `New ${name} ${i}`));
  h.served.set(url, rss([...news, ...baseline]));
  await h.run('UPDATE n_feed SET due_at=0,retry_at=0,dispatch_until=0 WHERE feed_id=?', feed);
  await h.invoke('test/dispatch');
  const wakes = (await h.polls()).filter(w => w.feed_id === feed);
  assert.equal(wakes.length, 1, `${name}: one changed wake`);
  return { feed, url, wake: wakes[0], items: base + fresh, fresh };
}
const lastConsume = async h => (await h.invoke('metrics')).recent.filter(t => t.path === '/test/consume').at(-1);
const scanLine = (h, from) => h.logs.slice(from).filter(e => e.event === 'storage_phases' && e.handler === 'consume').at(-1);
const staging = (h, feed) => h.first("SELECT observation_id,generation,lease_id,preparation_key,valid_eof FROM n_observation WHERE feed_id=? AND state='staging' AND valid_eof=1", feed);
async function object(h, key) {
  const found = await h.bucket.get(key);
  return found ? Buffer.from(await found.arrayBuffer()) : null;
}

// (b) Per page, its PUT returned before its HEAD started, and every HEAD
// follows a returned PUT of its key; `log` is the hooks' ordered call log.
function putBeforeHead(log, keys) {
  for (const key of keys) {
    const puts = log.filter(e => e.op === 'put' && e.key === key), heads = log.filter(e => e.op === 'head' && e.key === key);
    assert.equal(puts.length, 1, `(b) one PUT of ${key}`);
    assert.equal(heads.length, 1, `(b) one HEAD of ${key}`);
    assert.ok(puts[0].ok && puts[0].end < heads[0].start, `(b) PUT of ${key} returned (seq ${puts[0].end}) before its HEAD (seq ${heads[0].start})`);
  }
}
// (h) Some PUT that started later returned earlier: completion was out of order.
function inversions(log) {
  const puts = log.filter(e => e.op === 'put' && e.ok);
  let n = 0;
  for (let i = 0; i < puts.length; i++) for (let j = i + 1; j < puts.length; j++) if (puts[i].start < puts[j].start && puts[i].end > puts[j].end) n++;
  return n;
}
// (c) and (d) on a staged preparation: each list ordered as its input, every
// page re-read with its recorded sha256 and size (R2 and its n_snapshot row),
// the spool's ordinals the scan order and matched by the item keys, the hash
// pages' boundaries globally ordered. Returns the page lists and counts.
async function verifyStaged(h, feed, expected) {
  const staged = await staging(h, feed);
  assert.ok(staged?.preparation_key, 'a staged, checkpointed preparation');
  const preparation = JSON.parse((await object(h, staged.preparation_key)).toString());
  const lists = { spool: preparation.spool, identity: preparation.current_ids, fingerprint: preparation.current_fingerprints, item_keys: preparation.item_keys };
  const bytes = {};
  for (const [index, pages] of Object.entries(lists)) {
    bytes[index] = [];
    for (const page of pages) {
      assert.equal(page.index, index, `${page.key} is a ${index} page`);
      const body = await object(h, page.key);
      assert.ok(body, `${index} page ${page.key} is in R2`);
      assert.deepEqual([body.length, sha256(body)], [page.bytes, page.sha256], `(d) ${index} page ${page.key} re-reads with its recorded size and sha256`);
      const row = await h.first('SELECT state,sha256,bytes FROM n_snapshot WHERE object_key=?', page.key);
      assert.deepEqual([row?.state, row?.sha256, Number(row?.bytes)], ['uploaded', page.sha256, page.bytes], `(d) ${index} page ${page.key} is recorded as uploaded`);
      bytes[index].push(body);
    }
  }
  // The spool: every parsed item once, its ordinals 0..n-1 in list order.
  const records = [];
  lists.spool.forEach((page, p) => {
    const rows = JSON.parse(bytes.spool[p].toString());
    assert.equal(rows.length, page.count, `spool page ${p} count`);
    records.push(...rows);
  });
  assert.deepEqual(records.map(r => r[0]), Array.from({ length: expected.items }, (_, i) => i), '(c) the spool pages are in scan order: ordinals 0..n-1');
  // The item keys: record k is the spool's ordinal-k identity and fingerprint.
  const keys = Buffer.concat(bytes.item_keys);
  assert.equal(keys.length, expected.items * ITEM_KEY_BYTES, 'one item key per parsed item');
  lists.item_keys.forEach((page, p) => assert.equal(bytes.item_keys[p].length, page.count * ITEM_KEY_BYTES, `item-key page ${p} count`));
  for (let k = 0; k < expected.items; k++) {
    const key = keys.subarray(k * ITEM_KEY_BYTES, (k + 1) * ITEM_KEY_BYTES), [, id, fingerprint] = records[k];
    assert.ok(key.subarray(0, 32).equals(Buffer.from(id, 'base64')), `(c) item key ${k} names spool ordinal ${k}`);
    assert.equal(key[32], fingerprint == null ? 0 : 1);
    if (fingerprint != null) assert.ok(key.subarray(33).equals(Buffer.from(fingerprint, 'base64')), `(c) item key ${k} carries ordinal ${k}'s fingerprint`);
  }
  // The hash pages: sorted within, boundaries recorded, globally increasing.
  for (const index of ['identity', 'fingerprint']) {
    let last = null, total = 0;
    lists[index].forEach((page, p) => {
      const body = bytes[index][p], hashes = Array.from({ length: body.length / HASH_BYTES }, (_, i) => body.subarray(i * HASH_BYTES, (i + 1) * HASH_BYTES).toString('hex'));
      assert.equal(hashes.length, page.count, `${index} page ${p} count`);
      assert.deepEqual([page.first_hash, page.last_hash], [hashes[0], hashes.at(-1)], `${index} page ${p} boundaries`);
      for (const value of hashes) { assert.ok(last === null || last < value, `(c) ${index} hashes increase across page ${p}`); last = value; }
      total += hashes.length;
    });
    assert.equal(total, expected.items, `${index}: one hash per distinct item`);
  }
  return { staged, lists, pages: Object.fromEntries(Object.entries(lists).map(([k, v]) => [k, v.length])), spoolBytes: lists.spool.map(p => p.bytes) };
}
// (c) The preparation completed, published once; the final candidate sequence
// is the fresh items in (eligible_at, episode_id) order; the drain consumed
// it to its end.
async function verifyPublished(h, feed, expected) {
  await h.drain(); await h.deliver(true);
  assert.equal((await h.first('SELECT observation_generation FROM n_feed WHERE feed_id=?', feed)).observation_generation, 2, 'the change published as generation 2');
  const published = await h.rows("SELECT snapshot_key,candidate_count,candidate_cursor,drain_complete FROM n_observation WHERE feed_id=? AND state='published' AND generation=2", feed);
  assert.equal(published.length, 1, 'published once');
  const [o] = published;
  const manifest = JSON.parse((await object(h, o.snapshot_key)).toString());
  const candidates = [];
  for (const page of manifest.candidate_pages) {
    const body = await object(h, page.key);
    assert.deepEqual([body.length, sha256(body)], [page.bytes, page.sha256], `candidate page ${page.key} integrity`);
    candidates.push(...JSON.parse(body.toString()));
  }
  assert.equal(candidates.length, expected.fresh, 'every fresh item is a candidate');
  assert.equal(Number(o.candidate_count), expected.fresh);
  for (let i = 1; i < candidates.length; i++) {
    const [a, b] = [candidates[i - 1], candidates[i]];
    assert.ok(a.eligible_at < b.eligible_at || (a.eligible_at === b.eligible_at && a.episode_id < b.episode_id), `(c) candidate ${i} follows ${i - 1} in (eligible_at, episode_id) order`);
  }
  assert.deepEqual(new Set(candidates.map(c => c.title)), new Set(Array.from({ length: expected.fresh }, (_, i) => `New ${expected.name} ${i}`)), 'the candidates are the fresh items');
  assert.deepEqual([Number(o.candidate_cursor), Number(o.drain_complete)], [expected.fresh, 1], '(c) the drain cursor reached the candidate count');
  assert.equal((await h.first('SELECT COUNT(*) AS n FROM n_episode_release WHERE feed_id=?', feed)).n, expected.fresh, 'one release per candidate');
  return candidates.length;
}
// Every R2 object under a page key of this feed's scans is covered by an
// n_snapshot row (reserved or recorded): nothing the GC cannot find.
async function covered(h, keys) {
  for (const key of keys) {
    const row = await h.first('SELECT state,gc_after,created_at FROM n_snapshot WHERE object_key=?', key);
    assert.ok(row, `(e) object ${key} lies under its n_snapshot reservation`);
  }
}
// Replies are held and no PUT was made or held for 500 ms (the quiet rule of
// action-boundary.mjs's oneAction): the uploads in flight are all started.
// Returns the PUTs held and made since the arming.
async function heldWindow(h, running) {
  let last = '', since = performance.now(), done = false;
  running.then(() => { done = true; }, () => { done = true; });
  for (;;) {
    const s = await h.invoke('test/r2-state'), now = `${s.held}/${s.ordinals.put ?? 0}`;
    if (now !== last) { last = now; since = performance.now(); }
    else if (s.held > 0 && performance.now() - since >= 500) return { held: s.held, made: s.ordinals.put };
    if (done) throw Error(`the scan ended before a held window (${now})`);
    await sleep(20);
  }
}

await test('(a) concurrent starts: with every PUT reply held, the first window holds at least 2 and at most UPLOAD_WINDOW pages at once; the scan\'s in-flight peak is at most UPLOAD_WINDOW', async () => {
  const h = await open();
  await within(h, async () => {
    const c = await changedFeed(h, 'window', { base: 1200, fresh: 30 });
    await h.invoke('test/r2-hooks', { log: true, put: { hold: 1_000_000 } });
    const running = stopAfter(h, c.wake, 1);
    const { held: first } = await heldWindow(h, running);
    await h.invoke('test/r2-release', { stop: true });
    assert.equal((await running).outcome, 'guard');
    assert.ok(first >= 2, `(a) concurrent starts ${first} >= 2`);
    assert.ok(first <= UPLOAD_WINDOW, `(a) concurrent starts ${first} <= ${UPLOAD_WINDOW}`);
    const trace = await lastConsume(h);
    const { pages } = await verifyStaged(h, c.feed, c);
    assert.equal(first, Math.min(UPLOAD_WINDOW, pages.spool), '(a) the first spool window is full');
    assert.ok(trace.r2_in_flight_peak <= UPLOAD_WINDOW, `(a) in-flight peak ${trace.r2_in_flight_peak} <= ${UPLOAD_WINDOW}`);
    report.push(`(a) first window held ${first} PUTs at once (spool ${pages.spool} pages); scan in-flight peak ${trace.r2_in_flight_peak}`);
  });
});

for (const variant of ['in-memory', 'spilled']) {
  await test(`(b)(c)(d)(g)(h) ${variant} changed spool with forced out-of-order completion: per page PUT before HEAD, the lists ordered as input, every page re-read, published and drained in candidate order`, async () => {
    const h = await open();
    await within(h, async () => {
      const name = `ordered-${variant}`;
      // Quotes double under JSON escaping: the spool spills past the 5 MiB
      // buffer while the body itself stays inside it (two-pass.mjs case 5a).
      const title = variant === 'spilled' ? i => `Quoted ${i} ${'"'.repeat(480)}` : undefined;
      const c = await changedFeed(h, name, { base: variant === 'spilled' ? 5600 : 5000, fresh: 120, title });
      // The k-th PUT of each window waits longest: the window completes in reverse.
      await h.invoke('test/r2-hooks', { log: true, put: { delays_ms: [120, 100, 80, 60, 40, 20] } });
      const from = h.logs.length;
      assert.equal((await stopAfter(h, c.wake, 1)).outcome, 'guard');
      const trace = await lastConsume(h), { log } = (await h.invoke('metrics')).r2hooks;
      const staged = await verifyStaged(h, c.feed, c);
      const pageKeys = Object.values(staged.lists).flat().map(p => p.key);
      putBeforeHead(log, pageKeys);
      const flipped = inversions(log);
      assert.ok(flipped > 0, `(h) PUT completion was out of order (${flipped} inversions)`);
      assert.ok(trace.r2_in_flight_peak <= UPLOAD_WINDOW, `in-flight peak ${trace.r2_in_flight_peak}`);
      const spool = staged.spoolBytes.reduce((a, b) => a + b, 0);
      if (variant === 'spilled') {
        assert.ok(spool > 5 * MiB, `(g) the spool spilled: ${spool} bytes`);
        assert.ok(trace.multipart_create === 1 && trace.multipart_complete === 1 && trace.scratch_get >= 1 && trace.scratch_delete === 1, `(g) one scratch upload completed, read back and deleted: ${JSON.stringify(trace)}`);
        // A page straddles the last uploaded part and the tail buffer.
        const spilled = Math.floor(spool / (5 * MiB)) * 5 * MiB;
        let offset = 0, straddles = 0;
        for (const bytes of staged.spoolBytes) { if (offset < spilled && offset + bytes > spilled) straddles++; offset += bytes; }
        assert.equal(straddles, 1, `(g) one spool page straddles the spilled part and the tail buffer at ${spilled}`);
      } else {
        assert.ok(spool < 5 * MiB, `(g) the spool stayed in memory: ${spool} bytes`);
        assert.equal(trace.multipart, 0, '(g) no scratch upload');
      }
      // Every R2 call of the scan is a recorded witness interval: the page
      // PUTs and HEADs, the reads, and the spool scratch calls (item 3).
      const scan = scanLine(h, from)?.action?.find(a => a.name === 'scan');
      assert.ok(scan, 'the consume line carries its scan action');
      assert.equal(scan.r2_calls, trace.get + trace.put + trace.head + trace.delete + trace.list + trace.multipart, `(spans) every R2 call of the scan is a witness interval: ${JSON.stringify({ scan, trace })}`);
      const drained = await verifyPublished(h, c.feed, { ...c, name });
      report.push(`(b)(c)(d)(g)(h) ${variant}: pages ${JSON.stringify(staged.pages)}, spool ${spool} bytes, ${flipped} PUT completion inversions, in-flight peak ${trace.r2_in_flight_peak}, scan r2_calls ${scan.r2_calls}; ${drained} candidates published and drained`);
    });
  });
}

await test('(e) a failure on the k-th page: no valid checkpoint, no preparation row, every object reserved; the retry publishes once', async () => {
  const h = await open();
  await within(h, async () => {
    const c = await changedFeed(h, 'failure', { base: 1500, fresh: 40 });
    const before = await h.first('SELECT COUNT(*) AS n FROM n_observation WHERE feed_id=?', c.feed);
    // The 8th page: the second window's second upload.
    await h.invoke('test/r2-hooks', { log: true, put: { fail: [8] } });
    const failure = await h.consume(c.wake);
    assert.notEqual(failure.status, 200, `the failed scan is not acknowledged: ${failure.text}`);
    const { log, fired } = (await h.invoke('metrics')).r2hooks;
    assert.deepEqual(fired.map(f => [f.hook, f.k]), [['fail', 8]]);
    assert.equal(await staging(h, c.feed), null, '(e) no valid checkpoint');
    assert.equal((await h.first('SELECT COUNT(*) AS n FROM n_observation WHERE feed_id=? AND preparation_key IS NOT NULL', c.feed)).n, 0, '(e) no preparation row');
    assert.equal((await h.first('SELECT observation_generation FROM n_feed WHERE feed_id=?', c.feed)).observation_generation, 1, '(e) nothing published');
    // Durable safety, not a failed-prefix count: every page object that
    // reached R2 has its reservation (the snapshot GC's).
    const landed = log.filter(e => e.op === 'put' && e.ok).map(e => e.key);
    await covered(h, landed);
    report.push(`(e) the 8th PUT failed: ${landed.length} PUTs had landed, each under its reservation; ${(await h.first('SELECT COUNT(*) AS n FROM n_observation WHERE feed_id=?', c.feed)).n - before.n} observation row(s) written, none checkpointed`);
    await h.invoke('test/r2-hooks', {});
    const retry = await h.consume(c.wake, { attempts: 2 });
    assert.equal(retry.status, 200, retry.text);
    await verifyPublished(h, c.feed, { ...c, name: 'failure' });
  });
});

// (f) The gate of tests/entry.mjs (x-test-r2-gate): the held calls of one
// execution are released by that execution's own request, which stays open
// until each of them settled and its in-flight count stayed 0 for 500 ms, so
// a continuation of a released call would run and be counted there. The
// window's first two PUTs are held before they are made (their objects arrive
// late) and the next two after (their replies arrive late).
const GATED_HOLDS = { hold_request: [1, 2], hold: [3, 4] };
const gateOf = async (h, key) => (await h.invoke('test/r2-state')).executions[key];
// The gated operation's own result, read while its request stays open.
async function gatedResult(h, key) {
  for (let i = 0; i < 1000; i++) { const gate = await gateOf(h, key); if (gate?.result) return gate.result; await sleep(20); }
  throw Error(`the gated execution ${key} reported no result`);
}
// Every held call of the window reached its finally (stamped settled) and
// returned; the gated invocation's in-flight count was 0 when it closed.
function settledThroughGate(gate, holds, log) {
  assert.equal(gate.released, 4, '(f) the four held PUTs were released within their own request context');
  assert.deepEqual([gate.drained?.in_flight, gate.drained?.unsettled], [0, 0], `(f) every held call settled and the invocation's in-flight count returned to 0: ${JSON.stringify(gate)}`);
  for (const f of holds) {
    assert.ok(f.released && f.settled && f.settled >= f.released, `(f) the held ${f.stage} of ${f.key} was released and reached its completion record: ${JSON.stringify(f)}`);
    const call = log.find(e => e.op === 'put' && e.key === f.key);
    assert.ok(call?.ok && call.end > gate.released_seq, `(f) the held PUT of ${f.key} returned after the release (seq ${call?.end} > ${gate.released_seq})`);
  }
}

await test('(f) cancellation with uploads in flight: the dropped work issues no late HEAD, statement or checkpoint; its late objects lie under reserved keys; lease and permit recover; the retry publishes once', async () => {
  const h = await open();
  await within(h, async () => {
    const c = await changedFeed(h, 'cancel', { base: 1500, fresh: 40 });
    const ts = h.storage.testStorage('polling-runtime');
    await h.invoke('test/r2-hooks', { log: true, put: GATED_HOLDS });
    let settled = false;
    const running = h.consume(c.wake, { headers: { 'x-test-execution': 'cancel-staging', 'x-test-r2-gate': '1' } });
    running.then(() => { settled = true; }, () => { settled = true; });
    // Four PUTs held, the window's other two returned: it cannot complete.
    const window = await heldWindow(h, running);
    if (window.held !== 4) { await h.invoke('test/r2-release', { stop: true }); await running; }
    assert.deepEqual([window.held, window.made], [4, UPLOAD_WINDOW], '(f) four PUTs held within one full window');
    const abandoned = await h.first("SELECT observation_id,lease_id FROM n_observation WHERE feed_id=? AND state='staging' ORDER BY scan_started_at DESC LIMIT 1", c.feed);
    await h.invoke('abort', 'cancel-staging');
    // The cancelled operation's result, while its request stays open.
    const result = await gatedResult(h, 'cancel-staging');
    assert.equal(result.status, 503, `the cancelled delivery is not acknowledged: ${JSON.stringify(result)}`);
    const holds = (await h.invoke('metrics')).r2hooks.fired.filter(f => f.hook === 'hold');
    const held = holds.map(f => f.key), late = holds.filter(f => f.stage === 'request').map(f => f.key);
    assert.equal(held.length, 4);
    assert.equal(late.length, 2);
    for (const key of late) assert.equal(await object(h, key), null, `(f) the request-held PUT of ${key} has not reached R2`);
    // The successor scan, while the dropped PUTs are still held.
    const successor = await h.consume(c.wake, { attempts: 2 });
    assert.equal(successor.status, 200, `(f) the successor ran: permit and lease recovered: ${successor.text}`);
    assert.equal(settled, false, '(f) the cancelled request is still open');
    const statements = ts({ op: 'witness' }).counters.statements, calls = (await h.invoke('metrics')).r2hooks.log.length;
    assert.deepEqual(await h.invoke('test/r2-release', { execution: 'cancel-staging' }), { execution: 'cancel-staging', requested: true });
    // The request closes only once its released calls settled and its
    // in-flight count stayed 0: every assertion below follows that.
    const cancelled = await running;
    assert.equal(cancelled.status, 503, `the cancelled delivery is not acknowledged: ${cancelled.text}`);
    const gate = await gateOf(h, 'cancel-staging'), { log, fired } = (await h.invoke('metrics')).r2hooks;
    settledThroughGate(gate, fired.filter(f => f.hook === 'hold'), log);
    assert.deepEqual(gate.drained.calls_after_release, { get: 0, put: 0, head: 0, delete: 0, list: 0, multipart: 0 }, '(f) no call from the dropped work in its own request after the release');
    assert.equal(ts({ op: 'witness' }).counters.statements, statements, '(f) no late statement from the dropped work');
    assert.deepEqual(log.slice(calls).map(e => [e.op, e.key]), [], '(f) no late R2 call from the dropped work');
    for (const key of held) {
      assert.equal(log.filter(e => e.op === 'head' && e.key === key).length, 0, `(f) no HEAD for the dropped PUT of ${key}`);
      const row = await h.first('SELECT state,sha256,lease_id,gc_after,created_at FROM n_snapshot WHERE object_key=?', key);
      assert.deepEqual([row?.state, row?.sha256, row?.lease_id], ['reserved', '', abandoned.lease_id], `(f) the late object ${key} lies under its reservation`);
      assert.equal(Number(row.gc_after), Number(row.created_at) + 604800, '(f) collected by the snapshot GC after its grace');
      assert.ok(await object(h, key), `(f) the late object ${key} landed`);
    }
    const old = await h.first('SELECT state,preparation_key,valid_eof FROM n_observation WHERE observation_id=?', abandoned.observation_id);
    assert.ok(old.preparation_key === null && old.state !== 'published', `(f) no checkpoint or publication from the abandoned attempt: ${JSON.stringify(old)}`);
    await verifyPublished(h, c.feed, { ...c, name: 'cancel' });
    report.push(`(f) cancelled with 4 PUTs held (2 requests, 2 replies), released in the cancelled request's own context after the successor: each settled, in-flight 0, no call in that context after the release (${JSON.stringify(gate.drained.calls_after_release)}), no late call or statement, the 2 request-held objects absent at the cancellation and landed after it, each late object reserved under the abandoned lease; the successor published once`);
  });
});

await test('(f) control: an uncancelled scan whose held PUTs are released through the same gate continues to each HEAD and publishes', async () => {
  const h = await open();
  await within(h, async () => {
    const c = await changedFeed(h, 'control', { base: 1500, fresh: 40 });
    await h.invoke('test/r2-hooks', { log: true, put: GATED_HOLDS });
    const running = h.consume(c.wake, { headers: { 'x-test-execution': 'control-staging', 'x-test-r2-gate': '1' } });
    running.catch(() => {});
    const window = await heldWindow(h, running);
    if (window.held !== 4) { await h.invoke('test/r2-release', { stop: true }); await running; }
    assert.deepEqual([window.held, window.made], [4, UPLOAD_WINDOW], '(f) control: four PUTs held within one full window');
    assert.equal((await gateOf(h, 'control-staging')).result, null, '(f) control: the scan is still running');
    assert.deepEqual(await h.invoke('test/r2-release', { execution: 'control-staging' }), { execution: 'control-staging', requested: true });
    const done = await running;
    assert.equal(done.status, 200, `(f) control: the delivery completed: ${done.text}`);
    const gate = await gateOf(h, 'control-staging'), { log, fired } = (await h.invoke('metrics')).r2hooks;
    const holds = fired.filter(f => f.hook === 'hold');
    assert.deepEqual(holds.map(f => f.stage), ['request', 'request', 'reply', 'reply']);
    settledThroughGate(gate, holds, log);
    for (const f of holds) {
      const put = log.find(e => e.op === 'put' && e.key === f.key), heads = log.filter(e => e.op === 'head' && e.key === f.key);
      assert.equal(heads.length, 1, `(f) control: one HEAD of ${f.key}`);
      assert.ok(heads[0].ok && heads[0].start > put.end && heads[0].start > gate.released_seq, `(f) control: the released PUT of ${f.key} continued to its HEAD (seq ${heads[0].start} after the PUT's ${put.end} and the release's ${gate.released_seq})`);
    }
    assert.ok(gate.drained.calls_after_release.head >= 4, `(f) control: the live continuations' HEADs ran in the gated request: ${JSON.stringify(gate.drained)}`);
    await verifyPublished(h, c.feed, { ...c, name: 'control' });
    report.push(`(f) control: the same gate released 4 held PUTs of a live scan; each continued to its HEAD in that request (calls after the release ${JSON.stringify(gate.drained.calls_after_release)}), in-flight 0 at its close; published and drained`);
  });
});

console.log(`staging-concurrency: ${passed} passed, ${failed} failed`);
for (const line of report) console.log(`  ${line}`);
if (failed) process.exit(1);
