// The two-pass scan. The probe parses a 200 into exact identity and
// fingerprint sets while retaining the body (5 MiB in the isolate, the rest in
// one scratch multipart upload); an equal digest settles there. Only a changed
// digest replays the retained body through the full observation, never a
// second publisher request. The publisher sends no validators, so every poll
// parses.
import assert from 'node:assert/strict';
import { harness } from './harness.mjs';

const MiB = 1024 * 1024;
const serve = new Map(), requests = new Map();
const h = await harness(request => {
  requests.set(request.url, (requests.get(request.url) ?? 0) + 1);
  const body = serve.get(request.url);
  return body == null ? new Response('missing', { status: 404 }) : new Response(body);
});
const bucket = await h.instance.getR2Bucket('FEED_SNAPSHOTS', 'polling-runtime');
const delivery = await h.instance.getWorker('delivery-runtime');
let offset = 0;
async function at(seconds) {
  offset = seconds; await h.invoke('clock', String(seconds));
  await (await delivery.fetch('https://delivery.invalid/clock', { method: 'POST', body: String(seconds) })).text();
}
const entry = ({ guid, at: date, title = `Episode ${guid}`, description }) => `<item><guid>${guid}</guid><title>${title}</title>${description == null ? '' : `<description>${description}</description>`}${date == null ? '' : `<pubDate>${new Date(date * 1000).toUTCString()}</pubDate>`}<enclosure url="https://audio.example.com/${guid}.mp3"/></item>`;
const document = items => `<rss><channel><title>Two-pass fixture</title>${items.map(entry).join('')}</channel></rss>`;
const COUNTERS = ['get', 'put', 'head', 'delete', 'multipart', 'multipart_create', 'multipart_part', 'multipart_complete', 'multipart_abort', 'scratch_get', 'scratch_delete', 'scratch_peak_bytes'];
const row = feed => h.first('SELECT * FROM n_feed WHERE feed_id=?', feed);
const scratch = async () => (await bucket.list({ prefix: 'scratch/' })).objects.length;
const bounds = feed => h.rows("SELECT scan_started_at FROM n_observation WHERE feed_id=? AND state='staging' AND valid_eof=0 AND recovery_evidence=1", feed);
// Dispatch `feed` alone and consume its poll message; the response JSON is the
// consumer's own. `retry` replays the same message as a redelivery.
let wake;
async function consume(feed, url, { step = 60, attempts = 1, fault } = {}) {
  await at(offset + step);
  // Work that came due with the clock runs first, so only this poll is measured.
  await h.drain();
  if (attempts === 1) {
    await h.run('UPDATE n_feed SET due_at=? WHERE feed_id<>?', h.now + 100 * 86400, feed);
    await h.run('UPDATE n_feed SET due_at=0,retry_at=0,poll_failures=0,dispatch_until=0 WHERE feed_id=?', feed);
    await h.run('DELETE FROM n_poll_origin');
    await h.invoke('test/dispatch');
    wake = (await h.polls()).find(w => w.feed_id === feed); assert.ok(wake, 'feed was not dispatched');
  }
  const seen = requests.get(url) ?? 0, before = await h.invoke('metrics');
  if (fault) await h.invoke('fault', fault);
  const consumed = await h.consume(wake, { attempts });
  // Requests made while this one message ran: the scan and any replay.
  const made = (requests.get(url) ?? 0) - seen;
  let result; try { result = JSON.parse(consumed.text); } catch {}
  if (consumed.status === 200) { await h.drain(); await h.deliver(true); }
  const after = await h.invoke('metrics');
  return {
    status: consumed.status, text: consumed.text, result, passes: result?.passes, requests: made,
    r2: Object.fromEntries(COUNTERS.map(k => [k, after[k] - before[k]])),
    logged: Object.fromEntries(Object.entries(after.logged).map(([k, n]) => [k, n - (before.logged[k] ?? 0)]).filter(([, n]) => n)),
    state: await row(feed),
  };
}
const release = (feed, episode) => h.first("SELECT r.first_observed_at,r.expires_at,r.reason,json_extract(x.payload_json,'$.data.episode_title') AS title FROM n_episode_release r LEFT JOIN n_outbox x ON x.event_id=r.event_id WHERE r.feed_id=? AND r.episode_id=(SELECT episode_id FROM n_episode_release WHERE feed_id=? AND json_extract(metadata_json,'$.title')=?)", feed, feed, episode);
const releases = async feed => (await h.first('SELECT COUNT(*) AS n FROM n_episode_release WHERE feed_id=?', feed)).n;

