// The placed route: a poll delivery's
// engine call through the script's own default fetch, reached by the POLL_PLACED binding to itself. Each
// delivery goes through the shipped queue() (the harness's placed mode: /test/deliver, a one-message batch,
// or the real local Queue) and, on the placed route, through the shipped default fetch.
// Cases (PLACED_CASES=<n,...> runs a subset; 2b is the key's absence over the whole run):
//  1 the route function and the committed configuration    6 a caller that stops waiting; redelivery before release
//  2 the default export's refusals                         7 the 230 s bound, in real time (about four minutes)
//  3 equivalence at share 256 against share 0              8 mixed routes at share 32 and the token join
//  4 the header rule                                        9 refused FeedEvents posts on both routes; a key skew
//  5 a rejected hop and a rejected body read               2b the key nowhere in the run
// Case 6 rests on the harness's edge emulation (tests/entry.mjs holds a placed callee with waitUntil, because
// local workerd cancels a callee whose caller aborts and the edge does not): a green case 6 is evidence of the
// adapter's rules (no message id, no reclaim, one scan per isolate), not of the edge's lifetime.
import assert from 'node:assert/strict';
import { createHash, randomBytes } from 'node:crypto';
import { setTimeout as sleep } from 'node:timers/promises';
import { harness, hash, item, rss, wranglerConfig } from './harness.mjs';

