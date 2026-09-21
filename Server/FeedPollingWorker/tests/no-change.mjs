import assert from 'node:assert/strict';
import { setTimeout } from 'node:timers/promises';
import { writeFile } from 'node:fs/promises';
import { harness, item, rss } from './harness.mjs';
let behavior;
const h = await harness(request => behavior(request));
const bucket = await h.instance.getR2Bucket('FEED_SNAPSHOTS', 'polling-runtime');
const TABLES = ['n_observation', 'n_snapshot', 'n_snapshot_ref', 'n_episode_release', 'n_outbox', 'n_event', 'n_delivery'];
const durable = async () => ({ ...Object.fromEntries(await Promise.all(TABLES.map(async t => [t, (await h.first(`SELECT COUNT(*) AS n FROM ${t}`)).n]))), objects: (await bucket.list()).objects.length });
const scratch = async () => (await bucket.list({ prefix: 'scratch/' })).objects.length;
// On a fifteen-minute boundary the dispatcher also admits a cleanup wakeup.
const last = async () => (await h.invoke('metrics')).recent.filter(t => t.path === '/test/consume' && t.outcome !== 'cleanup_saved').at(-1);
const poll = async feed => { await h.run('UPDATE n_feed SET due_at=0,retry_at=0,poll_failures=0,dispatch_until=0 WHERE feed_id=?', feed); await h.invoke('test/dispatch'); await h.drain(); return last(); };
const pointer = feed => h.first('SELECT observation_generation,snapshot_key,semantic_digest FROM n_feed WHERE feed_id=?', feed);
try {
  // Bodies that differ byte-for-byte but not in membership are schedule
  // updates. Each case below is a changed body for a caching proxy.
  const base = [item('pin', h.now - 40 * 86400), item('one', h.now - 9 * 86400), item('two', h.now - 8 * 86400), item('three', h.now - 7 * 86400)];
  let document = base, build = 0;
  behavior = () => new Response(`<rss><channel><title>Fixture</title><lastBuildDate>${new Date(Date.now() + ++build * 1000).toUTCString()}</lastBuildDate>${document.join('')}</channel></rss>`);
  const feed = await h.add('https://membership.example.com/feed');
  assert.equal((await poll(feed)).outcome, 'published');
  const published = await pointer(feed), before = await durable();
  assert.match(published.semantic_digest, new RegExp(`^${published.snapshot_key}:[0-9a-f]{64}$`));
  for (const [name, next] of Object.entries({
    'rebuilt channel metadata': base,
    'reordered items': [base[3], base[1], base[0], base[2]],
    'pinned item moved': [base[1], base[2], base[3], base[0]],
    'duplicated item': [...base, base[2]],
  })) {
    document = next;
    const trace = await poll(feed);
    assert.equal(trace.outcome, 'unchanged', name);
    assert.deepEqual(await durable(), before, `${name}: no observation, snapshot, candidate, event or receipt row`);
    assert.deepEqual(await pointer(feed), published, `${name}: the published checkpoint is untouched`);
    assert.deepEqual([trace.put, trace.get, trace.head, trace.list, trace.multipart, trace.queue_messages], [0, 0, 0, 0, 0, 0], name);
  }
  console.log('PASS rebuilt, reordered, pinned and duplicated bodies are unchanged: zero durable rows, objects or messages');

  // A change is never suppressed. Each of these moves the generation once.
  let generation = 1;
  for (const [name, next, events] of [
    ['edited title changes a fingerprint', [base[0], item('one', h.now - 9 * 86400, 'Episode one (corrected)'), base[2], base[3]], 0],
    ['removed item', [base[0], base[2], base[3]], 0],
    ['returned item', [base[0], item('one', h.now - 9 * 86400, 'Episode one (corrected)'), base[2], base[3]], 0],
    ['bonus release below the pin', [base[0], item('one', h.now - 9 * 86400, 'Episode one (corrected)'), base[2], base[3], item('bonus', h.now - 30)], 1],
  ]) {
    document = next;
    const sent = (await h.first('SELECT COUNT(*) AS n FROM n_event')).n;
    await poll(feed);
    assert.equal((await pointer(feed)).observation_generation, ++generation, name);
    assert.equal((await h.first('SELECT COUNT(*) AS n FROM n_event')).n, sent + events, name);
    assert.equal((await poll(feed)).outcome, 'unchanged', `${name}: the next identical poll is unchanged`);
    assert.equal((await pointer(feed)).observation_generation, generation, name);
  }
  const latest = await pointer(feed);
  assert.ok(latest.semantic_digest.startsWith(`${latest.snapshot_key}:`) && latest.snapshot_key !== published.snapshot_key, 'the digest is bound to the snapshot it describes');
  console.log('PASS edited, removed, returned and bonus items each materialize exactly one complete observation');
  // A digest left behind by a binary that does not maintain it: rollback.mjs.

  // A feed too large for the worker buffer spills to one multipart scratch
  // upload. Unchanged: aborted, never an object. Changed: copied, then deleted.
  const long = 'x'.repeat(480);
  const large = extra => rss([...Array.from({ length: 9000 }, (_, i) => `<item><guid>big-${i}</guid><title>${long} ${i}</title><description>${long}</description><pubDate>${new Date((h.now - 86400 * 30 - i) * 1000).toUTCString()}</pubDate><enclosure url="https://audio.example.com/big-${i}.mp3"/></item>`), ...extra]);
  let body = large([]);
  behavior = () => new Response(body);
  const big = await h.add('https://large.example.com/feed');
  await poll(big);
  assert.equal((await pointer(big)).observation_generation, 1);
  assert.equal((await h.invoke('metrics')).scratch_peak_bytes, 0, 'a quiet baseline keeps only fixed-width hashes');
  let held = await durable();
  const unchanged = await poll(big);
  assert.equal(unchanged.outcome, 'unchanged');
  assert.ok(unchanged.multipart >= 3, `create, part and abort were ${unchanged.multipart} calls`);
  assert.deepEqual([unchanged.put, unchanged.get, unchanged.head], [0, 0, 0]);
  assert.deepEqual(await durable(), held, 'an unchanged large feed leaves no row and no object');
  assert.equal(await scratch(), 0);
  const peak = (await h.invoke('metrics')).scratch_peak_bytes;
  assert.ok(peak >= 5 * 1024 * 1024 && peak % (5 * 1024 * 1024) === 0, `scratch is whole 5 MiB parts, was ${peak}`);
  console.log(`PASS unchanged ${(body.length / 1048576).toFixed(1)} MiB feed spills ${(peak / 1048576).toFixed(0)} MiB to one aborted scratch upload: no object, no row`);

  for (const [name, reply] of [
    ['truncated', () => new Response(large([]).slice(0, -60))],
    ['inactivity timeout', () => new Response(new ReadableStream({ start(c) { c.enqueue(new TextEncoder().encode(large([]).slice(0, -60))); } }))],
  ]) {
    behavior = reply; held = await durable();
    const trace = await poll(big);
    assert.equal(trace.outcome, 'publisher_failed', name);
    // Only the failure streak's single first-observed bound may be written.
    const kept = await durable(), evidence = (await h.first("SELECT COUNT(*) AS n FROM n_observation WHERE feed_id=? AND state='staging' AND valid_eof=0 AND recovery_evidence=1", big)).n;
    assert.equal(evidence, 1, name);
    assert.deepEqual({ ...kept, n_observation: kept.n_observation - evidence, n_snapshot: kept.n_snapshot - evidence }, name === 'truncated' ? held : { ...held, n_observation: held.n_observation - 1, n_snapshot: held.n_snapshot - 1 }, `${name}: nothing published, no object kept`);
    assert.equal(await scratch(), 0, name);
    assert.equal((await pointer(big)).observation_generation, 1, name);
  }
  // Cancellation cannot await an abort. The upload was never completed, so it
  // is not an object; R2 expires the abandoned upload.
  let entered = false; held = await durable();
  behavior = () => new Response(new ReadableStream({ start(c) { c.enqueue(new TextEncoder().encode(large([]).slice(0, -60))); entered = true; } }));
  await h.run('UPDATE n_feed SET due_at=0,retry_at=0,poll_failures=0,dispatch_until=0 WHERE feed_id=?', big);
  await h.invoke('test/dispatch'); const [wake] = await h.polls();
  const pending = h.consume(wake, { headers: { 'x-test-execution': 'cancel-large' } });
  while (!entered) await setTimeout(10);
  await setTimeout(300); await h.invoke('abort', 'cancel-large');
  assert.equal((await pending).status, 503);
  assert.deepEqual(await durable(), held, 'cancellation: nothing published, no object kept, the streak keeps its one bound');
  assert.equal(await scratch(), 0, 'cancellation');
  console.log('PASS truncated, timed-out and cancelled large scans publish nothing and leave no scratch object');

  body = large([item('big-release', h.now - 20)]); behavior = () => new Response(body);
  assert.equal((await h.consume(wake, { attempts: 2 })).status, 200); await h.drain(); await h.deliver(true);
  assert.equal((await pointer(big)).observation_generation, 2);
  assert.equal(await scratch(), 0, 'the completed scratch object is deleted after its pages are copied');
  assert.equal((await h.first("SELECT COUNT(*) AS n FROM n_event e JOIN n_episode_release r ON r.event_id=e.event_id WHERE r.feed_id=?", big)).n, 1);
  assert.equal((await h.first("SELECT reason_counts_json FROM n_observation WHERE feed_id=? AND state='published' AND generation=2", big)).reason_counts_json.includes('"known_identity":9000'), true);
  const metrics = await h.invoke('metrics');
  assert.ok(metrics.max_d1 < 800, `largest invocation used ${metrics.max_d1} D1 statements`);
  console.log(`PASS changed large feed copies every spilled page under its lease: one exact event from 9,001 items, largest invocation ${metrics.max_d1} D1 statements`);
  await writeFile('/private/tmp/opencast-pass045-no-change.json', JSON.stringify({ status: 'passed', scratch_peak_bytes: peak, wasm_memory_bytes: (await h.invoke('test/stats')).wasm_memory_bytes, metrics }, null, 2));
} finally { await h.instance.dispose(); }
