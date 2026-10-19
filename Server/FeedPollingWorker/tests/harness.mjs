import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { Miniflare, convertV4MiniflareOptions } from 'miniflare';
import { openStorage } from '../../NotificationsWorker/tests/storage.mjs';
// The fixture operator-alert webhook; tests bind it as ALERT_WEBHOOK_URL.
export const ALERT_WEBHOOK_URL = 'https://alerts.example.com/v1/notifications';
export const hash = parts => createHash('sha256').update(JSON.stringify(parts)).digest('hex');
const root = fileURLToPath(new URL('../../', import.meta.url));
// `pollingBuild: <dir>` runs the polling Workers on that build's index.js and
// wasm (a storage-fixture build) under the packaged modules' names.
const fixtureBuild = (options, worker, file) => worker === 'FeedPollingWorker' && options.pollingBuild ? { contents: readFileSync(`${options.pollingBuild}/${file}`) } : {};
// wrangler.jsonc is JSONC, not JSON: the public self-hosting template carries a
// comment banner. Drop comments and trailing commas that sit outside strings.
const jsonc = text => text
  .replace(/"(?:\\.|[^"\\])*"|\/\*[\s\S]*?\*\/|\/\/[^\n]*/g, match => (match[0] === '"' ? match : ' '))
  .replace(/"(?:\\.|[^"\\])*"|,(?=\s*[}\]])/g, match => (match[0] === '"' ? match : ''));
