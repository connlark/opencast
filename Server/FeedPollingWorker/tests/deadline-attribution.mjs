// Gate item 12 (b): a queued deadline spent by our own storage is never
// settled as the publisher's fetch_failed. The publisher sends 5,000 items at
// once, then trickles the last 100 a few at a time until 19 s (each read well
// inside the 5 s inactivity bound). A spool part stalled 9 s mid-scan spends
// most of the 15 s, so on main the deadline expires while the scan waits on
// the trickle with no storage pending: a 599 on the origin and a publisher
// failure, although the publisher's own share stayed far under 15 s.
import assert from 'node:assert/strict';
import { harness } from './harness.mjs';

const MiB = 1024 * 1024;
const URL_ = 'https://trickle.example.com/feed';
const entry = (guid, title) => `<item><guid>${guid}</guid><title>${title}</title><enclosure url="https://audio.example.com/${guid}.mp3"/></item>`;
const head = '<rss><channel><title>Attribution fixture</title>';
const bulk = Array.from({ length: 5000 }, (_, i) => entry(`bulk-${i}`, `Quoted ${i} ${'"'.repeat(480)}`)).join('');
const tail = Array.from({ length: 20 }, (_, piece) => Array.from({ length: 5 }, (_, i) => entry(`tail-${piece * 5 + i}`, `Tail ${piece * 5 + i}`)).join(''));
const whole = head + bulk + tail.join('') + '</channel></rss>';
let trickle = false, requests = 0;
const timers = new Set();
const h = await harness(request => {
  if (request.url !== URL_) return new Response('missing', { status: 404 });
  requests++;
  if (!trickle) return new Response(whole);
  const encoder = new TextEncoder();
  return new Response(new ReadableStream({
    start(controller) {
      controller.enqueue(encoder.encode(head + bulk));
      tail.forEach((piece, i) => {
        const timer = setTimeout(() => {
          timers.delete(timer);
          try { controller.enqueue(encoder.encode(piece + (i === tail.length - 1 ? '</channel></rss>' : ''))); if (i === tail.length - 1) controller.close(); } catch {}
        }, 950 * (i + 1));
        timers.add(timer);
      });
    },
  }));
});
h.now -= h.now % 900;
const delivery = await h.instance.getWorker('delivery-runtime');
async function at(seconds) {
  await h.invoke('clock', String(seconds));
  await (await delivery.fetch('https://delivery.invalid/clock', { method: 'POST', body: String(h.now + seconds - Math.floor(Date.now() / 1000)) })).text();
}

try {
  await h.run("UPDATE n_control SET enabled=0 WHERE name='cleanup'");
  // The wall clock runs (no freeze), so poll_delivery's publisher_fetch_ms is real.
  await at(0);
  assert.ok(Buffer.byteLength(whole) < 5 * MiB, 'the body fits the buffer');
  const feed = await h.add(URL_, 0);
  await h.invoke('test/dispatch'); await h.drain(); await h.deliver(true);
  assert.equal((await h.first('SELECT last_poll_outcome FROM n_feed WHERE feed_id=?', feed)).last_poll_outcome, 'published');

  // The same document, trickled, rescanned as one full pass inside the fetch.
  await at(120); await h.drain();
  trickle = true;
  await h.run('UPDATE n_feed SET semantic_digest=NULL,due_at=0,retry_at=0,poll_failures=0,dispatch_until=0 WHERE feed_id=?', feed);
  await h.run('DELETE FROM n_poll_origin');
  await h.invoke('test/dispatch');
  const wake = (await h.polls()).find(w => w.feed_id === feed); assert.ok(wake, 'feed was not dispatched');
  const before = await h.invoke('metrics'), seen = requests;
  await h.invoke('fault', 'slow_part:9000');
  const start = performance.now();
  const consumed = await h.consume(wake);
  const wall = performance.now() - start;
  const after = await h.invoke('metrics');
  const logged = Object.fromEntries(Object.entries(after.logged).map(([k, n]) => [k, n - (before.logged[k] ?? 0)]).filter(([, n]) => n));
  const state = await h.first('SELECT last_poll_outcome,poll_failures,handling_failures FROM n_feed WHERE feed_id=?', feed);
  const origins = await h.rows('SELECT failures,last_status FROM n_poll_origin');
  const delivered = after.deliveries.at(-1);
  const facts = `status ${consumed.status} ${consumed.text} wall ${Math.round(wall)} ms logged ${JSON.stringify(logged)} feed ${JSON.stringify(state)} origins ${JSON.stringify(origins)} publisher_fetch_ms ${delivered?.publisher_fetch_ms} storage_ms ${delivered?.storage_ms}`;
  console.log(`attribution: ${facts}`);

  assert.equal(await (await h.instance.dispatchFetch('https://polling.invalid/fault-state')).text(), '', `the stalled part upload ran: ${facts}`);
  assert.equal(requests - seen, 1, `one publisher request: ${facts}`);
  assert.ok(wall > 15000, `the scan outlasted the 15 s queued deadline: ${facts}`);
  assert.ok(delivered && delivered.publisher_fetch_ms < 15000, `the publisher's own share stayed under 15 s: ${facts}`);
  assert.equal(logged['upstream_error:fetch_failed'], undefined, `our storage's time is not the publisher's fetch_failed: ${facts}`);
  assert.deepEqual(origins.filter(o => o.last_status === 599 || o.failures > 0), [], `no 599 recorded against the origin: ${facts}`);
  assert.equal(state.poll_failures, 0, `no publisher failure settled: ${facts}`);
  assert.equal(consumed.status, 200, facts);
  assert.ok(['unchanged', 'published'].includes(state.last_poll_outcome), `the feed settles: ${facts}`);
  assert.equal(state.handling_failures, 0, facts);
  console.log('PASS deadline-attribution: a deadline our storage spent is not settled as the publisher\'s fetch_failed');
} finally { for (const timer of timers) clearTimeout(timer); await h.instance.dispose(); }
