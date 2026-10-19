// Isolated runtime instrumentation. This module is never shipped.
import RustWorker from '../build/index.js';
import Worker, {FeedObservations, FeedEvents, FeedControl} from '../adapter/index.js';
export {FeedEvents};
const NativeDate=Date;let offset=0;
globalThis.Date=class extends NativeDate {constructor(...args){super(...(args.length?args:[NativeDate.now()+offset]));}static now(){return NativeDate.now()+offset;}};
const traces=[];let fault,logEvents=0;
for(const method of ['log','warn','error']){const native=console[method].bind(console);console[method]=(...args)=>{logEvents++;native(...args);};}
function fail(point){if(fault===point){fault=undefined;throw Error(`fixture failure: ${point}`);}}
// The storage hooks act on the wire (tests/postgres/proxy.mjs), armed through
// TEST_STORAGE, storage.mjs's Node function for this Worker's proxy alias;
// `fault` stays local otherwise.
async function storage(env,op){const response=await env.TEST_STORAGE.fetch('https://test-storage.invalid/',{method:'POST',body:JSON.stringify(op)});const body=await response.json();if(!response.ok)throw Error(`TEST_STORAGE ${op.op}: ${body.error}`);return body;}
// The alias's counters around one invocation: application statements, rows
// written by INSERT/UPDATE/DELETE tags, watchdog reads (absent when none), and
// whether another measured invocation overlapped any part of the window.
// Without TEST_STORAGE (a direct binding) it returns run()'s own promise and
// counts nothing.
function counted(env,trace,run){
  if(!env.TEST_STORAGE)return run();
  return (async()=>{
    const begin=await storage(env,{op:'counters',begin:true});
    try{return await run();}finally{
      const end=await storage(env,{op:'counters',end:begin.invocation});
      trace.d1+=end.statements-begin.statements;trace.rows_written=(trace.rows_written??0)+end.rows_written-begin.rows_written;
      if(end.watchdog_reads>begin.watchdog_reads)trace.watchdog_reads=(trace.watchdog_reads??0)+end.watchdog_reads-begin.watchdog_reads;
      trace.storage_exclusive=end.exclusive;
    }
  })();
}
function instrument(env,trace){
  const bucket=new Proxy(env.FEED_SNAPSHOTS,{get(target,key){
    if(key==='constructor')return target.constructor;
    if(['get','put','head','delete'].includes(key))return async (...args)=>{trace[key]++;fail(`before_${key}`);const result=await target[key](...args);fail(`after_${key}`);return result;};
    const value=Reflect.get(target,key);return typeof value==='function'?value.bind(target):value;
  }});
  const result={...env,FEED_SNAPSHOTS:bucket};
  for(const binding of ['EVENT_QUEUE','EPISODE_DELIVERY_QUEUE','JOB_DELIVERY_QUEUE'])if(env[binding])result[binding]=new Proxy(env[binding],{get(target,key){if(key==='constructor')return target.constructor;const value=Reflect.get(target,key);if(key==='send')return (...args)=>{trace.queue_messages=(trace.queue_messages??0)+1;return value.apply(target,args);};return typeof value==='function'?value.bind(target):value;}});
  return result;
}
export default class extends Worker {
  async fetch(request){
    const path=new URL(request.url).pathname;
    if(path==='/fault'){fault=await request.text();if(this.env.TEST_STORAGE)await storage(this.env,{op:'arm',kind:'fault',name:fault});return new Response('ok');}
    if(path==='/clock'){offset=Number(await request.text())*1000;return new Response('ok');}
    if(path==='/traces')return Response.json(traces);
    if(path==='/logcount')return Response.json({log_events:logEvents});
    const trace={path,d1:0,get:0,put:0,head:0,delete:0};traces.push(trace);
    return counted(this.env,trace,()=>route(this.ctx,instrument(this.env,trace),request,path));
  }
}
// A module function, not a method: a WorkerEntrypoint method would be RPC surface.
function route(ctx,env,request,path){
  if(path==='/scheduled')return (async()=>{await new Worker(ctx,env).scheduled({scheduledTime:Number(request.headers.get('x-test-scheduled-time')??Date.now()),cron:'* * * * *'});return new Response('ok');})();
  if(path.startsWith('/control/'))return new FeedControl(ctx,env).fetch(new Request(request.url.replace('/control',''),request));
  if(path==='/queue')return new RustWorker(ctx,{...env,NOTIFICATION_CAPABILITY:'queue'}).fetch(request);
  if(path.startsWith('/observation/'))return new FeedObservations(ctx,env).fetch(new Request(request.url.replace('/observation',''),request));
  if(path==='/v1/events')return new FeedEvents(ctx,env).fetch(request);
  return new Worker(ctx,env).fetch(request);
}