try {
  await h.run("UPDATE n_control SET enabled=0 WHERE name='cleanup'");
  await h.invoke('freeze', String(h.now)); await at(0);

  // Small body: three items, well inside the 5 MiB buffer.
  const SMALL = 'https://small.example.com/feed';
  const small = await h.add(SMALL);
  let smallItems = [1, 2, 3].map(i => ({ guid: `small-${i}`, at: h.now - i * 86400, description: `Small notes ${i}.` }));
  serve.set(SMALL, document(smallItems));
  assert.equal((await consume(small, SMALL, { step: 0 })).state.last_poll_outcome, 'published');

  // 1. Unchanged small body: one parse, no R2 at all, validators refreshed.
  let p = await consume(small, SMALL);
  assert.equal(p.passes, 1, `unchanged small body: passes from ${p.text}`);
  assert.equal(p.result.outcome, 'unchanged'); assert.equal(p.state.last_poll_outcome, 'unchanged');
  assert.deepEqual(p.r2, Object.fromEntries(COUNTERS.map(k => [k, 0])), 'no R2 get/put/head/multipart and no scratch');
  assert.equal(p.requests, 1);
  assert.deepEqual([p.state.validator_url, p.state.validator_at], [SMALL, h.now + offset], 'the unchanged settle refreshed the validator binding');
  console.log('PASS case 1: unchanged small body is one pass with zero R2 calls; validator_url/validator_at refreshed');

  // 2. Changed small body: two passes over one response.
  const events = (await h.first('SELECT COUNT(*) AS n FROM n_event')).n;
  smallItems = [{ guid: 'small-new', title: 'Small release', at: h.now + offset + 60 - 30, description: '<![CDATA[<p>New <em>small</em> release &amp; notes.</p>]]>' }, ...smallItems];
  serve.set(SMALL, document(smallItems));
  p = await consume(small, SMALL);
  assert.equal(p.passes, 2, `changed small body: passes from ${p.text}`);
  assert.equal(p.requests, 1, 'exactly one publisher request');
  assert.equal(p.state.last_poll_outcome, 'published');
  assert.equal((await h.first('SELECT COUNT(*) AS n FROM n_event')).n, events + 1);
  assert.deepEqual(await h.rows("SELECT json_extract(x.payload_json,'$.data.episode_title') AS title,json_extract(x.payload_json,'$.data.episode_summary') AS summary FROM n_outbox x JOIN n_episode_release r ON r.event_id=x.event_id WHERE r.feed_id=?", small), [{ title: 'Small release', summary: 'New small release & notes.' }]);
  console.log('PASS case 2: changed small body is two passes over one publisher request and publishes the release');

  // Large body: over the 5 MiB buffer, so the probe spills it to scratch.
  const LARGE = 'https://large.example.com/feed';
  const large = await h.add(LARGE);
  const notes = i => `<![CDATA[${`<p>Large item ${i} with <a href="https://example.com/${i}">a link</a> &amp; words.</p>`.repeat(48).slice(0, 3060)}]]>`;
  let largeItems = Array.from({ length: 2000 }, (_, i) => ({ guid: `large-${i}`, at: h.now - 30 * 86400 - i * 60, description: notes(i) }));
  serve.set(LARGE, document(largeItems));
  const largeBytes = Buffer.byteLength(serve.get(LARGE));
  assert.ok(largeBytes > 5 * MiB && largeBytes < 10 * MiB, `large body is ${largeBytes} bytes`);
  assert.equal((await consume(large, LARGE)).state.last_poll_outcome, 'published');

  // 3. Unchanged large body: one pass; the spilled body is aborted, never read.
  p = await consume(large, LARGE);
  assert.equal(p.passes, 1, `unchanged large body: passes from ${p.text}`);
  assert.equal(p.state.last_poll_outcome, 'unchanged');
  assert.deepEqual([p.r2.multipart_create, p.r2.multipart_part, p.r2.multipart_abort, p.r2.multipart_complete], [1, Math.floor(largeBytes / (5 * MiB)), 1, 0], 'body parts uploaded, then aborted');
  assert.deepEqual([p.r2.get, p.r2.put, p.r2.head, p.r2.scratch_get], [0, 0, 0, 0], 'no object and no read');
  assert.equal(await scratch(), 0);
  console.log(`PASS case 3: unchanged ${(largeBytes / MiB).toFixed(1)} MiB body is one pass: multipart create, ${p.r2.multipart_part} part, abort; no object, no get`);

  // 4. Changed large body: the retained body is completed, read back by range
  // for the replay, then deleted. Still one publisher request.
  largeItems = [{ guid: 'large-new', title: 'Large release', at: h.now + offset + 60 - 30, description: '<![CDATA[<p>Large <b>feed</b> release.</p>]]>' }, ...largeItems];
  serve.set(LARGE, document(largeItems));
  p = await consume(large, LARGE);
  assert.equal(p.passes, 2, `changed large body: passes from ${p.text}`);
  assert.equal(p.requests, 1, 'exactly one publisher request');
  assert.ok(p.r2.multipart_complete >= 1 && p.r2.scratch_get >= 1 && p.r2.scratch_delete >= 1, `complete, range gets and delete: ${JSON.stringify(p.r2)}`);
  assert.equal(p.state.last_poll_outcome, 'published');
  assert.equal(await scratch(), 0, 'the completed body is deleted after the replay');
  assert.deepEqual(await release(large, 'Large release'), { first_observed_at: h.now + offset, expires_at: (await release(large, 'Large release')).expires_at, reason: 'recent', title: 'Large release' });
  console.log(`PASS case 4: changed large body is two passes over one request: ${p.r2.multipart_complete} complete, ${p.r2.scratch_get} range gets, ${p.r2.scratch_delete} delete; published`);

  // 5a. A scratch write fails during the replay. The body fits the buffer but
  // its spool does not: a title of quotes doubles under JSON escaping, so
  // the probe uploads nothing and the replay's spool is the first scratch write.
  const QUOTED = 'https://quoted.example.com/feed';
  const quoted = await h.add(QUOTED);
  let quotedItems = Array.from({ length: 5000 }, (_, i) => ({ guid: `quoted-${i}`, title: `Quoted ${i} ${'"'.repeat(480)}`, at: h.now - 30 * 86400 - i * 60 }));
  serve.set(QUOTED, document(quotedItems));
  assert.ok(Buffer.byteLength(serve.get(QUOTED)) < 5 * MiB, 'the quoted body fits the buffer');
  assert.equal((await consume(quoted, QUOTED)).state.last_poll_outcome, 'published');
  quotedItems = [{ guid: 'quoted-new', title: 'Quoted release' }, ...quotedItems];
  serve.set(QUOTED, document(quotedItems));
  const generation = (await row(quoted)).observation_generation;
  p = await consume(quoted, QUOTED, { fault: 'scratch_uploadPart' });
  const failedAt = h.now + offset;
  assert.notEqual(p.status, 200, `the replay's scratch failure is retryable handling trouble: ${p.text}`);
  assert.equal(p.logged['storage_error:observation_stage_failed'], 1, JSON.stringify(p.logged));
  assert.equal(p.requests, 1);
  assert.ok(p.r2.multipart_create >= 1 && p.r2.multipart_abort >= 1, `the spool upload was aborted: ${JSON.stringify(p.r2)}`);
  assert.equal(await scratch(), 0);
  assert.deepEqual((await bounds(quoted)).map(b => b.scan_started_at), [failedAt], 'the failed scan recorded its first-observed bound');
  assert.equal((await row(quoted)).observation_generation, generation, 'nothing published');
  p = await consume(quoted, QUOTED, { attempts: 2, step: 120 });
  assert.equal(p.status, 200, p.text); assert.equal(p.passes, 2);
  assert.equal(p.state.last_poll_outcome, 'published');
  let kept = await release(quoted, 'Quoted release');
  assert.deepEqual([kept.reason, kept.first_observed_at, kept.expires_at], ['undated', failedAt, failedAt + 86400], 'the retry publishes with the original bound');
  console.log('PASS case 5a: a scratch write failing during the replay is storage_error: bound recorded, upload aborted, the retry publishes with the original bound');

  // 5b. The spilled body's read back stalls past the scan deadline.
  largeItems = [{ guid: 'large-slow', title: 'Slow release' }, ...largeItems];
  serve.set(LARGE, document(largeItems));
  const start = performance.now();
  p = await consume(large, LARGE, { fault: 'slow_get' });
  const slowAt = h.now + offset, wall = performance.now() - start;
  assert.notEqual(p.status, 200, `the stalled replay read is retryable handling trouble: ${p.text}`);
  assert.equal(Object.keys(p.logged).filter(k => k.startsWith('storage_error:')).length, 1, JSON.stringify(p.logged));
  assert.equal(await (await h.instance.dispatchFetch('https://polling.invalid/fault-state')).text(), '', 'the stalled get was the replay read');
  assert.equal(p.requests, 1);
  assert.equal(await scratch(), 0, 'the completed body was deleted on failure');
  assert.ok((await bounds(large)).some(b => b.scan_started_at === slowAt), 'the failed scan recorded its first-observed bound');
  p = await consume(large, LARGE, { attempts: 2, step: 120 });
  assert.equal(p.status, 200, p.text); assert.equal(p.passes, 2);
  assert.equal(p.state.last_poll_outcome, 'published');
  kept = await release(large, 'Slow release');
  assert.deepEqual([kept.reason, kept.first_observed_at, kept.expires_at], ['undated', slowAt, slowAt + 86400], 'the retry publishes with the original bound');
  console.log(`PASS case 5b: a stalled spilled-body read trips the scan deadline (${Math.round(wall)} ms): storage_error, bound recorded, body deleted, the retry publishes with the original bound`);

  // 6. Without a bound digest a probe could never say unchanged: one full pass,
  // which repairs the digest; the next poll is the probe again.
  await h.run('UPDATE n_feed SET semantic_digest=NULL WHERE feed_id=?', small);
  p = await consume(small, SMALL);
  assert.equal(p.passes, 1, `unbound digest: passes from ${p.text}`);
  assert.equal(p.requests, 1);
  assert.match(p.state.semantic_digest, new RegExp(`^${p.state.snapshot_key}:[0-9a-f]{64}$`), 'the digest is repaired');
  p = await consume(small, SMALL);
  assert.deepEqual([p.passes, p.state.last_poll_outcome], [1, 'unchanged']);
  console.log('PASS case 6: an unbound digest is a single full pass that repairs it; the next poll probes and settles unchanged');
} finally { await h.instance.dispose(); }