const only = process.env.PLACED_CASES?.split(',').map(s => s.trim());
const selected = n => !only || only.includes(String(n));
const results = [];
async function test(n, name, fn) {
  if (n !== '2b' && !selected(n)) return;
  const start = Date.now();
  try { await fn(); results.push({ n, ok: true }); console.log(`PLACED-CONSUME PASS case ${n}: ${name} (${Date.now() - start} ms)`); }
  catch (error) { results.push({ n, ok: false }); console.log(`PLACED-CONSUME FAIL case ${n}: ${name}: ${String(error?.stack ?? error).split('\n').slice(0, 4).join(' | ')}`); }
}
// A run-independent form of rows or payloads: volatile columns dropped, UUIDs masked, JSON columns parsed, sorted.
// payload_digest hashes the raw payload, its times included, and raw_date is the fixture item's pubDate text from
// each harness's own start time: both differ between two runs by construction.
const VOLATILE = /(_at|_ms|_until|_time|lease_id|lease|receipt_id|nonce)$|^(created|updated|lease|observation_id|scan_started|payload_digest|raw_date)/;
// The masks and the re-parse act on every string; the fields they touched are recorded (SCRUBBED), and case 3
// asserts that none is a content field, so on these fixtures the normalization provably erases no content.
const SCRUBBED = { uuid: new Set(), json: new Set() }, CONTENT = /title|summary|description|url|guid|link|name|author|text|subtitle|category/;
const UUID = /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/gi;
const scrub = (value, key = '') => typeof value === 'string' ? (/^[\[{]/.test(value) ? (() => { try { const parsed = JSON.parse(value); SCRUBBED.json.add(key); return scrub(parsed, key); } catch { return value; } })() : (UUID.test(value) ? (UUID.lastIndex = 0, SCRUBBED.uuid.add(key), value.replace(UUID, '<uuid>')) : value))
  : Array.isArray(value) ? value.map(v => scrub(v, key)) : value && typeof value === 'object' ? Object.fromEntries(Object.entries(value).filter(([k]) => !VOLATILE.test(k)).sort(([a], [b]) => a < b ? -1 : 1).map(([k, v]) => [k, scrub(v, k)])) : value;
const normalized = rows => rows.map(row => JSON.stringify(scrub(row))).sort();
const sha16 = id => createHash('sha256').update(id).digest('hex').slice(0, 16);
const hex64 = () => randomBytes(32).toString('hex');
// A wake the dispatcher would send (schema 2, the harness's development lane).
const wake = (feed, extra = {}) => ({ schema_version: 2, environment: 'development', kind: 'poll', feed_id: feed, owner_epoch: 1, generation: 1, due_at: 0, step: 0, ...extra });
// A feed URL whose opaque id (hash(['feed-v1', url])) matches `pattern`.
const urlFor = (pattern, tag) => { for (let i = 0; ; i++) { const url = `https://placed-${tag}.example.com/feed-${i}`; if (pattern.test(hash(['feed-v1', url]))) return url; } };
const v1 = now => new Response(rss([item('base', now - 100)]), { headers: { etag: '"v1"' } });
const v2 = now => new Response(rss([item('base', now - 100), ...Array.from({ length: 5 }, (_, i) => item(`new-${i}`, now - 10 + i))]), { headers: { etag: '"v2"' } });
const until = async (predicate, ms = 15000, what = 'condition') => { const end = Date.now() + ms; while (Date.now() < end) { if (await predicate()) return; await sleep(25); } throw Error(`timed out waiting for ${what}`); };
const metricsOf = async (h, replica = 0) => (await (await (replica ? await h.instance.getWorker(`polling-runtime-${replica}`) : { fetch: h.instance.dispatchFetch.bind(h.instance) }).fetch('https://polling.invalid/metrics')).json());
const post = async (h, path, body, replica = 0) => {
  const target = replica ? await h.instance.getWorker(`polling-runtime-${replica}`) : { fetch: h.instance.dispatchFetch.bind(h.instance) };
  const response = await target.fetch(`https://polling.invalid/${path}`, { method: 'POST', body: typeof body === 'string' ? body : JSON.stringify(body ?? {}) });
  const text = await response.text(); assert.equal(response.status, 200, `${path}: ${text}`); return JSON.parse(text);
};
const due = async (h, feed) => h.run('UPDATE n_feed SET due_at=?,dispatch_until=0,retry_at=0 WHERE feed_id=?', h.now, feed);
// The dispatcher admits every feed due within its 30 s look-ahead, and a feed settled earlier in a harness is due again
// within seconds when its fixed grid point follows the settle (policy.rs next_due; dispatch.rs SCAN_DUE). Where a case
// reads more than its own feed's deliveries, its feed is dispatched alone: every other feed paused for that one dispatch.
const wakeOnly = async (h, feed) => { await h.run('UPDATE n_feed SET admission_paused=CASE WHEN feed_id=? THEN 0 ELSE 1 END', feed); try { return await wakeOf(h, feed); } finally { await h.run('UPDATE n_feed SET admission_paused=0'); } };
const wakeOf = async (h, feed) => { await h.invoke('test/dispatch'); const w = (await h.polls()).filter(x => x.feed_id === feed); assert.equal(w.length, 1, `one wake for ${feed}: ${JSON.stringify(w)}`); return w[0]; };
// Every delivery through the shipped queue() until no wakeup is due; each recorded.
async function drainRecorded(h, log, label, { replica = 0 } = {}) {
  for (let i = 0; i < 200; i++) {
    const wakes = await h.invoke('wakeups'); if (!wakes.length) return;
    for (const w of wakes) {
      let attempts = 1, r;
      for (;;) { r = await h.consume(w, { attempts, replica }); log.push({ label, feed: w.feed_id, step: w.step, attempts, outcome: r.outcome, status: r.status, decision: r.decision, route: r.route }); if (['ack', 'implicit_ack'].includes(r.decision) || attempts > 3) break; attempts++; }
    }
  }
  throw Error('drainRecorded did not end');
}
// Evidence of the run for case 2b: every text the run produced, and every key in play.
const KEYS = new Set(), TEXTS = [];
const keep = value => { TEXTS.push(typeof value === 'string' ? value : JSON.stringify(value)); return value; };
// Every callee's evidence is complete or 2b says so: per replica, a callee still in `stage` (engine or reading) is a
// failure, and so is a failed callee (its response never existed) unless the case that produced it declares it in
// EXPECTED_FAILED_CALLEES (none does today). 2b's PASS line prints the totals.
let harnessesClosed = 0;
const CALLEES = { completed: 0, refused: 0, failed: 0, pending: 0 }, EXPECTED_FAILED_CALLEES = new Map();
async function closeHarness(h, replicas = 1) {
  for (const key of h.placed?.allKeys ?? []) KEYS.add(key);
  for (let r = 0; r < replicas; r++) {
    let m; try { m = await metricsOf(h, r); } catch (error) { TEXTS.push(`metrics ${r}: ${error}`); KEYLEAKS.push(`replica ${r}: its witness is unavailable (${String(error?.message ?? error).slice(0, 80)})`); continue; }
    keep(m);
    const counters = [m.placed?.rust?.key_env, m.placed?.rust?.key_header, ...['caller_request', 'caller_response', 'callee_response', 'sent_response'].map(k => m.placed?.leaks?.[k])];
    if (!counters.every(n => typeof n === 'number')) { KEYLEAKS.push(`replica ${r}: its witness is malformed`); continue; }
    const callee = m.placed.callee ?? {}, pending = Object.entries(callee.stage ?? {});
    CALLEES.completed += callee.entered ?? 0; CALLEES.refused += callee.refused ?? 0; CALLEES.failed += callee.failed ?? 0; CALLEES.pending += pending.length;
    for (const [invocation, stage] of pending) KEYLEAKS.push(`replica ${r}: callee invocation ${invocation} still ${stage}: its evidence is incomplete`);
    const expected = EXPECTED_FAILED_CALLEES.get(`${h.placed?.share}:${r}`) ?? 0;
    if ((callee.failed ?? 0) > expected) KEYLEAKS.push(`replica ${r}: ${callee.failed} failed callee(s), ${expected} expected: their evidence is incomplete`);
    if ((m.placed?.rust?.key_env ?? 0) !== 0) KEYLEAKS.push(`replica ${r}: the key in an env handed to Rust (${m.placed.rust.key_env})`);
    if ((m.placed?.rust?.key_header ?? 0) !== 0) KEYLEAKS.push(`replica ${r}: the key in a request handed to Rust (${m.placed.rust.key_header})`);
    for (const [where, n] of Object.entries(m.placed?.leaks ?? {})) if (n !== 0) KEYLEAKS.push(`replica ${r}: the key in ${where} (${n})`);
  }
  if (!Array.isArray(h.placedOutbound)) KEYLEAKS.push('the outbound witness is missing');
  const outbound = (h.placedOutbound ?? []).filter(x => x.leak).length;
  if (outbound) KEYLEAKS.push(`the key in ${outbound} outbound request(s)`);
  harnessesClosed++;
  keep(h.raw); keep(h.logs); keep(h.events); keep(h.placedOutbound ?? []);
  // A placed harness none of whose deliveries took the binding fails at close (its PLACED-ROUTE line): a
  // failure of the run, recorded, and the other cases still run.
  try { await h.instance.dispose(); }
  catch (error) { results.push({ n: 'harness', ok: false }); console.log(`PLACED-CONSUME FAIL harness close: ${String(error?.message ?? error)}`); }
}
const KEYLEAKS = [];

// ---- H1: share 256; replicas: 0 keyed and self-bound (one isolate); 1 no key; 2 an empty key; 3 a 31-character
// key; 4 key K1 bound to 5 (key K2, self-bound): a rotation's skew; 6 the environment brake; 7 share 0.
const H1_KEY = hex64(), K1 = hex64(), K2 = hex64(), SHORT = 'k'.repeat(31);
[H1_KEY, K1, K2, SHORT].forEach(k => KEYS.add(k));
if (['1', '2', '4', '6', '9'].some(selected) || !only) {
  const behavior = new Map(), fallback = { fn: now => v1(now) };
  const h = await harness(request => (behavior.get(request.url.replace(/\?.*$/, '')) ?? fallback.fn)(h.now, request), {
    logs: true, replicas: 8,
    placed: { share: '256', key: H1_KEY, keys: { 1: null, 2: '', 3: SHORT, 4: K1, 5: K2 }, targets: { 4: 'polling-runtime-5' },
      bindings: { 6: { NOTIFICATION_FEED_OBSERVATION: 'false' }, 7: { POLL_PLACED_SHARE: '0' } } },
  });
  try {
    await test(1, 'the route function: shares, boundaries, malformed shares, keys, bodies, no binding; the committed configuration', async () => {
      const B = {}, K = 'a'.repeat(64), id = p => p + '0'.repeat(64 - p.length);
      const env = (share, extra = {}) => ({ POLL_PLACED: B, POLL_PLACED_KEY: K, POLL_PLACED_SHARE: share, ...extra });
      const cases = [
        ['share 0', env('0'), wake(id('00')), false],
        ['share 32, 00', env('32'), wake(id('00')), true], ['share 32, 1f (below)', env('32'), wake(id('1f')), true],
        ['share 32, 20 (at)', env('32'), wake(id('20')), false], ['share 32, 21 (above)', env('32'), wake(id('21')), false], ['share 32, ff', env('32'), wake(id('ff')), false],
        ['share 1, 00', env('1'), wake(id('00')), true], ['share 1, 01', env('1'), wake(id('01')), false],
        ['share 256, 00', env('256'), wake(id('00')), true], ['share 256, ff', env('256'), wake(id('ff')), true],
        ...['', ' 32', '32 ', '32.0', '0x20', '257', '-1', '032', '1e2', 'abc', '+32'].map(s => [`malformed share ${JSON.stringify(s)}`, env(s), wake(id('00')), false]),
        ['share unbound', (({ POLL_PLACED_SHARE, ...rest }) => rest)(env('32')), wake(id('00')), false],
        ['share a number', env(32), wake(id('00')), false],
        ['key missing', (({ POLL_PLACED_KEY, ...rest }) => rest)(env('256')), wake(id('00')), false],
        ['key empty', env('256', { POLL_PLACED_KEY: '' }), wake(id('00')), false],
        ['key 31 characters', env('256', { POLL_PLACED_KEY: 'a'.repeat(31) }), wake(id('00')), false],
        ['key 32 characters', env('256', { POLL_PLACED_KEY: 'a'.repeat(32) }), wake(id('00')), true],
        ['key a number', env('256', { POLL_PLACED_KEY: 12345678901234567890123456789012 }), wake(id('00')), false],
        ['no binding', (({ POLL_PLACED, ...rest }) => rest)(env('256')), wake(id('00')), false],
        ['a legacy cleanup message', env('256'), { ...wake(id('00')), kind: 'cleanup' }, false],
        ['an undecodable body (a string)', env('256'), 'not json', false], ['a null body', env('256'), null, false],
        ['no feed_id', env('256'), (({ feed_id, ...rest }) => rest)(wake(id('00'))), false],
        ['feed_id not hex', env('256'), wake(id('g0')), false], ['feed_id uppercase', env('256'), wake(id('AB')), false],
        ['feed_id one character', env('256'), wake('0'), false], ['feed_id a number', env('256'), wake(12), false],
      ];
      const answer = await post(h, 'test/placed-route', { cases: cases.map(([, e, body]) => ({ env: e, body })) });
      assert.ok(!answer.missing, answer.missing);
      cases.forEach(([name, , , expected], i) => assert.equal(answer.results[i], expected, `route: ${name}`));
      // The committed configuration: each lane's share by value (production "256", every feed placed; development and
      // prod-staging "0"), the variable parses as the function requires, placement and the self-binding. A disable or a
      // reduction moves the expected value here in the same commit (README, Controls).
      const committed = [['development', wranglerConfig, '0'], ['prod-staging', wranglerConfig.env['prod-staging'], '0'], ['production', wranglerConfig.env.production, '256']];
      for (const [lane, c, expected] of committed) {
        const share = c.vars?.POLL_PLACED_SHARE;
        assert.equal(share, expected, `${lane}: the committed POLL_PLACED_SHARE`);
        assert.ok(typeof share === 'string' && /^(0|[1-9][0-9]{0,2})$/.test(share) && Number(share) <= 256, `${lane}: POLL_PLACED_SHARE ${JSON.stringify(share)}`);
        const [placedAt, placedAtFf] = (await post(h, 'test/placed-route', { cases: [{ env: env(share), body: wake(id('00')) }, { env: env(share), body: wake(id('ff')) }] })).results;
        assert.equal(placedAt, Number(share) > 0, `${lane}: the committed share ${share} routes 00 as its value says`);
        assert.equal(placedAtFf, Number(share) > 0xff, `${lane}: the committed share ${share} routes ff as its value says`);
        console.log(`  committed ${lane}: POLL_PLACED_SHARE ${share}`);
      }
      for (const lane of ['prod-staging', 'production']) {
        const c = wranglerConfig.env[lane];
        assert.deepEqual(c.placement, { region: 'azure:northcentralus' }, `${lane}: placement`);
        assert.deepEqual(c.services.filter(s => s.binding === 'POLL_PLACED'), [{ binding: 'POLL_PLACED', service: c.name }], `${lane}: POLL_PLACED binds the script to itself`);
      }
      assert.equal(wranglerConfig.placement, undefined, 'development: no placement');
      assert.equal(wranglerConfig.services.some(s => s.binding === 'POLL_PLACED'), false, 'development: no binding');
    });

    await test(2, 'the default export refuses everything but a keyed POST /consume, without entering Rust', async () => {
      const cohort = hash(['feed-v1', 'https://placed-refusal.example.com/never-added']).replace(/^./, '0');
      const body = JSON.stringify(wake(cohort));
      const ts = replica => h.storage.testStorage(replica ? `polling-runtime-${replica}` : 'polling-runtime');
      async function refused(replica, spec, what) {
        const before = (await metricsOf(h, replica)).placed, statements = ts(replica)({ op: 'witness' }).counters.statements, raw = h.raw.length;
        const target = replica ? await h.instance.getWorker(`polling-runtime-${replica}`) : { fetch: h.instance.dispatchFetch.bind(h.instance) };
        let r;
        if (spec.public) { const response = await target.fetch(`https://polling.invalid${spec.path}`, { method: spec.method, headers: spec.headers, ...(spec.method === 'GET' ? {} : { body }) }); r = { status: response.status, engine: response.headers.has('x-poll-engine-ms'), text: await response.text() }; }
        else r = keep(await (await target.fetch('https://polling.invalid/test/placed-send', { method: 'POST', body: JSON.stringify({ ...spec, body }) })).json());
        const after = (await metricsOf(h, replica)).placed;
        assert.deepEqual([r.status, r.text, r.engine], [404, 'not_found', false], `${what}: ${JSON.stringify(r)}`);
        assert.equal(after.rust.entries, before.rust.entries, `${what}: Rust was entered`);
        assert.equal(ts(replica)({ op: 'witness' }).counters.statements, statements, `${what}: a storage statement ran`);
        const lines = h.raw.slice(raw).map(x => x.message).filter(m => /storage_phases|poll_outcome|poll_delivery|poll_placed/.test(m));
        assert.deepEqual(lines, [], `${what}: a line from the engine`);
      }
      const k = '<KEY>';
      await refused(0, { method: 'GET', path: '/consume', headers: { 'x-poll-placed-key': k } }, 'GET /consume with the key');
      for (const path of ['/dispatch', '/cleanup', '/stats', '/repair', '/dead-letter', '/identity']) await refused(0, { method: 'POST', path, headers: { 'x-poll-placed-key': k } }, `POST ${path} with the key`);
      await refused(0, { method: 'POST', path: '/consume', headers: {} }, 'POST /consume without a key');
      await refused(0, { method: 'POST', path: '/consume', headers: { 'x-poll-placed-key': hex64() } }, 'POST /consume with a wrong key of the same length');
      await refused(0, { method: 'POST', path: '/consume', headers: { 'x-poll-placed-key': H1_KEY.slice(1) } }, 'POST /consume with a key one character short');
      await refused(0, { method: 'POST', path: '/consume', headers: { 'x-poll-placed-key': H1_KEY + 'a' } }, 'POST /consume with a key one character long');
      await refused(0, { method: 'POST', path: '/consume/', headers: { 'x-poll-placed-key': k } }, 'POST /consume/ with the key');
      await refused(0, { public: true, method: 'POST', path: '/consume', headers: {} }, 'public POST /consume without a key');
      await refused(1, { method: 'POST', path: '/consume', headers: {} }, 'the key unconfigured, no header');
      await refused(1, { method: 'POST', path: '/consume', headers: { 'x-poll-placed-key': '' } }, 'the key unconfigured, an empty header');
      await refused(2, { method: 'POST', path: '/consume', headers: { 'x-poll-placed-key': '' } }, 'the key configured empty, the same empty header');
      await refused(3, { method: 'POST', path: '/consume', headers: { 'x-poll-placed-key': k } }, 'the key 31 characters, the same 31 characters');
      // Where the key is not usable the route is off as well: a delivery runs in process.
      for (const replica of [1, 2, 3]) {
        const r = keep(await h.consume(wake(cohort.replace(/^0./, '0' + replica)), { replica }));
        assert.deepEqual([r.route, r.decision, r.status, r.outcome], ['in_process', 'ack', 200, 'obsolete'], `replica ${replica}: ${JSON.stringify(r)}`);
      }
    });

    await test(4, 'the header rule: only an ok or 400 response carrying the engine header is acknowledged', async () => {
      const obsolete = wake('0' + hex64().slice(1));
      for (const [status, header] of [[200, false], [400, false], [404, false], [503, false]]) {
        await post(h, 'test/placed-stub', { mode: 'status', status, header, times: 1 });
        const r = keep(await h.consume(obsolete));
        assert.deepEqual([r.route, r.status, r.hops[0]?.engine, r.decision, r.retry?.delaySeconds], ['placed', status, false, 'retry', 60], `${status} without the header: ${JSON.stringify(r)}`);
      }
      // The engine's own answers, each carrying the header.
      const url = 'https://placed-header.example.com/feed';
      const feed = await h.add(url);
      await h.consume(await wakeOf(h, feed)); await h.drain();
      await due(h, feed);
      const w = await wakeOf(h, feed);
      await h.invoke('fault', 'always:before_settle');
      let r = keep(await h.consume(w));
      await h.invoke('fault', 'none');
      assert.deepEqual([r.route, r.status, r.hops[0]?.engine, r.decision], ['placed', 500, true, 'retry'], `the engine's 500: ${JSON.stringify(r)}`);
      r = keep(await h.consume(w, { attempts: 2, replica: 6 }));
      assert.deepEqual([r.route, r.status, r.hops[0]?.engine, r.decision], ['placed', 503, true, 'retry'], `the engine's 503 (the brake): ${JSON.stringify(r)}`);
      assert.ok(r.text.includes('polling_disabled'), r.text);
      r = keep(await h.consume(w, { attempts: 3 }));
      assert.deepEqual([r.route, r.status, r.hops[0]?.engine, r.decision], ['placed', 200, true, 'ack'], `the engine's 200: ${JSON.stringify(r)}`);
      r = keep(await h.consume({ ...w, schema_version: 99 }));
      assert.deepEqual([r.route, r.status, r.hops[0]?.engine, r.decision], ['placed', 400, true, 'ack'], `the engine's 400: ${JSON.stringify(r)}`);
    });

    await test(6, 'a caller that stops waiting: the engine runs on (its lifetime is the harness\'s waitUntil emulation of the edge); its redelivery reclaims nothing; one scan per isolate', async () => {
      const urlF = 'https://placed-held.example.com/feed', urlG = 'https://placed-unrelated.example.com/feed';
      const F = await h.add(urlF);
      await h.consume(await wakeOf(h, F)); await h.drain();
      assert.equal((await h.first('SELECT observation_generation FROM n_feed WHERE feed_id=?', F)).observation_generation, 1, 'the baseline');
      let entered = false, releaseF;
      behavior.set(urlF, async now => { entered = true; await new Promise(resolve => { releaseF = resolve; }); return v2(now); });
      await due(h, F);
      const heldWake = await wakeOf(h, F);
      const G = await h.add(urlG); const otherWake = await wakeOf(h, G);
      const statsBefore = await h.invoke('test/stats'), rawFrom = h.raw.length, caseFrom = Date.now();
      const pending = h.consume(heldWake, { headers: { 'x-test-hop-key': 'held' } });
      let first, enteredBefore;
      try {
        await until(async () => entered && (await h.invoke('test/stats')).active_permits === 2, 15000, 'the held scan to own both permits');
        assert.deepEqual(await post(h, 'test/hop-abort', 'held'), { aborted: true }, 'the caller\'s call was not in flight through the binding (no hop)');
        first = keep(await Promise.race([pending, sleep(5000).then(() => null)]));
        assert.ok(first, 'the aborted caller did not end');
        assert.equal(first.decision, 'throw', `the caller gave up: ${JSON.stringify(first)}`);
        assert.match(first.error, /caller_gave_up/);
        // BEFORE the release: the same message's redelivery and an unrelated feed's delivery after it.
        const redo = h.consume(heldWake, { attempts: 2 });
        await sleep(100);
        const other = h.consume(otherWake);
        let maxPermits = 0, otherFetched = 0;
        const watching = (async () => { for (;;) { const s = await h.invoke('test/stats'); maxPermits = Math.max(maxPermits, s.active_permits); otherFetched = Math.max(otherFetched, h.fetches.filter(u => u.startsWith(urlG)).length); if (watching.done) return; await sleep(100); } })();
        const [redone, others] = await Promise.all([redo, other]); watching.done = true; await watching;
        keep(redone); keep(others);
        const statsHeld = await h.invoke('test/stats');
        assert.equal(statsHeld.permit_reclaim_total, statsBefore.permit_reclaim_total, 'the redelivery reclaimed a live engine\'s permits');
        assert.deepEqual(h.raw.slice(rawFrom).filter(x => x.message.includes('scan_permit_reclaimed')), [], 'a scan_permit_reclaimed line');
        assert.equal(statsHeld.active_permits, 2, 'the first engine still owns both permits');
        assert.ok(maxPermits <= 2, `permits ${maxPermits}`);
        assert.equal(otherFetched, 0, 'the unrelated feed\'s scan reached its publisher while the first scan held the isolate');
        assert.deepEqual([redone.route, redone.outcome, redone.decision], ['placed', 'scan_busy', 'ack'], `the redelivery: ${JSON.stringify(redone)}`);
        assert.deepEqual([others.route, others.outcome, others.decision], ['placed', 'scan_busy', 'ack'], `the unrelated delivery: ${JSON.stringify(others)}`);
        // The message id at both boundaries: the requests the binding received and those Rust received.
        for (const [name, r] of [['the held attempt', first], ['the redelivery', redone], ['the unrelated delivery', others]]) {
          assert.equal(r.hops.length, 1, `${name}: one hop`);
          assert.ok(!r.hops[0].header_names.includes('x-poll-message-id') && r.hops[0].message_id === null, `${name}: the binding received a message id: ${JSON.stringify(r.hops[0])}`);
        }
        const consumes = (await metricsOf(h)).placed.rust.consumes.filter(e => e.at >= caseFrom);
        for (const [name, feed, attempts] of [['the held attempt', F, '1'], ['the redelivery', F, '2'], ['the unrelated delivery', G, '1']]) {
          const seen = consumes.filter(e => e.feed === feed && e.attempts === attempts);
          assert.equal(seen.length, 1, `${name}: one request handed to Rust: ${JSON.stringify(consumes.map(e => [e.feed?.slice(0, 4), e.attempts]))}`);
          assert.ok(seen[0].message_id === null && !seen[0].header_names.includes('x-poll-message-id') && !seen[0].hop, `${name}: Rust received a message id or a token: ${JSON.stringify(seen[0])}`);
        }
      } finally { enteredBefore = (await metricsOf(h)).placed.callee.entered; releaseF?.(); await Promise.race([pending, sleep(20000)]); }
      // Released: the first engine completes and commits (its response reaches a callee whose caller is gone);
      // then its continuations and the two scan_busy continuations proceed.
      try { await until(async () => (await metricsOf(h)).placed.callee.entered === enteredBefore + 1, 30000, 'the first engine to answer'); }
      catch (error) { throw Error(`${error.message}: callee ${JSON.stringify((await metricsOf(h)).placed.callee)}`); }
      behavior.delete(urlF); behavior.set(urlF, now => v2(now));
      await h.invoke('clock', '61'); await h.drain(); await h.invoke('clock', '0');
      assert.equal((await h.first('SELECT observation_generation FROM n_feed WHERE feed_id=?', F)).observation_generation, 2, 'the first delivery\'s observation committed');
      assert.equal((await h.first('SELECT observation_generation FROM n_feed WHERE feed_id=?', G)).observation_generation, 1, 'the unrelated feed proceeded');
      assert.equal((await h.first('SELECT COUNT(*) AS n FROM n_episode_release WHERE feed_id=?', F)).n, 5, 'the first delivery\'s work committed once');
      // The old caller's direction of a version skew: an adapter at share 0 never calls the binding.
      const skew = keep(await h.consume(wake('0' + hex64().slice(1)), { replica: 7 }));
      assert.deepEqual([skew.route, skew.hops.length, skew.decision], ['in_process', 0, 'ack'], JSON.stringify(skew));
    });

    await test(9, '(b) a caller and callee holding different keys: the unmarked 404 is retried, then delivered', async () => {
      const S = await h.add('https://placed-skew.example.com/feed');
      const w = await wakeOf(h, S);
      const skewed = keep(await h.consume(w, { replica: 4 }));
      assert.deepEqual([skewed.route, skewed.status, skewed.hops[0]?.engine, skewed.hops[0]?.key.present, skewed.decision], ['placed', 404, false, true, 'retry'], `the skew: ${JSON.stringify(skewed)}`);
      assert.equal((await h.first('SELECT observation_generation FROM n_feed WHERE feed_id=?', S)).observation_generation, 0, 'nothing ran');
      const delivered = keep(await h.consume(w, { replica: 5, attempts: 2 }));
      assert.deepEqual([delivered.route, delivered.status, delivered.hops[0]?.engine, delivered.decision], ['placed', 200, true, 'ack'], `then delivered: ${JSON.stringify(delivered)}`);
      await h.drain();
      assert.equal((await h.first('SELECT observation_generation FROM n_feed WHERE feed_id=?', S)).observation_generation, 1, 'the delivered baseline');
    });
  } finally { await closeHarness(h, 8); }
}

// ---- Case 3: the same fixtures through the shipped queue() at share 256 (H2) and share 0 (H3).
if (selected(3)) {
  async function scenario(share) {
    let version = 1;
    const h = await harness(request => (version === 1 ? v1 : v2)(h.now, request), { logs: true, replicas: 2, placed: { share, allowZero: share === '0', bindings: { 1: { NOTIFICATION_FEED_OBSERVATION: 'false' } } } });
    const log = [];
    try {
      const A = await h.add('https://equivalence.example.com/a');
      const firstWake = await wakeOf(h, A);
      const r0 = await h.consume(firstWake); log.push({ label: 'baseline', outcome: r0.outcome, status: r0.status, decision: r0.decision, route: r0.route });
      await drainRecorded(h, log, 'baseline-continuations');
      await due(h, A); await h.invoke('test/dispatch'); await drainRecorded(h, log, 'unchanged');
      version = 2; await due(h, A); await h.invoke('test/dispatch'); await drainRecorded(h, log, 'changed'); await h.deliver(true);
      const old = await h.consume(firstWake); log.push({ label: 'obsolete', outcome: old.outcome, status: old.status, decision: old.decision, route: old.route });
      const bad = await h.consume({ ...firstWake, schema_version: 99 }); log.push({ label: 'invalid', status: bad.status, decision: bad.decision, route: bad.route });
      await due(h, A); const braked = await wakeOf(h, A);
      const b = await h.consume(braked, { replica: 1 }); log.push({ label: 'brake', status: b.status, decision: b.decision, route: b.route, polling_disabled: b.text.includes('polling_disabled') });
      const after = await h.consume(braked, { attempts: 2 }); log.push({ label: 'after-brake', outcome: after.outcome, decision: after.decision, route: after.route });
      await drainRecorded(h, log, 'after-brake-continuations');
      // scan_busy: B's changed scan holds both permits on a hung R2 read; behind a stalled owner C is refused at once.
      const B = await h.add('https://equivalence.example.com/b');
      version = 1; await h.consume(await wakeOnly(h, B)); await drainRecorded(h, log, 'b-baseline');
      version = 2; await due(h, B); const bWake = await wakeOnly(h, B);
      await h.invoke('fault', 'hang_get');
      const hung = h.consume(bWake);
      await until(async () => (await h.invoke('test/stats')).active_permits === 2 && (await h.invoke('fault-state')) === 'hang_get_active', 15000, 'the hung read');
      await h.invoke('clock', '100');
      const C = await h.add('https://equivalence.example.com/c'); const cWake = await wakeOnly(h, C);
      const busy = await h.consume(cWake); log.push({ label: 'scan_busy', outcome: busy.outcome, decision: busy.decision, route: busy.route });
      await h.invoke('release-hang'); const hb = await hung; log.push({ label: 'hung-b', outcome: hb.outcome, decision: hb.decision, route: hb.route });
      await h.invoke('clock', '200'); await drainRecorded(h, log, 'continuations'); await h.invoke('clock', '0');
      // A dead-lettered message: the shipped queue()'s dead-letter branch, in process at every share.
      const D = await h.add('https://equivalence.example.com/d'); const dWake = await wakeOnly(h, D);
      const dl = await h.consume(dWake, { queue: 'isolated-poll-dlq' }); log.push({ label: 'dead-letter', decision: dl.decision, route: dl.route });
      // Every row of the tables a delivery writes, and every posted payload, normalized (times, UUIDs and leases
      // differ between two runs by construction) and sorted.
      const db = { posted: normalized(h.events), sends: h.sends.length };
      for (const table of ['n_feed', 'n_observation', 'n_outbox', 'n_event', 'n_episode_release', 'n_poll_origin']) db[table] = normalized(await h.rows(`SELECT * FROM ${table}`));
      keep(log);
      return { log, db, h };
    } catch (error) { await closeHarness(h, 2); throw error; }
  }
  await test(3, 'equivalence through the shipped queue(): share 256 against share 0 on the same fixtures', async () => {
    const placedRun = await scenario('256'); let inProcess;
    try { inProcess = await scenario('0'); } finally { await closeHarness(placedRun.h, 2); }
    await closeHarness(inProcess.h, 2);
    const strip = log => log.map(({ route, ...rest }) => rest);
    console.log(`  share 256: ${JSON.stringify(placedRun.log.map(x => `${x.label}:${x.outcome ?? x.status}:${x.decision}:${x.route}`))}`);
    console.log(`  share 0:   ${JSON.stringify(inProcess.log.map(x => `${x.label}:${x.outcome ?? x.status}:${x.decision}:${x.route}`))}`);
    assert.deepEqual(strip(placedRun.log), strip(inProcess.log), 'the same deliveries, outcomes and decisions');
    for (const key of Object.keys(placedRun.db)) {
      const [x, y] = [placedRun.db[key], inProcess.db[key]];
      if (Array.isArray(x)) { const onlyX = x.filter(r => !y.includes(r)), onlyY = y.filter(r => !x.includes(r)); const flat = (v, at = '') => v && typeof v === 'object' ? Object.entries(v).flatMap(([k, w]) => flat(w, at ? `${at}.${k}` : k)) : [[at, v]];
        const fields = (p, q) => { const [m, n] = [Object.fromEntries(flat(JSON.parse(p ?? '{}'))), Object.fromEntries(flat(JSON.parse(q ?? '{}')))]; return [...new Set([...Object.keys(m), ...Object.keys(n)])].filter(k => JSON.stringify(m[k]) !== JSON.stringify(n[k])).map(k => `${k}: ${JSON.stringify(m[k])} / ${JSON.stringify(n[k])}`); };
        assert.deepEqual(x, y, `the same ${key}: ${x.length} against ${y.length}; ${onlyX.length} rows only at 256, ${onlyY.length} only at 0; first pair differs in ${JSON.stringify(fields(onlyX[0], onlyY[0]))}`); }
      else assert.deepEqual(x, y, `the same ${key}`);
    }
    const touched = [...SCRUBBED.uuid, ...SCRUBBED.json];
    console.log(`  normalization touched: uuid ${JSON.stringify([...SCRUBBED.uuid])}, json ${JSON.stringify([...SCRUBBED.json])}`);
    assert.deepEqual(touched.filter(k => CONTENT.test(k)), [], 'the normalization touched a content field');
    assert.ok(placedRun.db.posted.length > 0 && placedRun.db.n_event.length > 0, `the changed fixture published events: ${placedRun.db.posted.length} posted, ${placedRun.db.n_event.length} stored`);
    console.log(`  compared: ${Object.entries(placedRun.db).map(([k, v]) => `${k} ${Array.isArray(v) ? v.length : v}`).join(', ')}`);
    for (const x of placedRun.log) assert.equal(x.route, x.label === 'dead-letter' ? 'in_process' : 'placed', `share 256, ${x.label}: ${x.route}`);
    for (const x of inProcess.log) assert.equal(x.route, 'in_process', `share 0, ${x.label}`);
    const find = (log, label) => log.find(x => x.label === label);
    assert.deepEqual([find(placedRun.log, 'invalid').status, find(placedRun.log, 'invalid').decision], [400, 'ack'], 'the invalid wake: 400, acknowledged once');
    assert.deepEqual([find(placedRun.log, 'brake').status, find(placedRun.log, 'brake').decision, find(placedRun.log, 'brake').polling_disabled], [503, 'retry', true], 'the brake: 503, retried');
    assert.equal(find(placedRun.log, 'scan_busy').outcome, 'scan_busy');
    assert.equal(find(placedRun.log, 'obsolete').outcome, 'obsolete');
  });
}

// ---- H4: share 32. P's id begins 00-1f (placed, cohort); Q's 20-3f (in process, cohort).
if (selected(8) || selected(9)) {
  const urlP = urlFor(/^[01]/, 'p'), urlQ = urlFor(/^[23]/, 'q');
  // Each URL's current body: v1, v2 (five new items) or, for case 9, v2 plus five more.
  const body = new Map();
  const v3 = now => new Response(rss([item('base', now - 100), ...Array.from({ length: 5 }, (_, i) => item(`new-${i}`, now - 10 + i)), ...Array.from({ length: 5 }, (_, i) => item(`more-${i}`, now - 5 + i))]), { headers: { etag: '"v3"' } });
  const h = await harness(request => (body.get(request.url) ?? v1)(h.now, request), { logs: true, placed: { share: '32' } });
  KEYS.add(h.placed.key);
  const P = hash(['feed-v1', urlP]), Q = hash(['feed-v1', urlQ]);
  try {
    await test(8, 'mixed routes at share 32: each feed keeps its route; three lines joined by a token; equal chains stay apart', async () => {
      await h.add(urlP); await h.add(urlQ);
      const log = []; await h.invoke('test/dispatch'); await drainRecorded(h, log, 'baseline');
      body.set(urlP, v2); body.set(urlQ, v2); await due(h, P); await due(h, Q);
      await h.invoke('test/dispatch'); await drainRecorded(h, log, 'changed'); await h.deliver(true);
      // Continuations: a third feed R (in process) holds both permits on a hung R2 read; behind that stalled owner
      // P and Q are refused scan_busy at once with a continuation each (step 1), delivered after the release.
      const urlR = urlFor(/^[4-9a-f]/, 'r'), R = await h.add(urlR);
      await h.consume(await wakeOf(h, R)); await h.drain();
      body.set(urlR, v2); await due(h, R); const rWake = await wakeOf(h, R);
      await h.invoke('fault', 'hang_get');
      const hung = h.consume(rWake);
      await until(async () => (await h.invoke('test/stats')).active_permits === 2 && (await h.invoke('fault-state')) === 'hang_get_active', 15000, 'the hung read');
      await h.invoke('clock', '100');
      await due(h, P); await due(h, Q); await h.invoke('test/dispatch');
      await drainRecorded(h, log, 'refused');
      await h.invoke('release-hang'); await hung;
      await h.invoke('clock', '200'); await drainRecorded(h, log, 'continuation'); await h.invoke('clock', '0');
      for (const f of [P, Q]) assert.ok(log.some(x => x.feed === f && x.label === 'refused' && x.outcome === 'scan_busy') && log.some(x => x.feed === f && x.step > 0), `a scan_busy continuation of ${f.slice(0, 4)}: ${JSON.stringify(log.filter(x => x.feed === f))}`);
      keep(log);
      const steps = {}; for (const x of log) steps[`${x.feed === P ? 'P' : 'Q'}:step${x.step}`] = (steps[`${x.feed === P ? 'P' : 'Q'}:step${x.step}`] ?? 0) + 1;
      console.log(`  deliveries ${JSON.stringify(steps)}`);
      for (const x of log.filter(x => x.feed === P || x.feed === Q)) assert.equal(x.route, x.feed === P ? 'placed' : 'in_process', `${x.label} ${x.feed.slice(0, 4)} step ${x.step}: ${x.route}`);
      assert.ok(log.filter(x => x.feed === P).length >= 2 && log.filter(x => x.feed === Q).length >= 2);
      // Two messages with the same feed, generation, step and attempts, apart by their tokens.
      await due(h, P); const pw = await wakeOf(h, P);
      const from = h.raw.length;
      const a = keep(await h.consume(pw, { headers: { 'x-poll-message-id': 'message-a' } }));
      const b = keep(await h.consume(pw, { headers: { 'x-poll-message-id': 'message-b' } }));
      await drainRecorded(h, log, 'after-pair');
      const lines = h.raw.map((x, i) => { try { return { i, ...JSON.parse(x.message) }; } catch { return null; } }).filter(Boolean);
      const of = (event, from = 0) => lines.filter(l => l.event === event && l.i >= from);
      // Every placed delivery of P: poll_hop_start < poll_placed < its storage_phases row < poll_hop, one token.
      const starts = of('poll_hop_start');
      assert.ok(starts.length >= log.filter(x => x.feed === P).length, `poll_hop_start lines ${starts.length}`);
      for (const s of starts) {
        assert.equal(s.feed, P, 'a hop line for an in-process feed');
        assert.match(s.hop, /^[0-9a-f]{16}$/);
        const placedLine = lines.find(l => l.event === 'poll_placed' && l.hop === s.hop), end = lines.find(l => l.event === 'poll_hop' && l.hop === s.hop);
        assert.ok(placedLine && end, `token ${s.hop}: poll_placed ${!!placedLine}, poll_hop ${!!end}`);
        const row = lines.find(l => l.event === 'storage_phases' && l.handler === 'consume' && l.i > placedLine.i && l.i < end.i && l.chain?.feed === P);
        assert.ok(s.i < placedLine.i && row && row.i < end.i, `token ${s.hop}: the row between poll_placed and poll_hop`);
        // The same invocation: poll_placed written while exactly one callee was in flight, and a consume witness
        // row for P written while that same one, and only it, was in flight.
        const identified = (await metricsOf(h)).placed.lines, mark = identified.find(l => l.event === 'poll_placed' && l.hop === s.hop);
        assert.ok(mark && mark.inflight.length === 1, `token ${s.hop}: poll_placed's invocation: ${JSON.stringify(mark)}`);
        assert.ok(identified.some(l => l.event === 'storage_phases' && l.feed === P && l.inflight.length === 1 && l.inflight[0] === mark.inflight[0]), `token ${s.hop}: no witness row of invocation ${mark.inflight[0]}`);
        for (const k of ['feed', 'generation', 'step', 'attempts']) assert.equal(String(row.chain[k]), String(end[k]), `token ${s.hop}: ${k}`);
        assert.equal(row.chain.message_digest ?? null, null, 'a placed row carries no message digest');
        assert.deepEqual([end.engine, end.status], [true, 200]);
        assert.equal(s.message, end.message);
      }
      const pairStarts = of('poll_hop_start', from).slice(0, 2);
      assert.equal(pairStarts.length, 2);
      assert.deepEqual(pairStarts.map(s => s.message), [sha16('message-a'), sha16('message-b')]);
      assert.notEqual(pairStarts[0].hop, pairStarts[1].hop, 'two messages, one token');
      for (const k of ['feed', 'generation', 'step', 'attempts']) assert.equal(pairStarts[0][k], pairStarts[1][k], `the pair shares ${k}`);
      // Q: no hop line, and its rows carry the digest of the message id the in-process route passes.
      await due(h, Q); const qw = await wakeOnly(h, Q);
      const qFrom = h.raw.length;
      const q = keep(await h.consume(qw, { headers: { 'x-poll-message-id': 'message-q' } }));
      assert.deepEqual([q.route, q.decision], ['in_process', 'ack']);
      await drainRecorded(h, log, 'after-q');
      const qLines = h.raw.slice(qFrom).map(x => { try { return JSON.parse(x.message); } catch { return null; } }).filter(Boolean);
      assert.deepEqual(qLines.filter(l => /^poll_hop|^poll_placed/.test(l.event)), [], 'a hop line for the in-process feed');
      const qRow = qLines.find(l => l.event === 'storage_phases' && l.handler === 'consume' && l.chain?.feed === Q);
      assert.equal(qRow?.chain.message_digest, sha16('message-q'), 'the in-process row carries the digest of its message id');
      const qRows = lines.filter(l => l.event === 'storage_phases' && l.handler === 'consume' && l.chain?.feed === Q);
      assert.ok(qRows.length >= 2 && qRows.every(row => /^[0-9a-f]{16}$/.test(row.chain.message_digest ?? '')), 'every in-process row carries a digest');
      // x-poll-hop never reaches Rust.
      const rust = (await metricsOf(h)).placed.rust.recent.filter(e => e.path === '/consume');
      assert.ok(rust.length > 0 && rust.every(e => !e.hop && !e.header_names.includes('x-poll-hop')), 'x-poll-hop reached Rust');
      assert.ok([a, b].every(r => r.route === 'placed' && r.decision === 'ack'));
    });

    await test(9, '(a) FeedEvents posts refused from the third on, on both routes: the consume holds, a later delivery posts them, once each', async () => {
      for (const [name, feed, url, route] of [['placed', P, urlP, 'placed'], ['in process', Q, urlQ, 'in_process']]) {
        if (!(await h.first('SELECT feed_id FROM n_feed WHERE feed_id=?', feed))) { await h.add(url); await h.invoke('test/dispatch'); await drainRecorded(h, [], 'baseline'); }
        const releases = (await h.first('SELECT COUNT(*) AS n FROM n_episode_release WHERE feed_id=?', feed)).n;
        // New items beyond what is stored (five or more): one delivery with as many outboxes.
        body.set(url, v3);
        const witnessFrom = (await metricsOf(h)).hooks.service.length;
        await post(h, 'test/refuse-events', { from: 3, count: 3 });
        const eventsBefore = h.events.length;
        await due(h, feed);
        const log = []; await h.invoke('test/dispatch'); await drainRecorded(h, log, `refused-${name}`);
        keep(log);
        // Another feed the dispatcher found due may be delivered in the same drain; the claim is about this feed.
        const mine = log.filter(x => x.feed === feed);
        assert.ok(mine.length > 0 && mine.every(x => x.route === route && x.decision === 'ack' && x.outcome !== 'failed'), `${name}: ${JSON.stringify(log)}`);
        const refused = (await metricsOf(h)).hooks.service.slice(witnessFrom).filter(s => s.hook === 'refuse_events');
        assert.deepEqual(refused.map(s => s.k), [3, 4, 5], `${name}: posts 3 to 5 refused: ${JSON.stringify(refused)}`);
        const pending = await h.rows("SELECT event_id,next_attempt_at FROM n_outbox WHERE state='pending'");
        assert.equal(pending.length, 3, `${name}: the refused outboxes are scheduled for retry`);
        await post(h, 'test/refuse-events', '');
        await h.run("UPDATE n_outbox SET next_attempt_at=0 WHERE state='pending'");
        const later = []; await h.invoke('test/dispatch'); await drainRecorded(h, later, `later-${name}`); await h.deliver(true);
        const laterMine = later.filter(x => x.feed === feed);
        assert.ok(laterMine.length > 0 && laterMine.every(x => x.route === route), `${name}: a later delivery on the same route: ${JSON.stringify(later)}`);
        assert.equal((await h.first("SELECT COUNT(*) AS n FROM n_outbox WHERE state='pending'")).n, 0, `${name}: every outbox posted`);
        const ids = h.events.slice(eventsBefore).map(e => e.event_id ?? e.id ?? JSON.stringify(e));
        assert.equal(new Set(ids).size, ids.length, `${name}: an event arrived twice`);
        const added = (await h.first('SELECT COUNT(*) AS n FROM n_episode_release WHERE feed_id=?', feed)).n - releases;
        assert.ok(added >= 5, `${name}: ${added} new releases`);
        assert.equal(ids.length, added, `${name}: every new event arrived once`);
      }
    });
  } finally { await closeHarness(h, 1); }
}

// ---- H5: the real local Queue, share 256: a rejected hop, a rejected body read, the 230 s bound.
if (selected(5) || selected(7)) {
  const h = await harness(request => v1(h.now, request), { logs: true, realQueues: true, retryDelay: 1, placed: { share: '256' } });
  KEYS.add(h.placed.key);
  const settled = async feed => until(async () => (await h.first('SELECT dispatch_until,observation_generation FROM n_feed WHERE feed_id=?', feed)).observation_generation >= 1 && (await h.first('SELECT dispatch_until FROM n_feed WHERE feed_id=?', feed)).dispatch_until === 0, 30000, 'the real Queue to settle');
  // Only the feed under test may be admitted: a feed settled earlier in this harness is due again within seconds when its
  // fixed grid point follows the settle within the dispatcher's 30 s look-ahead (policy.rs next_due; dispatch.rs SCAN_DUE).
  const only = feed => h.run('UPDATE n_feed SET admission_paused=CASE WHEN feed_id=? THEN 0 ELSE 1 END', feed);
  // Nothing of this harness in flight before the next mode or case: every admitted delivery has settled.
  const quiet = () => until(async () => Number((await h.first('SELECT COUNT(*) AS n FROM n_feed WHERE dispatch_until>0')).n) === 0, 30000, 'no delivery in flight');
  try {
    // The message's batches on the real Queue (hooks.batches), its hops and the engine's entries since t0.
    const since = async (t0, feed) => {
      const m = keep(await metricsOf(h));
      const hops = m.placed.hops.filter(x => x.at >= t0);
      const batches = m.hooks.batches.filter(b => b.queue === 'isolated-poll' && b.at >= t0);
      const ids = new Set(batches.map(b => b.messages[0].id));
      return { m, hops, batches, ids, rust: m.placed.rust.recent.filter(e => e.path === '/consume' && e.at >= t0) };
    };
    await test(5, 'a rejected binding fetch and a rejected body read: queue() throws, the Queue redelivers (attempts 2), no in-process run', async () => {
      for (const [mode, error] of [['reject', /TypeError: fixture:placed_binding_rejected/], ['body_reject', null]]) {
        const feed = await h.add(`https://placed-${mode}.example.com/feed`);
        await only(feed);
        const t0 = Date.now();
        await post(h, 'test/placed-stub', { mode, times: 1 });
        try { await h.invoke('test/dispatch'); await settled(feed); } finally { await post(h, 'test/placed-stub', ''); }
        // The database settles before the caller's hop record is completed: wait for every hop to settle.
        await until(async () => (await since(t0)).hops.every(x => x.settled !== null), 10000, 'the hops to settle');
        await quiet();
        const { hops, batches, ids, rust, m } = await since(t0, feed);
        assert.deepEqual([...new Set(hops.map(x => x.feed))], [feed], `a delivery of another feed: ${JSON.stringify(hops.map(x => [x.feed?.slice(0, 6), x.attempts, x.stub]))}`);
        assert.equal(hops[0]?.stub, mode, `the delivery never reached the binding: ${JSON.stringify(hops)}`);
        // reject: the binding's fetch rejected; body_reject: the response arrived (200, marked) and the adapter's
        // own body read rejected. Either way queue() threw: the adapter asked for no retry().
        if (mode === 'reject') assert.match(hops[0].error ?? '', error);
        else assert.deepEqual([hops[0].status, hops[0].engine, hops[0].error], [200, true, null], JSON.stringify(hops[0]));
        assert.equal(m.hooks.retries.filter(r => ids.has(r.id)).length, 0, `the adapter asked for a retry instead of throwing: ${JSON.stringify(m.hooks.retries)}`);
        assert.equal(ids.size, 1, `one message: ${JSON.stringify(batches)}`);
        assert.deepEqual(batches.map(b => b.messages[0].attempts), [1, 2], `the Queue redelivered with attempts 2: ${JSON.stringify(batches)}`);
        assert.deepEqual([hops.length, hops[1]?.status, hops[1]?.engine], [2, 200, true], `the redelivery reached the engine: ${JSON.stringify(hops.map(x => [x.feed?.slice(0, 6), x.attempts, x.stub, x.status, x.engine, x.error]))}`);
        assert.equal(rust.length, 1, `one engine entry for the two attempts: ${JSON.stringify(rust.map(e => e.at))}`);
        assert.ok(rust[0].at >= hops[1].at, 'the engine entry is the redelivery\'s, none for the rejected attempt');
        assert.equal(m.placed.rust.recent.filter(e => ids.has(e.message_id)).length, 0, 'an in-process run of the message');
      }
    });

    await test(7, 'the 230 s bound in real time: a binding that never answers rejects between 230 and 240 s; the Queue redelivers', async () => {
      const feed = await h.add('https://placed-never.example.com/feed');
      await quiet();
      await only(feed);
      const t0 = Date.now();
      await post(h, 'test/placed-stub', { mode: 'never', times: 1 });
      try {
        await h.invoke('test/dispatch');
        const done = async () => (await h.first('SELECT dispatch_until,observation_generation FROM n_feed WHERE feed_id=?', feed)).dispatch_until === 0;
        await until(async () => (await since(t0)).hops.length > 0 || await done(), 30000, 'the hop or the settle');
        const { hops } = await since(t0);
        assert.equal(hops[0]?.stub, 'never', 'the delivery never reached the binding');
        await until(async () => (await since(t0)).hops[0].settled, 250000, 'the 230 s bound');
        await settled(feed);
        await until(async () => (await since(t0)).hops.every(x => x.settled !== null), 10000, 'the hops to settle');
      } finally { await post(h, 'test/placed-stub', ''); }
      const { hops, batches, ids, rust, m } = await since(t0);
      assert.deepEqual([...new Set(hops.map(x => x.feed))], [feed], `a delivery of another feed: ${JSON.stringify(hops.map(x => [x.feed?.slice(0, 6), x.attempts, x.stub]))}`);
      const hop = hops[0], elapsed = hop.settled - hop.at;
      console.log(`  the never-answered hop rejected after ${elapsed} ms: ${hop.error}`);
      assert.ok(elapsed >= 230000 && elapsed < 240000, `elapsed ${elapsed}`);
      assert.match(hop.error, /TimeoutError|AbortError|timed out|abort/i);
      assert.equal(m.hooks.retries.filter(r => ids.has(r.id)).length, 0, `the adapter asked for a retry instead of throwing: ${JSON.stringify(m.hooks.retries)}`);
      assert.equal(ids.size, 1, `one message: ${JSON.stringify(batches)}`);
      assert.deepEqual(batches.map(b => b.messages[0].attempts), [1, 2], `redelivered: ${JSON.stringify(batches)}`);
      assert.deepEqual([hops[1]?.status, hops[1]?.engine], [200, true], 'the redelivery reached the engine');
      assert.equal(rust.length, 1, `one engine entry for the two attempts: ${JSON.stringify(rust.map(e => e.at))}`);
      assert.ok(rust[0].at >= hops[1].at, 'the engine entry is the redelivery\'s, none for the never-answered attempt');
      assert.equal(m.placed.rust.recent.filter(e => ids.has(e.message_id)).length, 0, 'an in-process run of the message');
    });
  } finally { await closeHarness(h, 1); }
}

// ---- 2b: the key in no log line, witness row, response, error text, outbound request or Rust-readable binding.
// It runs after whatever cases were selected, and fails on an empty corpus.
await test('2b', 'the key appears nowhere in the run', async () => {
  assert.ok(harnessesClosed > 0 && TEXTS.length > 0, `an empty corpus: ${harnessesClosed} harnesses, ${TEXTS.length} records`);
  assert.deepEqual(KEYLEAKS, [], `the key leaked: ${KEYLEAKS.join('; ')}`);
  const all = TEXTS.join('\n'), keys = [...KEYS].filter(key => key.length >= 16);
  keys.forEach((key, i) => assert.ok(!all.includes(key), `key #${i + 1} of ${keys.length} appears in the run's output`));
  console.log(`  callees: completed ${CALLEES.completed}, refused ${CALLEES.refused}, failed ${CALLEES.failed}, pending ${CALLEES.pending}`);
  console.log(`  ${KEYS.size} keys checked against ${TEXTS.length} records (${all.length} characters)`);
});

const failed = results.filter(r => !r.ok);
console.log(`PLACED-CONSUME summary pass=${results.length - failed.length} fail=${failed.length}${failed.length ? ` failed=${failed.map(r => r.n).join(',')}` : ''}`);
if (failed.length) process.exitCode = 1;
