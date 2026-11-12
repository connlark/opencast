import assert from 'node:assert/strict';
import { createHash, randomBytes } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { readFileSync } from 'node:fs';
import { basename } from 'node:path';
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
export const wranglerConfig = config;
// Placed mode, off unless `placed` is given or
// OPENCAST_POLL_PLACED_SHARE is set (which runs an unmodified suite placed).
// Each polling Worker gets POLL_PLACED bound to its own default export (a
// replica to itself), a key, the share and TEST_PLACED. A delivery then goes
// through the shipped queue() (h.consume and h.drain post /test/deliver, a
// one-message batch; or the real local Queue) and, on the placed route,
// through the shipped default fetch, which tests/entry.mjs instruments as it
// does /test/consume. `placed`: { share, key, keys: {replica: key|null},
// targets: {replica: worker name|null}, bindings: {replica: {name: value}},
// allowZero }. A key null leaves POLL_PLACED_KEY unbound, a target null
// leaves POLL_PLACED unbound. In placed mode the real build/index.js is served
// as build/index.real.js behind RUST_BOUNDARY (module registration only; the
// file on disk is read, never written): a witness of what Rust receives.
const PLACED_PREFIX = 'PLACED-ROUTE';
const RUST_BOUNDARY = `// The Rust boundary witness (tests/harness.mjs, placed mode only).
import RealWorker from './index.real.js';
export * from './index.real.js';
const witness = globalThis.__opencastRustBoundary ??= { constructed: 0, entries: 0, key_env: 0, key_header: 0, recent: [], consumes: [] };
export default function RustBoundary(ctx, env) {
  // Only a key long enough to mean anything is compared (an empty or short configured key is not usable).
  const key = typeof globalThis.__opencastPlacedKey === 'string' && globalThis.__opencastPlacedKey.length >= 16 ? globalThis.__opencastPlacedKey : null;
  const keyInEnv = 'POLL_PLACED_KEY' in env || (typeof key === 'string' && Object.values(env).some(value => typeof value === 'string' && value.includes(key)));
  witness.constructed++; if (keyInEnv) witness.key_env++;
  const envKeys = Object.keys(env).sort(), inner = new RealWorker(ctx, env);
  return { async fetch(request) {
    const headers = [...request.headers];
    const entry = { at: Date.now(), path: new URL(request.url).pathname, method: request.method, env_keys: envKeys, key_in_env: keyInEnv,
      header_names: headers.map(([name]) => name), message_id: request.headers.get('x-poll-message-id'), attempts: request.headers.get('x-poll-attempts'),
      hop: request.headers.has('x-poll-hop'), key_header: request.headers.has('x-poll-placed-key'),
      key_value_in_headers: typeof key === 'string' && headers.some(([, value]) => value.includes(key)), status: null, text: null };
    if (entry.key_header || entry.key_value_in_headers) witness.key_header++;
    witness.entries++; witness.recent.push(entry); if (witness.recent.length > 500) witness.recent.shift();
    // Consumes apart, with the wake's feed: what Rust received for each delivery it ran.
    if (entry.path === '/consume') { try { entry.feed = JSON.parse(await request.clone().text())?.feed_id ?? null; } catch { entry.feed = null; } witness.consumes.push(entry); if (witness.consumes.length > 300) witness.consumes.shift(); }
    const response = await inner.fetch(request);
    entry.status = response.status;
    try { entry.text = (await response.clone().text()).slice(0, 4000); } catch {}
    return response;
  } };
}
`;
const sha256File = path => { try { return createHash('sha256').update(readFileSync(path)).digest('hex'); } catch { return 'missing'; } };
// One storage per harness, a PostgreSQL clone shared by every polling replica
// and the delivery Worker (NotificationsWorker/tests/storage.mjs). The harness
// owns it: close(), or the suites' existing h.instance.dispose(), disposes
// Miniflare and then the storage.
// `logs: true` also keeps every Worker's JSON log events in h.logs and every
// message, JSON or plain, as {level, message} in h.raw, each still printed as
// Miniflare prints it. `direct: true` binds PostgreSQL without the
// wire proxy: no storage hook and no storage counter, so only for a suite whose
// source arms none and asserts none.
export async function harness(outbound, options = {}) {
  // Retired options fail loudly rather than run a different suite than asked.
  if ('persist' in options) throw Error('harness: persist was retired: each harness owns one transient PostgreSQL clone');
  if ('fiveMinute' in options) throw Error('harness: fiveMinute was retired: the polling suites run the production cadence');
  const sends = [], fetches = [], events = [], alerts = [], logs = [], raw = [];
  let instance;
  const placed = options.placed ?? (process.env.OPENCAST_POLL_PLACED_SHARE !== undefined ? { share: process.env.OPENCAST_POLL_PLACED_SHARE } : undefined);
  const placedKey = placed ? (placed.key ?? randomBytes(32).toString('hex')) : undefined;
  const buildIndex = root + 'FeedPollingWorker/build/index.js', buildSha = placed ? sha256File(buildIndex) : undefined;
  // Placed mode: every outbound request's URL and whether a key of this harness appears in its URL, a header
  // value or its body (a boolean; the value is never kept).
  const placedOutbound = [];
  const placedKeys = () => [placedKey, ...Object.values(placed?.keys ?? {})].filter(key => typeof key === 'string' && key.length >= 16);
  const placedLeak = (...texts) => placedKeys().some(key => texts.flat(2).some(text => typeof text === 'string' && text.includes(key)));
  if (placed) console.log(`PLACED-MODE start suite=${basename(process.argv[1] ?? '?')} share=${placed.share ?? '256'} build_index_sha256=${buildSha}`);
  const storage = await openStorage();
  const modules = (worker, entry) => [
    { type: 'ESModule', path: root + worker + '/' + entry },
    { type: 'ESModule', path: root + worker + '/adapter/index.js' },
    ...(placed && worker === 'FeedPollingWorker' ? [
      { type: 'ESModule', path: root + worker + '/build/index.js', contents: RUST_BOUNDARY },
      { type: 'ESModule', path: root + worker + '/build/index.real.js', contents: readFileSync(options.pollingBuild ? `${options.pollingBuild}/index.js` : buildIndex) },
    ] : [{ type: 'ESModule', path: root + worker + '/build/index.js', ...fixtureBuild(options, worker, 'index.js') }]),
    { type: 'CompiledWasm', path: root + worker + '/build/index_bg.wasm', ...fixtureBuild(options, worker, 'index_bg.wasm') },
  ];
  const workers = [
    { name: 'polling-runtime', modulesRoot: root, modules: modules('FeedPollingWorker', 'tests/entry.mjs'),
      compatibilityDate: config.compatibility_date, compatibilityFlags: config.compatibility_flags,
      r2Buckets: { FEED_SNAPSHOTS: 'isolated-snapshots' },
      queueProducers: { POLL_QUEUE: 'isolated-poll' },
      ...(options.realQueues?{queueConsumers:{'isolated-poll':{maxBatchSize:1,maxConcurrency:2,maxBatchTimeout:0.1,maxRetries:3,retryDelay:options.retryDelay??1,deadLetterQueue:'isolated-poll-dlq'},'isolated-poll-dlq':{maxBatchSize:10,maxBatchTimeout:0.1}}}:{}),
      bindings: { TEST_REAL_QUEUE: options.realQueues?'true':'false',NOTIFICATION_ENVIRONMENT: options.environment ?? 'development', NOTIFICATION_DISPATCHER_ADMISSION: 'true', NOTIFICATION_FEED_OBSERVATION: 'true', NOTIFICATION_CLEANUP: 'true', ...(options.alertSecrets ?? {}) },
      serviceBindings: { NOTIFICATION_EVENTS: options.realQueues?{name:'delivery-runtime',entrypoint:'FeedEvents'}:async request => {
        const body = await request.text(); events.push(JSON.parse(body));
        const worker = await instance.getWorker('delivery-runtime');
        const response = await worker.fetch('https://delivery.invalid/v1/events', { method: 'POST', body });
        if (options.loseReceipt?.()) { await response.text(); return new Response('lost', { status: 503 }); }
        return response;
      } },
      outboundService: async request => { fetches.push(request.url); if (placed) placedOutbound.push({ url: request.url, leak: placedLeak(request.url, [...request.headers], await request.clone().text()) }); if (request.url === ALERT_WEBHOOK_URL) alerts.push({ headers: Object.fromEntries(request.headers), body: await request.clone().json() }); return outbound(request); },
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
  const pollingWorkers = workers.filter(worker => worker.name.startsWith('polling-runtime'));
  if (placed) for (const worker of pollingWorkers) {
    const replica = worker.name === 'polling-runtime' ? 0 : Number(worker.name.slice('polling-runtime-'.length));
    const key = placed.keys && replica in placed.keys ? placed.keys[replica] : placedKey;
    const target = placed.targets && replica in placed.targets ? placed.targets[replica] : worker.name;
    worker.bindings = { ...worker.bindings, TEST_PLACED: 'true', POLL_PLACED_SHARE: String(placed.share ?? '256'), ...(key == null ? {} : { POLL_PLACED_KEY: key }), ...(placed.bindings?.[replica] ?? {}) };
    // TEST_PLACED_NEVER never answers: the "never" stub forwards the adapter's
    // own request and signal to it, so the runtime's timer ends the call.
    worker.serviceBindings = { ...worker.serviceBindings, ...(target == null ? {} : { POLL_PLACED: { name: target } }), TEST_PLACED_NEVER: async () => new Promise(() => {}) };
  }
  // The placed-mode summary (one PLACED-ROUTE line per harness): deliveries
  // that took the binding and those that ran in process, by reason, from every
  // polling Worker's metrics, and build/index.js's sha256 at start and end. A
  // placed harness none of whose deliveries took the binding fails.
  async function placedSummary() {
    const total = { binding: 0, in_process: 0, reasons: {} };
    for (const { name } of pollingWorkers) {
      let metrics; try { metrics = await (await (await instance.getWorker(name)).fetch('https://polling.invalid/metrics')).json(); } catch { continue; }
      const counts = metrics.placed ?? {};
      total.binding += counts.binding ?? 0; total.in_process += counts.in_process ?? 0;
      for (const [reason, n] of Object.entries(counts.reasons ?? {})) total.reasons[reason] = (total.reasons[reason] ?? 0) + n;
    }
    const end = sha256File(buildIndex);
    console.log(`${PLACED_PREFIX} suite=${basename(process.argv[1] ?? '?')} share=${placed.share ?? '256'} binding=${total.binding} in_process=${total.in_process} reasons=${JSON.stringify(total.reasons)} build_index_sha256_start=${buildSha} build_index_sha256_end=${end}`);
    if (end !== buildSha) return Error(`${PLACED_PREFIX}: build/index.js changed during the run`);
    if (total.binding === 0 && !placed.allowZero) return Error(`${PLACED_PREFIX}: no delivery took the binding`);
  }
  // Miniflare first, so no Worker still holds a connection, then the storage
  // (its witness checked, its database dropped). Once, however it is reached.
  let disposeInstance, closing, db;
  const close = () => closing ??= (async () => {
    let summary;
    try { if (placed && instance) summary = await placedSummary(); await disposeInstance?.(); } finally { await storage.dispose(); }
    if (summary) throw summary;
  })();
  try {
    // Bound after the replicas are copied: each Worker gets its own alias and,
    // for these instrumented entries, its own TEST_STORAGE.
    const bound = workers.map(worker => storage.bind(worker, { direct: !!options.direct }));
    const handleStructuredLogs = ({ level, message }) => { raw.push({ level, message }); try { const event = JSON.parse(message); if (event?.event) logs.push(event); } catch {} (level === 'error' || level === 'warn' ? console.error : console.log)(message); };
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
  // In placed mode the delivery goes through the shipped queue() as a
  // one-message batch (/test/deliver): the result adds the adapter's decision
  // (ack, retry, throw), its hops through the binding and the route taken; the
  // status, outcome and text are the hop's response (or, in process, the Rust
  // boundary's). The message id is the suite's x-poll-message-id, else one per
  // wake, so a redelivery keeps its id as the Queue's does. A consume carrying
  // x-test-execution (an engine cancellation control) has no handle on a
  // placed engine, which is handed no signal: it runs in process, said so.
  async function consume(wake, { attempts = 1, replica = 0, headers = {}, queue } = {}) {
    const target = replica ? await instance.getWorker(`polling-runtime-${replica}`) : { fetch: instance.dispatchFetch.bind(instance) };
    if (placed && !('x-test-execution' in headers)) {
      const id = headers['x-poll-message-id'] ?? `placed-${hash(['placed-message', wake]).slice(0, 32)}`;
      const response = await target.fetch('https://polling.invalid/test/deliver', { method: 'POST', body: JSON.stringify(wake), headers: { 'x-poll-attempts': String(attempts), ...headers, 'x-poll-message-id': id, ...(queue ? { 'x-test-queue': queue } : {}) } });
      const result = JSON.parse(await response.text()), hop = result.hops.at(-1), text = hop?.text ?? result.rust?.text ?? '';
      let outcome; try { outcome = JSON.parse(text).outcome; } catch {}
      return { ...result, status: hop?.status ?? result.rust?.status ?? 0, outcome, text, route: result.hops.length ? 'placed' : 'in_process' };
    }
    if (placed) { headers = { ...headers, 'x-test-placed-reason': 'engine_cancellation_control' }; console.log(`PLACED-MODE in-process consume (engine cancellation control ${headers['x-test-execution']}): a placed engine is handed no signal`); }
    const response = await target.fetch('https://polling.invalid/test/consume', { method: 'POST', body: JSON.stringify(wake), headers: { 'x-poll-attempts': String(attempts), ...headers } });
    const text = await response.text(); let outcome;
    try { outcome = JSON.parse(text).outcome; } catch {}
    return { status: response.status, outcome, text };
  }
  // The consumer adapter's delivery policy: three retries, then dead-letter.
  // In placed mode the shipped adapter decides: its ack ends a message, its
  // retry or a throw out of queue() redelivers it.
  async function drain(limit = 3000) {
    const redelivery = [];
    for (let i = 0; i < limit; i++) {
      const wakeups = [...redelivery.splice(0), ...(await invoke('wakeups')).map(wake => ({ wake, attempts: 1 }))];
      if (!wakeups.length) return;
      for (const { wake, attempts } of wakeups) {
        const result = await consume(wake, { attempts });
        if (placed ? ['ack', 'implicit_ack'].includes(result.decision) : (result.status === 200 || result.status === 400)) continue;
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
  return { instance, db, run, first, rows, invoke, add, consume, polls, drain, deliver, sends, fetches, events, alerts, logs, raw, now, storage, close, ...(placed ? { placed: { ...placed, key: placedKey, allKeys: placedKeys() }, placedOutbound } : {}) };
}
// `description` is emitted verbatim (wrap markup in CDATA); omitted, the item is unchanged.
export const item = (id, at, title = `Episode ${id}`, description) => `<item><guid>${id}</guid><title>${title}</title>${description == null ? '' : `<description>${description}</description>`}${at == null ? '' : `<pubDate>${new Date(at * 1000).toUTCString()}</pubDate>`}<enclosure url="https://audio.example.com/${id}.mp3"/></item>`;
export const rss = items => `<rss><channel><title>Fixture</title>${items.join('')}</channel></rss>`;
