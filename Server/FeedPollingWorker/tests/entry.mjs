// Isolated workerd instrumentation. Never included in either deployed bundle.
import Worker, { PollingControl } from '../adapter/index.js';
const NativeDate = Date;
// `frozen` pins the wall clock so two executions can share one integer second.
let offset = 0, fault, frozen;
globalThis.Date = class extends NativeDate {
  constructor(...args) { super(...(args.length ? args : [(frozen ?? NativeDate.now()) + offset])); }
  static now() { return (frozen ?? NativeDate.now()) + offset; }
};
const wakeups = [], controllers = new Map();
const COUNTERS = ['d1', 'rows_read', 'rows_written', 'get', 'put', 'head', 'delete', 'list', 'multipart', 'queue_messages'];
const totals = { outcomes: {}, logged: {}, calls: 0, log_events: 0, ...Object.fromEntries(COUNTERS.map(name => [name, 0])), max_d1: 0, max_r2: 0, scratch_peak_bytes: 0, recent: [] };
for(const method of ['log','warn','error']){const native=console[method].bind(console);console[method]=(...args)=>{
  totals.log_events++;
  // Failures are always logged; healthy polls are only sampled. Exact outcome
  // counts come from the consume results, failure classes from these events.
  try { const event=JSON.parse(args[0]);if(event.event==='poll_outcome'){const key=`${event.outcome}:${event.reason??''}`;totals.logged[key]=(totals.logged[key]??0)+1;} } catch {}
  native(...args);
};}
function fail(point) { if (fault === `always:${point}`) throw Error(`fixture:${point}`); if (fault === point) { fault = undefined; throw Error(`fixture:${point}`); } }
function instrument(env, trace) {
  const raw = new WeakMap(), sqls = new WeakMap();
  const count = n => { trace.d1 += n; if (trace.d1 > 1000) throw Error('D1 invocation limit'); };
  const result = value => { for (const r of Array.isArray(value) ? value : [value]) { trace.rows_read += r?.meta?.rows_read ?? 0; trace.rows_written += r?.meta?.rows_written ?? 0; } return value; };
  const prepared = (s, sql) => {
    const proxy = new Proxy(s, { get(target, key) {
      if (key === 'constructor') return target.constructor;
      if (key === 'bind') return (...args) => prepared(target.bind(...args), sql);
      if (['run', 'all', 'first', 'raw'].includes(key)) return async (...args) => {
        count(1); fail('d1'); if(sql.includes('INSERT INTO n_poll_origin'))fail('origin_status_d1');
        if(key==='first'){const value=result(await target.all());const row=value.results[0]??null;return args[0]&&row?row[args[0]]:row;}
        return result(await target[key](...args));
      };
      const value = Reflect.get(target, key); return typeof value === 'function' ? value.bind(target) : value;
    } }); raw.set(proxy, s); sqls.set(proxy, sql); return proxy;
  };
  const db = new Proxy(env.APP_ATTEST_DB, { get(target, key) {
    if (key === 'constructor') return target.constructor;
    if (key === 'prepare') return sql => prepared(target.prepare(sql), sql);
    if (key === 'batch') return async statements => {
      count(statements.length); const sql = statements.map(s => sqls.get(s) ?? '').join(' ');
      if (sql.includes('UPDATE n_feed SET observation_generation=')) {
        fail('before_publish');
        // A newer dispatch generation, or a new owner epoch, arrives between
        // the fetch and its commit: the in-flight message must not publish.
        if (fault === 'stale_generation') { fault = undefined; await target.prepare('UPDATE n_feed SET schedule_generation=schedule_generation+1 WHERE dispatch_until>0').run(); }
        if (fault === 'stale_epoch') { fault = undefined; await target.prepare('UPDATE n_feed SET epoch=epoch+1 WHERE dispatch_until>0').run(); }
      }
      if (sql.includes('UPDATE n_feed SET last_success_at=')) {
        fail('before_settle');
        if (fault === 'stale_settle') { fault = undefined; await target.prepare('UPDATE n_feed SET schedule_generation=schedule_generation+1 WHERE dispatch_until>0').run(); }
      }
      const value = await target.batch(statements.map(s => raw.get(s) ?? s));
      if (sql.includes('UPDATE n_feed SET last_success_at=')) fail('after_settle');
      if (sql.includes('UPDATE n_feed SET observation_generation=')) fail('after_publish');
      return result(value);
    };
    const value = Reflect.get(target, key); return typeof value === 'function' ? value.bind(target) : value;
  } });
  const bucket = new Proxy(env.FEED_SNAPSHOTS, { get(target, key) {
    if (key === 'constructor') return target.constructor;
    if (['get', 'put', 'head', 'delete', 'list'].includes(key)) return async (...args) => { trace[key]++; if(key==='get'&&fault==='slow_get'){fault=undefined;await new Promise(resolve=>setTimeout(resolve,16000));} fail(`before_${key}`); const value = await target[key](...args); fail(`after_${key}`); return value; };
    // Scratch is one multipart upload: count every Class A call and its bytes.
    if (key === 'createMultipartUpload') return async (...args) => {
      trace.multipart++; const upload = await target.createMultipartUpload(...args); let bytes = 0;
      return new Proxy(upload, { get(inner, name) {
        if (name === 'constructor') return inner.constructor;
        if (['uploadPart', 'complete', 'abort'].includes(name)) return async (...parts) => {
          trace.multipart++; fail(`scratch_${name}`);
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
  const instrumented={ ...env, APP_ATTEST_DB: db, FEED_SNAPSHOTS: bucket, POLL_QUEUE: env.TEST_REAL_QUEUE==='true'?env.POLL_QUEUE:queue };
  if(fault==='missing_events'){fault=undefined;delete instrumented.NOTIFICATION_EVENTS;}
  return instrumented;
}
export default class extends Worker {
  // The real Queue path runs the shipped consumer adapter unchanged, against
  // the same fault-injecting bindings. Only its retry delay is shortened.
  async queue(batch) {
    const trace = { path: '/queue', ...Object.fromEntries(COUNTERS.map(name => [name, 0])) };
    const messages = batch.messages.map(message => new Proxy(message, { get(target, key) {
      if (key === 'retry') return () => target.retry({ delaySeconds: 1 });
      const value = Reflect.get(target, key); return typeof value === 'function' ? value.bind(target) : value;
    } }));
    return Worker.prototype.queue.call({ ctx: this.ctx, env: instrument(this.env, trace) }, { queue: batch.queue, messages });
  }
  async fetch(request) {
    const path = new URL(request.url).pathname;
    if (path === '/clock') { offset = Number(await request.text()) * 1000; return new Response('ok'); }
    if (path === '/fault') { fault = await request.text(); return new Response('ok'); }
    if (path === '/freeze') { const at = await request.text(); frozen = at ? Number(at) * 1000 : undefined; return new Response('ok'); }
    if (path === '/wakeups') {
      const due=wakeups.filter(w=>w.at<=Date.now());
      const waiting=wakeups.filter(w=>w.at>Date.now());wakeups.splice(0,wakeups.length,...waiting);
      return Response.json(due.map(w=>w.body));
    }
    if (path === '/metrics') return Response.json(totals);
    if (path === '/abort') { const pending=controllers.get(await request.text());if(pending)pending.requested=true;return new Response('ok'); }
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
      const response = await new PollingControl(this.ctx, instrument(this.env, trace)).fetch(controller ? new Request(input, { signal: controller.signal }) : input);
      // Healthy polls are only sampled in logs; the consume result is exact.
      if (path === '/test/consume' && response.ok) { try { const { outcome } = await response.clone().json(); trace.outcome = outcome; totals.outcomes[outcome] = (totals.outcomes[outcome] ?? 0) + 1; } catch {} }
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
