// Isolated workerd instrumentation. Never included in either deployed bundle.
import Worker, { PollingControl } from '../adapter/index.js';
// The adapter's exports by name, for a function a base adapter may not have.
import * as adapterModule from '../adapter/index.js';
const NativeDate = Date;
// `frozen` pins the wall clock so two executions can share one integer second.
let offset = 0, fault, frozen, releaseHang;
globalThis.Date = class extends NativeDate {
  constructor(...args) { super(...(args.length ? args : [(frozen ?? NativeDate.now()) + offset])); }
  static now() { return (frozen ?? NativeDate.now()) + offset; }
};
const wakeups = [], controllers = new Map(), gates = new Map();
// Placed mode's invocation identity: each instrumented callee /consume gets a sequence number while it runs, and
// each poll_placed line and consume storage_phases line records which callees were in flight when it was written
// (one in flight = the line is that invocation's). Null until placed mode's first request.
let placedLines = null, calleeSeq = 0; const calleesInFlight = new Set();
// `d1` and `max_d1` are the storage statement counters (their names kept for
// the suites that assert them); `rows_read` and `rollup_rows_read` read 0, as
// the PostgreSQL counters report statements and rows written only.
// `multipart` is every Class A multipart call; the `multipart_*` split and the
// `scratch_*` reads and deletes say which scratch lifecycle a scan took.
const COUNTERS = ['d1', 'rows_read', 'rows_written', 'rollup_rows_read', 'get', 'put', 'head', 'delete', 'list', 'multipart', 'multipart_create', 'multipart_part', 'multipart_complete', 'multipart_abort', 'scratch_get', 'scratch_delete', 'queue_messages'];
const totals = { deliveries: [], cleanup: [], cron: [], alert_deliveries: [], outcomes: {}, passes: {}, logged: {}, calls: 0, log_events: 0, ...Object.fromEntries(COUNTERS.map(name => [name, 0])), max_d1: 0, max_r2: 0, max_r2_in_flight: 0, scratch_peak_bytes: 0, recent: [] };
for(const method of ['log','warn','error']){const native=console[method].bind(console);console[method]=(...args)=>{
  totals.log_events++;
  // Failures are always logged; healthy polls are only sampled. Exact outcome
  // counts come from the consume results, failure classes from these events.
  try { const event=JSON.parse(args[0]);if(event.event==='poll_delivery'){totals.deliveries.push(event);if(totals.deliveries.length>100)totals.deliveries.shift();}if(event.event==='poll_cleanup')totals.cleanup.push(event);if(event.event==='poll_alert_delivery')totals.alert_deliveries.push({level:method,...event});if(event.event==='poll_outcome'){const key=`${event.outcome}:${event.reason??''}`;totals.logged[key]=(totals.logged[key]??0)+1;}if(placedLines&&(event.event==='poll_placed'||(event.event==='storage_phases'&&event.handler==='consume'))){placedLines.push({event:event.event,hop:event.hop??null,feed:event.chain?.feed??null,inflight:[...calleesInFlight]});if(placedLines.length>300)placedLines.shift();} } catch {}
  native(...args);
};}
const hooks = fixtureHooks({ totals, now: () => NativeDate.now(), fault: () => fault, setFault: value => { fault = value; }, hang: release => { releaseHang = release; } });
const r2 = r2Hooks({ totals, now: () => NativeDate.now() });
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
// An invocation's bucket calls so far, by operation (multipart: every Class A
// multipart call).
const r2Calls = trace => Object.fromEntries(['get', 'put', 'head', 'delete', 'list', 'multipart'].map(name => [name, trace[name]]));
// One bucket call of an invocation, in flight from its start to its return.
// `r2_flights` counts the calls so counted.
async function flight(trace, run) {
  trace.r2_flights = (trace.r2_flights ?? 0) + 1; trace.r2_in_flight = (trace.r2_in_flight ?? 0) + 1; trace.r2_in_flight_peak = Math.max(trace.r2_in_flight_peak ?? 0, trace.r2_in_flight);
  try { return await run(); } finally { trace.r2_in_flight--; }
}
// /test/r2-probe (hooks-runtime.mjs): bucket calls made through an
// invocation's instrumented bucket, exactly as the Worker's own calls are, so
// the R2 hooks, the in-flight counter and the gate are qualified without a
// scan. The JSON body {"serial":false,"ops":[{"op":"put","key":"k","then":"head"}]}
// makes its ops at once (serial: one after another). An op is get, put, head,
// delete, list (the key a prefix), multipart (create, one part, complete) or
// resume_abort (create, then abort through a resumed handle);
// `then` names a second call on the same key made once the first returned (a
// continuation). The reply: each op's {op, key, ok, error, start, end} (ms)
// and the invocation's calls, flights, in flight and in-flight peak. Under
// x-test-execution, /abort ends the probe at once with 503 and leaves its ops
// and their continuations running: an invocation whose work was not dropped.
async function probe(bucket, { ops = [], serial = false }, signal, trace) {
  const call = async (op, key, body) => {
    if (op === 'put') return bucket.put(key, body ?? `probe ${key}`);
    if (op === 'list') return bucket.list({ prefix: key });
    if (op === 'get') { const object = await bucket.get(key); await object?.arrayBuffer(); return object; }
    if (op === 'multipart') { const upload = await bucket.createMultipartUpload(key); const part = await upload.uploadPart(1, body ?? `probe ${key}`); return upload.complete([part]); }
    if (op === 'resume_abort') { const upload = await bucket.createMultipartUpload(key); return bucket.resumeMultipartUpload(key, upload.uploadId).abort(); }
    return bucket[op](key);
  };
  const one = async ({ op, key, body, then }) => {
    const start = NativeDate.now();
    try { await call(op, key, body); if (then) await call(then, key); return { op, key, ok: true, start, end: NativeDate.now() }; }
    catch (error) { return { op, key, ok: false, error: String(error?.message ?? error), start, end: NativeDate.now() }; }
  };
  const results = [];
  // A call held for a release from another request leaves this one nothing
  // pending of its own; a timer keeps workerd from judging it hung.
  const alive = setInterval(() => {}, 25);
  const work = serial ? (async () => { for (const op of ops) results.push(await one(op)); })() : Promise.all(ops.map(one)).then(all => { results.push(...all); });
  const aborted = signal ? new Promise(resolve => { if (signal.aborted) resolve(true); else signal.addEventListener('abort', () => resolve(true), { once: true }); }) : new Promise(() => {});
  const cancelled = await Promise.race([work.then(() => false), aborted]).finally(() => clearInterval(alive));
  return Response.json({ cancelled, results, calls: r2Calls(trace), flights: trace.r2_flights ?? 0, in_flight: trace.r2_in_flight ?? 0, in_flight_peak: trace.r2_in_flight_peak ?? 0 }, { status: cancelled ? 503 : 200 });
}
// A gated execution's record (see x-test-r2-gate below), live while it runs.
const gated = gate => ({ result: gate.result, released: gate.released, released_seq: gate.released_seq, in_flight: gate.trace.r2_in_flight ?? 0, in_flight_peak: gate.trace.r2_in_flight_peak ?? 0, unsettled: r2.unsettled(gate.trace), calls: r2Calls(gate.trace), drained: gate.drained });
function instrument(env, trace) {
  const bucket = new Proxy(env.FEED_SNAPSHOTS, { get(target, key) {
    if (key === 'constructor') return target.constructor;
    if (['get', 'put', 'head', 'delete', 'list'].includes(key)) return async (...args) => {
      trace[key]++; if (['get', 'delete'].includes(key) && typeof args[0] === 'string' && args[0].startsWith('scratch/')) trace[`scratch_${key}`]++;
      // This invocation's bucket calls in flight at once, and their peak:
      // every call through this bucket, the multipart calls below included.
      trace.r2_flights = (trace.r2_flights ?? 0) + 1; trace.r2_in_flight = (trace.r2_in_flight ?? 0) + 1; trace.r2_in_flight_peak = Math.max(trace.r2_in_flight_peak ?? 0, trace.r2_in_flight);
      try { if(key==='delete'&&fault==='cleanup_budget'){offset+=26000;fault=undefined;} if(key==='get'&&fault==='slow_get'){fault=undefined;await new Promise(resolve=>setTimeout(resolve,16000));} if(key==='get'&&fault==='hang_get'){fault='hang_get_active';await new Promise(resolve=>releaseHang=resolve);} fail(`before_${key}`); const value = await r2.call(key, args, () => target[key](...args), trace); fail(`after_${key}`); return value; }
      finally { trace.r2_in_flight--; }
    };
    // Scratch is one multipart upload: count every Class A call and its bytes.
    if (key === 'createMultipartUpload') return async (...args) => {
      trace.multipart++; trace.multipart_create++; const upload = await flight(trace, () => target.createMultipartUpload(...args)); let bytes = 0;
      return new Proxy(upload, { get(inner, name) {
        if (name === 'constructor') return inner.constructor;
        if (['uploadPart', 'complete', 'abort'].includes(name)) return async (...parts) => {
          trace.multipart++; trace[name === 'uploadPart' ? 'multipart_part' : `multipart_${name}`]++;
          return flight(trace, async () => {
            // `slow_part:<ms>` stalls the next part upload once: a spool or body write mid-scan.
            if (name === 'uploadPart' && fault?.startsWith('slow_part:')) { const ms = Number(fault.slice(10)); fault = undefined; await new Promise(resolve => setTimeout(resolve, ms)); }
            fail(`scratch_${name}`);
            if (name === 'uploadPart') { bytes += parts[1].byteLength ?? parts[1].length ?? 0; totals.scratch_peak_bytes = Math.max(totals.scratch_peak_bytes, bytes); }
            return inner[name](...parts);
          });
        };
        const value = Reflect.get(inner, name); return typeof value === 'function' ? value.bind(inner) : value;
      } });
    };
    // A resumed upload (only the abort after a failed completion): its calls
    // are in flight like every other; the multipart counters stay as they were.
    if (key === 'resumeMultipartUpload') return (...args) => {
      const upload = target.resumeMultipartUpload(...args);
      return new Proxy(upload, { get(inner, name) {
        if (name === 'constructor') return inner.constructor;
        if (['uploadPart', 'complete', 'abort'].includes(name)) return (...parts) => flight(trace, () => inner[name](...parts));
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
  if (env.TEST_PLACED === 'true' && env.POLL_PLACED) instrumented.POLL_PLACED = placedBinding(env, trace);
  if(fault==='missing_events'){fault=undefined;delete instrumented.NOTIFICATION_EVENTS;}
  hooks.instrument(instrumented);
  return instrumented;
}
// Placed mode (the harness's `placed`; TEST_PLACED is bound only then). Route
// counts: a delivery that took the binding, or one that ran in process and
// why; the caller's hops (what the binding received and answered); the stub
// the caller's binding answers with; the test's aborts of a caller's call.
const placed = { binding: 0, in_process: 0, reasons: {}, dead_letter: 0, callee: { entered: 0, refused: 0 }, hops: [], stub: null, aborts: new Map(), leaks: { caller_request: 0, caller_response: 0, callee_response: 0, sent_response: 0 } };
// Whether a usable key (16 characters or more) appears in a header value or a body: a boolean, never the value.
const leaks = (key, headers, text) => typeof key === 'string' && key.length >= 16 && ([...headers].some(([, value]) => value.includes(key)) || (text ?? '').includes(key));
const countRoute = reason => { if (reason === 'binding') placed.binding++; else { placed.in_process++; placed.reasons[reason] = (placed.reasons[reason] ?? 0) + 1; } };
const rustBoundary = () => globalThis.__opencastRustBoundary ?? { constructed: 0, entries: 0, key_env: 0, key_header: 0, recent: [] };
const anySignal = signals => {
  if (AbortSignal.any) return AbortSignal.any(signals);
  const controller = new AbortController();
  for (const signal of signals) signal.addEventListener('abort', () => controller.abort(signal.reason), { once: true });
  return controller.signal;
};
// The caller's POLL_PLACED, as the shipped queue() sees it: the adapter's own
// request and init are forwarded (its 230 s signal merged with the test's
// abort, /test/hop-abort), and each call is recorded on the invocation's trace
// as a hop: header names, the x-poll-* values, the key only as present, equal
// and length, then the status, the marker header and the body text. A stub
// (/test/placed-stub) answers instead: {mode:'status', status, header},
// 'reject' (the fetch rejects), 'body_reject' (the body read rejects) or
// 'never' (forwarded with the adapter's own init to TEST_PLACED_NEVER, which
// never answers, so the runtime's timer ends it); `times` bounds a stub.
function placedBinding(env, trace) {
  return new Proxy(env.POLL_PLACED, { get(target, key) {
    if (key === 'constructor') return target.constructor;
    if (key !== 'fetch') { const value = Reflect.get(target, key); return typeof value === 'function' ? value.bind(target) : value; }
    return async (input, init) => {
      const request = new Request(input, init), sent = request.headers.get('x-poll-placed-key');
      // The request may carry the key in x-poll-placed-key alone: not in another header, not in its body.
      const requestBody = await request.clone().text();
      if (leaks(env.POLL_PLACED_KEY, [...request.headers].filter(([name]) => name !== 'x-poll-placed-key'), requestBody)) placed.leaks.caller_request++;
      const hop = { at: NativeDate.now(), method: request.method, path: new URL(request.url).pathname, header_names: [...request.headers.keys()],
        message_id: request.headers.get('x-poll-message-id'), attempts: request.headers.get('x-poll-attempts'), enqueued: request.headers.get('x-poll-enqueued-ms'),
        hop: request.headers.get('x-poll-hop'), feed: (() => { try { return JSON.parse(requestBody).feed_id ?? null; } catch { return null; } })(), key: { present: sent !== null, equals_key: sent !== null && sent === env.POLL_PLACED_KEY, length: sent?.length ?? 0 },
        signal: !!init?.signal, stub: null, status: null, engine: null, engine_ms: null, text: null, error: null, settled: null };
      (trace.hops ??= []).push(hop); placed.hops.push(hop); if (placed.hops.length > 200) placed.hops.shift();
      const stub = placed.stub;
      if (stub && stub.times !== undefined && --stub.times <= 0) placed.stub = null;
      hop.stub = stub?.mode ?? null;
      const controller = new AbortController();
      if (trace.hopKey) placed.aborts.set(trace.hopKey, controller);
      try {
        let response;
        if (!stub) response = await target.fetch(request, { signal: init?.signal ? anySignal([init.signal, controller.signal]) : controller.signal });
        else if (stub.mode === 'status') response = new Response('stub', { status: stub.status, headers: stub.header ? { 'x-poll-engine-ms': '0' } : {} });
        else if (stub.mode === 'reject') throw new TypeError('fixture:placed_binding_rejected');
        else if (stub.mode === 'body_reject') response = new Response(new ReadableStream({ pull(source) { source.error(new Error('fixture:placed_body_rejected')); } }), { status: 200, headers: { 'x-poll-engine-ms': '0' } });
        else if (stub.mode === 'never') response = await env.TEST_PLACED_NEVER.fetch(request, { signal: init?.signal });
        else throw Error(`placed stub ${stub.mode}`);
        hop.status = response.status; hop.engine = response.headers.has('x-poll-engine-ms'); hop.engine_ms = response.headers.get('x-poll-engine-ms');
        if (stub?.mode !== 'body_reject') { hop.text = await response.clone().text(); if (leaks(env.POLL_PLACED_KEY, response.headers, hop.text)) { placed.leaks.caller_response++; hop.text = '<withheld: the key>'; } }
        hop.settled = NativeDate.now();
        return response;
      } catch (error) {
        hop.error = `${error?.name ?? 'Error'}: ${error?.message ?? error}`; hop.settled = NativeDate.now();
        throw error;
      } finally { if (trace.hopKey && placed.aborts.get(trace.hopKey) === controller) placed.aborts.delete(trace.hopKey); }
    };
  } });
}
// Every counter and total an instrumented consume adds, as /test/* does.
function account(trace, start) {
  trace.wall_ms = performance.now() - start;
  totals.calls++;
  for (const name of COUNTERS) totals[name] += trace[name];
  totals.max_d1 = Math.max(totals.max_d1, trace.d1);
  totals.max_r2 = Math.max(totals.max_r2, trace.get + trace.put + trace.head + trace.delete + trace.list + trace.multipart);
  totals.max_r2_in_flight = Math.max(totals.max_r2_in_flight, trace.r2_in_flight_peak ?? 0);
  totals.recent.push(trace); if (totals.recent.length > 100) totals.recent.shift();
}
async function noteOutcome(trace, response) {
  try { const { outcome, passes } = await response.clone().json(); trace.outcome = outcome; totals.outcomes[outcome] = (totals.outcomes[outcome] ?? 0) + 1; if (passes > 0) { trace.passes = passes; totals.passes[passes] = (totals.passes[passes] ?? 0) + 1; } } catch {}
}
// The placed-mode routes; undefined lets the entry's own routing go on.
async function placedRoutes(worker, path, request) {
  const { env, ctx } = worker;
  // The Rust boundary compares what Rust receives with this isolate's key.
  globalThis.__opencastPlacedKey = env.POLL_PLACED_KEY;
  placedLines ??= [];
  if (path === '/metrics') { const r = rustBoundary(); return Response.json({ ...totals, placed: { binding: placed.binding, in_process: placed.in_process, reasons: placed.reasons, dead_letter: placed.dead_letter, callee: placed.callee, leaks: placed.leaks, lines: placedLines, hops: placed.hops.slice(-50), rust: { constructed: r.constructed, entries: r.entries, key_env: r.key_env, key_header: r.key_header, recent: r.recent.slice(-100), consumes: r.consumes ?? [] } } }); }
  if (path === '/test/placed-stub') { const body = await request.text(); placed.stub = body ? JSON.parse(body) : null; return Response.json({ stub: placed.stub }); }
  if (path === '/test/hop-abort') { const controller = placed.aborts.get(await request.text()); controller?.abort(new Error('fixture:caller_gave_up')); return Response.json({ aborted: !!controller }); }
  if (path === '/test/placed-route') {
    const { cases } = await request.json();
    if (typeof adapterModule.placedRoute !== 'function') return Response.json({ missing: 'placedRoute is not exported by adapter/index.js' });
    return Response.json({ results: cases.map(({ env: e, body }) => adapterModule.placedRoute(e, body)) });
  }
  if (path === '/test/placed-send') {
    // A request sent through the real self-binding; '<KEY>' stands for this
    // Worker's own key, so the key never leaves the isolate.
    const spec = await request.json();
    const headers = Object.fromEntries(Object.entries(spec.headers ?? {}).map(([name, value]) => [name, value === '<KEY>' ? env.POLL_PLACED_KEY : value]));
    const response = await env.POLL_PLACED.fetch(`https://polling.invalid${spec.path}`, { method: spec.method, headers, ...(spec.method === 'GET' ? {} : { body: spec.body ?? '' }) });
    let text = await response.text();
    if (leaks(env.POLL_PLACED_KEY, response.headers, text)) { placed.leaks.sent_response++; text = '<withheld: the key>'; }
    return Response.json({ status: response.status, engine: response.headers.has('x-poll-engine-ms'), header_names: [...response.headers.keys()], text });
  }
  if (path === '/test/deliver') {
    // One message through the shipped queue(): a one-message batch whose ack
    // and retry are recorded; a throw out of queue() is the decision 'throw'.
    const text = await request.text(); let body; try { body = JSON.parse(text); } catch { body = text; }
    const id = request.headers.get('x-poll-message-id'), enqueued = request.headers.get('x-poll-enqueued-ms'), queue = request.headers.get('x-test-queue') ?? 'isolated-poll';
    const record = { id, queue, decision: null, retry: null, error: null, hops: [], rust: null };
    const message = { id, body, attempts: Number(request.headers.get('x-poll-attempts') ?? 1), timestamp: new Date(enqueued !== null ? Number(enqueued) : Date.now()),
      ack() { record.decision ??= 'ack'; }, retry(options) { record.decision ??= 'retry'; record.retry = options ?? null; } };
    // The caller makes no storage call on the placed route; the callee's
    // window counts the engine. A dead-letter batch runs in process, counted.
    const trace = { path: '/test/deliver', hopKey: request.headers.get('x-test-hop-key'), hops: record.hops, ...Object.fromEntries(COUNTERS.map(name => [name, 0])) };
    const run = () => Worker.prototype.queue.call({ ctx, env: instrument(env, trace) }, { queue, messages: [message] });
    try { await (queue.endsWith('-dlq') ? counted(env, trace, run) : run()); }
    catch (error) { record.decision ??= 'throw'; record.error = `${error?.name ?? 'Error'}: ${error?.message ?? error}`; }
    record.decision ??= 'implicit_ack';
    if (queue.endsWith('-dlq')) placed.dead_letter++; else countRoute(record.hops.length ? 'binding' : 'adapter_route');
    record.rust = rustBoundary().recent.filter(entry => entry.message_id === id).at(-1) ?? null;
    return Response.json(record);
  }
  if (path === '/consume') {
    // The default export's fetch as the binding (or anyone) reaches it, run
    // with the instrumented env inside the storage counter's window, so the
    // engine's faults, hooks and counts mean what they mean on /test/consume.
    const trace = { path: '/consume', route: 'placed', ...Object.fromEntries(COUNTERS.map(name => [name, 0])) }, start = performance.now();
    const invocation = trace.invocation = ++calleeSeq; calleesInFlight.add(invocation);
    const work = counted(env, trace, () => Worker.prototype.fetch.call({ ctx, env: instrument(env, trace) }, request)).finally(() => calleesInFlight.delete(invocation));
    // The body's bytes are read completely inside the chain waitUntil holds (a read in the handler's own
    // continuation never settles in local workerd once the caller has gone), before the response is returned; a
    // decoded copy is checked and the same status, headers and bytes are returned. So every callee body is checked
    // whole; one still being read stays in `stage` and one that failed is counted, and both fail case 2b.
    (placed.callee.stage ??= {})[invocation] = 'engine';
    const buffered = work.then(async answered => { placed.callee.stage[invocation] = 'reading'; const bytes = await answered.arrayBuffer(); delete placed.callee.stage[invocation]; return { answered, bytes }; })
      .catch(error => { delete placed.callee.stage[invocation]; throw error; }); // failed, not pending: counted below
    // EDGE EMULATION (harness only; the shipped adapter calls no waitUntil).
    // Local workerd cancels a callee whose caller aborts or ends; the edge
    // let a placed callee run to its end 16 of 16 times (plan §1.5). Holding
    // the instrumented run here gives the engine the edge's lifetime.
    ctx.waitUntil(buffered.catch(() => {}));
    let response, text;
    try {
      const { answered, bytes } = await buffered;
      text = new TextDecoder().decode(bytes);
      response = new Response(bytes.byteLength === 0 ? null : bytes, { status: answered.status, statusText: answered.statusText, headers: answered.headers });
      return response;
    } finally {
      if (response?.headers.has('x-poll-engine-ms')) { placed.callee.entered++; trace.path = '/test/consume'; }
      else if (response) placed.callee.refused++;
      else placed.callee.failed = (placed.callee.failed ?? 0) + 1;
      if (response) {
        if (leaks(env.POLL_PLACED_KEY, response.headers, text)) placed.leaks.callee_response++;
        if (trace.path === '/test/consume') {
          if (response.ok) { try { const { outcome, passes } = JSON.parse(text); trace.outcome = outcome; totals.outcomes[outcome] = (totals.outcomes[outcome] ?? 0) + 1; if (passes > 0) { trace.passes = passes; totals.passes[passes] = (totals.passes[passes] ?? 0) + 1; } } catch {} }
          account(trace, start);
        }
      }
    }
  }
  if (path === '/test/consume') countRoute(request.headers.get('x-test-placed-reason') ?? 'test_consume');
  return undefined;
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
    if (this.env.TEST_PLACED !== 'true' || batch.queue.endsWith('-dlq')) {
      if (this.env.TEST_PLACED === 'true') { globalThis.__opencastPlacedKey = this.env.POLL_PLACED_KEY; placed.dead_letter += batch.messages.length; }
      return counted(this.env, trace, () => Worker.prototype.queue.call({ ctx: this.ctx, env: instrument(this.env, trace) }, { queue: batch.queue, messages }));
    }
    // Placed mode, a poll batch (one message): no caller window, the callee's
    // window counts the engine; the route is the hop's presence.
    globalThis.__opencastPlacedKey = this.env.POLL_PLACED_KEY;
    try { return await Worker.prototype.queue.call({ ctx: this.ctx, env: instrument(this.env, trace) }, { queue: batch.queue, messages }); }
    finally { for (const _ of batch.messages) countRoute(trace.hops?.length ? 'binding' : 'adapter_route'); }
  }
  async fetch(request) {
    const path = new URL(request.url).pathname;
    if (this.env.TEST_PLACED === 'true') { const handled = await placedRoutes(this, path, request); if (handled) return handled; }
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
    if (path === '/test/r2-hooks') return Response.json(r2.arm(JSON.parse(await request.text() || '{}')));
    if (path === '/test/r2-release') {
      const body = JSON.parse(await request.text() || '{}');
      // A gated execution's held calls are released by its own request's loop.
      if (body.execution !== undefined) { const gate = gates.get(body.execution); if (gate) gate.release = true; return Response.json({ execution: body.execution, requested: !!gate }); }
      return Response.json(r2.release({ stop: !!body.stop }));
    }
    if (path === '/test/r2-state') return Response.json({ ...r2.state(), executions: Object.fromEntries([...gates].map(([key, gate]) => [key, gated(gate)])) });
    if (path === '/abort') { const pending=controllers.get(await request.text());if(pending)pending.requested=true;return new Response('ok'); }
    const hooked = await hooks.route(path, request); if (hooked) return hooked;
    if (!path.startsWith('/test/')) return super.fetch(request);
    const trace = { path, ...Object.fromEntries(COUNTERS.map(name => [name, 0])) };
    const key = request.headers.get('x-test-execution'), controller = key ? new AbortController() : undefined;
    const cancellation={requested:false,finished:false};
    let watching, gating;
    if (controller) {
      controllers.set(key,cancellation);
      // Abort native I/O in the originating request's workerd context.
      watching=(async()=>{while(!cancellation.requested&&!cancellation.finished)await new Promise(resolve=>setTimeout(resolve,10));if(cancellation.requested)controller.abort();})();
    }
    // x-test-r2-gate (with x-test-execution): the R2 hooks' held calls of this
    // invocation are released by this request's own loop, in its own workerd
    // context, when /test/r2-release {"execution": <key>} asks; and after its
    // operation returns (or is cancelled) this request stays open until each of
    // them is released and settled and its in-flight count has stayed 0 for
    // 500 ms. A continuation of a released call therefore runs here, where its
    // calls are made and counted, not cancelled with a completed request. The
    // operation's result and the gate's record are in /test/r2-state's
    // `executions`.
    const gate = controller && request.headers.get('x-test-r2-gate') === '1' ? { trace, result: null, release: false, released: 0, released_seq: null, at_release: null, drained: null } : undefined;
    if (gate) {
      gates.set(key, gate);
      gating = (async () => {
        while (!cancellation.finished) {
          if (gate.release) { gate.release = false; gate.at_release ??= r2Calls(trace); const { released, seq } = r2.release({ owner: trace }); gate.released += released; gate.released_seq ??= seq; }
          await new Promise(resolve => setTimeout(resolve, 10));
        }
      })();
    }
    const probing = path === '/test/r2-probe' ? JSON.parse(await request.text() || '{}') : null;
    const start = performance.now();
    try {
      let operation;
      if (probing) operation = () => probe(instrument(this.env, trace).FEED_SNAPSHOTS, probing, controller?.signal, trace);
      else {
        const input = new Request(request.url.replace('/test', ''), request);
        operation = () => new PollingControl(this.ctx, instrument(this.env, trace)).fetch(controller ? new Request(input, { signal: controller.signal }) : input);
      }
      const response = await counted(this.env, trace, operation);
      if (gate) gate.result = { status: response.status, text: await response.clone().text() };
      // Healthy polls are only sampled in logs; the consume result is exact.
      // `passes` is how many times a scan parsed its one response body; steps
      // that parsed nothing (304s, continuations) are not counted.
      if (path === '/test/consume' && response.ok) { try { const { outcome, passes } = await response.clone().json(); trace.outcome = outcome; totals.outcomes[outcome] = (totals.outcomes[outcome] ?? 0) + 1; if (passes > 0) { trace.passes = passes; totals.passes[passes] = (totals.passes[passes] ?? 0) + 1; } } catch {} }
      return response;
    } catch (error) {
      if (gate) gate.result = { error: String(error?.message ?? error) };
      throw error;
    } finally {
      if (gate) {
        for (let quiet = 0; quiet < 500;) {
          await new Promise(resolve => setTimeout(resolve, 25));
          quiet = r2.unsettled(trace) === 0 && !(trace.r2_in_flight > 0) ? quiet + 25 : 0;
        }
        const calls = r2Calls(trace);
        gate.drained = { in_flight: trace.r2_in_flight ?? 0, unsettled: r2.unsettled(trace), calls_after_release: gate.at_release && Object.fromEntries(Object.entries(calls).map(([name, n]) => [name, n - gate.at_release[name]])) };
      }
      cancellation.finished=true;controllers.delete(key);if(watching)await watching;if(gating)await gating;
      trace.wall_ms = performance.now() - start;
      totals.calls++;
      for (const name of COUNTERS) totals[name] += trace[name];
      totals.max_d1 = Math.max(totals.max_d1, trace.d1);
      totals.max_r2 = Math.max(totals.max_r2, trace.get + trace.put + trace.head + trace.delete + trace.list + trace.multipart);
      totals.max_r2_in_flight = Math.max(totals.max_r2_in_flight, trace.r2_in_flight_peak ?? 0);
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
//  /test/refuse-events {"from":<k>,"count":<n>}  FeedEvents posts k to k+n-1,
//      counted from the arming, reject without reaching the binding (as the
//      platform's invocation limit would refuse them); each is a witness
//      `refuse_events` record. An empty body disarms.
function fixtureHooks({ totals, now, fault, setFault, hang }) {
  const witness = totals.hooks = { batches: [], retries: [], r2: [], service: [], outbound: [] };
  let retryDelay = 1, refuse = null;
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
          if (refuse) {
            const k = ++refuse.seen;
            if (k >= refuse.from && k < refuse.from + refuse.count) { witness.service.push({ hook: 'refuse_events', k, at: now() }); throw new Error('fixture:feed_events_refused'); }
          }
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
      if (path === '/test/refuse-events') {
        const text = await request.text(); const body = text ? JSON.parse(text) : null;
        refuse = body ? { from: body.from, count: body.count, seen: 0 } : null;
        return Response.json({ refuse });
      }
      if (path !== '/test/retry-delay') return undefined;
      const text = (await request.text()).trim(), seconds = Number(text);
      if (text !== '' && !(Number.isSafeInteger(seconds) && seconds >= 0 && seconds <= 43200)) return new Response('retry-delay takes whole seconds, 0-43200', { status: 400 });
      retryDelay = text === '' ? 1 : seconds;
      return Response.json({ retry_delay_s: retryDelay });
    },
  };
}
// The R2 hooks (/test/r2-hooks), for the concurrent page uploads of a scan
// (staging-concurrency.mjs). Each bucket operation is configured on its own;
// a hook acts on the calls its key selection admits, counted from the arming,
// so the k-th selected put is the k-th page a scan uploads. The JSON body
//   {"log":true,"put":{"delay_ms":50},"head":{"fail":[2]}}
// arms, per operation (get, put, head, delete, list):
//   delay_ms   every selected call waits this long before it is made;
//   delays_ms  the k-th selected call waits delays_ms[(k - 1) % length];
//   hold       these selected calls (a number <n>: the first n; an array: these
//              ordinals) are made, then their replies are held until
//              /test/r2-release ({"stop":true} also ends both holds);
//   hold_request  these selected calls wait for /test/r2-release before they
//              are made (their objects arrive late); it wins over `hold`;
//   fail       the selected calls of these ordinals throw instead of being made;
//   prefix / skip_prefix  the key selection (default: every call);
// and `log` keeps every bucket call in order, with its key, its start and end
// sequence numbers and whether it returned. An empty body disarms (a call
// already held stays held until a release). Each held call is a `fired`
// record (stage request or reply) stamped when released and when it settled
// (its finally ran), and belongs to its invocation: /test/r2-release
// {"execution": <key>} releases one gated execution's held calls only (see
// x-test-r2-gate). The witness is the metrics' `r2hooks` (/test/r2-state: the
// same without its log, with the gated executions); the in-flight peak of each
// invocation is its trace's `r2_in_flight_peak`, over every bucket call it
// made: get, put, head, delete, list and each multipart call (create, part,
// complete, abort, a resumed upload's included). The hooks act on get, put,
// head, delete and list only. /test/r2-probe qualifies all of it.
function r2Hooks({ totals, now }) {
  const fresh = () => ({ armed: null, seq: 0, ordinals: {}, held: 0, released: 0, fired: [], log: [] });
  let witness = totals.r2hooks = fresh(), config = null;
  // Every held call not yet settled: its record, its invocation's trace and,
  // until it is released, its release.
  let holds = [];
  const waiting = () => holds.filter(h => h.release).length;
  const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
  const selected = (spec, key) => (!spec.prefix || key?.startsWith(spec.prefix)) && !(spec.skip_prefix && key?.startsWith(spec.skip_prefix));
  const holding = (value, k) => Array.isArray(value) ? value.includes(k) : k <= (value ?? 0);
  const hold = (op, k, key, stage, owner) => {
    const record = { hook: 'hold', op, k, key, stage, at: now(), released: null, settled: null }; witness.fired.push(record);
    const held = { record, owner };
    const wait = new Promise(resolve => { held.release = () => { record.released = now(); resolve(); }; });
    holds.push(held); witness.held = waiting();
    return { record, wait };
  };
  return {
    arm(body) {
      config = Object.keys(body).length ? body : null;
      witness = totals.r2hooks = { ...fresh(), armed: config, held: waiting() };
      return { armed: config };
    },
    release({ stop = false, owner } = {}) {
      const due = holds.filter(h => h.release && (!owner || h.owner === owner));
      for (const h of due) { const release = h.release; h.release = null; release(); }
      witness.held = waiting(); witness.released += due.length;
      if (stop && config) for (const spec of Object.values(config)) if (spec && typeof spec === 'object') { spec.hold = 0; spec.hold_request = 0; }
      return { released: due.length, seq: witness.seq };
    },
    // An invocation's held calls not yet settled, released or not.
    unsettled(owner) { return holds.filter(h => h.owner === owner).length; },
    state() { const { log, ...rest } = witness; return { ...rest, logged: log.length }; },
    async call(op, args, make, owner) {
      const spec = config?.[op], key = typeof args[0] === 'string' ? args[0] : null;
      const entry = config?.log && witness.log.length < 50000 ? { op, key, start: ++witness.seq, end: null, ok: false } : null;
      if (entry) witness.log.push(entry);
      let held = null;
      try {
        let k = 0;
        if (spec && selected(spec, key)) {
          k = witness.ordinals[op] = (witness.ordinals[op] ?? 0) + 1;
          if (spec.fail?.includes(k)) { witness.fired.push({ hook: 'fail', op, k, key, at: now() }); throw Error(`fixture:r2_${op}_${k}`); }
          const ms = spec.delays_ms ? spec.delays_ms[(k - 1) % spec.delays_ms.length] : spec.delay_ms ?? 0;
          if (ms > 0) await pause(ms);
          if (holding(spec.hold_request, k)) { held = hold(op, k, key, 'request', owner); await held.wait; }
        }
        const value = await make();
        if (k && !held && holding(spec.hold, k)) { held = hold(op, k, key, 'reply', owner); await held.wait; }
        if (entry) entry.ok = true;
        return value;
      } finally {
        if (entry) entry.end = ++witness.seq;
        if (held) { held.record.settled = now(); holds = holds.filter(h => h.record !== held.record); }
      }
    },
  };
}
