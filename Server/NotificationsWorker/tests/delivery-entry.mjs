// Test-only clock and queue driver around the shipped adapter and Rust binary.
import Worker from '../adapter/index.js';
import RustWorker from '../build/index.js';
export { FeedEvents, AdAnalysisEvents, RemoteTranscriptionEvents } from '../adapter/index.js';
const NativeDate = Date;
let timestamp = 1800000000000;
let fault;
let holdPath, heldWrite, releaseWrite;
const enqueued=[];
const trace=[];
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
    if(path==='/test/hold-auth-write'){holdPath=await request.text();heldWrite=false;return new Response('ok');}
    if(path==='/test/auth-write-held')return Response.json(Boolean(heldWrite));
    if(path==='/test/release-auth-write'){releaseWrite?.();return new Response('ok');}
    if(path===holdPath){
      const database=this.env.APP_ATTEST_DB;
      const APP_ATTEST_DB=new Proxy(database,{get(target,key){
        if(key==='constructor')return target.constructor;
        if(key==='batch')return async statements=>{
          if(holdPath===path){
            holdPath=undefined;heldWrite=true;
            // A live timeout keeps workerd from treating this test barrier as
            // an unresolved request; also fail rather than hang on a lost release.
            await new Promise((resolve,reject)=>{
              const timeout=setTimeout(()=>reject(Error('auth write barrier timed out')),20_000);
              releaseWrite=()=>{clearTimeout(timeout);resolve();};
            });
          }
          return target.batch(statements);
        };
        const value=Reflect.get(target,key);return typeof value==='function'?value.bind(target):value;
      }});
      return new Worker(this.ctx,{...this.env,APP_ATTEST_DB}).fetch(request);
    }
    if(path==='/test/fault'){fault=await request.text();return new Response('ok');}
    if(path==='/test/queue-trace')return Response.json(trace);
    if(path==='/test/enqueued')return Response.json(enqueued);
    if (path === '/test/clock') { timestamp = Number(await request.text()) * 1000; return new Response('ok'); }
    if (path === '/test/queue') {
      const original=this.env.APNS_CERT;
      const APNS_CERT=new Proxy(original,{get(target,key){
        if(key==='constructor')return target.constructor;
        if(key==='fetch')return async (...args)=>{const response=await target.fetch(...args);if(response.headers.get('x-fixture-lost'))throw Error('synthetic lost response');return response;};
        const value=Reflect.get(target,key);return typeof value==='function'?value.bind(target):value;
      }});
      const originalDB=this.env.APP_ATTEST_DB;
      const APP_ATTEST_DB=new Proxy(originalDB,{get(target,key){
        if(key==='constructor')return target.constructor;
        if(key==='prepare')return query=>{
          const wrap=statement=>new Proxy(statement,{get(prepared,method){
            if(method==='constructor')return prepared.constructor;
            if(method==='bind')return (...values)=>wrap(prepared.bind(...values));
            if(method==='first')return async (...args)=>{
              if(fault==='final_send_off' && query.includes('attempt_token_generation=(SELECT token_generation') && query.startsWith('SELECT')) {
                fault=undefined;await target.prepare("UPDATE n_control SET enabled=0 WHERE name='episode_send'").run();
              }
              return prepared.first(...args);
            };
            const value=Reflect.get(prepared,method);return typeof value==='function'?value.bind(prepared):value;
          }});return wrap(target.prepare(query));
        };
        if(key==='batch')return async statements=>{
          if(fault==='reclaim_fanout'){fault=undefined;await target.prepare("UPDATE n_event SET lease_id='reclaimed' WHERE fanout_complete=0").run();}
          if(fault==='fail_batch'){fault=undefined;return target.batch([...statements,target.prepare('INSERT INTO missing_fixture_table VALUES(1)')]);}
          return target.batch(statements);
        };
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
      return new RustWorker(this.ctx, { ...this.env, ...queueBindings, APP_ATTEST_DB, APNS_CERT, NOTIFICATION_CAPABILITY:'queue' }).fetch(request);
    }
    if (path === '/test/reconcile') { await this.scheduled({ cron:'* * * * *', scheduledTime:timestamp }); return new Response('ok'); }
    return super.fetch(request);
  }
}
