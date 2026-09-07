// Run after packaging the Worker. No remote services or production test hooks.
import assert from 'node:assert/strict';
import http from 'node:http';
import { readdir, readFile, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { setTimeout } from 'node:timers/promises';
import { Miniflare, convertV4MiniflareOptions } from 'miniflare';
import { compatibilityDate, compatibilityFlags } from './runtime-compatibility.mjs';
import { sampleRuntimeMemory } from './runtime-memory.mjs';

assert.ok(compatibilityFlags.includes('enable_request_signal'));
const root = fileURLToPath(new URL('../', import.meta.url));
const token = 'local-cancellation-only';
const now = Math.floor(Date.now() / 1000);
const sends = [];
const fixtureRequests = new Map();
const releases = new Set();
const cycles = [];
let version = 1;
const item = index => `<item><guid>episode-${index}</guid><title>Episode ${index}</title><pubDate>${new Date((now - 10 + index) * 1000).toUTCString()}</pubDate><enclosure url="https://audio.example.com/${index}.mp3"/></item>`;
const xml = () => `<rss><channel><title>Cancellation proof</title>${version === 2 ? item(1) : ''}${item(0)}</channel></rss>`;
const mf = new Miniflare(convertV4MiniflareOptions({
  cf: false,
  inspectorPort: 0,
  workers: [{ name: 'notifications-feed-runtime', modulesRoot: root,
    modules: [{ type: 'ESModule', path: root + 'tests/cancellation-entry.mjs' },
      { type: 'ESModule', path: root + 'build/index.js' },
      { type: 'CompiledWasm', path: root + 'build/index_bg.wasm' }],
    compatibilityDate, compatibilityFlags,
    d1Databases: { APP_ATTEST_DB: 'cancellation-runtime' },
    bindings: { APPLE_TEAM_ID: 'EXAMPLETEAM', APPLE_BUNDLE_ID: 'com.example.opencast',
      APP_ATTEST_ENVIRONMENT: 'development', APNS_ENVIRONMENT: 'development',
      ADMIN_TEST_ENDPOINTS_ENABLED: 'true', ADMIN_TEST_TOKEN: token,
      PUBLIC_NOTIFICATIONS_ENABLED: 'true', DEBUG_ENDPOINTS_ENABLED: 'true' },
    serviceBindings: { APNS_CERT: async request => {
      sends.push(await request.json());
      return new Response(null, { status: 200, headers: { 'apns-id': `test-${sends.length}` } });
    } },
    outboundService: async request => {
      const name = new URL(request.url).pathname;
      assert.equal(new URL(request.url).hostname, 'fixtures.example.com');
      fixtureRequests.set(name, (fixtureRequests.get(name) ?? 0) + 1);
      if (name.includes('cancel-fetch')) {
        await new Promise(resolve => releases.add(resolve));
        return new Response(xml());
      }
      if (name.includes('cancel-read') || name.includes('cancel-parse')) {
        let position = 0;
        return new Response(new ReadableStream({
          async pull(controller) {
            if (position === 0) {
              position++;
              controller.enqueue(new TextEncoder().encode('<rss><channel><title>Pending</title>'));
            } else if (name.includes('cancel-parse') && position < 5) {
              position++;
              controller.enqueue(new TextEncoder().encode(Array.from({ length: 200 }, (_, i) => item(position * 200 + i)).join('')));
            } else {
              await new Promise(resolve => releases.add(resolve));
              try { controller.close(); } catch { /* Already canceled by workerd. */ }
            }
          },
        }), { headers: { 'content-type': 'application/rss+xml', etag: '"never-commit"' } });
      }
      return new Response(xml(), { headers: { 'content-type': 'application/rss+xml', etag: `"v${version}"` } });
    },
  }],
}));

let stopMemory;
try {
  await mf.ready;
  const origin = await mf.ready;
  const db = await mf.getD1Database('APP_ATTEST_DB');
  for (const file of (await readdir(root + 'migrations')).filter(x => x.endsWith('.sql')).sort()) {
    const sql = (await readFile(root + 'migrations/' + file, 'utf8')).replace(/--[^\n]*/g, '');
    for (const statement of sql.split(';').map(x => x.trim()).filter(Boolean)) await db.prepare(statement).run();
  }
  await db.prepare(`INSERT INTO devices(install_id,key_id,device_token,device_token_hash,apns_environment,bundle_id,notifications_enabled,created_at,last_seen_at)
    VALUES ('local','key',?,'hash','development','com.example.opencast',1,?,?)`).bind('a'.repeat(64), now - 120, now).run();
  const urls = new Map();
  for (const name of ['probe', 'cancel-fetch-a', 'cancel-fetch-b', 'cancel-read-a', 'cancel-read-b', 'cancel-parse-a', 'cancel-parse-b', 'postscan']) {
    const url = `https://fixtures.example.com/${name}`;
    urls.set(name, url);
    await db.prepare('INSERT INTO feeds(feed_url,source_url,poll_interval_seconds,consecutive_failures,created_at,updated_at,next_poll_at) VALUES (?,?,3600,0,?,?,?)')
      .bind(url, url, now, now, now + 3600).run();
    await db.prepare("INSERT INTO feed_subscriptions(install_id,feed_url,notifications_enabled,created_at,updated_at) VALUES ('local',?,1,?,?)")
      .bind(url, now - 120, now).run();
  }
  function pollOptions(name, headers = {}) {
    return { method: 'POST', headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json', ...headers },
      body: JSON.stringify({ feed_url: urls.get(name) }) };
  }
  async function poll(name) {
    const response = await mf.dispatchFetch(new URL('/v1/admin/test/poll-feed', origin), pollOptions(name));
    assert.equal(response.status, 200, response.status === 200 ? '' : await response.text());
    return response.json();
  }
  async function state() { return (await mf.dispatchFetch(new URL('/__cancellation-state', origin))).json(); }
  async function until(predicate, label) {
    const deadline = Date.now() + 10_000;
    while (!(await predicate())) {
      assert.ok(Date.now() < deadline, `Timed out: ${label}`);
      await setTimeout(10);
    }
  }
  function startRequest(name, headers = {}) {
    const { body, ...options } = pollOptions(name, { ...headers, 'x-test-cancel': name });
    options.headers['content-length'] = Buffer.byteLength(body);
    const request = http.request(new URL('/v1/admin/test/poll-feed', origin), { ...options, agent: false });
    request.on('error', () => {});
    request.on('response', response => response.resume());
    request.end(body);
    return request;
  }
  const baseline = await poll('probe');
  stopMemory = await sampleRuntimeMemory(await mf.getInspectorURL());
  let aborts = 0;
  for (const phase of ['fetch', 'read', 'parse']) {
    for (let iteration = 0; iteration < 16; iteration++) {
      const names = [`cancel-${phase}-a`, `cancel-${phase}-b`];
      const before = names.map(name => fixtureRequests.get('/' + name) ?? 0);
      const consumedBefore = (await stopMemory.transportAudit()).readerBytes;
      const requests = names.map(name => startRequest(name));
      await until(() => names.every((name, i) => (fixtureRequests.get('/' + name) ?? 0) > before[i]), 'both transports admitted');
      if (phase !== 'fetch') await until(async () => {
        const consumed = (await stopMemory.transportAudit()).readerBytes;
        return names.every(name => (consumed['/' + name] ?? 0) - (consumedBefore['/' + name] ?? 0)
          >= (phase === 'parse' ? 65_536 : 1));
      }, 'native reader consumed the intended phase');
      const busy = await poll('probe');
      assert.equal(busy.scan_active, 2);
      assert.equal(busy.feeds_polled, 0);
      for (const name of names) {
        const canceled = await (await mf.dispatchFetch(new URL('/__cancel?id=' + name, origin).href)).json();
        assert.deepEqual(canceled, { id: name, found: true });
      }
      requests.forEach(request => request.destroy());
      aborts += 2;
      try {
        await until(async () => (await state()).incomingAborts === aborts, 'native cancellation signal');
      } catch (error) {
        console.error({ phase, iteration, expectedAborts: aborts, state: await state(), sockets: requests.map(x => ({ destroyed: x.destroyed, closed: x.closed })) });
        throw error;
      }
      const recovered = await poll('probe');
      assert.equal(recovered.feeds_polled, 1, JSON.stringify(recovered));
      assert.equal(recovered.scan_active, 0);
      assert.equal(recovered.isolate_id, baseline.isolate_id);
      assert.equal(recovered.wasm_instance_id, baseline.wasm_instance_id);
      for (const name of names) {
        const row = await db.prepare('SELECT latest_episode_id,etag,last_error,last_polled_at FROM feeds WHERE feed_url=?').bind(urls.get(name)).first();
        assert.deepEqual(row, { latest_episode_id: null, etag: null, last_error: null, last_polled_at: null });
      }
      for (const resolve of releases) resolve();
      releases.clear();
      cycles.push({ phase, iteration, wasmBytes: recovered.wasm_memory_bytes });
    }
    console.log(`Passed 32 native signal cancellations during ${phase}`);
  }
  await poll('postscan');
  const original = await db.prepare('SELECT latest_episode_id,etag FROM feeds WHERE feed_url=?').bind(urls.get('postscan')).first();
  // Admit a controlled new episode after a known historical baseline.
  await db.prepare('UPDATE feeds SET baseline_established_at=? WHERE feed_url=?').bind(now - 60, urls.get('postscan')).run();
  version = 2;
  const postscan = startRequest('postscan', { 'x-test-postscan': '1' });
  await until(async () => (await state()).postscanReads === 1, 'post-scan fanout read');
  await mf.dispatchFetch(new URL('/__cancel?id=postscan', origin).href);
  postscan.destroy();
  aborts++;
  await until(async () => (await state()).incomingAborts === aborts, 'post-scan disconnect');
  const replacementNames = ['cancel-read-a', 'cancel-read-b'];
  const replacementCounts = replacementNames.map(name => fixtureRequests.get('/' + name));
  const replacements = replacementNames.map(name => startRequest(name));
  await until(() => replacementNames.every((name, i) => fixtureRequests.get('/' + name) > replacementCounts[i]), 'replacement owners');
  await mf.dispatchFetch(new URL('/__release-postscan', origin));
  const stillBusy = await poll('probe');
  assert.equal(stillBusy.scan_active, 2, 'Old continuation must not release replacement permits');
  assert.equal(stillBusy.feeds_polled, 0);
  await db.prepare('UPDATE feeds SET next_poll_at=0 WHERE feed_url=?').bind(urls.get('probe')).run();
  await (await mf.getWorker()).scheduled({ cron: '*/5 * * * *', scheduledTime: new Date() });
  assert.equal((await db.prepare('SELECT next_poll_at FROM feeds WHERE feed_url=?').bind(urls.get('probe')).first()).next_poll_at, 0);
  for (const name of replacementNames) await mf.dispatchFetch(new URL('/__cancel?id=' + name, origin).href);
  aborts += 2;
  await until(async () => (await state()).incomingAborts === aborts, 'replacement cancellation');
  replacements.forEach(request => request.destroy());
  for (const resolve of releases) resolve();
  releases.clear();
  const recovered = await poll('probe');
  assert.equal(recovered.scan_active, 0);
  assert.equal(recovered.isolate_id, baseline.isolate_id);
  assert.equal(recovered.wasm_instance_id, baseline.wasm_instance_id);
  assert.deepEqual(await db.prepare('SELECT latest_episode_id,etag FROM feeds WHERE feed_url=?').bind(urls.get('postscan')).first(), original);
  assert.equal(sends.length, 0);
  assert.equal((await poll('postscan')).apns_200_count, 1);
  assert.equal((await poll('postscan')).notifications_attempted, 0);
  assert.equal(sends.length, 1);
  const memory = await stopMemory();
  stopMemory = undefined;
  assert.ok(memory.totalBytes < 96 * 1024 * 1024, JSON.stringify(memory));
  for (const phase of ['fetch', 'read', 'parse']) {
    for (const suffix of ['a', 'b']) {
      const name = `/cancel-${phase}-${suffix}`;
      const expected = phase === 'read' ? 17 : 16;
      assert.equal(memory.transportAudit.aborted.filter(x => x === name).length, expected, `Native fetch aborts: ${name}`);
      if (phase !== 'fetch') assert.equal(memory.transportAudit.readersCancelled.filter(x => x === name).length, expected, `Reader disposal: ${name}`);
    }
  }
  const settled = cycles.filter(x => x.iteration >= 4).map(x => x.wasmBytes);
  assert.ok(Math.max(...settled) - Math.min(...settled) < 2 * 1024 * 1024, 'Repeated cancellation retained Wasm buffers');
  const report = process.env.OPENCAST_FEED_CANCELLATION_REPORT ?? '/private/tmp/opencast-feed-cancellation-runtime.json';
  await writeFile(report, JSON.stringify({ passed: true, signalCancellations: aborts, cycles, memory, sends: sends.length }, null, 2));
  console.log('Cancellation runtime passed:', report);
} finally {
  for (const resolve of releases) resolve();
  await stopMemory?.();
  await mf.dispose();
}
