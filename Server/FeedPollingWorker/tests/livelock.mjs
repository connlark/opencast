// Finite Queue service continues across dispatch ticks. Never drain between
// ticks: an outage must recover without discarding old messages or redeploying.
import assert from 'node:assert/strict';
import { writeFile } from 'node:fs/promises';
import { harness, item, rss } from './harness.mjs';

let changed = false;
const h = await harness(request => request.headers.has('if-none-match') && !changed
  ? new Response(null, { status: 304 })
  : new Response(rss([item('baseline', h.now - 86400), ...(changed ? [item('release', null)] : [])]), { headers: { etag: changed ? '"v2"' : '"v1"' } }));
const queue = [], samples = [], settled = new Set();
let obsoleteUnsettled = 0, generationViolations = 0, lateTicks = 0, maximumRepairs = 0;
const state = () => h.rows('SELECT feed_id,schedule_generation,dispatch_until FROM n_feed');
try {
  for (let i = 0; i < 80; i++) await h.add(`https://host-${i % 8}.example.com/${i}`);
  await h.invoke('test/dispatch'); await h.drain();
  const baselinePublications = (await h.first("SELECT COUNT(*) AS n FROM n_observation WHERE state='published'")).n;
  const start = h.now + 120;
  await h.run('UPDATE n_feed SET due_at=?', start);
  changed = true;
  const ticks = 100;
  for (let tick = 0; tick < ticks; tick++) {
    const at = start + tick * 60;
    await h.invoke('freeze', String(at));
    const delivery = await h.instance.getWorker('delivery-runtime');
    await (await delivery.fetch('https://delivery.invalid/clock', { method: 'POST', body: String(at - Math.floor(Date.now() / 1000)) })).text();
    const before = new Map((await state()).map(row => [row.feed_id, row]));
    const rollup = await h.invoke('test/dispatch');
    const wakes = await h.polls();
    const repairs = wakes.filter(w => before.get(w.feed_id).dispatch_until > 0);
    // Check the bound from messages as well as the diagnostic field.
    maximumRepairs = Math.max(maximumRepairs, repairs.length);
    for (const row of await state()) {
      const previous = before.get(row.feed_id);
      if (row.schedule_generation !== previous.schedule_generation + (previous.dispatch_until === 0 && row.dispatch_until > 0 ? 1 : 0)) generationViolations++;
    }
    // Reorder adjacent wakeups and retain duplicate copies, including later
    // continuations. Each copy consumes a real slot in the finite budget.
    wakes.reverse();
    for (const wake of wakes) {
      queue.push({ wake, enqueued: at });
      if (tick === 0 && queue.length % 10 === 0) queue.push({ wake, enqueued: at });
    }
    if (queue.length && at - queue[0].enqueued > 300) lateTicks++;
    const budget = tick < 30 ? 1 : 40;
    for (let slot = 0; slot < budget && queue.length; slot++) {
      const { wake } = queue.shift();
      const row = await h.first('SELECT dispatch_until FROM n_feed WHERE feed_id=?', wake.feed_id);
      const result = await h.consume(wake);
      assert.equal(result.status, 200, result.text);
      const obligation = `${wake.feed_id}:${wake.generation}`;
      if (row.dispatch_until > 0 && !settled.has(obligation) && result.outcome === 'obsolete') obsoleteUnsettled++;
      const after = await h.first('SELECT dispatch_until,schedule_generation FROM n_feed WHERE feed_id=?', wake.feed_id);
      if (after.dispatch_until === 0) settled.add(`${wake.feed_id}:${after.schedule_generation}`);
      for (const next of await h.polls()) {
        queue.push({ wake: next, enqueued: at });
        if (next.step === 1) queue.push({ wake: next, enqueued: at });
      }
    }
    await h.deliver();
    const stats = await h.invoke('test/stats');
    samples.push({ tick, backlog: queue.length, oldest: stats.oldest_due_seconds, repairs: repairs.length, admitted: rollup.admitted });
  }
  const report = { obsoleteUnsettled, generationViolations, lateTicks, maximumRepairs, samples };
  await writeFile('/private/tmp/opencast-poll-livelock.json', JSON.stringify(report, null, 2));
  console.log(JSON.stringify({ obsoleteUnsettled, generationViolations, lateTicks, final: samples.at(-1) }));
  assert.ok(lateTicks >= 10, 'at least ten ticks with queue wait above the reservation');
  assert.equal(obsoleteUnsettled, 0, 'an old queued wakeup for unsettled work remains useful');
  assert.equal(generationViolations, 0, 'generation advances only for a new settled cycle');
  assert.ok(maximumRepairs <= 20, `repair limit: ${maximumRepairs}`);
  assert.equal(queue.length, 0, 'finite service drains the retained backlog unaided');
  assert.ok(samples.at(-1).oldest < 60, 'oldest overdue age converges after capacity returns');
  const delivery = await h.instance.getWorker('delivery-runtime');
  await (await delivery.fetch('https://delivery.invalid/clock', { method: 'POST', body: String(start + (ticks + 1) * 60 - Math.floor(Date.now() / 1000)) })).text();
  await h.deliver(true);
  assert.equal((await h.first("SELECT COUNT(*) AS n FROM n_observation WHERE state='published'")).n, baselinePublications + 80, 'one publication of each changed feed');
  assert.equal((await h.first('SELECT COUNT(*) AS n FROM n_event')).n, 80, 'one logical event per release');
  assert.equal(h.sends.length, 80, 'one send per release despite duplicate and reordered continuations');
  console.log('PASS finite-service reservation livelock, coalescing, duplicate publication/event/send and unaided recovery');

  // One shared repair budget, oldest reservation first, even when maintenance
  // is backed off and fresh baseline obligations are admitted alongside it.
  const at = start + ticks * 60;
  await h.invoke('freeze', String(at));
  await h.run('UPDATE n_feed SET due_at=?', at + 7200);
  const recurring = (await state()).slice(0, 20).map(row => row.feed_id);
  await h.run('UPDATE n_feed SET dispatch_until=?,due_at=? WHERE feed_id IN(SELECT value FROM json_each(?))', at - 200, at - 100, JSON.stringify(recurring));
  const maintenance = recurring.slice(0, 10);
  await h.run("UPDATE n_outbox SET state='pending',next_attempt_at=0 WHERE observation_id IN(SELECT observation_id FROM n_observation WHERE feed_id IN(SELECT value FROM json_each(?)))", JSON.stringify(maintenance));
  await h.run('UPDATE n_feed SET dispatch_until=?,due_at=?,retry_at=? WHERE feed_id IN(SELECT value FROM json_each(?))', at - 300, at + 7200, at + 7200, JSON.stringify(maintenance));
  const baselines = [];
  for (let i = 0; i < 10; i++) baselines.push(await h.add(`https://repair-baseline-${i}.example.com/feed`, at - 100));
  await h.run('UPDATE n_feed SET dispatch_until=?,schedule_generation=1 WHERE feed_id IN(SELECT value FROM json_each(?))', at - 100, JSON.stringify(baselines));
  const fresh = await h.add('https://fresh.example.com/feed', at);
  const repairRollup = await h.invoke('test/dispatch');
  const repairWakes = await h.polls();
  assert.equal(repairRollup.repairs, 20);
  assert.equal(repairRollup.admitted, 1, 'new work does not consume the repair limit');
  assert.deepEqual(new Set(repairWakes.map(w => w.feed_id)), new Set([...recurring, fresh]), 'oldest maintenance and recurring reservations win over newer baselines');
  // A second overlapping pair cannot reserve a feed twice.
  await Promise.all([h.invoke('test/dispatch'), h.invoke('test/dispatch')]);
  const overlap = await h.polls();
  assert.equal(overlap.length, 10);
  assert.equal(new Set(overlap.map(w => w.feed_id)).size, 10);
  console.log('PASS shared oldest-first repair budget, independent new admission and overlapping reservations');

  await h.run('UPDATE n_feed SET admission_paused=1');
  const uncertain = await h.add('https://uncertain.example.com/feed', at);
  await h.invoke('fault', 'after_enqueue');
  await assert.rejects(h.invoke('test/dispatch'), error => error.actual === 500);
  const retained = (await h.polls()).find(w => w.feed_id === uncertain);
  assert.ok(retained, 'the uncertain send did reach the queue');
  const lapsed = await h.first('SELECT dispatch_until,schedule_generation FROM n_feed WHERE feed_id=?', uncertain);
  assert.equal(lapsed.dispatch_until, at, 'uncertain sends lapse rather than settle');
  await h.invoke('freeze', String(at + 60));
  assert.equal((await h.invoke('test/dispatch')).repairs, 1);
  const retry = (await h.polls()).find(w => w.feed_id === uncertain);
  assert.equal(retry.generation, retained.generation);
  assert.notEqual((await h.consume(retained)).outcome, 'obsolete', 'an uncertain send that arrived remains useful');
  await h.consume(retry); await h.drain();
  assert.equal((await h.first('SELECT schedule_generation FROM n_feed WHERE feed_id=?', uncertain)).schedule_generation, lapsed.schedule_generation);
  console.log('PASS uncertain enqueue repairs the same generation and retained copies remain useful');
} finally { await h.instance.dispose(); }
