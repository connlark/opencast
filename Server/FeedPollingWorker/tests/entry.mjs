// Isolated workerd instrumentation. Never included in either deployed bundle.
import Worker, { PollingControl } from '../adapter/index.js';
const NativeDate = Date;
// `frozen` pins the wall clock so two executions can share one integer second.
let offset = 0, fault, frozen, releaseHang;
globalThis.Date = class extends NativeDate {
  constructor(...args) { super(...(args.length ? args : [(frozen ?? NativeDate.now()) + offset])); }
  static now() { return (frozen ?? NativeDate.now()) + offset; }
};
const wakeups = [], controllers = new Map();
// `d1` and `max_d1` are the storage statement counters (their names kept for
// the suites that assert them); `rows_read` and `rollup_rows_read` read 0, as
// the PostgreSQL counters report statements and rows written only.
// `multipart` is every Class A multipart call; the `multipart_*` split and the
// `scratch_*` reads and deletes say which scratch lifecycle a scan took.
const COUNTERS = ['d1', 'rows_read', 'rows_written', 'rollup_rows_read', 'get', 'put', 'head', 'delete', 'list', 'multipart', 'multipart_create', 'multipart_part', 'multipart_complete', 'multipart_abort', 'scratch_get', 'scratch_delete', 'queue_messages'];
const totals = { deliveries: [], cleanup: [], cron: [], alert_deliveries: [], outcomes: {}, passes: {}, logged: {}, calls: 0, log_events: 0, ...Object.fromEntries(COUNTERS.map(name => [name, 0])), max_d1: 0, max_r2: 0, scratch_peak_bytes: 0, recent: [] };
for(const method of ['log','warn','error']){const native=console[method].bind(console);console[method]=(...args)=>{
  totals.log_events++;
  // Failures are always logged; healthy polls are only sampled. Exact outcome
  // counts come from the consume results, failure classes from these events.
  try { const event=JSON.parse(args[0]);if(event.event==='poll_delivery'){totals.deliveries.push(event);if(totals.deliveries.length>100)totals.deliveries.shift();}if(event.event==='poll_cleanup')totals.cleanup.push(event);if(event.event==='poll_alert_delivery')totals.alert_deliveries.push({level:method,...event});if(event.event==='poll_outcome'){const key=`${event.outcome}:${event.reason??''}`;totals.logged[key]=(totals.logged[key]??0)+1;} } catch {}
  native(...args);
};}
const hooks = fixtureHooks({ totals, now: () => NativeDate.now(), fault: () => fault, setFault: value => { fault = value; }, hang: release => { releaseHang = release; } });
function fail(point) { if (fault === `always:${point}`) throw Error(`fixture:${point}`); if (fault === point) { fault = undefined; throw Error(`fixture:${point}`); } }
// The storage hooks act on the wire, in
// Server/NotificationsWorker/tests/postgres/proxy.mjs, armed through
// TEST_STORAGE (storage.mjs's Node function for this Worker's proxy alias).
// `fault` stays this entry's own variable for every local hook.
async function storage(env, op) {
  const response = await env.TEST_STORAGE.fetch('https://test-storage.invalid/', { method: 'POST', body: JSON.stringify(op) });
  const body = await response.json(); if (!response.ok) throw Error(`TEST_STORAGE ${op.op}: ${body.error}`); return body;
}
// The alias's counters around one instrumented invocation: application
// statements, rows written by INSERT/UPDATE/DELETE tags, and whether another
// measured invocation overlapped any part of this window. Without
// TEST_STORAGE (a direct binding) it returns run()'s own promise and counts
// nothing.
function counted(env, trace, run) {
  if (!env.TEST_STORAGE) return run();
  return (async () => {
    const begin = await storage(env, { op: 'counters', begin: true });
    try { return await run(); } finally {
      const end = await storage(env, { op: 'counters', end: begin.invocation });
      trace.d1 += end.statements - begin.statements; trace.rows_written += end.rows_written - begin.rows_written; trace.storage_exclusive = end.exclusive;
    }
  })();
}
function instrument(env, trace) {
  const bucket = new Proxy(env.FEED_SNAPSHOTS, { get(target, key) {
    if (key === 'constructor') return target.constructor;
    if (['get', 'put', 'head', 'delete', 'list'].includes(key)) return async (...args) => { trace[key]++; if (['get', 'delete'].includes(key) && typeof args[0] === 'string' && args[0].startsWith('scratch/')) trace[`scratch_${key}`]++; if(key==='delete'&&fault==='cleanup_budget'){offset+=26000;fault=undefined;} if(key==='get'&&fault==='slow_get'){fault=undefined;await new Promise(resolve=>setTimeout(resolve,16000));} if(key==='get'&&fault==='hang_get'){fault='hang_get_active';await new Promise(resolve=>releaseHang=resolve);} fail(`before_${key}`); const value = await target[key](...args); fail(`after_${key}`); return value; };
    // Scratch is one multipart upload: count every Class A call and its bytes.
    if (key === 'createMultipartUpload') return async (...args) => {
      trace.multipart++; trace.multipart_create++; const upload = await target.createMultipartUpload(...args); let bytes = 0;
      return new Proxy(upload, { get(inner, name) {
        if (name === 'constructor') return inner.constructor;
        if (['uploadPart', 'complete', 'abort'].includes(name)) return async (...parts) => {
          trace.multipart++; trace[name === 'uploadPart' ? 'multipart_part' : `multipart_${name}`]++;
          // `slow_part:<ms>` stalls the next part upload once: a spool or body write mid-scan.
          if (name === 'uploadPart' && fault?.startsWith('slow_part:')) { const ms = Number(fault.slice(10)); fault = undefined; await new Promise(resolve => setTimeout(resolve, ms)); }
          fail(`scratch_${name}`);
          if (name === 'uploadPart') { bytes += parts[1].byteLength ?? parts[1].length ?? 0; totals.scratch_peak_bytes = Math.max(totals.scratch_peak_bytes, bytes); }
          return inner[name](...parts);
        };
        const value = Reflect.get(inner, name); return typeof value === 'function' ? value.bind(inner) : value;
      } });
    };
    const value = Reflect.get(target, key); return typeof value === 'function' ? value.bind(target) : value;
  } });
  const queue = new Proxy(env.POLL_QUEUE, { get(target, key) {
    if (key === 'constructor') return target.constructor;
    if (key === 'send') return async (body, options) => {
      fail('enqueue'); trace.queue_messages++;
      wakeups.push({body,at:Date.now()+(options?.delaySeconds??0)*1000});
    };
    if (key === 'sendBatch') return async (messages, options) => {
      fail('enqueue'); trace.queue_messages += messages.length;
      if (fault === 'lost_queue') { fault = undefined; return; }
      wakeups.push(...messages.map(m => ({body:m.body, at:Date.now()+(options?.delaySeconds??0)*1000}))); fail('after_enqueue');
    };
    const value = Reflect.get(target, key); return typeof value === 'function' ? value.bind(target) : value;
  } });
  const instrumented={ ...env, FEED_SNAPSHOTS: bucket, POLL_QUEUE: env.TEST_REAL_QUEUE==='true'?env.POLL_QUEUE:queue };
  if(fault==='missing_events'){fault=undefined;delete instrumented.NOTIFICATION_EVENTS;}
  hooks.instrument(instrumented);
  return instrumented;
}
export default class extends Worker {
  async scheduled(controller) {
    const trace = { path: '/scheduled', ...Object.fromEntries(COUNTERS.map(name => [name, 0])) };
    totals.cron.push(controller.cron);
    await counted(this.env, trace, () => Worker.prototype.scheduled.call({ctx:this.ctx,env:instrument(this.env,trace)},controller));
    for(const name of COUNTERS)totals[name]+=trace[name];
    totals.max_d1=Math.max(totals.max_d1,trace.d1);
  }
  // The real Queue path runs the shipped consumer adapter unchanged, against
  // the same fault-injecting bindings. Only its retry delay is shortened.
  async queue(batch) {
    const trace = { path: '/queue', ...Object.fromEntries(COUNTERS.map(name => [name, 0])) };
    hooks.batch(batch);
    const messages = batch.messages.map(message => new Proxy(message, { get(target, key) {
      if (key === 'retry') return options => hooks.retry(target, options);
      const value = Reflect.get(target, key); return typeof value === 'function' ? value.bind(target) : value;
    } }));
    return counted(this.env, trace, () => Worker.prototype.queue.call({ ctx: this.ctx, env: instrument(this.env, trace) }, { queue: batch.queue, messages }));
  }
  async fetch(request) {
    const path = new URL(request.url).pathname;
    if (path === '/clock') { offset = Number(await request.text()) * 1000; return new Response('ok'); }
    if (path === '/fault') { fault = await request.text(); if (this.env.TEST_STORAGE) await storage(this.env, { op: 'arm', kind: 'fault', name: fault }); return new Response('ok'); }
    if (path === '/fault-state') {
      // A fired, unreleased storage hold answers; otherwise this entry's own variable.
      if (this.env.TEST_STORAGE) { const held = await storage(this.env, { op: 'state', which: 'fault-state' }); if (held.value !== null) return new Response(String(held.value)); }
      return new Response(fault??'');
    }
    if (path === '/release-hang') { releaseHang?.(); releaseHang = undefined; fault = undefined; if (this.env.TEST_STORAGE) await storage(this.env, { op: 'release', kind: 'release-hang' }); return new Response('ok'); }
    if (path === '/freeze') { const at = await request.text(); frozen = at ? Number(at) * 1000 : undefined; return new Response('ok'); }
    if (path === '/wakeups') {
      const due=wakeups.filter(w=>w.at<=Date.now());
      const waiting=wakeups.filter(w=>w.at>Date.now());wakeups.splice(0,wakeups.length,...waiting);
      return Response.json(due.map(w=>w.body));
    }
    if (path === '/metrics') return Response.json(totals);
    if (path === '/abort') { const pending=controllers.get(await request.text());if(pending)pending.requested=true;return new Response('ok'); }
    const hooked = await hooks.route(path, request); if (hooked) return hooked;
    if (!path.startsWith('/test/')) return super.fetch(request);
    const trace = { path, ...Object.fromEntries(COUNTERS.map(name => [name, 0])) };
    const key = request.headers.get('x-test-execution'), controller = key ? new AbortController() : undefined;
    const cancellation={requested:false,finished:false};
    let watching;
    if (controller) {
      controllers.set(key,cancellation);
      // Abort native I/O in the originating request's workerd context.
      watching=(async()=>{while(!cancellation.requested&&!cancellation.finished)await new Promise(resolve=>setTimeout(resolve,10));if(cancellation.requested)controller.abort();})();
    }
    const start = performance.now();
    try {
      const input = new Request(request.url.replace('/test', ''), request);
      const response = await counted(this.env, trace, () => new PollingControl(this.ctx, instrument(this.env, trace)).fetch(controller ? new Request(input, { signal: controller.signal }) : input));
      // Healthy polls are only sampled in logs; the consume result is exact.
      // `passes` is how many times a scan parsed its one response body; steps
      // that parsed nothing (304s, continuations) are not counted.
      if (path === '/test/consume' && response.ok) { try { const { outcome, passes } = await response.clone().json(); trace.outcome = outcome; totals.outcomes[outcome] = (totals.outcomes[outcome] ?? 0) + 1; if (passes > 0) { trace.passes = passes; totals.passes[passes] = (totals.passes[passes] ?? 0) + 1; } } catch {} }
      return response;
    } finally {
      cancellation.finished=true;controllers.delete(key);if(watching)await watching;
      trace.wall_ms = performance.now() - start;
      totals.calls++;
      for (const name of COUNTERS) totals[name] += trace[name];
      totals.max_d1 = Math.max(totals.max_d1, trace.d1);
      totals.max_r2 = Math.max(totals.max_r2, trace.get + trace.put + trace.head + trace.delete + trace.list + trace.multipart);
      totals.recent.push(trace); if (totals.recent.length > 100) totals.recent.shift();
    }
  }
}
// The fixture hooks, called from the instrumentation above. Each is armed by
// its own /test route or by the entry's one `fault` variable, acts only when
// armed, and leaves its witness in the entry's metrics as `hooks`:
//  /test/retry-delay <seconds>  the real-queue path's retry wrapper forwards
//      this delay instead of 1 s (an empty body restores 1). Every retry the
//      shipped consumer adapter asks for is recorded with the delay it asked
//      for and the one forwarded, and every batch with its arrival, so a run
//      can witness the adapter's own retry({ delaySeconds: 60 }).
//  fault slow_get:<ms>:<prefix>  the next R2 get of a key starting with
//      <prefix> waits <ms> before it is made (the unscoped slow_get waits 16 s
//      on any get).
//  fault hang_get:<prefix>  the next R2 get of a key starting with <prefix>
//      returns its object, but every read of the object's body waits for
//      /release-hang (the unscoped hang_get holds the get itself); fault-state
//      reads hang_get_active meanwhile.
//  fault hold_service_body:<ms>  the next FeedEvents reply (the
//      NOTIFICATION_EVENTS binding) returns its status and headers at once
//      and its body <ms> later.
//  x-test-body-delay-ms  an outbound reply carrying this header (the
//      webhook stub's, webhook-stub.mjs) reaches the Worker with its status
//      and headers at once and its body that many ms later. A delay made
//      before the reply leaves Node would hold the whole reply instead:
//      Miniflare buffers an outbound reply before handing it to workerd.
//  /test/stall <ms>  a synchronous stall of this isolate for <ms> (every
//      other request's timers and I/O wait behind it), timed on
//      performance.now(), which advances during execution here; the proxy's
//      controls.stall schedules it from another hook's fire.
function fixtureHooks({ totals, now, fault, setFault, hang }) {
  const witness = totals.hooks = { batches: [], retries: [], r2: [], service: [], outbound: [] };
  let retryDelay = 1;
  const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
  const scoped = (name, key) => {
    const value = fault(), m = typeof value === 'string' && typeof key === 'string' && (name === 'slow_get' ? /^slow_get:(\d+):(.+)$/ : /^hang_get:(.+)$/).exec(value);
    return m && key.startsWith(m.at(-1)) ? m : null;
  };
  // Every body read of a held object waits for the one release.
  const heldBody = (object, released) => new Proxy(object, { get(target, key) {
    if (['arrayBuffer', 'text', 'json', 'blob', 'bytes'].includes(key)) return async (...args) => { await released; return target[key](...args); };
    if (key === 'body') return new ReadableStream({ async start(controller) { await released; const reader = target.body.getReader(); for (;;) { const { done, value } = await reader.read(); if (done) break; controller.enqueue(value); } controller.close(); } });
    const value = Reflect.get(target, key); return typeof value === 'function' ? value.bind(target) : value;
  } });
  const nativeFetch = globalThis.fetch;
  globalThis.fetch = async function (...args) {
    const response = await nativeFetch.apply(this, args), ms = Number(response.headers.get('x-test-body-delay-ms') ?? 0);
    if (!(ms > 0)) return response;
    const record = { hook: 'body_delay', url: typeof args[0] === 'string' ? args[0] : args[0]?.url, status: response.status, ms, headers: now(), body: null }; witness.outbound.push(record);
    const body = new ReadableStream({ async start(controller) { const bytes = new Uint8Array(await response.arrayBuffer()); await pause(ms); record.body = now(); controller.enqueue(bytes); controller.close(); } });
    return new Response(body, { status: response.status, statusText: response.statusText, headers: response.headers });
  };
  return {
    instrument(env) {
      const events = env.NOTIFICATION_EVENTS;
      if (events) env.NOTIFICATION_EVENTS = new Proxy(events, { get(target, key) {
        if (key === 'constructor') return target.constructor;
        if (key === 'fetch') return async (...args) => {
          const m = /^hold_service_body:(\d+)$/.exec(fault() ?? '');
          if (!m) return target.fetch(...args);
          setFault(undefined);
          const record = { hook: 'hold_service_body', ms: Number(m[1]), sent: now(), headers: null, body: null }; witness.service.push(record);
          const response = await target.fetch(...args); record.headers = now();
          const body = new ReadableStream({ async start(controller) { const bytes = new Uint8Array(await response.arrayBuffer()); await pause(record.ms); record.body = now(); controller.enqueue(bytes); controller.close(); } });
          return new Response(body, { status: response.status, statusText: response.statusText, headers: response.headers });
        };
        const value = Reflect.get(target, key); return typeof value === 'function' ? value.bind(target) : value;
      } });
      const bucket = env.FEED_SNAPSHOTS;
      env.FEED_SNAPSHOTS = new Proxy(bucket, { get(target, key) {
        if (key === 'constructor') return target.constructor;
        if (key === 'get') return async (...args) => {
          const slow = scoped('slow_get', args[0]), held = !slow && scoped('hang_get', args[0]);
          if (slow) {
            setFault(undefined); const record = { hook: 'slow_get', key: args[0], prefix: slow[2], ms: Number(slow[1]), start: now(), end: null }; witness.r2.push(record);
            await pause(record.ms); record.end = now();
          }
          if (!held) return target.get(...args);
          setFault('hang_get_active'); const record = { hook: 'hang_get', key: args[0], prefix: held[1], held: now(), released: null }; witness.r2.push(record);
          let release; const released = new Promise(resolve => { release = () => { record.released ??= now(); resolve(); }; }); hang(release);
          const object = await target.get(...args);
          return object && 'body' in object ? heldBody(object, released) : (release(), object);
        };
        const value = Reflect.get(target, key); return typeof value === 'function' ? value.bind(target) : value;
      } });
    },
    batch(batch) { witness.batches.push({ at: now(), queue: batch.queue, messages: batch.messages.map(m => ({ id: m.id, attempts: m.attempts })) }); },
    retry(message, options) {
      witness.retries.push({ at: now(), id: message.id, attempts: message.attempts, requested: options?.delaySeconds ?? null, forwarded: retryDelay });
      return message.retry({ delaySeconds: retryDelay });
    },
    async route(path, request) {
      if (path === '/test/stall') {
        const ms = Number(await request.text());
        if (!(Number.isSafeInteger(ms) && ms >= 0 && ms <= 60000)) return new Response('stall takes whole milliseconds, 0-60000', { status: 400 });
        const start = performance.now(), date = now(); while (performance.now() - start < ms) {}
        return Response.json({ ms, elapsed: performance.now() - start, date_start: date, date_end: now() });
      }
      if (path !== '/test/retry-delay') return undefined;
      const text = (await request.text()).trim(), seconds = Number(text);
      if (text !== '' && !(Number.isSafeInteger(seconds) && seconds >= 0 && seconds <= 43200)) return new Response('retry-delay takes whole seconds, 0-43200', { status: 400 });
      retryDelay = text === '' ? 1 : seconds;
      return Response.json({ retry_delay_s: retryDelay });
    },
  };
}
