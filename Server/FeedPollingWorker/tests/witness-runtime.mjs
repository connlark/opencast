// The storage timing witness's runtime controls: each case runs the shipped
// FeedPolling Worker on its own PostgreSQL clone through the wire proxy and
// reads the invocation's one `storage_phases` line from the Worker's logs,
// asserting it against the proxy's own witness of the same operations.
import assert from 'node:assert/strict';
import { writeFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { setTimeout as sleep } from 'node:timers/promises';
import { harness, hash, item, rss } from './harness.mjs';
import { POLLING_FIXTURE, stopAfter } from './action-boundary.mjs';

let passed = 0, failed = 0;
const report = [];
// WITNESS_CASES=rollup-hold,cold-connect runs only the cases whose names start with those names.
const only = process.env.WITNESS_CASES?.split(',');
async function test(name, run) {
  if (only && !only.some(id => name.startsWith(id))) return;
  try { await run(); passed++; console.log(`PASS ${name}`); }
  catch (error) {
    failed++;
    // A body failure first; a teardown failure it caused is listed after it.
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
// The storage_phases lines of `handler` logged after `from`.
const lines = (h, handler, from = 0) => h.logs.slice(from).filter(e => e.event === 'storage_phases' && e.handler === handler);
async function line(h, handler, from) {
  for (let i = 0; i < 200; i++) { const found = lines(h, handler, from); if (found.length) return found.at(-1); await sleep(10); }
  throw Error(`no storage_phases line for ${handler}`);
}
// Every line any case logged, for the parser's round trip.
const rows = [];
const keep = h => rows.push(...h.logs.filter(e => e.event === 'storage_phases' || e.event === 'storage_phases_overflow'));

await test('scheduled-lag: scheduled_lag_ms from the private header on dispatch and cleanup; null without it, malformed, on consume; the public path stays 404', async () => {
  const h = await harness(() => new Response(rss([item('scheduled-lag', Math.floor(Date.now() / 1000) - 100)]), { headers: { etag: '"scheduled-lag"' } }), { logs: true });
  try {
    await h.invoke('freeze', String(h.now));
    let from = h.logs.length;
    await h.invoke('test/dispatch', {}, { 'x-poll-scheduled-ms': String(h.now * 1000 - 7000) });
    const lagged = await line(h, 'dispatch', from);
    assert.ok(lagged.scheduled_lag_ms >= 7000 && lagged.scheduled_lag_ms <= 7500, `lag ${lagged.scheduled_lag_ms}`);
    for (const header of [undefined, 'abc', '', '-5', '9'.repeat(20)]) {
      from = h.logs.length;
      await h.invoke('test/dispatch', {}, header === undefined ? {} : { 'x-poll-scheduled-ms': header });
      assert.equal((await line(h, 'dispatch', from)).scheduled_lag_ms, null, `header ${JSON.stringify(header)}`);
    }
    // The shipped adapter forwards the cron's scheduledTime itself.
    from = h.logs.length;
    const worker = await h.instance.getWorker('polling-runtime');
    await worker.scheduled({ cron: '*/2 * * * *', scheduledTime: new Date(h.now * 1000 - 3000) });
    const cleanup = await line(h, 'cleanup', from);
    assert.ok(cleanup.scheduled_lag_ms >= 3000 && cleanup.scheduled_lag_ms <= 3500, `cron lag ${cleanup.scheduled_lag_ms}`);
    // A consume never carries a lag, even with the header forged on it.
    const feed = await h.add('https://witness.example.com/scheduled-lag');
    await h.invoke('test/dispatch');
    const wake = (await h.polls()).find(w => w.feed_id === feed);
    from = h.logs.length;
    await h.consume(wake, { headers: { 'x-poll-scheduled-ms': '1' } });
    assert.equal((await line(h, 'consume', from)).scheduled_lag_ms, null);
    // The public path: 404, and no line.
    from = h.logs.length;
    const response = await h.instance.dispatchFetch('https://polling.invalid/dispatch', { method: 'POST', headers: { 'x-poll-scheduled-ms': '1' } });
    assert.equal(response.status, 404); await response.text();
    await sleep(100);
    assert.equal(lines(h, 'dispatch', from).length, 0, 'a public request writes no line');
    keep(h);
  } finally { await h.close(); }
});

await test('dispatch-hold: a dispatch tick with a 2,500 ms hold on its first WITH live AS read: ops.total is the proxy\'s operation count and the held read is that ordinal, its race spans the hold, slowest[0]', async () => {
  const h = await harness(() => new Response(rss([item('dispatch-hold', Math.floor(Date.now() / 1000) - 100)])), { logs: true });
  try {
    const ts = h.storage.testStorage('polling-runtime');
    for (const name of ['repair', 'recurring', 'baseline']) await h.add(`https://witness.example.com/dispatch-hold-${name}`);
    await h.invoke('test/dispatch'); await h.drain();
    await h.run('UPDATE n_feed SET due_at=0,dispatch_until=0');
    const before = ts({ op: 'witness' }).operations.length, from = h.logs.length;
    const arm = ts({ op: 'arm', kind: 'statement', action: 'hold-response', match: 'WITH live AS', release_after_ms: 2500 });
    await h.invoke('test/dispatch');
    const row = await line(h, 'dispatch', from);
    const w = ts({ op: 'witness' }), mine = w.operations.slice(before);
    const fire = w.fires.find(f => f.arming === arm.arming);
    assert.ok(fire, 'the hold fired');
    const held = mine.findIndex(o => o.id === fire.op) + 1;
    assert.equal(row.ops.total, mine.length, `ops.total ${row.ops.total} vs the proxy's ${mine.length} operations`);
    assert.equal(row.primary, null);
    const entry = row.op.find(o => o.ordinal === held);
    assert.ok(entry, `the held operation ${held} is detailed: ${JSON.stringify(row.op.map(o => o.ordinal))}`);
    const read = entry.race.find(r => r.boundary === 'read');
    const span = read.end_ms - read.start_ms;
    assert.ok(span >= 2500 && span <= read.budget_ms, `read span ${span}, budget ${read.budget_ms}`);
    assert.equal(row.slowest[0].ordinal, held);
    ts({ op: 'expect', fire: fire.id, outcome: 'released' });
    report.push(`dispatch-hold: ops.total ${row.ops.total} = proxy ${mine.length}; held ordinal ${held}, read span ${span} ms of budget ${read.budget_ms}`);
    keep(h);
  } finally { await h.close(); }
});

// A dispatch through the test route without the 200 assertion: a failing tick is the point.
async function tick(h, headers = {}) {
  const response = await h.instance.dispatchFetch('https://polling.invalid/test/dispatch', { method: 'POST', headers });
  return { status: response.status, text: await response.text() };
}
const ROLLUP = 'WITH f AS (SELECT f.due_at,f.snapshot_key';

for (const [label, action, forwarded] of [['(a)', 'hold-request', false], ['(b)', 'hold-response', true]]) {
  await test(`rollup-hold${label}: ${action} forever on the rollup read (A14): the public string unchanged; primary.race read, submitted, timed out at its budget; the wire ${forwarded ? 'forwarded' : 'did not forward'} it`, async () => {
    const h = await harness(() => new Response(rss([])), { logs: true });
    await within(h, async () => {
      const ts = h.storage.testStorage('polling-runtime');
      await h.add('https://witness.example.com/rollup-hold');
      const before = ts({ op: 'witness' }).operations.length, from = h.logs.length;
      const arm = ts({ op: 'arm', kind: 'statement', action: action === 'hold-request' ? 'hold-forever' : 'hold-response', match: ROLLUP, ...(action === 'hold-request' ? {} : {}) });
      const result = await tick(h);
      assert.equal(result.status, 500, result.text);
      const row = await line(h, 'dispatch', from);
      assert.equal(row.outcome, 'failed');
      // The components of the unchanged public string storage_A14_Deadline_NotApplicable.
      assert.deepEqual([row.primary.op, row.primary.kind, row.primary.outcome], ['A14', 'Deadline', 'NotApplicable']);
      const race = row.primary.race;
      assert.deepEqual([row.primary.op, race.boundary, race.status, race.submitted], ['A14', 'read', 'timeout', true], JSON.stringify(row.primary));
      assert.ok(race.end_ms - race.start_ms >= race.budget_ms, `span ${race.end_ms - race.start_ms} >= budget ${race.budget_ms}`);
      const w = ts({ op: 'witness' }), fire = w.fires.find(f => f.arming === arm.arming), op = w.operations.find(o => o.id === fire.op);
      assert.equal(op.forwarded !== null, forwarded, `wire forwarded: ${JSON.stringify(op.forwarded)}`);
      assert.equal(row.primary.ordinal, w.operations.slice(before).findIndex(o => o.id === fire.op) + 1);
      for (let i = 0; i < 200 && !ts({ op: 'witness' }).operations.find(o => o.id === fire.op).close; i++) await sleep(10);
      ts({ op: 'expect', fire: fire.id, outcome: 'discarded' });
      report.push(`rollup-hold${label}: ${action}: A14 read span ${race.end_ms - race.start_ms} ms of budget ${race.budget_ms} (${race.limit}); forwarded ${op.forwarded !== null}`);
      keep(h);
    });
  });
}

// Consumes pending wakeups one at a time until `stop(outcome)` says so; returns the last outcome.
async function stepUntil(h, stop, limit = 50) {
  let last;
  for (let i = 0; i < limit; i++) {
    const [wake] = await h.polls();
    if (!wake) return last;
    last = await h.consume(wake);
    if (stop(last.outcome)) return last;
  }
  throw Error('the chain did not reach its stop');
}
// A feed URL whose opaque id falls in the provenance cohort (first hex nibble
// below 4), so each of its consumes writes a line: a delivery the loop carries
// on into an unchanged scan is otherwise only sampled.
const cohort = base => { for (let i = 0; ; i++) { const url = `${base}-${i}`; if (parseInt(hash(['feed-v1', url])[0], 16) < 4) return url; } };
// The same, one action per delivery (the loop stopped at its first boundary,
// a storage-fixture build): `stop` reads that action's result; returns the last.
async function stepActions(h, stop, limit = 50) {
  for (let i = 0; i < limit; i++) {
    const [wake] = await h.polls();
    if (!wake) break;
    const from = h.logs.length;
    const last = await stopAfter(h, wake, 1);
    last.result = (await line(h, 'consume', from)).action[0]?.result;
    if (stop(last.result)) return last;
  }
  throw Error('the chain did not reach its stop');
}

await test('drain-r2: the drain action carries its own R2 evidence: r2_calls 2 (manifest and page), r2_ms over a 1,500 ms key-scoped hold on the candidate page get', async () => {
  let items = [item('base', Math.floor(Date.now() / 1000) - 86_400)];
  const h = await harness(() => new Response(rss(items)), { logs: true, pollingBuild: POLLING_FIXTURE });
  await within(h, async () => {
    const feed = await h.add(cohort('https://witness.example.com/drain-r2'));
    await h.invoke('test/dispatch'); await h.drain();
    // A changed feed: three new recent episodes, then the chain up to its publication.
    const t = Math.floor(Date.now() / 1000);
    items = [item('n1', t - 60), item('n2', t - 50), item('n3', t - 40), ...items];
    await h.run('UPDATE n_feed SET due_at=0,retry_at=0,dispatch_until=0 WHERE feed_id=?', feed);
    await h.invoke('test/dispatch');
    const published = await stepActions(h, result => result === 'published');
    assert.equal(published?.result, 'published');
    const observation = await h.first("SELECT snapshot_key FROM n_observation WHERE feed_id=? AND state='published' AND drain_complete=0", feed);
    assert.ok(observation, 'a published, undrained observation');
    const bucket = await h.instance.getR2Bucket('FEED_SNAPSHOTS', 'polling-runtime');
    const manifest = JSON.parse(await (await bucket.get(observation.snapshot_key)).text());
    const page = manifest.candidate_pages[0].key;
    await h.invoke('fault', `slow_get:1500:${page}`);
    const from = h.logs.length;
    const [wake] = await h.polls();
    const drained = await h.consume(wake);
    assert.equal(drained.status, 200, drained.text);
    const row = await line(h, 'consume', from);
    const action = row.action.find(a => a.name === 'drain');
    assert.ok(action, `a drain action: ${JSON.stringify(row.action)}`);
    assert.equal(action.r2_calls, 2, JSON.stringify(action));
    assert.ok(action.r2_ms >= 1500, `r2_ms ${action.r2_ms}`);
    assert.equal(action.start_checkpoint?.kind, 'drain');
    assert.equal(action.end_checkpoint?.status, 'committed');
    report.push(`drain-r2: drain r2_calls ${action.r2_calls}, r2_ms ${action.r2_ms}; cursor ${action.start_checkpoint.candidate_cursor} -> ${action.end_checkpoint.candidate_cursor}`);
    keep(h);
  });
});

// The fire of `arming`, once the proxy has held its operation.
async function fired(ts, arming) {
  for (let i = 0; i < 1000; i++) { const f = ts({ op: 'witness' }).fires.find(x => x.arming === arming); if (f) return f; await sleep(10); }
  throw Error(`arming ${arming} never fired`);
}

await test('date-jump: a +20 s Date jump between two operations of a tick: the next operation STILL fails at entry, budget 0, unsubmitted; the line records the jump', async () => {
  const h = await harness(() => new Response(rss([])), { logs: true });
  await within(h, async () => {
    const ts = h.storage.testStorage('polling-runtime');
    await h.add('https://witness.example.com/date-jump');
    const from = h.logs.length;
    const arm = ts({ op: 'arm', kind: 'statement', action: 'hold-response', match: 'WITH live AS' });
    const running = tick(h);
    const fire = await fired(ts, arm.arming);
    await h.invoke('clock', '20');
    ts({ op: 'release', fire: fire.id });
    const result = await running;
    assert.equal(result.status, 500, result.text);
    const row = await line(h, 'dispatch', from);
    const race = row.primary.race;
    assert.deepEqual([row.primary.kind, race.boundary, race.limit, race.budget_ms, race.status, race.submitted],
      ['Deadline', 'connect', 'authority_deadline', 0, 'timeout', false], JSON.stringify(row.primary));
    assert.ok(row.date_vs_perf_ms >= 20_000, `date_vs_perf_ms ${row.date_vs_perf_ms}`);
    ts({ op: 'expect', fire: fire.id, outcome: 'released' });
    report.push(`date-jump: after the +20 s jump the next operation (${row.primary.op}, ordinal ${row.primary.ordinal}) failed at entry with budget 0; date_vs_perf_ms ${row.date_vs_perf_ms}`);
    keep(h);
  });
});

const RETIRE = 'DELETE FROM n_observation WHERE observation_id IN';
const RETIRE_READBACK = "SELECT 'n_observation' AS relation";
async function cleanup(h) {
  const response = await h.instance.dispatchFetch('https://polling.invalid/test/cleanup', { method: 'POST' });
  return { status: response.status, text: await response.text() };
}
// Every fire of the window that ended discarded, expected before teardown.
async function settle(ts, fires) {
  for (const fire of fires) {
    for (let i = 0; i < 300 && !ts({ op: 'witness' }).operations.find(o => o.id === fire.op)?.close; i++) await sleep(10);
    const state = ts({ op: 'witness' }).fires.find(f => f.id === fire.id);
    if (state?.discarded != null) ts({ op: 'expect', fire: fire.id, outcome: 'discarded' });
  }
}

for (const [label, action, failReadback] of [['(a)', 'drop-commit-ack', false], ['(b)', 'hold-commit-reply', false], ['(b) + a failed readback', 'hold-commit-reply', true]]) {
  await test(`retire-unknown${label}: ${action} on a cleanup tick's RetireObservations: the readback has its own guard and the unchanged storage_unknown_readback line${failReadback ? '; the initiating failure stays primary, the readback\'s is failures[0]' : ''}`, async () => {
    const h = await harness(() => new Response(rss([])), { logs: true });
    await within(h, async () => {
      const ts = h.storage.testStorage('polling-runtime');
      const from = h.logs.length, armings = [];
      armings.push(ts({ op: 'arm', kind: 'statement', action, match: RETIRE, ...(action === 'hold-commit-reply' ? { forever: true } : {}) }).arming);
      if (failReadback) armings.push(ts({ op: 'arm', kind: 'statement', action: 'close-before', match: RETIRE_READBACK }).arming);
      const result = await cleanup(h);
      assert.equal(result.status, 500, result.text);
      const row = await line(h, 'cleanup', from);
      const primary = row.primary, race = primary.race;
      assert.equal(primary.op, 'e_retire_observations');
      assert.deepEqual([primary.phase, primary.outcome], ['commit', 'Unknown'], JSON.stringify(primary));
      if (action === 'drop-commit-ack') {
        assert.deepEqual([primary.kind, race.status], ['Driver', 'driver'], JSON.stringify(race));
        assert.ok(race.end_ms - race.start_ms < race.budget_ms / 2, `a prompt failure: ${race.end_ms - race.start_ms} of ${race.budget_ms}`);
      } else {
        assert.deepEqual([primary.kind, race.status, race.submitted], ['Deadline', 'timeout', true], JSON.stringify(race));
        assert.equal(race.steps_completed, race.steps_total - 1, `all but COMMIT: ${race.steps_completed}/${race.steps_total}`);
        assert.ok(race.gate_reply_at_ms !== null, 'the gate reply time survived the failure');
        assert.ok(race.end_ms - race.start_ms >= race.budget_ms, `span ${race.end_ms - race.start_ms} >= ${race.budget_ms}`);
        // The CLOSE_MS signature of the test topology's held reply, a property
        // of its held-reply mechanism, not a production reply-matching claim:
        // the ROLLBACK cleanup's reply waits behind the held one for its whole
        // 500 ms. Recorded, never a witness defect.
        // The summary carries it whatever the detail cap kept.
        const rollbackMs = row.summary.rollback.sum_ms;
        assert.ok(rollbackMs >= 450 && rollbackMs <= 500 + 250, `rollback ${rollbackMs} ms`);
        const rollback = row.op.find(o => o.ordinal === primary.ordinal)?.race?.find(r => r.boundary === 'rollback');
        if (rollback) assert.equal(rollback.limit, 'close_ms');
        report.push(`retire-unknown${label} CLOSE_MS signature: rollback ${rollbackMs} ms after the held COMMIT reply (bytes_policy ${row.bytes_policy})`);
      }
      assert.ok(h.logs.slice(from).some(e => e.event === 'storage_unknown_readback' && e.operation === 'e_retire_observations'), 'the readback line is kept');
      assert.ok(row.ops.readbacks >= 1, `ops.readbacks ${row.ops.readbacks}`);
      const readback = row.op.find(o => o.role === 'readback');
      if (readback) assert.equal(readback.parent, primary.ordinal);
      if (failReadback) {
        assert.equal(row.failures[0]?.role, 'readback', JSON.stringify(row.failures));
        assert.equal(row.failures[0]?.parent, primary.ordinal);
      }
      // The readback's interval lies after the initiating one and inside durations.storage.
      assert.ok(row.durations.storage >= race.end_ms - race.start_ms, `storage ${row.durations.storage}`);
      const w = ts({ op: 'witness' });
      await settle(ts, w.fires.filter(f => armings.includes(f.arming)));
      report.push(`retire-unknown${label}: ${primary.kind}/${primary.phase}/${primary.outcome}, race ${race.status} ${race.end_ms - race.start_ms} ms of ${race.budget_ms}${race.steps_total ? `, steps ${race.steps_completed}/${race.steps_total}` : ''}; readbacks ${row.ops.readbacks}${failReadback ? `, failures[0] ${row.failures[0]?.op} ${row.failures[0]?.kind}` : ''}`);
      keep(h);
    });
  });
}

await test('cold-connect: a failed cold connect (startup-close), the identity gate ungated: one guard, role operation, one connect race, status driver', async () => {
  const h = await harness(() => new Response(rss([])), { logs: true });
  await within(h, async () => {
    const ts = h.storage.testStorage('polling-runtime');
    const from = h.logs.length;
    const arm = ts({ op: 'arm', kind: 'startup', action: 'startup-close' });
    const result = await tick(h);
    assert.equal(result.status, 500, result.text);
    const row = await line(h, 'dispatch', from);
    assert.equal(row.identity, 'ungated');
    assert.deepEqual([row.primary.role, row.primary.parent, row.primary.race.boundary, row.primary.race.status],
      ['operation', null, 'connect', 'driver'], JSON.stringify(row.primary));
    const entry = row.op.find(o => o.ordinal === row.primary.ordinal);
    assert.equal(entry.race.length, 1, JSON.stringify(entry.race));
    await settle(ts, ts({ op: 'witness' }).fires.filter(f => f.arming === arm.arming));
    keep(h);
  });
});

await test('identity-failure: an identity read failure on a cold cache: a guard of role identity whose parent is the operation it gates; the primary is that identity race, never the parent', async () => {
  const h = await harness(() => new Response(rss([])), { logs: true, alertSecrets: { STORAGE_IDENTITY: 'v1;development;postgres;pg:any_database' } });
  await within(h, async () => {
    const ts = h.storage.testStorage('polling-runtime');
    const from = h.logs.length;
    const arm = ts({ op: 'arm', kind: 'statement', action: 'fail-in-place', match: 'SELECT current_database()::text AS database' });
    const result = await tick(h);
    assert.equal(result.status, 500, result.text);
    const row = await line(h, 'dispatch', from);
    assert.equal(row.identity, 'unreadable');
    assert.equal(row.primary.role, 'identity', JSON.stringify(row.primary));
    assert.ok(row.primary.parent !== null && row.primary.parent < row.primary.ordinal, `parent ${row.primary.parent}`);
    assert.ok(['database', 'driver'].includes(row.primary.race?.status), JSON.stringify(row.primary.race));
    assert.ok(row.ops.identity >= 1);
    await settle(ts, ts({ op: 'witness' }).fires.filter(f => f.arming === arm.arming));
    report.push(`identity-failure: identity primary ordinal ${row.primary.ordinal} (parent ${row.primary.parent}), race ${row.primary.race.boundary} ${row.primary.race.status} ${row.primary.race.sqlstate ?? ''}`);
    keep(h);
  });
});

await test('cleanup-release-failure: a ReleaseCleanup failure after a cleanup primary: failures[] holds release_cleanup after the RetireObservations primary', async () => {
  const h = await harness(() => new Response(rss([])), { logs: true });
  await within(h, async () => {
    const ts = h.storage.testStorage('polling-runtime');
    const from = h.logs.length, armings = [];
    armings.push(ts({ op: 'arm', kind: 'statement', action: 'drop-commit-ack', match: RETIRE }).arming);
    armings.push(ts({ op: 'arm', kind: 'statement', action: 'close-before', match: 'UPDATE n_poll_dispatch SET cleanup_lease=NULL' }).arming);
    const result = await cleanup(h);
    assert.equal(result.status, 500, result.text);
    const row = await line(h, 'cleanup', from);
    assert.equal(row.primary.op, 'e_retire_observations');
    const release = row.failures.find(f => f.op === 'release_cleanup');
    assert.ok(release, `failures: ${JSON.stringify(row.failures.map(f => [f.op, f.kind]))}`);
    assert.ok(release.ordinal > row.primary.ordinal);
    await settle(ts, ts({ op: 'witness' }).fires.filter(f => armings.includes(f.arming)));
    keep(h);
  });
});

await test('bookkeeping-failure: a swallowed consume bookkeeping failure: failures[] holds A13 while poll_handling_failed reports bookkeeping_failed true', async () => {
  const h = await harness(() => new Response(rss([])), { logs: true });
  await within(h, async () => {
    const ts = h.storage.testStorage('polling-runtime');
    const feed = await h.add('https://witness.example.com/bookkeeping-failure');
    await h.invoke('test/dispatch');
    const [wake] = (await h.polls()).filter(w => w.feed_id === feed);
    const from = h.logs.length, before = ts({ op: 'witness' }).fires.length;
    await h.invoke('fault', 'hang_bookkeeping');
    const result = await h.consume(wake);
    assert.equal(result.status, 500, result.text);
    const failedLine = h.logs.slice(from).find(e => e.event === 'poll_handling_failed');
    assert.equal(failedLine?.bookkeeping_failed, true, JSON.stringify(failedLine));
    const row = await line(h, 'consume', from);
    assert.equal(row.outcome, 'failed');
    assert.equal(row.primary.op, 'A04', JSON.stringify(row.primary));
    const stat = row.failures.find(f => f.op === 'A13');
    assert.ok(stat, `failures: ${JSON.stringify(row.failures.map(f => [f.op, f.kind]))}`);
    await settle(ts, ts({ op: 'witness' }).fires.slice(before));
    report.push(`bookkeeping-failure: primary A04 ${row.primary.kind}; failures[] A13 ${stat.kind}/${stat.race?.status}; bookkeeping_failed ${failedLine.bookkeeping_failed}`);
    keep(h);
  });
});

const CONTROL = 'SELECT enabled FROM n_control WHERE name=';
const span = r => r.end_ms - r.start_ms;

await test('held-connect-and-read: a 2 s held connect then a read held to its 4 s budget: the read times out with overshoot about 0, the connect completes at about 2,000, the operation total is connect + read + the measured close', async () => {
  const h = await harness(() => new Response(rss([])), { logs: true });
  await within(h, async () => {
    const ts = h.storage.testStorage('polling-runtime');
    const from = h.logs.length, armings = [];
    armings.push(ts({ op: 'arm', kind: 'startup', action: 'startup-hold', release_after_ms: 2000 }).arming);
    armings.push(ts({ op: 'arm', kind: 'statement', action: 'hold-forever', match: CONTROL }).arming);
    const result = await tick(h);
    assert.equal(result.status, 500, result.text);
    const row = await line(h, 'dispatch', from);
    const entry = row.op.find(o => o.ordinal === row.primary.ordinal);
    const by = b => entry.race.find(r => r.boundary === b);
    const [connect, read, close] = [by('connect'), by('read'), by('close')];
    assert.equal(connect.status, 'completed');
    assert.ok(span(connect) >= 2000 && span(connect) < 2500, `connect ${span(connect)}`);
    assert.equal(read.status, 'timeout');
    assert.ok(read.overshoot_ms < 250, `overshoot ${read.overshoot_ms}`);
    const total = entry.end_ms - entry.start_ms;
    assert.ok(Math.abs(total - (span(connect) + span(read) + (close ? span(close) : 0))) < 250, `total ${total}`);
    await settle(ts, ts({ op: 'witness' }).fires.filter(f => armings.includes(f.arming)));
    report.push(`held-connect-and-read: connect ${span(connect)} ms, read ${span(read)} ms (overshoot ${read.overshoot_ms}), close ${close ? span(close) : 'none'} ms, operation ${total} ms`);
    keep(h);
  });
});

await test('close-delay: a normal read with the fixture close delay of 400 ms: every race completed, no overshoot, the close race measured at about 400', async () => {
  const pollingBuild = process.env.OPENCAST_POLLING_FIXTURE_BUILD;
  assert.ok(pollingBuild, 'OPENCAST_POLLING_FIXTURE_BUILD names the polling storage-fixture build');
  const h = await harness(() => new Response(rss([])), { logs: true, pollingBuild });
  await within(h, async () => {
    await h.invoke('test/close-delay', '400');
    const from = h.logs.length;
    await h.invoke('test/dispatch');
    const row = await line(h, 'dispatch', from);
    await h.invoke('test/close-delay', '0');
    assert.equal(row.primary, null);
    assert.equal(row.summary.races.completed, row.summary.races.total);
    assert.equal(row.summary.overshoot_ms_max, null);
    const closes = row.op.flatMap(o => o.race).filter(r => r.boundary === 'close');
    assert.ok(closes.length && closes.every(r => span(r) >= 400 && span(r) < 650), `closes ${closes.map(span)}`);
    report.push(`close-delay: close races ${closes.map(span).join(', ')} ms under a 400 ms fixture delay`);
    keep(h);
  });
});

await test('isolate-stall: a 2 s isolate stall that straddles a held read\'s 4 s expiry: the read times out with overshoot about the stall\'s end less the expiry, the only numeric overshoot', async () => {
  const h = await harness(() => new Response(rss([])), { logs: true });
  await within(h, async () => {
    const ts = h.storage.testStorage('polling-runtime'), alias = h.storage.alias('polling-runtime');
    const from = h.logs.length;
    const arm = ts({ op: 'arm', kind: 'statement', action: 'hold-forever', match: CONTROL });
    const stall = h.storage.proxy.controls.stall(alias, { after: arm.arming, start_ms: 3000, ms: 2000, run: ms => h.invoke('test/stall', String(ms)) });
    const result = await tick(h);
    assert.equal(result.status, 500, result.text);
    const row = await line(h, 'dispatch', from);
    const read = row.primary.race;
    assert.equal(read.status, 'timeout');
    const w = ts({ op: 'witness' }), g = w.fires.find(f => f.arming === stall.arming)?.stall;
    assert.ok(g, 'the stall ran');
    // The expiry was due 1 s into the stall; it ran when the stall ended.
    assert.ok(read.overshoot_ms >= 500 && read.overshoot_ms <= 1500, `overshoot ${read.overshoot_ms}`);
    assert.equal(row.summary.overshoot_ms_max, read.overshoot_ms);
    await settle(ts, w.fires.filter(f => f.arming === arm.arming));
    report.push(`isolate-stall: stall ${Math.round(g.end - g.start)} ms; read ${span(read)} ms of ${read.budget_ms}, overshoot ${read.overshoot_ms}`);
    keep(h);
  });
});

await test('readback-interval: a successful readback after a drop-commit-ack primary lies inside durations.storage; idle is the wall less the union', async () => {
  const h = await harness(() => new Response(rss([])), { logs: true });
  await within(h, async () => {
    const ts = h.storage.testStorage('polling-runtime');
    const from = h.logs.length;
    const arm = ts({ op: 'arm', kind: 'statement', action: 'drop-commit-ack', match: RETIRE });
    await cleanup(h);
    const row = await line(h, 'cleanup', from);
    const readback = row.op.find(o => o.role === 'readback');
    assert.ok(readback && readback.status === 'completed', JSON.stringify(readback));
    const primary = row.op.find(o => o.ordinal === row.primary.ordinal);
    assert.ok(readback.start_ms >= primary.end_ms - 1, 'the readback runs after the initiating operation ended');
    const d = row.durations, leaves = d.r2 + d.service + d.alert + d.queue;
    assert.ok(d.storage >= (primary.end_ms - primary.start_ms) + (readback.end_ms - readback.start_ms) - 2, `storage ${d.storage} covers both`);
    assert.ok(d.idle <= row.wall_ms - d.storage && d.idle >= row.wall_ms - d.storage - leaves - d.publisher - 2, `idle ${d.idle}, wall ${row.wall_ms}`);
    await settle(ts, ts({ op: 'witness' }).fires.filter(f => f.arming === arm.arming));
    keep(h);
  });
});

// The shipped parser's join classifications for `rows`, keyed by chain {step, attempts}.
const PARSER = fileURLToPath(new URL('../storage_phases/', import.meta.url));
function joins(rows) {
  const program = 'import json,sys\nimport storage_phases_parse as p\nrows=[json.loads(l) for l in sys.stdin if l.strip()]\n'
    + 'print(json.dumps([{"step":j["row"]["chain"]["step"],"attempts":j["row"]["chain"]["attempts"],"join":j["join"]} for j in p.joins(rows)]))';
  return JSON.parse(execFileSync('python3', ['-B', '-c', program], { cwd: PARSER, input: rows.map(r => JSON.stringify(r)).join('\n') }).toString());
}
// A feed with a baseline, then new episodes (three unless `count` says):
// its next scan stages a continuation.
async function changedFeed(h, name, setItems, count = 3) {
  const t = Math.floor(Date.now() / 1000);
  const feed = await h.add(cohort(`https://witness.example.com/${name}`));
  setItems([item('base', t - 86_400)]);
  await h.invoke('test/dispatch'); await h.drain();
  const fresh = count === 3 ? [item('n1', t - 60), item('n2', t - 50), item('n3', t - 40)]
    : Array.from({ length: count }, (_, i) => item(`n${i + 1}`, t - 60 - i));
  setItems([...fresh, item('base', t - 86_400)]);
  await h.run('UPDATE n_feed SET due_at=0,retry_at=0,dispatch_until=0 WHERE feed_id=?', feed);
  await h.invoke('test/dispatch');
  return feed;
}

await test('send-provenance: send provenance on real chains through the shipped parser: an uncertain duplicate is ambiguous, a commit lost before the send leaves one exact sender, a withheld predecessor is unknown', async () => {
  let items = [];
  const h = await harness(() => new Response(rss(items)), { logs: true, pollingBuild: POLLING_FIXTURE });
  await within(h, async () => {
    const ts = h.storage.testStorage('polling-runtime');
    const consumes = from => lines(h, 'consume', from);
    // (i) the send enqueues, then errors: the step fails and its redelivery sends step 1 again.
    const feed = await changedFeed(h, 'send-provenance', next => { items = next; });
    let from = h.logs.length;
    const [wake] = (await h.polls()).filter(w => w.feed_id === feed);
    // One action per delivery, so each sends its continuation at its first boundary.
    await h.invoke('fault', 'after_enqueue');
    assert.equal((await stopAfter(h, wake, 1)).status, 500);
    assert.equal((await stopAfter(h, wake, 1, { attempts: 2 })).status, 200);
    const pending = (await h.polls()).filter(w => w.feed_id === feed && w.step === 1);
    assert.equal(pending.length, 2, 'two producing sends of step 1');
    await h.consume(pending[0]);
    let rows = consumes(from);
    assert.deepEqual(rows.filter(r => r.sent?.step === 1).map(r => r.sent.result), ['uncertain', 'ok']);
    let classified = joins(rows);
    assert.deepEqual(classified.find(j => j.step === 1 && j.attempts === 1)?.join, 'ambiguous', JSON.stringify(classified));
    for (const extra of (await h.polls()).filter(w => w.feed_id === feed)) await h.consume(extra);
    await h.drain();
    // (i') the continuation's commit acknowledgement is lost before any send: the redelivery's send is the only one.
    const other = await changedFeed(h, 'send-provenance-other', next => { items = next; });
    from = h.logs.length;
    const [first] = (await h.polls()).filter(w => w.feed_id === other);
    // The continuation's renewal: the second of the delivery (the first renews
    // the reservation before its action).
    const arm = ts({ op: 'arm', kind: 'statement', action: 'drop-commit-ack', match: 'UPDATE n_feed SET dispatch_until=$2 WHERE', skip: 1 });
    assert.equal((await stopAfter(h, first, 1)).status, 500);
    assert.equal((await stopAfter(h, first, 1, { attempts: 2 })).status, 200);
    const [successor] = (await h.polls()).filter(w => w.feed_id === other && w.step === 1);
    await h.consume(successor);
    rows = consumes(from);
    assert.equal(rows.filter(r => r.sent?.step === 1).length, 1, 'one producing send');
    classified = joins(rows);
    assert.equal(classified.find(j => j.step === 1 && j.attempts === 1)?.join, 'exact', JSON.stringify(classified));
    // The redelivered wake is step 0, the dispatcher's own send: it has no predecessor to join.
    // (ii) the predecessor row withheld (a feed outside the retained cohort): unknown.
    classified = joins(rows.filter(r => !(r.sent?.step === 1)));
    assert.equal(classified.find(j => j.step === 1 && j.attempts === 1)?.join, 'unknown', JSON.stringify(classified));
    await settle(ts, ts({ op: 'witness' }).fires.filter(f => f.arming === arm.arming));
    keep(h);
  });
});

const RESERVE = 'WITH input AS (SELECT * FROM unnest($1::text[],$2::text[],$3::text[])';

await test('zero-budget: the zero-budget control in its own disposable fixture: a reserve\'s COMMIT reply held while the Date clock moves +12 s, then released; the reserve completes and the next operation fails at entry: connect, budget 0, authority_deadline, unsubmitted, with no new connection on the wire', async () => {
  const h = await harness(() => new Response(rss([])), { logs: true });
  await within(h, async () => {
    const ts = h.storage.testStorage('polling-runtime');
    await h.add('https://witness.example.com/zero-budget');
    const before = ts({ op: 'witness' }).operations.length, from = h.logs.length;
    const arm = ts({ op: 'arm', kind: 'statement', action: 'hold-commit-reply', match: RESERVE });
    const running = tick(h);
    const fire = await fired(ts, arm.arming);
    await h.invoke('clock', '12');
    ts({ op: 'release', fire: fire.id });
    const result = await running;
    assert.equal(result.status, 500, result.text);
    const row = await line(h, 'dispatch', from);
    const reserve = row.op.find(o => o.op === 'A02' && o.status === 'completed') ?? row.op.find(o => o.status === 'completed' && o.read === false);
    assert.ok(reserve && reserve.affected_rows >= 1, `the reserve completed with its rows: ${JSON.stringify(reserve)}`);
    const race = row.primary.race;
    assert.deepEqual([race.boundary, race.budget_ms, race.limit, race.submitted, race.status], ['connect', 0, 'authority_deadline', false, 'timeout'], JSON.stringify(row.primary));
    assert.ok(row.primary.ordinal > reserve.ordinal);
    // No socket for the expired operation: the reserve's was the window's last operation.
    const w = ts({ op: 'witness' }), mine = w.operations.slice(before), held = mine.findIndex(o => o.id === fire.op);
    assert.equal(held, mine.length - 1, `operations after the reserve: ${mine.length - 1 - held}`);
    assert.equal(mine[held].commit_tag, 'COMMIT');
    ts({ op: 'expect', fire: fire.id, outcome: 'released' });
    report.push(`zero-budget: reserve ${reserve.op} completed (${reserve.affected_rows} rows); then ${row.primary.op} at ordinal ${row.primary.ordinal}: connect budget 0, unsubmitted; no operation after the reserve on the wire`);
    keep(h);
  });
});

await test('nested-identity: a nested identity read on a cold cache: the identity guard\'s interval lies inside its parent\'s and the union counts it once', async () => {
  const h = await harness(() => new Response(rss([])), { logs: true, alertSecrets: { STORAGE_IDENTITY: 'v1;development;postgres;pg:any_database' } });
  await within(h, async () => {
    const from = h.logs.length;
    await tick(h);
    const row = await line(h, 'dispatch', from);
    const child = row.op.find(o => o.role === 'identity');
    assert.ok(child, `an identity guard: ${JSON.stringify(row.op.map(o => [o.ordinal, o.role]))}`);
    const parent = row.op.find(o => o.ordinal === child.parent);
    assert.ok(parent && parent.role === 'operation', JSON.stringify(parent));
    assert.ok(child.start_ms >= parent.start_ms && child.end_ms <= parent.end_ms, `child [${child.start_ms},${child.end_ms}] inside parent [${parent.start_ms},${parent.end_ms}]`);
    // The child did real work: a positive interval, which the union counts.
    assert.ok(child.end_ms - child.start_ms > 0, `the identity read took ${child.end_ms - child.start_ms} ms`);
    // The tick's only storage work is that operation: the union is its interval, the child counted once.
    const intervals = row.op.filter(o => o.role !== 'identity').map(o => o.end_ms - o.start_ms).reduce((a, b) => a + b, 0);
    assert.ok(row.durations.storage <= intervals + 1, `storage ${row.durations.storage} vs parents ${intervals}`);
    assert.ok(row.durations.storage >= parent.end_ms - parent.start_ms - 1, `storage ${row.durations.storage} covers the parent`);
    report.push(`nested-identity: identity child ${child.end_ms - child.start_ms} ms inside parent ${parent.end_ms - parent.start_ms} ms; durations.storage ${row.durations.storage}`);
    keep(h);
  });
});

await test('owner-abort: a write\'s first application statement held (hold-unit-reply:0), then the delivery aborted: the non-polling future is disposed, the operation and its in-flight transaction race read dropped', async () => {
  let items = [];
  const h = await harness(() => new Response(rss(items)), { logs: true });
  await within(h, async () => {
    const ts = h.storage.testStorage('polling-runtime');
    const feed = await changedFeed(h, 'owner-abort', next => { items = next; });
    const [wake] = (await h.polls()).filter(w => w.feed_id === feed);
    const from = h.logs.length;
    const arm = ts({ op: 'arm', kind: 'statement', action: 'hold-unit-reply:0', forever: true, match: 'UPDATE n_feed SET dispatch_until=$2 WHERE' });
    const running = h.consume(wake, { headers: { 'x-test-execution': 'owner-abort' } });
    const fire = await fired(ts, arm.arming);
    await (await h.instance.dispatchFetch('https://polling.invalid/abort', { method: 'POST', body: 'owner-abort' })).text();
    const result = await running;
    assert.notEqual(result.status, 200, result.text);
    const row = await line(h, 'consume', from);
    assert.equal(row.outcome, 'cancelled');
    assert.equal(row.primary?.status, 'dropped', JSON.stringify(row.primary));
    assert.deepEqual([row.primary.op, row.primary.race?.boundary, row.primary.race?.status], ['A11', 'transaction', 'dropped'], JSON.stringify(row.primary));
    assert.ok(row.ops.dropped >= 1);
    await settle(ts, [fire]);
    report.push(`owner-abort: ${row.primary.op} ${row.primary.status}, race ${row.primary.race.boundary} ${row.primary.race.status} after ${row.primary.race.end_ms - row.primary.race.start_ms} ms`);
    keep(h);
  });
});

// A changed feed taken through its chain to publication, one action per
// delivery; the next wakeup is its drain delivery. Returns the feed and that
// wakeup. A storage-fixture build (stepActions).
async function publishedDrain(h, name, setItems, count = 3) {
  const feed = await changedFeed(h, name, setItems, count);
  const published = await stepActions(h, result => result === 'published');
  assert.equal(published?.result, 'published');
  const [wake] = (await h.polls()).filter(w => w.feed_id === feed);
  assert.ok(wake, 'the drain delivery');
  return { feed, wake };
}
const OUTBOX_RELEASE = 'INSERT INTO n_outbox(source,event_id,observation_id';

for (const [form, action] of [['after the replies to BEGIN and the gate', 'hold-unit-reply:0'], ['after submission, before any reply', 'hold-forever']]) {
  await test(`aborted-outbox-release: the drain delivery's outbox release held ${form}, then the delivery aborted: the dropped transaction is attempted and unknown, never acknowledged`, async () => {
    let items = [];
    const h = await harness(() => new Response(rss(items)), { logs: true, pollingBuild: POLLING_FIXTURE });
    await within(h, async () => {
      const ts = h.storage.testStorage('polling-runtime');
      const { wake } = await publishedDrain(h, `aborted-outbox-release-${action}`, next => { items = next; });
      const from = h.logs.length, key = `aborted-outbox-release-${action}`;
      const arm = ts({ op: 'arm', kind: 'statement', action, match: OUTBOX_RELEASE, ...(action === 'hold-forever' ? {} : { forever: true }) });
      const running = h.consume(wake, { headers: { 'x-test-execution': key } });
      const fire = await fired(ts, arm.arming);
      await sleep(100);
      await (await h.instance.dispatchFetch('https://polling.invalid/abort', { method: 'POST', body: key })).text();
      const result = await running;
      assert.notEqual(result.status, 200, result.text);
      const row = await line(h, 'consume', from);
      assert.equal(row.outcome, 'cancelled');
      const race = row.primary?.race;
      assert.deepEqual([row.primary?.op, row.primary?.status, race?.boundary, race?.status, race?.submitted], ['B10', 'dropped', 'transaction', 'dropped', true], JSON.stringify(row.primary));
      assert.equal(race.steps_completed, action === 'hold-forever' ? 0 : 2, `steps ${race.steps_completed}/${race.steps_total}`);
      assert.deepEqual(row.recovery.outbox_release, { acknowledged_txns: 0, attempted_txns: 1, unknown_txns: 1 }, JSON.stringify(row.recovery));
      await settle(ts, [fire]);
      report.push(`aborted-outbox-release (${action}): B10 dropped after ${race.steps_completed}/${race.steps_total} steps, submitted ${race.submitted}; outbox_release ${JSON.stringify(row.recovery.outbox_release)}`);
      keep(h);
    });
  });
}

const abort = async (h, key) => (await h.instance.dispatchFetch('https://polling.invalid/abort', { method: 'POST', body: key })).text();
const DRAIN_CHECKPOINT = 'WITH r AS (SELECT * FROM unnest($5::text[]';
const PREPARE_CHECKPOINT = 'UPDATE n_observation SET preparation_key=$2';

await test('aborted-drain-checkpoint: the drain checkpoint\'s COMMIT reply held (the server committed), then the delivery aborted: the action keeps the attempted target with status unknown, never committed, though the fixture reads the cursor back durable', async () => {
  let items = [];
  const h = await harness(() => new Response(rss(items)), { logs: true, pollingBuild: POLLING_FIXTURE });
  await within(h, async () => {
    const ts = h.storage.testStorage('polling-runtime');
    const { feed, wake } = await publishedDrain(h, 'aborted-drain-checkpoint', next => { items = next; });
    const observation = await h.first("SELECT observation_id FROM n_observation WHERE feed_id=? AND state='published' AND drain_complete=0", feed);
    const from = h.logs.length, key = 'aborted-drain-checkpoint';
    const arm = ts({ op: 'arm', kind: 'statement', action: 'hold-commit-reply', forever: true, match: DRAIN_CHECKPOINT });
    const running = h.consume(wake, { headers: { 'x-test-execution': key } });
    const fire = await fired(ts, arm.arming);
    await sleep(100);
    await abort(h, key);
    const result = await running;
    assert.notEqual(result.status, 200, result.text);
    const row = await line(h, 'consume', from);
    assert.equal(row.outcome, 'cancelled');
    assert.deepEqual([row.primary?.op, row.primary?.race?.status], ['B09', 'dropped'], JSON.stringify(row.primary));
    const last = row.recovery.last_action;
    assert.equal(last?.name, 'drain', JSON.stringify(row.recovery));
    assert.equal(last.start_checkpoint?.status, 'committed');
    assert.deepEqual([last.end_checkpoint?.kind, last.end_checkpoint?.phase, last.end_checkpoint?.status], ['drain', null, 'unknown'], JSON.stringify(last));
    assert.ok(last.end_checkpoint.candidate_cursor > last.start_checkpoint.candidate_cursor, JSON.stringify(last));
    // The fixture's own evidence, kept apart from the line: the proxy saw the
    // COMMIT and never relayed its reply, and the cursor is durable.
    const op = ts({ op: 'witness' }).operations.find(o => o.id === fire.op);
    assert.deepEqual([op?.commit_tag, op?.commit_relayed], ['COMMIT', false], JSON.stringify(op));
    const durable = await h.first('SELECT candidate_cursor FROM n_observation WHERE observation_id=?', observation.observation_id);
    assert.equal(durable.candidate_cursor, last.end_checkpoint.candidate_cursor);
    await settle(ts, [fire]);
    report.push(`aborted-drain-checkpoint: cursor ${last.start_checkpoint.candidate_cursor} -> ${last.end_checkpoint.candidate_cursor} ${last.end_checkpoint.status} in the line; durable ${durable.candidate_cursor}, COMMIT unrelayed`);
    keep(h);
  });
});

await test('aborted-prepare-checkpoint: a preparation checkpoint\'s COMMIT reply held (the server committed), then the delivery aborted: the action keeps the attempted next phase with status unknown, never committed', async () => {
  let items = [];
  const h = await harness(() => new Response(rss(items)), { logs: true });
  await within(h, async () => {
    const ts = h.storage.testStorage('polling-runtime');
    const feed = await changedFeed(h, 'aborted-prepare-checkpoint', next => { items = next; });
    // The scan writes the first checkpoint (phase-0); the hold takes the next,
    // a prepare action's.
    const arm = ts({ op: 'arm', kind: 'statement', action: 'hold-commit-reply', forever: true, match: PREPARE_CHECKPOINT, skip: 1 });
    // The chain's deliveries in turn, until one holds its checkpoint's COMMIT reply.
    let running, fire, key, from;
    for (let i = 0; i < 50 && !fire; i++) {
      const [wake] = (await h.polls()).filter(w => w.feed_id === feed);
      assert.ok(wake, 'the chain reached a preparation checkpoint');
      key = `aborted-prepare-checkpoint-${i}`; from = h.logs.length;
      running = h.consume(wake, { headers: { 'x-test-execution': key } });
      for (;;) {
        fire = ts({ op: 'witness' }).fires.find(f => f.arming === arm.arming);
        if (fire || await Promise.race([running.then(() => true), sleep(20).then(() => false)])) break;
      }
    }
    assert.ok(fire, 'a preparation checkpoint was held');
    await sleep(100);
    await abort(h, key);
    const result = await running;
    assert.notEqual(result.status, 200, result.text);
    const row = await line(h, 'consume', from);
    assert.equal(row.outcome, 'cancelled');
    const last = row.recovery.last_action;
    assert.equal(last?.name, 'prepare', JSON.stringify(row.recovery));
    assert.deepEqual([last.end_checkpoint?.kind, last.end_checkpoint?.status], ['prepare', 'unknown'], JSON.stringify(last));
    assert.equal(last.start_checkpoint?.kind, 'prepare', JSON.stringify(last));
    assert.ok(last.end_checkpoint.phase > last.start_checkpoint.phase, JSON.stringify(last));
    const op = ts({ op: 'witness' }).operations.find(o => o.id === fire.op);
    assert.deepEqual([op?.commit_tag, op?.commit_relayed], ['COMMIT', false], JSON.stringify(op));
    await settle(ts, [fire]);
    report.push(`aborted-prepare-checkpoint: phase ${last.start_checkpoint.phase} -> ${last.end_checkpoint.phase} ${last.end_checkpoint.status} in the line; COMMIT unrelayed`);
    keep(h);
  });
});

for (const [form, pin] of [['a malformed pin', 'malformed'], ['a pin for another environment', 'v1;production;postgres;pg:any_database']]) {
  await test(`identity-refusal: ${form} refused before any read: the first invocation's line reads identity decided, the next one's cached`, async () => {
    const h = await harness(() => new Response(rss([])), { logs: true, alertSecrets: { STORAGE_IDENTITY: pin } });
    await within(h, async () => {
      const seen = [];
      for (const expected of ['decided', 'cached']) {
        const from = h.logs.length;
        const response = await h.instance.dispatchFetch('https://polling.invalid/test/dispatch', { method: 'POST' });
        assert.equal(response.status, 500, await response.text());
        const row = await line(h, 'dispatch', from);
        if (expected === 'decided') assert.ok(h.logs.slice(from).some(e => e.event === 'storage_identity' && e.verdict === 'refused'), 'the refusal is logged');
        assert.equal(row.identity, expected, JSON.stringify({ identity: row.identity, ops: row.ops }));
        seen.push(row.identity);
      }
      report.push(`identity-refusal (${form}): ${seen.join(' then ')}`);
      keep(h);
    });
  });
}

await test('consume-admission: a valid message writes its line on every exit, the environment brake\'s 503 included (outcome refused), for a cohort feed and any other; an invalid payload or a legacy cleanup message writes none; every response unchanged', async () => {
  const wakeup = (h, fields) => ({ schema_version: 2, environment: 'development', kind: 'poll', feed_id: '0'.repeat(64), generation: 1, owner_epoch: 1, due_at: h.now, ...fields });
  const braked = await harness(() => new Response(rss([])), { logs: true, alertSecrets: { NOTIFICATION_FEED_OBSERVATION: 'false' } });
  await within(braked, async () => {
    for (const feed of ['0'.repeat(64), 'f'.repeat(64)]) {
      const from = braked.logs.length;
      const result = await braked.consume(wakeup(braked, { feed_id: feed }));
      assert.deepEqual([result.status, result.text], [503, 'polling_disabled']);
      const row = await line(braked, 'consume', from);
      assert.deepEqual([row.outcome, row.chain?.feed, row.chain?.generation, row.ops.total, row.primary, row.action.length], ['refused', feed, 1, 0, null, 0], JSON.stringify(row));
    }
    // An invalid payload under the brake: the same 503, no line.
    const from = braked.logs.length;
    const result = await braked.consume(wakeup(braked, { generation: 0 }));
    assert.deepEqual([result.status, result.text], [503, 'polling_disabled']);
    await sleep(200);
    assert.equal(lines(braked, 'consume', from).length, 0);
    keep(braked);
  });
  const h = await harness(() => new Response(rss([])), { logs: true });
  await within(h, async () => {
    for (const [fields, status, text] of [[{ generation: 0 }, 400, 'invalid_wakeup'], [{ environment: 'production' }, 400, 'invalid_wakeup'],
      [{ kind: 'other' }, 400, 'invalid_wakeup'], [{ feed_id: 'not-hex' }, 400, 'invalid_wakeup'], [{ owner_epoch: 0 }, 400, 'invalid_wakeup'],
      [{ kind: 'cleanup' }, 200, null]]) {
      const from = h.logs.length;
      const result = await h.consume(wakeup(h, fields));
      assert.equal(result.status, status, result.text);
      if (text) assert.equal(result.text, text); else assert.equal(result.outcome, 'cleanup_ignored');
      await sleep(200);
      assert.equal(lines(h, 'consume', from).length, 0, JSON.stringify(fields));
    }
    keep(h);
  });
  report.push('consume-admission: the brake\'s 503 writes a line for a cohort feed and another (its chain, no operation); an invalid payload (under the brake or not) and a legacy cleanup message write none; responses unchanged');
});

const CLAIM_GC = "UPDATE n_snapshot AS s SET state='gc_claimed' WHERE object_key=$2";

await test('gc-late-failure: a GC tick whose 90th operation is closed before it is sent: the tick stops there, the primary is ordinal 90 with its race, its readback and the ReleaseCleanup attempt follow it, the detail capped and the rest counted', async () => {
  const h = await harness(() => new Response(rss([])), { logs: true });
  await within(h, async () => {
    const ts = h.storage.testStorage('polling-runtime');
    const owner = await h.add('https://witness.example.com/gc-late-failure');
    for (let i = 0; i < 40; i++) {
      await h.run("INSERT INTO n_snapshot(object_key,feed_id,owner_epoch,lease_id,sha256,bytes,state,created_at,gc_after) VALUES(?,?,1,'gc-late-failure-lease','x',1,'uploaded',0,0)", `gc-late-failure/${String(i).padStart(4, '0')}`, owner);
    }
    // Eleven operations open the tick (the cleanup claim, the stat prune, the
    // control read, the retention sweeps, the candidate read); then three per
    // object (claim, claim read, mark deleted): the 27th object's claim is the 90th.
    const arm = ts({ op: 'arm', kind: 'statement', action: 'close-before', match: CLAIM_GC, skip: 26 });
    const before = ts({ op: 'witness' }).operations.length, from = h.logs.length;
    const result = await cleanup(h);
    assert.equal(result.status, 500, result.text);
    const row = await line(h, 'cleanup', from);
    const w = ts({ op: 'witness' }), mine = w.operations.slice(before);
    const fire = w.fires.find(f => f.arming === arm.arming);
    assert.ok(fire, 'the close fired');
    assert.equal(mine.findIndex(o => o.id === fire.op) + 1, 90, 'the proxy counts the closed operation 90th');
    assert.equal(row.ops.total, mine.length, `ops.total ${row.ops.total} vs the proxy's ${mine.length}`);
    // The closed write's outcome is Unknown (its statements were already
    // sent), so its readback follows it; then only the ReleaseCleanup attempt.
    assert.equal(row.ops.total, 92, 'the closed operation, its readback, the ReleaseCleanup attempt');
    assert.equal(row.ops.readbacks, 1);
    assert.deepEqual([row.primary?.ordinal, row.primary?.op, row.primary?.race?.boundary, row.primary?.race?.status], [90, 'e_claim_gc', 'transaction', 'driver'], JSON.stringify(row.primary));
    assert.equal(row.ops.after_primary, 2);
    assert.ok(row.ops.detailed <= 16, `detailed ${row.ops.detailed}`);
    assert.equal(row.ops.omitted, row.ops.total - row.ops.detailed);
    assert.ok(row.op.some(o => o.ordinal === 90), 'the primary operation is detailed');
    report.push(`gc-late-failure: primary ordinal ${row.primary.ordinal} ${row.primary.op} ${row.primary.race.boundary} ${row.primary.race.status}; ops ${row.ops.total} (detailed ${row.ops.detailed}, omitted ${row.ops.omitted}, after the primary ${row.ops.after_primary}); ${row.bytes_policy}`);
    keep(h);
  });
});

// The parser's recovery reading of a cancelled or failed row and its resumption.
function recovery(cancelled, resuming) {
  const program = 'import json,sys\nimport storage_phases_parse as p\na,b=[json.loads(l) for l in sys.stdin if l.strip()]\n'
    + 'r=p.recovery(a,b)\nprint(json.dumps({"checkpoint_outcome":r["checkpoint_outcome"],"cursor_comparison":r["cursor_comparison"],'
    + '"page_repeated":r["page_repeated"],"prepare_redo":r["prepare_redo"],"skipped_rows":r["skipped_rows"],"tags":p.classified(a)["tags"]}))';
  return JSON.parse(execFileSync('python3', ['-B', '-c', program], { cwd: PARSER, input: [cancelled, resuming].map(r => JSON.stringify(r)).join('\n') }).toString());
}
const preparationKey = async (h, feed) => (await h.first("SELECT preparation_key FROM n_observation WHERE feed_id=? AND state='staging' ORDER BY scan_started_at DESC LIMIT 1", feed))?.preparation_key ?? null;
// Delivers `wake` and waits for the arming's fire inside it or for its end; returns { result, fire, from }.
async function deliverUntil(h, ts, arming, wake, headers) {
  const from = h.logs.length;
  const running = h.consume(wake, { attempts: headers.attempts ?? 1, headers: headers.headers ?? {} });
  let fire;
  for (;;) {
    fire = ts({ op: 'witness' }).fires.find(f => f.arming === arming);
    if (fire || await Promise.race([running.then(() => true), sleep(20).then(() => false)])) break;
  }
  return { result: await running, fire, from };
}

// The paired uncertain-checkpoint histories: a delivery (A) that resumed at
// phase-2 writes its phase-3 checkpoint, and either the server commits it while
// its acknowledgement is held to A's deadline (committed), or the held statement
// never reaches the server (never committed) and a duplicate delivery of the
// same wakeup, another message, redoes phase-2 and commits phase-3 first. In
// both, A's line keeps start phase-2 and end phase-3 UNKNOWN, A's retry resumes
// at a durable phase-3, and the parser reads the same coarse outcome; only the
// fixture's own evidence (the proxy's commit tag, the preparation key read
// back) tells the two apart.
const histories = {};
for (const [history, action] of [['committed', 'hold-commit-reply'], ['never-committed', 'hold-forever']]) {
  await test(`uncertain-checkpoint (${history}): a phase-3 checkpoint whose outcome the delivery never learns: its line keeps start phase-2 and end phase-3 unknown, the retry resumes at a durable phase-3, and only the fixture tells the histories apart`, async () => {
    let items = [];
    const h = await harness(() => new Response(rss(items)), { logs: true, pollingBuild: POLLING_FIXTURE });
    await within(h, async () => {
      const ts = h.storage.testStorage('polling-runtime');
      const feed = await changedFeed(h, `uncertain-checkpoint-${history}`, next => { items = next; });
      // A failed preparation waits out its backoff (processing_next_at, 300 s)
      // before the next delivery may prepare: the Worker's Date moves past it.
      const backoff = () => h.invoke('clock', '301');
      // The scan writes the phase-0 checkpoint and each preparation phase the
      // next one, so the fourth write names phase-3: A is the delivery holding
      // it, its last action the phase that started at a durable phase-2.
      const arm = ts({ op: 'arm', kind: 'statement', action, match: PREPARE_CHECKPOINT, skip: 3, ...(action === 'hold-commit-reply' ? { forever: true } : {}) });
      // One action per delivery through the first three writes, so A starts
      // at the durable phase-2 pointer.
      const opsAt = ts({ op: 'witness' }).operations.length;
      const written = () => ts({ op: 'witness' }).operations.slice(opsAt).filter(o => (o.statements?.[0] ?? '').startsWith(PREPARE_CHECKPOINT)).length;
      for (let i = 0; i < 10 && written() < 3; i++) {
        const [wake] = (await h.polls()).filter(w => w.feed_id === feed);
        assert.ok(wake, 'the chain reached its phase-2 checkpoint');
        await stopAfter(h, wake, 1);
      }
      let a, wakeA, before;
      for (let i = 0; i < 20 && !a?.fire; i++) {
        const [wake] = (await h.polls()).filter(w => w.feed_id === feed);
        assert.ok(wake, 'the chain reached its phase-3 checkpoint');
        wakeA = wake; before = await preparationKey(h, feed);
        a = await deliverUntil(h, ts, arm.arming, wake, { headers: { 'x-poll-message-id': `history-${history}-a` } });
      }
      assert.ok(a.fire, 'A held its phase-3 checkpoint');
      assert.equal(a.result.status, 500, a.result.text);
      const rowA = await line(h, 'consume', a.from);
      const last = rowA.recovery.last_action;
      assert.deepEqual([last?.name, last?.start_checkpoint?.phase, last?.start_checkpoint?.status, last?.end_checkpoint?.phase, last?.end_checkpoint?.status],
        ['prepare', 2, 'committed', 3, 'unknown'], JSON.stringify(rowA.recovery));
      assert.deepEqual([rowA.primary?.kind, rowA.primary?.phase, rowA.primary?.outcome, rowA.primary?.race?.boundary, rowA.primary?.race?.submitted],
        ['Deadline', 'commit', 'Unknown', 'transaction', true], JSON.stringify(rowA.primary));
      const afterA = await preparationKey(h, feed);
      let duplicate = null;
      if (history === 'never-committed') {
        // The duplicate producing message's delivery: phase-2 again, its own
        // phase-3 checkpoint committed.
        await backoff();
        const fromD = h.logs.length;
        const d = await stopAfter(h, wakeA, 1, { headers: { 'x-poll-message-id': `history-${history}-b` } });
        assert.equal(d.status, 200, d.text);
        duplicate = await line(h, 'consume', fromD);
        const own = duplicate.recovery.first_action;
        assert.deepEqual([own?.start_checkpoint?.phase, own?.end_checkpoint?.phase, own?.end_checkpoint?.status, duplicate.chain.message_digest === rowA.chain.message_digest],
          [2, 3, 'committed', false], JSON.stringify(duplicate.recovery));
      }
      const beforeRetry = await preparationKey(h, feed);
      // A's retry: the same message again.
      await backoff();
      const r = await deliverUntil(h, ts, -1, wakeA, { attempts: 2, headers: { 'x-poll-message-id': `history-${history}-a` } });
      assert.equal(r.result.status, 200, r.result.text);
      const resumed = await line(h, 'consume', r.from);
      assert.deepEqual([resumed.recovery.first_action?.start_checkpoint?.phase, resumed.recovery.first_action?.start_checkpoint?.status],
        [3, 'committed'], JSON.stringify(resumed.recovery));
      // The fixture's own evidence, never the line's.
      const op = ts({ op: 'witness' }).operations.find(o => o.id === a.fire.op);
      if (history === 'committed') {
        assert.deepEqual([op?.commit_tag, op?.commit_relayed], ['COMMIT', false], JSON.stringify(op));
        assert.notEqual(afterA, before, 'A\'s checkpoint is durable');
        assert.equal(beforeRetry, afterA);
      } else {
        assert.ok(!op?.commit_tag, `no COMMIT ever reached the server: ${JSON.stringify(op)}`);
        assert.equal(afterA, before, 'nothing of A is durable');
        assert.notEqual(beforeRetry, afterA, 'the duplicate committed phase-3 under its own key');
      }
      // The parser: the same coarse outcome for both histories.
      const reading = recovery(rowA, resumed);
      assert.deepEqual([reading.checkpoint_outcome, reading.page_repeated, reading.prepare_redo, reading.skipped_rows], ['unknown', 'unknown', 'unknown', 'unknown'], JSON.stringify(reading));
      histories[history] = { rowA, resumed, steps: rowA.primary.race.steps_completed };
      await settle(ts, [a.fire]);
      report.push(`uncertain-checkpoint (${history}): A ${last.start_checkpoint.phase} -> ${last.end_checkpoint.phase} ${last.end_checkpoint.status}, race steps ${rowA.primary.race.steps_completed}/${rowA.primary.race.steps_total}${duplicate ? ', a duplicate committed phase-3 first' : ''}; the retry resumed at phase ${resumed.recovery.first_action.start_checkpoint.phase}; fixture: commit tag ${op?.commit_tag ?? 'none'}, key ${afterA === before ? 'unchanged' : 'A\'s'} after A; parser ${reading.checkpoint_outcome}`);
      keep(h);
    });
  });
}
await test('uncertain-checkpoint (the pair): the two histories agree in every checkpoint field the recovery rule reads and differ only in where A\'s race stopped', async () => {
  const { committed, 'never-committed': never } = histories;
  assert.ok(committed && never, 'both histories ran');
  const fields = row => [row.recovery.last_action.start_checkpoint, row.recovery.last_action.end_checkpoint];
  assert.deepEqual(fields(committed.rowA), fields(never.rowA));
  assert.deepEqual(committed.resumed.recovery.first_action.start_checkpoint, never.resumed.recovery.first_action.start_checkpoint);
  assert.notEqual(committed.steps, never.steps, 'the race stopped at a different step');
  report.push(`uncertain-checkpoint (the pair): checkpoint fields equal; A's race stopped after ${committed.steps} and ${never.steps} steps`);
});

// Two drain histories with equal aggregate counts but different repeated work:
// the first page's drain write either never reaches the server (the page is
// drained again) or commits while its acknowledgement is held to the deadline
// (the next page follows). The parser reports page repetition unknown on both
// and only the coarse cursor comparison (unequal, equal); the fixture tells
// them apart from its own evidence: the durable cursor read back and whether
// the first page's key is fetched again (a one-shot R2 hook on that key).
const drains = {};
for (const [history, action] of [['repeated', 'hold-forever'], ['advanced', 'hold-commit-reply']]) {
  await test(`drain-history (${history}): a failed first-page drain and its resumption: the parser never infers page repetition, only the coarse cursor comparison; the fixture's own evidence separates the histories`, async () => {
    let items = [];
    const h = await harness(() => new Response(rss(items)), { logs: true, pollingBuild: POLLING_FIXTURE });
    await within(h, async () => {
      const ts = h.storage.testStorage('polling-runtime');
      const { feed, wake } = await publishedDrain(h, `drain-history-${history}`, next => { items = next; }, 150);
      const observation = await h.first("SELECT observation_id,snapshot_key FROM n_observation WHERE feed_id=? AND state='published' AND drain_complete=0", feed);
      const bucket = await h.instance.getR2Bucket('FEED_SNAPSHOTS', 'polling-runtime');
      const manifest = JSON.parse(await (await bucket.get(observation.snapshot_key)).text());
      assert.ok(manifest.candidate_pages.length >= 2, `two candidate pages: ${manifest.candidate_pages.length}`);
      const arm = ts({ op: 'arm', kind: 'statement', action, match: DRAIN_CHECKPOINT, ...(action === 'hold-commit-reply' ? { forever: true } : {}) });
      const failed = await deliverUntil(h, ts, arm.arming, wake, { headers: { 'x-poll-message-id': `drain-history-${history}` } });
      assert.ok(failed.fire, 'the first page\'s drain write was held');
      assert.equal(failed.result.status, 500, failed.result.text);
      const row = await line(h, 'consume', failed.from);
      const last = row.recovery.last_action;
      assert.deepEqual([last?.name, last?.start_checkpoint?.candidate_cursor, last?.end_checkpoint?.status], ['drain', 0, 'unknown'], JSON.stringify(row.recovery));
      // The fixture's own evidence: the durable cursor, and whether the first
      // page is fetched again by the resumption.
      const durable = (await h.first('SELECT candidate_cursor FROM n_observation WHERE observation_id=?', observation.observation_id)).candidate_cursor;
      await h.invoke('fault', `slow_get:1:${manifest.candidate_pages[0].key}`);
      const resumedAt = h.logs.length;
      const resumed = await h.consume(wake, { attempts: 2, headers: { 'x-poll-message-id': `drain-history-${history}` } });
      assert.equal(resumed.status, 200, resumed.text);
      const next = await line(h, 'consume', resumedAt);
      const refetched = (await h.invoke('metrics')).hooks.r2.some(r => r.hook === 'slow_get' && r.key === manifest.candidate_pages[0].key);
      await h.invoke('fault', 'none');
      if (history === 'repeated') assert.deepEqual([durable, refetched], [0, true]);
      else assert.deepEqual([durable, refetched], [last.end_checkpoint.candidate_cursor, false]);
      const reading = recovery(row, next);
      assert.deepEqual([reading.page_repeated, reading.checkpoint_outcome, reading.cursor_comparison],
        ['unknown', 'unknown', history === 'repeated' ? 'unequal' : 'equal'], JSON.stringify(reading));
      drains[history] = row;
      await settle(ts, [failed.fire]);
      report.push(`drain-history (${history}): line cursor 0 -> ${last.end_checkpoint.candidate_cursor} unknown; fixture durable ${durable}, first page fetched again ${refetched}; parser page_repeated ${reading.page_repeated}, cursors ${reading.cursor_comparison}`);
      keep(h);
    });
  });
}
await test('drain-history (the pair): the two failed rows carry equal aggregate counts', async () => {
  const { repeated, advanced } = drains;
  assert.ok(repeated && advanced, 'both histories ran');
  const counts = row => [row.ops.total, row.ops.reads, row.ops.writes, row.action.map(a => [a.name, a.r2_calls]), row.primary.op, row.recovery.last_action.end_checkpoint];
  assert.deepEqual(counts(repeated), counts(advanced));
  report.push('drain-history (the pair): equal aggregate counts and checkpoint fields; only the fixture separates them');
});

// Each storage_phases line after `from` with the fixture build's cost line logged just before it.
const costed = (h, from) => h.logs.slice(from).flatMap((e, i, all) =>
  e.event === 'storage_phases' && all[i - 1]?.event === 'storage_phases_cost' ? [{ row: e, cost: all[i - 1] }] : []);
const maxima = [];

await test('runtime-maxima: the runtime maxima, bytes and build time measured on the polling fixture build: the 100-candidate drain, the 16-page merge step, the 200-object GC tick; every line within 8,192 bytes', async () => {
  const pollingBuild = process.env.OPENCAST_POLLING_FIXTURE_BUILD;
  assert.ok(pollingBuild, 'OPENCAST_POLLING_FIXTURE_BUILD names the polling storage-fixture build');
  let items = [];
  const h = await harness(() => new Response(rss(items)), { logs: true, pollingBuild });
  await within(h, async () => {
    const t = Math.floor(Date.now() / 1000);
    const chain = async (name, count) => {
      const feed = await h.add(cohort(`https://witness.example.com/${name}`));
      items = [item('base', t - 86_400)];
      await h.invoke('test/dispatch'); await h.drain();
      items = [...Array.from({ length: count }, (_, i) => item(`${name}-${i}`, t - 60 - i)), item('base', t - 86_400)];
      await h.run('UPDATE n_feed SET due_at=0,retry_at=0,dispatch_until=0 WHERE feed_id=?', feed);
      await h.invoke('test/dispatch');
      const from = h.logs.length;
      await stepUntil(h, () => false, 400).catch(() => {});
      return costed(h, from).filter(x => x.row.chain?.feed === feed);
    };
    // The 100-candidate drain: one page of 100, its drain action maturing them.
    const drains = (await chain('maxima-drain', 100)).filter(x => x.row.action.some(a => a.name === 'drain'));
    assert.ok(drains.length, 'a drain line');
    const drain = drains.reduce((a, b) => (b.cost.bytes > a.cost.bytes ? b : a));
    maxima.push(['100-candidate drain', drain]);
    // The 16-page merge step: 1,700 candidates, the merge writing its 16 pages in one step.
    const prepares = (await chain('maxima-merge', 1700)).filter(x => x.row.action.some(a => a.name === 'prepare' && a.start_checkpoint?.phase === 3));
    assert.ok(prepares.length, 'a merge step line');
    maxima.push(['16-page merge step', prepares.reduce((a, b) => (b.cost.bytes > a.cost.bytes ? b : a))]);
    // The 200-object GC tick: 200 collectable snapshot objects under a lease no feed holds.
    const [owner] = await h.rows('SELECT feed_id FROM n_feed LIMIT 1');
    for (let i = 0; i < 200; i++) {
      await h.run("INSERT INTO n_snapshot(object_key,feed_id,owner_epoch,lease_id,sha256,bytes,state,created_at,gc_after) VALUES(?,?,1,'maxima-gc-lease','x',1,'uploaded',0,0)", `maxima-gc/${String(i).padStart(4, '0')}`, owner.feed_id);
    }
    const from = h.logs.length;
    await cleanup(h);
    const [gc] = costed(h, from).filter(x => x.row.handler === 'cleanup');
    assert.ok(gc, 'a cleanup line');
    assert.ok(gc.row.ops.total >= 600, `the tick claimed the objects: ${gc.row.ops.total} operations`);
    maxima.push(['200-object GC tick', gc]);
    for (const [name, { row, cost }] of maxima) {
      assert.ok(cost.bytes <= 8192, `${name}: ${cost.bytes} bytes`);
      report.push(`runtime-maxima ${name}: ${cost.bytes} bytes (${row.bytes_policy}; truncated ${Object.entries(row.truncated).filter(([, v]) => v).map(([k]) => k).join(',') || 'none'}), build ${cost.build_us} us, ${row.ops.total} operations, ${row.summary.races.total} races, wall ${row.wall_ms} ms`);
    }
    keep(h);
  });
}, );

const out = process.env.STORAGE_PHASES_ROWS_OUT;
if (out) writeFileSync(out, rows.map(r => JSON.stringify(r)).join('\n') + '\n');
for (const r of report) console.log('REPORT', r);
console.log(`${passed} passed, ${failed} failed`);
process.exitCode = failed ? 1 : 0;
