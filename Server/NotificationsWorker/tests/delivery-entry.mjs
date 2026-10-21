// Test-only clock and queue driver around the shipped adapter and Rust binary.
import Worker from '../adapter/index.js';
import RustWorker from '../build/index.js';
export { FeedEvents, AdAnalysisEvents, RemoteTranscriptionEvents } from '../adapter/index.js';
const NativeDate = Date;
let timestamp = 1800000000000;
let fault;
const enqueued=[];
const trace=[];
// The binary's per-send APNs witness lines, with the console level each used,
// and the cron's maintenance lines: its summary and its two failure warnings.
const witnesses=[],maintenance=[];
for(const level of ['log','warn','error']){const native=console[level].bind(console);console[level]=(...args)=>{
  try{const line=JSON.parse(args[0]);if(line?.event==='notification_apns_send')witnesses.push({level,...line});if(line?.event==='notification_reconciliation')maintenance.push({level,line:line.event});}catch{}
  if(typeof args[0]==='string'&&/^notification (retire|reconciliation) failed/.test(args[0]))maintenance.push({level,line:args[0]});
  native(...args);
};}
// The storage hooks act on the wire (tests/postgres/proxy.mjs), armed through
// TEST_STORAGE, storage.mjs's Node function for this Worker's proxy alias;
// `fault` stays local otherwise.
async function storage(env, op) {
  const response = await env.TEST_STORAGE.fetch('https://test-storage.invalid/', { method: 'POST', body: JSON.stringify(op) });
  const body = await response.json(); if (!response.ok) throw Error(`TEST_STORAGE ${op.op}: ${body.error}`); return body;
}
globalThis.Date = class extends NativeDate {
  constructor(...args) { super(...(args.length ? args : [timestamp])); }
  static now() { return timestamp; }
};
export default class extends Worker {
  async scheduled(event) {
    const queueBindings={};
    for (const name of ['EVENT_QUEUE','EPISODE_DELIVERY_QUEUE','JOB_DELIVERY_QUEUE']) {
      const original=this.env[name];
      queueBindings[name]=new Proxy(original,{get(target,key){
        if(key==='constructor')return target.constructor;
        if(key==='send')return async (...args)=>{enqueued.push({binding:name,message:args[0]});return target.send(...args);};
        const value=Reflect.get(target,key);return typeof value==='function'?value.bind(target):value;
      }});
    }
    return new Worker(this.ctx,{...this.env,...queueBindings}).scheduled(event);
  }
  async queue(batch) { trace.push({queue:batch.queue, timestamp, count:batch.messages.length, first:batch.messages[0]?.body}); try { await super.queue(batch); } catch(error) {trace.push(String(error));throw error;} }
  async fetch(request) {
    const path = new URL(request.url).pathname;
    if(path==='/test/hold-auth-write'){const holdPath=await request.text();if(this.env.TEST_STORAGE)await storage(this.env,{op:'arm',kind:'hold-auth-write',path:holdPath});return new Response('ok');}
    if(path==='/test/auth-write-held'){
      // A fired, unreleased storage hold answers; otherwise nothing is held.
      if(this.env.TEST_STORAGE){const held=await storage(this.env,{op:'state',which:'auth-write-held'});if(held.value!==null)return Response.json(Boolean(held.value));}
      return Response.json(false);
    }
    if(path==='/test/release-auth-write'){if(this.env.TEST_STORAGE)await storage(this.env,{op:'release',kind:'release-auth-write'});return new Response('ok');}
    if(path==='/test/fault'){fault=await request.text();if(this.env.TEST_STORAGE)await storage(this.env,{op:'arm',kind:'fault',name:fault});return new Response('ok');}
    if(path==='/test/queue-trace')return Response.json(trace);
    if(path==='/test/enqueued')return Response.json(enqueued);
    if(path==='/test/apns-witnesses')return Response.json(witnesses);
    if(path==='/test/maintenance')return Response.json(maintenance);
    if (path === '/test/clock') { timestamp = Number(await request.text()) * 1000; return new Response('ok'); }
    if (path === '/test/queue') {
      const original=this.env.APNS_CERT;
      const APNS_CERT=new Proxy(original,{get(target,key){
        if(key==='constructor')return target.constructor;
        if(key==='fetch')return async (...args)=>{const response=await target.fetch(...args);if(response.headers.get('x-fixture-lost'))throw Error('synthetic lost response');return response;};
        const value=Reflect.get(target,key);return typeof value==='function'?value.bind(target):value;
      }});
      const queueBindings={};
      for(const name of ['EVENT_QUEUE','EPISODE_DELIVERY_QUEUE','JOB_DELIVERY_QUEUE']){
        const original=this.env[name];queueBindings[name]=new Proxy(original,{get(target,key){
          if(key==='constructor')return target.constructor;
          if(key==='send')return async (...args)=>{if(fault==='lost_enqueue'){fault=undefined;throw Error('fixture enqueue interruption');}enqueued.push({binding:name,message:args[0]});return target.send(...args);};
          const value=Reflect.get(target,key);return typeof value==='function'?value.bind(target):value;
        }});
      }
      return new RustWorker(this.ctx, { ...this.env, ...queueBindings, APNS_CERT, NOTIFICATION_CAPABILITY:'queue' }).fetch(request);
    }
    if (path === '/test/reconcile') { await this.scheduled({ cron:'* * * * *', scheduledTime:timestamp }); return new Response('ok'); }
    return super.fetch(request);
  }
}
