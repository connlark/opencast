import { migrate } from './migrations.mjs';
// Run after packaging the Worker. No remote services or production test hooks.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import http from 'node:http';
import { fileURLToPath } from 'node:url';
import { setTimeout } from 'node:timers/promises';
import { Miniflare, convertV4MiniflareOptions } from 'miniflare';
import { compatibilityDate, compatibilityFlags } from './runtime-compatibility.mjs';
import { sampleRuntimeMemory } from './runtime-memory.mjs';

assert.ok(compatibilityFlags.includes('enable_request_signal'));
const root = fileURLToPath(new URL('../', import.meta.url));
const feedID = url => createHash('sha256').update(JSON.stringify(['feed-v1',url])).digest('hex');
const fixtureNames = ['probe', 'cancel-fetch-a', 'cancel-fetch-b', 'cancel-read-a', 'cancel-read-b', 'cancel-parse-a', 'cancel-parse-b', 'postscan'];
const now = Math.floor(Date.now() / 1000);
const sends = [];
const fixtureRequests = new Map();
const releases = new Set();
let version = 1;
const item = index => `<item><guid>episode-${index}</guid><title>Episode ${index}</title><pubDate>${new Date((now - 10 + index) * 1000).toUTCString()}</pubDate><enclosure url="https://audio.example.com/${index}.mp3"/></item>`;
const xml = () => `<rss><channel><title>Cancellation proof</title>${version === 2 ? item(1) : ''}${item(0)}</channel></rss>`;
const mf = new Miniflare(convertV4MiniflareOptions({
  cf: false,
  inspectorPort: 0,
  workers: [{ name: 'notifications-feed-runtime', modulesRoot: root,
    modules: [{ type: 'ESModule', path: root + 'tests/cancellation-entry.mjs' },
      { type: 'ESModule', path: root + 'adapter/index.js' },{ type: 'ESModule', path: root + 'build/index.js' },
      { type: 'CompiledWasm', path: root + 'build/index_bg.wasm' }],
    compatibilityDate, compatibilityFlags,
    d1Databases: { APP_ATTEST_DB: 'cancellation-runtime' },
    r2Buckets: { FEED_SNAPSHOTS: 'isolated-cancellation-snapshots' },
    bindings: { NOTIFICATION_FEED_OBSERVATION:'true', NOTIFICATION_ENVIRONMENT:'development' },
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
  await migrate(db,new URL('../migrations/',import.meta.url));
  await db.prepare("UPDATE n_control SET enabled=1 WHERE name='feed_observation'").run();
  await db.prepare(`INSERT INTO devices(install_id,key_id,device_token,device_token_hash,apns_environment,bundle_id,notifications_enabled,created_at,last_seen_at)
    VALUES ('local','key',?,'hash','development','com.example.opencast',1,?,?)`).bind('a'.repeat(64), now - 120, now).run();
  const urls = new Map();
  for (const name of fixtureNames) {
    const url = `https://fixtures.example.com/${name}`;
    urls.set(name, url);
    await db.prepare('INSERT INTO n_feed_catalog(feed_url,source_url,created_at,updated_at) VALUES (?,?,?,?)')
      .bind(url, url, now, now).run();
    await db.prepare("INSERT INTO n_feed(feed_id,canonical_url,epoch,due_at) VALUES(?,?,1,?)").bind(feedID(url),url,now).run();
    await db.prepare("INSERT INTO feed_subscriptions(install_id,feed_url,notifications_enabled,created_at,updated_at) VALUES ('local',?,1,?,?)")
      .bind(url, now - 120, now).run();
  }
  function pollOptions(name, headers = {}) {
    return { method: 'POST', headers: { 'content-type': 'application/json', ...headers },
      body: JSON.stringify({ feed_id: feedID(urls.get(name)) }) };
  }
  async function poll(name) {
    const response = await mf.dispatchFetch(new URL('/observation/scan', origin), pollOptions(name));
    assert.equal(response.status, 200, response.status === 200 ? '' : await response.text());
    return response.text();
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
    const request = http.request(new URL('/observation/scan', origin), { ...options, agent: false });
    request.on('error', () => {});
    request.on('response', response => response.resume());
    request.end(body);
    return request;
  }
  await poll('probe');
  await poll('postscan');
  stopMemory = await sampleRuntimeMemory(await mf.getInspectorURL());
  let aborts=0;
  const snapshot=async(name)=>db.prepare('SELECT snapshot_key,observation_generation FROM n_feed WHERE feed_id=?').bind(feedID(urls.get(name))).first();
  async function busy(){const response=await mf.dispatchFetch(new URL('/observation/scan',origin),pollOptions('probe'));assert.equal(response.status,429,await response.text());}
  for(const phase of ['fetch','read','parse'])for(let iteration=0;iteration<8;iteration++){
    const name=`cancel-${phase}-${iteration%2?'b':'a'}`;
    await db.prepare('UPDATE n_feed SET lease_id=NULL,lease_until=NULL WHERE feed_id=?').bind(feedID(urls.get(name))).run();
    const before=fixtureRequests.get('/'+name)??0;
    const bytes=(await stopMemory.transportAudit()).readerBytes['/'+name]??0;
    const request=startRequest(name);
    await until(()=> (fixtureRequests.get('/'+name)??0)>before,'transport admitted');
    if(phase!=='fetch')await until(async()=>((await stopMemory.transportAudit()).readerBytes['/'+name]??0)-bytes>=(phase==='parse'?65536:1),'reader reached intended phase');
    await busy();
    await mf.dispatchFetch(new URL('/__cancel?id='+name,origin));aborts++;
    await until(async()=> (await state()).incomingAborts===aborts,'native abort');request.destroy();
    await until(async()=>{const response=await mf.dispatchFetch(new URL('/observation/scan',origin),pollOptions('probe'));await response.text();return response.status===200;},'exclusive permit released');
    const audit=await stopMemory.transportAudit();
    assert.equal(audit.activeByOrigin['https://fixtures.example.com'],0);
    assert.equal((await snapshot(name)).snapshot_key,null);
  }
  console.log('PASS current observations repeatedly release transport and exclusive permits on fetch/read/parser cancellation');
  version=2;
  const original=await snapshot('postscan');
  const postscan=startRequest('postscan',{'x-test-postscan':'1'});
  await until(async()=> (await state()).postscanReads>0,'post-scan storage read');
  await mf.dispatchFetch(new URL('/__cancel?id=postscan',origin));aborts++;
  await until(async()=> (await state()).incomingAborts===aborts,'post-scan native abort');postscan.destroy();
  await db.prepare('UPDATE n_feed SET lease_id=NULL,lease_until=NULL WHERE feed_id=?').bind(feedID(urls.get('cancel-read-a'))).run();
  const before=fixtureRequests.get('/cancel-read-a')??0,replacement=startRequest('cancel-read-a');
  await until(()=> (fixtureRequests.get('/cancel-read-a')??0)>before,'replacement owner');
  await mf.dispatchFetch(new URL('/__release-postscan',origin));await busy();
  assert.deepEqual(await snapshot('postscan'),original);
  assert.equal((await db.prepare('SELECT COUNT(*) n FROM n_episode_release').first()).n,0);
  await mf.dispatchFetch(new URL('/__cancel?id=cancel-read-a',origin));aborts++;
  await until(async()=> (await state()).incomingAborts===aborts,'replacement abort');replacement.destroy();
  for(const resolve of releases)resolve();releases.clear();
  await until(async()=>{const response=await mf.dispatchFetch(new URL('/observation/scan',origin),pollOptions('probe'));await response.text();return response.status===200;},'healthy follow-up');
  assert.equal(sends.length,0);
  const memory=await stopMemory();stopMemory=undefined;
  assert.ok(memory.totalBytes<96*1024*1024,JSON.stringify(memory));
  console.log('PASS late post-scan continuation cannot publish or release replacement permits; healthy follow-up and bounded memory');
} finally {
  for(const resolve of releases)resolve();
  if(stopMemory)await stopMemory();
  await mf.dispose();
}
