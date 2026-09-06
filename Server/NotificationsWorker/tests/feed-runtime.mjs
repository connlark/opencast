// Runs the packaged production Worker in workerd with isolated D1 and mock
// feed/APNs services. No remote database, credentials or device is used.
// Build first: yarn workspace @opencast/notifications-worker deploy:dry-run
// Run from the repository root: node Server/NotificationsWorker/tests/feed-runtime.mjs
import assert from 'node:assert/strict';
import { createReadStream } from 'node:fs';
import { readdir, readFile, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { Readable } from 'node:stream';
import { setTimeout } from 'node:timers/promises';
import { Miniflare, convertV4MiniflareOptions } from 'miniflare';
import { sampleRuntimeMemory } from './runtime-memory.mjs';

const root = fileURLToPath(new URL('../', import.meta.url));
const reportPath = process.env.OPENCAST_FEED_RUNTIME_REPORT ?? '/private/tmp/opencast-feed-worker-runtime.json';
const captures = new Map([
  ['herd', '/private/tmp/opencast-feed-research-herd.xml'],
  ['boundless', '/private/tmp/opencast-feed-research-greenfield.xml'],
  ['eofire', '/private/tmp/opencast-feed-research-eofire.xml'],
  ['changelog', '/private/tmp/opencast-feed-research-changelog.xml'],
  ['maximum', '/private/tmp/opencast-feed-max.xml'],
]);
const observed = [];
const scheduledRuns = [];
const sends = [];
let fixtureVersion = 1;
let newEpisodeDate = 0;
let malformed = false;
let requests = 0;
const now = Math.floor(Date.now() / 1000);
const item = (id, date) => `<item><guid>${id}</guid><title>Episode ${id}</title><pubDate>${new Date(date * 1000).toUTCString()}</pubDate><enclosure url="https://audio.example.com/${id}.mp3"/><description><![CDATA[Full notification notes 🎧]]></description></item>`;
const localToken = 'local-fixture-only';
const mf = new Miniflare(convertV4MiniflareOptions({
  inspectorPort: 0,
  workers: [{
  name: 'notifications-feed-runtime',
  modulesRoot: root + 'build',
  modules: [{ type: 'ESModule', path: root + 'build/index.js' },
            { type: 'CompiledWasm', path: root + 'build/index_bg.wasm' }],
  compatibilityDate: '2026-08-14',
  d1Databases: { APP_ATTEST_DB: 'isolated-feed-runtime' },
  bindings: { APPLE_TEAM_ID: 'EXAMPLETEAM', APPLE_BUNDLE_ID: 'com.example.opencast',
    APP_ATTEST_ENVIRONMENT: 'development', APNS_ENVIRONMENT: 'development',
    ADMIN_TEST_ENDPOINTS_ENABLED: 'true', ADMIN_TEST_TOKEN: localToken,
    PUBLIC_NOTIFICATIONS_ENABLED: 'true', DEBUG_ENDPOINTS_ENABLED: 'true' },
  serviceBindings: { APNS_CERT: async request => {
    sends.push(JSON.parse(await request.text()));
    return new Response(null, { status: 200, headers: { 'apns-id': `local-${sends.length}` } });
  } },
  outboundService: async request => {
    const url = new URL(request.url);
    assert.equal(url.hostname, 'fixtures.example.com', 'unexpected outbound request');
    requests += 1;
    const name = url.pathname.slice(1).replace(/\.xml$/, '');
    if (name === 'unsolicited-304') return new Response(null, { status: 304 });
    if (name.startsWith('stalled-')) {
      return new Response(new ReadableStream({
        start(controller) {
          controller.enqueue(new TextEncoder().encode('<rss><channel>' + item('closed-before-stall', now)));
        },
      }), { headers: { 'content-type': 'application/rss+xml', etag: '"must-not-persist"' } });
    }
    if (captures.has(name)) {
      return new Response(Readable.toWeb(createReadStream(captures.get(name), { highWaterMark: 65536 })),
        { headers: { 'content-type': 'application/rss+xml', etag: `"${name}"` } });
    }
    const etag = `"mutable-${fixtureVersion}-${malformed}"`;
    if (request.headers.get('if-none-match') === etag) return new Response(null, { status: 304 });
    const body = '<rss><channel><title>Controlled feed</title>'
      + (fixtureVersion > 1 ? item('new', newEpisodeDate) : '')
      + item('baseline', now - 60) + (malformed ? '<item><title>broken' : '</channel></rss>');
    // Arbitrary byte boundaries, including inside UTF-8 and CDATA.
    const bytes = new TextEncoder().encode(body);
    let position = 0;
    return new Response(new ReadableStream({
      type: 'bytes', pull(controller) {
        if (position === bytes.length) { controller.close(); return; }
        const end = Math.min(position + 7, bytes.length);
        controller.enqueue(bytes.slice(position, end)); position = end;
      },
    }), { headers: { 'content-type': 'application/rss+xml', etag } });
  },
  }],
}));

let stopMemory;
try {
  await mf.ready;
  // Instantiate the Worker execution context before attaching the inspector.
  await (await mf.dispatchFetch('https://worker.example.com/__runtime-init')).arrayBuffer();
  console.log('Inspector:', (await mf.getInspectorURL()).href);
  stopMemory = await sampleRuntimeMemory(await mf.getInspectorURL());
  const db = await mf.getD1Database('APP_ATTEST_DB');
  for (const file of (await readdir(root + 'migrations')).filter(x => x.endsWith('.sql')).sort()) {
    const sql = (await readFile(root + 'migrations/' + file, 'utf8')).replace(/--[^\n]*/g, '');
    for (const statement of sql.split(';').map(x => x.trim()).filter(Boolean)) await db.prepare(statement).run();
  }
  await db.prepare(`INSERT INTO devices (install_id,key_id,device_token,device_token_hash,apns_environment,bundle_id,notifications_enabled,created_at,last_seen_at)
    VALUES ('local','local','${'a'.repeat(64)}','hash','development','com.example.opencast',1,?,?)`).bind(now - 120, now).run();

  async function admit(name) {
    const url = `https://fixtures.example.com/${name}.xml`;
    await db.prepare(`INSERT INTO feeds(feed_url,source_url,poll_interval_seconds,consecutive_failures,created_at,updated_at)
      VALUES (?,?,3600,0,?,?)`).bind(url, url, now, now).run();
    await db.prepare(`INSERT INTO feed_subscriptions(install_id,feed_url,notifications_enabled,created_at,updated_at)
      VALUES ('local',?,1,?,?)`).bind(url, now - 120, now).run();
    return url;
  }
  async function poll(url) {
    const start = performance.now();
    const response = await mf.dispatchFetch('https://worker.example.com/v1/admin/test/poll-feed', {
      method: 'POST', headers: { authorization: `Bearer ${localToken}`, 'content-type': 'application/json' },
      body: JSON.stringify({ feed_url: url }),
    });
    const result = await response.json();
    assert.equal(response.status, 200, JSON.stringify(result));
    const row = await db.prepare('SELECT last_error,latest_episode_id,etag,baseline_established_at FROM feeds WHERE feed_url=?').bind(url).first();
    observed.push({ url, seconds: (performance.now() - start) / 1000, result, row });
    console.log(JSON.stringify(observed.at(-1)));
    return { result, row };
  }
  const mutable = await admit('mutable');
  const unsolicited = await poll(await admit('unsolicited-304'));
  assert.equal(unsolicited.row.last_error, 'unexpected_not_modified');
  assert.equal(unsolicited.row.baseline_established_at, null);
  assert.equal(unsolicited.row.etag, null);
  let scan = await poll(mutable);
  assert.equal(scan.result.notifications_attempted, 0);
  assert.ok(scan.row.baseline_established_at);
  const baseline = scan.row.latest_episode_id;
  // A controlled update must actually postdate admission, not rely on a
  // timestamp in the future crossing a wall-clock second by accident.
  await setTimeout(1_100);
  newEpisodeDate = Math.floor(Date.now() / 1000);
  assert.ok(newEpisodeDate > scan.row.baseline_established_at);
  fixtureVersion = 2;
  malformed = true;
  scan = await poll(mutable);
  assert.ok(scan.row.last_error);
  assert.equal(scan.row.latest_episode_id, baseline);
  assert.equal(sends.length, 0);
  malformed = false;
  scan = await poll(mutable);
  assert.equal(scan.row.last_error, null);
  assert.equal(scan.result.apns_200_count, 1);
  assert.equal(sends.length, 1);
  await poll(mutable);
  assert.equal(sends.length, 1, 'repeat poll must not notify twice');

  if (process.env.OPENCAST_LARGE_FEED_CAPTURES === '1') {
    const urls = [];
    for (const name of captures.keys()) urls.push(await admit(name));
    // Three overlapping invocations exercise the isolate-wide two-scan gate.
    const before = requests;
    const overlap = await Promise.all(urls.slice(0, 3).map(poll));
    assert.equal(overlap.reduce((n, x) => n + x.result.feeds_polled, 0), 2);
    assert.equal(requests - before, 2);
    for (let i = 0; i < 3; i++) {
      if (overlap[i].result.feeds_polled === 0) assert.equal((await poll(urls[i])).row.last_error, null);
      else assert.equal(overlap[i].row.last_error, null);
    }
    for (const url of urls.slice(3)) assert.equal((await poll(url)).row.last_error, null);

    if (process.env.OPENCAST_LARGE_FIELD_CAPTURE) {
      captures.set('long-notes-a', process.env.OPENCAST_LARGE_FIELD_CAPTURE);
      captures.set('long-notes-b', process.env.OPENCAST_LARGE_FIELD_CAPTURE);
      const fields = [await admit('long-notes-a'), await admit('long-notes-b')];
      const scanned = await Promise.all(fields.map(poll));
      assert.ok(scanned.every(x => x.row.last_error === null && x.result.feeds_polled === 1));
    }

    // Two maximum feeds can already be in flight when the byte admission
    // budget is reached. A third due feed must remain due and unclaimed.
    captures.set('maximum-a', captures.get('maximum'));
    captures.set('maximum-b', captures.get('maximum'));
    const due = [await admit('maximum-a'), await admit('maximum-b'), await admit('unstarted')];
    for (let i = 0; i < due.length; i++) {
      await db.prepare('UPDATE feeds SET next_poll_at=0,updated_at=? WHERE feed_url=?').bind(i, due[i]).run();
    }
    const started = performance.now();
    const worker = await mf.getWorker();
    const outcome = await worker.scheduled({ cron: '*/5 * * * *', scheduledTime: new Date() });
    const seconds = (performance.now() - started) / 1000;
    // A single isolate cannot consume more CPU than its elapsed wall time;
    // this conservative local bound includes fetch, scan, D1 and logging.
    assert.ok(seconds < 24, `Scheduled invocation took ${seconds}s`);
    const pending = await db.prepare('SELECT next_poll_at,last_polled_at,consecutive_failures FROM feeds WHERE feed_url=?').bind(due[2]).first();
    assert.deepEqual(pending, { next_poll_at: 0, last_polled_at: null, consecutive_failures: 0 });
    for (const url of due.slice(0, 2)) {
      const row = await db.prepare('SELECT last_error,baseline_established_at FROM feeds WHERE feed_url=?').bind(url).first();
      assert.equal(row.last_error, null);
      assert.ok(row.baseline_established_at);
    }
    scheduledRuns.push({ outcome, seconds, unstarted: pending });
  }
  if (process.env.OPENCAST_FEED_RUNTIME_TIMEOUTS === '1') {
    await db.prepare('UPDATE feeds SET next_poll_at=?').bind(Math.floor(Date.now() / 1000) + 3600).run();
    const stalled = [await admit('stalled-a'), await admit('stalled-b'), await admit('waiting-after-stall')];
    for (let i = 0; i < stalled.length; i++) {
      await db.prepare('UPDATE feeds SET next_poll_at=0,updated_at=? WHERE feed_url=?').bind(i, stalled[i]).run();
    }
    const started = performance.now();
    await (await mf.getWorker()).scheduled({ cron: '*/5 * * * *', scheduledTime: new Date() });
    const seconds = (performance.now() - started) / 1000;
    assert.ok(seconds >= 19 && seconds < 24, `Inactivity deadline: ${seconds}s`);
    for (const url of stalled.slice(0, 2)) {
      const row = await db.prepare('SELECT last_error,baseline_established_at,etag FROM feeds WHERE feed_url=?').bind(url).first();
      assert.deepEqual(row, { last_error: 'feed_inactivity_timeout', baseline_established_at: null, etag: null });
    }
    const pending = await db.prepare('SELECT next_poll_at,last_polled_at,consecutive_failures FROM feeds WHERE feed_url=?').bind(stalled[2]).first();
    assert.deepEqual(pending, { next_poll_at: 0, last_polled_at: null, consecutive_failures: 0 });
    scheduledRuns.push({ seconds, inactivityDeadline: true, unstarted: pending });
  }
  const memory = await stopMemory();
  stopMemory = undefined;
  if (process.env.OPENCAST_FEED_RUNTIME_TIMEOUTS === '1') {
    const expected = ['/stalled-a.xml', '/stalled-b.xml'];
    assert.deepEqual(memory.transportAudit.aborted.sort(), expected, 'Timeouts must abort native fetches');
    assert.deepEqual(memory.transportAudit.readersCancelled.sort(), expected, 'Timeouts must cancel and release native readers');
  }
  assert.ok(memory.totalBytes < 96 * 1024 * 1024, JSON.stringify(memory));
  await writeFile(reportPath, JSON.stringify({ passed: true, sends: sends.length, requests, memory, scheduledRuns, observed }, null, 2));
  console.log('Runtime checks passed:', reportPath);
} finally {
  try { await stopMemory?.(); }
  finally { await mf.dispose(); }
}