const config = JSON.parse(jsonc(await readFile(new URL('../wrangler.jsonc', import.meta.url), 'utf8')));
// One storage per harness, a PostgreSQL clone shared by every polling replica
// and the delivery Worker (NotificationsWorker/tests/storage.mjs). The harness
// owns it: close(), or the suites' existing h.instance.dispose(), disposes
// Miniflare and then the storage.
// `logs: true` also keeps every Worker's JSON log events in h.logs, each still
// printed as Miniflare prints it. `direct: true` binds PostgreSQL without the
// wire proxy: no storage hook and no storage counter, so only for a suite whose
// source arms none and asserts none.
export async function harness(outbound, options = {}) {
  // Retired options fail loudly rather than run a different suite than asked.
  if ('persist' in options) throw Error('harness: persist was retired: each harness owns one transient PostgreSQL clone');
  if ('fiveMinute' in options) throw Error('harness: fiveMinute was retired: the polling suites run the production cadence');
  const sends = [], fetches = [], events = [], alerts = [], logs = [];
  let instance;
  const storage = await openStorage();
  const modules = (worker, entry) => [
    { type: 'ESModule', path: root + worker + '/' + entry },
    { type: 'ESModule', path: root + worker + '/adapter/index.js' },
    { type: 'ESModule', path: root + worker + '/build/index.js', ...fixtureBuild(options, worker, 'index.js') },
    { type: 'CompiledWasm', path: root + worker + '/build/index_bg.wasm', ...fixtureBuild(options, worker, 'index_bg.wasm') },
  ];
  const workers = [
    { name: 'polling-runtime', modulesRoot: root, modules: modules('FeedPollingWorker', 'tests/entry.mjs'),
      compatibilityDate: config.compatibility_date, compatibilityFlags: config.compatibility_flags,
      r2Buckets: { FEED_SNAPSHOTS: 'isolated-snapshots' },
      queueProducers: { POLL_QUEUE: 'isolated-poll' },
      ...(options.realQueues?{queueConsumers:{'isolated-poll':{maxBatchSize:1,maxConcurrency:2,maxBatchTimeout:0.1,maxRetries:3,retryDelay:options.retryDelay??1,deadLetterQueue:'isolated-poll-dlq'},'isolated-poll-dlq':{maxBatchSize:10,maxBatchTimeout:0.1}}}:{}),
      // Production shape: the five-minute switch stays off.
      bindings: { TEST_REAL_QUEUE: options.realQueues?'true':'false',NOTIFICATION_ENVIRONMENT: options.environment ?? 'development', NOTIFICATION_DISPATCHER_ADMISSION: 'true', NOTIFICATION_FEED_OBSERVATION: 'true', NOTIFICATION_FIVE_MINUTE_POLLING: 'false', NOTIFICATION_CLEANUP: 'true', ...(options.alertSecrets ?? {}) },
      serviceBindings: { NOTIFICATION_EVENTS: options.realQueues?{name:'delivery-runtime',entrypoint:'FeedEvents'}:async request => {
        const body = await request.text(); events.push(JSON.parse(body));
        const worker = await instance.getWorker('delivery-runtime');
        const response = await worker.fetch('https://delivery.invalid/v1/events', { method: 'POST', body });
        if (options.loseReceipt?.()) { await response.text(); return new Response('lost', { status: 503 }); }
        return response;
      } },
      outboundService: async request => { fetches.push(request.url); if (request.url === ALERT_WEBHOOK_URL) alerts.push({ headers: Object.fromEntries(request.headers), body: await request.clone().json() }); return outbound(request); },
    },
    { name: 'delivery-runtime', modulesRoot: root, modules: modules('NotificationsWorker', 'tests/observation-entry.mjs'),
      compatibilityDate: '2026-09-30', compatibilityFlags: ['enable_request_signal'],
      r2Buckets: { FEED_SNAPSHOTS: 'isolated-snapshots' },
      queueProducers: { EVENT_QUEUE: 'isolated-event', EPISODE_DELIVERY_QUEUE: 'isolated-episode', JOB_DELIVERY_QUEUE: 'isolated-job' },
      bindings: { NOTIFICATION_ENVIRONMENT: 'development', NOTIFICATION_EPISODE_ACTIVATION: 'true', NOTIFICATION_EPISODE_SEND: 'true', APPLE_TEAM_ID: 'EXAMPLETEAM', APPLE_BUNDLE_ID: 'com.example.opencast', APP_ATTEST_ENVIRONMENT: 'development', APNS_ENVIRONMENT: 'development', PUBLIC_NOTIFICATIONS_ENABLED: 'false',...options.deliveryBindings },
      serviceBindings: { APNS_CERT: async request => { sends.push(await request.json()); return new Response(null, { status: 200 }); } },
      outboundService: async request => { fetches.push(request.url); if (request.url === ALERT_WEBHOOK_URL) alerts.push({ headers: Object.fromEntries(request.headers), body: await request.clone().json() }); return outbound(request); },
    },
  ];
  for(let i=1;i<(options.replicas??1);i++) workers.push({...workers[0],name:`polling-runtime-${i}`});
  // Miniflare first, so no Worker still holds a connection, then the storage
  // (its witness checked, its database dropped). Once, however it is reached.
  let disposeInstance, closing, db;
  const close = () => closing ??= (async () => { try { await disposeInstance?.(); } finally { await storage.dispose(); } })();
  try {
    // Bound after the replicas are copied: each Worker gets its own alias and,
    // for these instrumented entries, its own TEST_STORAGE.
    const bound = workers.map(worker => storage.bind(worker, { direct: !!options.direct }));
    const handleStructuredLogs = ({ level, message }) => { try { const event = JSON.parse(message); if (event?.event) logs.push(event); } catch {} (level === 'error' || level === 'warn' ? console.error : console.log)(message); };
    instance = new Miniflare(convertV4MiniflareOptions({ cf: false, unsafeTriggerHandlers: true, inspectorPort: 0, ...(options.logs ? { handleStructuredLogs } : {}), workers: bound }));
    disposeInstance = instance.dispose.bind(instance);
    instance.dispose = close;
    await instance.ready;
    // A fresh clone of the migrated template, seeded below.
    db = await storage.database(instance, 'APP_ATTEST_DB', 'polling-runtime');
  } catch (error) { await close().catch(() => {}); throw error; }
  const run = (sql, ...args) => db.prepare(sql).bind(...args).run();
  const first = (sql, ...args) => db.prepare(sql).bind(...args).first();
  const rows = async (sql, ...args) => (await db.prepare(sql).bind(...args).all()).results;
  const invoke = async (path, body, headers, replica=0) => {
    const target=replica ? await instance.getWorker(`polling-runtime-${replica}`) : {fetch:instance.dispatchFetch.bind(instance)};
    const response = await target.fetch('https://polling.invalid/' + path, { method: 'POST', body: typeof body === 'string' ? body : JSON.stringify(body ?? {}), headers });
    const text = await response.text(); assert.equal(response.status, 200, `${path}: ${text}`);
    try { return JSON.parse(text); } catch { return text; }
  };
  const now = Math.floor(Date.now() / 1000);
  try {
    await run("UPDATE n_control SET enabled=1 WHERE name IN('dispatcher_admission','feed_observation','episode_activation','episode_send','cleanup')");
    await run("INSERT INTO devices(install_id,key_id,device_token,device_token_hash,apns_environment,bundle_id,notifications_enabled,created_at,last_seen_at) VALUES('local','key',?,'hash','development','com.example.opencast',1,?,?)", 'a'.repeat(64), now - 100000, now);
  } catch (error) { await close().catch(() => {}); throw error; }
  async function add(url, due = now, install = 'local') {
    const feed = hash(['feed-v1', url]);
    await db.batch([
      db.prepare('INSERT INTO n_feed_catalog(feed_url,source_url,created_at,updated_at) VALUES(?,?,?,?)').bind(url, url, now, now),
      db.prepare("INSERT INTO n_feed(feed_id,canonical_url,epoch,due_at) VALUES(?,?,1,?)").bind(feed, url, due),
      db.prepare('INSERT INTO feed_subscriptions(install_id,feed_url,notifications_enabled,created_at,updated_at) VALUES(?,?,1,?,?)').bind(install, url, now - 100000, now),
    ]); return feed;
  }
  // One Queue delivery. A non-2xx response is what makes the real consumer
  // call message.retry(); 400 is acknowledged as permanently invalid.
  async function consume(wake, { attempts = 1, replica = 0, headers = {} } = {}) {
    const target = replica ? await instance.getWorker(`polling-runtime-${replica}`) : { fetch: instance.dispatchFetch.bind(instance) };
    const response = await target.fetch('https://polling.invalid/test/consume', { method: 'POST', body: JSON.stringify(wake), headers: { 'x-poll-attempts': String(attempts), ...headers } });
    const text = await response.text(); let outcome;
    try { outcome = JSON.parse(text).outcome; } catch {}
    return { status: response.status, outcome, text };
  }
  // The consumer adapter's delivery policy: three retries, then dead-letter.
  async function drain(limit = 3000) {
    const redelivery = [];
    for (let i = 0; i < limit; i++) {
      const wakeups = [...redelivery.splice(0), ...(await invoke('wakeups')).map(wake => ({ wake, attempts: 1 }))];
      if (!wakeups.length) return;
      for (const { wake, attempts } of wakeups) {
        const result = await consume(wake, { attempts });
        if (result.status === 200 || result.status === 400) continue;
        if (attempts <= 3) redelivery.push({ wake, attempts: attempts + 1 });
        else await invoke('test/dead-letter', wake);
      }
    }
    throw Error('poll work did not drain');
  }
  const polls = async () => (await invoke('wakeups')).filter(wake => wake.kind === 'poll');
  async function deliver(settle = false) {
    const worker = await instance.getWorker('delivery-runtime');
    for (let i = 0; i < 100; i++) {
      const pending = await rows("SELECT event_id FROM n_event WHERE fanout_complete=0");
      if (!pending.length) break;
      for (const row of pending) {
        const response = await worker.fetch('https://delivery.invalid/queue', { method: 'POST', body: JSON.stringify({ queue: 'opencast-notification-event-development', message: { schema_version: 1, environment: 'development', source: 'feed_polling', id: row.event_id, generation: 1 } }) });
        assert.equal(response.status, 200, await response.text());
      }
    }
    for(let round=0;round<(settle?60:1);round++) {
    const pending=await rows("SELECT * FROM n_delivery WHERE state IN('pending','uncertain')");
    if(!pending.length)break;
    for (const row of pending) {
      const response = await worker.fetch('https://delivery.invalid/queue', { method: 'POST', body: JSON.stringify({ queue: 'opencast-notification-episode-development', message: { schema_version: 1, environment: 'development', source: 'feed_polling', id: row.delivery_id, generation: row.interest_generation } }) });
      assert.equal(response.status, 200, await response.text());
    }
    if(settle && (await first("SELECT COUNT(*) AS n FROM n_delivery WHERE state IN('pending','uncertain')")).n)await new Promise(resolve=>setTimeout(resolve,1000));
    }
  }
  return { instance, db, run, first, rows, invoke, add, consume, polls, drain, deliver, sends, fetches, events, alerts, logs, now, storage, close };
}
// `description` is emitted verbatim (wrap markup in CDATA); omitted, the item is unchanged.
export const item = (id, at, title = `Episode ${id}`, description) => `<item><guid>${id}</guid><title>${title}</title>${description == null ? '' : `<description>${description}</description>`}${at == null ? '' : `<pubDate>${new Date(at * 1000).toUTCString()}</pubDate>`}<enclosure url="https://audio.example.com/${id}.mp3"/></item>`;
export const rss = items => `<rss><channel><title>Fixture</title>${items.join('')}</channel></rss>`;
