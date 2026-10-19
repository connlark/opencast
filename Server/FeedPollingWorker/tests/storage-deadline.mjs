// Gate item 12 (a): a queued scan whose own storage outlasts the queued scan
// deadline settles instead of failing as handling trouble. The spool of a
// changed or unbound scan is written mid-scan as scratch multipart parts; one
// part stalled 16 s holds the scan past the publisher's 15 s while the
// publisher has long answered. On main this is storage_error:storage_failed,
// a 500 the Queue redelivers, and after attempt 4 a dead letter.
import assert from 'node:assert/strict';
import { harness } from './harness.mjs';

const MiB = 1024 * 1024;
const serve = new Map(), requests = new Map();
const h = await harness(request => {
  requests.set(request.url, (requests.get(request.url) ?? 0) + 1);
  const body = serve.get(request.url);
  return body == null ? new Response('missing', { status: 404 }) : new Response(body);
});
h.now -= h.now % 900;
const delivery = await h.instance.getWorker('delivery-runtime');
let offset = 0;
async function at(seconds) {
  offset = seconds; await h.invoke('clock', String(seconds));
  await (await delivery.fetch('https://delivery.invalid/clock', { method: 'POST', body: String(h.now + seconds - Math.floor(Date.now() / 1000)) })).text();
}
// The body fits the 5 MiB buffer but its spool does not: a title of quotes
// doubles under JSON escaping (two-pass.mjs case 5a), so the probe uploads
// nothing and the full observation's spool writes one scratch part mid-scan.
const entry = ({ guid, at: date, title }) => `<item><guid>${guid}</guid><title>${title}</title>${date == null ? '' : `<pubDate>${new Date(date * 1000).toUTCString()}</pubDate>`}<enclosure url="https://audio.example.com/${guid}.mp3"/></item>`;
const document = items => `<rss><channel><title>Storage deadline fixture</title>${items.map(entry).join('')}</channel></rss>`;
const quoted = name => Array.from({ length: 5000 }, (_, i) => ({ guid: `${name}-${i}`, title: `Quoted ${i} ${'"'.repeat(480)}`, at: h.now - 30 * 86400 - i * 60 }));
const row = feed => h.first('SELECT * FROM n_feed WHERE feed_id=?', feed);
let wake;
async function consume(feed, url, { fault } = {}) {
  await at(offset + 60);
  await h.drain();
  await h.run('UPDATE n_feed SET due_at=? WHERE feed_id<>?', h.now + 100 * 86400, feed);
  await h.run('UPDATE n_feed SET due_at=0,retry_at=0,poll_failures=0,dispatch_until=0 WHERE feed_id=?', feed);
  await h.run('DELETE FROM n_poll_origin');
  await h.invoke('test/dispatch');
  wake = (await h.polls()).find(w => w.feed_id === feed); assert.ok(wake, 'feed was not dispatched');
  const seen = requests.get(url) ?? 0, before = await h.invoke('metrics');
  if (fault) await h.invoke('fault', fault);
  const start = performance.now();
  const consumed = await h.consume(wake);
  const wall = performance.now() - start;
  let result; try { result = JSON.parse(consumed.text); } catch {}
  if (consumed.status === 200) { await h.drain(); await h.deliver(true); }
  const after = await h.invoke('metrics');
  return {
    status: consumed.status, text: consumed.text, passes: result?.passes, wall, requests: (requests.get(url) ?? 0) - seen,
    parts: after.multipart_part - before.multipart_part,
    logged: Object.fromEntries(Object.entries(after.logged).map(([k, n]) => [k, n - (before.logged[k] ?? 0)]).filter(([, n]) => n)),
    fault: await (await h.instance.dispatchFetch('https://polling.invalid/fault-state')).text(),
    state: await row(feed),
  };
}
// Both cases always run, so a red run shows each case's own failure.
const failures = [];
async function check(name, run) {
  try { await run(); console.log(`PASS ${name}`); }
  catch (error) { failures.push(name); console.log(`FAIL ${name}: ${error.message}`); }
}
function settled(p, passes, outcomes) {
  const facts = `status ${p.status} ${p.text} wall ${Math.round(p.wall)} ms logged ${JSON.stringify(p.logged)} last_poll_outcome ${p.state.last_poll_outcome}`;
  assert.equal(p.fault, '', `the stalled part upload ran: ${facts}`);
  assert.ok(p.wall > 15000, `the scan's storage outlasted the 15 s queued deadline: ${facts}`);
  assert.equal(p.requests, 1, `one publisher request: ${facts}`);
  assert.equal(p.status, 200, `slow storage after the publisher answered must settle, not fail into a redelivery: ${facts}`);
  assert.deepEqual(Object.keys(p.logged).filter(k => k.startsWith('storage_error:') || k.startsWith('upstream_error:')), [], `no storage or publisher failure: ${facts}`);
  assert.equal(p.passes, passes, facts);
  assert.ok(outcomes.includes(p.state.last_poll_outcome), facts);
  assert.deepEqual([p.state.poll_failures, p.state.handling_failures], [0, 0], facts);
}

try {
  await h.run("UPDATE n_control SET enabled=0 WHERE name='cleanup'");
  await h.invoke('freeze', String(h.now)); await at(0);
  const ONE = 'https://one-pass.example.com/feed', TWO = 'https://two-pass.example.com/feed';
  const one = await h.add(ONE), two = await h.add(TWO);
  serve.set(ONE, document(quoted('one'))); serve.set(TWO, document(quoted('two')));
  assert.ok(Buffer.byteLength(serve.get(ONE)) < 5 * MiB, 'the body fits the buffer');
  assert.equal((await consume(one, ONE)).state.last_poll_outcome, 'published');
  assert.equal((await consume(two, TWO)).state.last_poll_outcome, 'published');

  await check('(a1) one full pass: a spool part stalled 16 s inside the fetch settles', async () => {
    // Without a bound digest the full observation runs inside the fetch.
    await h.run('UPDATE n_feed SET semantic_digest=NULL WHERE feed_id=?', one);
    const p = await consume(one, ONE, { fault: 'slow_part:16000' });
    assert.ok(p.parts >= 1, `the spool wrote a part mid-scan: ${p.parts}`);
    settled(p, 1, ['unchanged', 'published']);
  });

  await check('(a2) two passes: a spool part stalled 16 s inside the replay settles', async () => {
    serve.set(TWO, document([{ guid: 'two-new', title: 'Two-pass release' }, ...quoted('two')]));
    const p = await consume(two, TWO, { fault: 'slow_part:16000' });
    settled(p, 2, ['published']);
  });

  assert.deepEqual(failures, [], 'every case settles');
  console.log('PASS storage-deadline: storage past the queued scan deadline settles in one attempt');
} finally { await h.instance.dispose(); }
