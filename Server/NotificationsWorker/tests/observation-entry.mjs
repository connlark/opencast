// Isolated runtime instrumentation. This module is never shipped.
import RustWorker from '../build/index.js';
import Worker, {FeedObservations, FeedEvents, FeedControl} from '../adapter/index.js';
export {FeedEvents};
const NativeDate=Date;let offset=0;
globalThis.Date=class extends NativeDate {constructor(...args){super(...(args.length?args:[NativeDate.now()+offset]));}static now(){return NativeDate.now()+offset;}};
const traces=[];let fault,logEvents=0;
for(const method of ['log','warn','error']){const native=console[method].bind(console);console[method]=(...args)=>{logEvents++;native(...args);};}
function fail(point){if(fault===point){fault=undefined;throw Error(`fixture failure: ${point}`);}}
function instrument(env,trace){
  const originals=new WeakMap(),queries=new WeakMap();
  const measured=value=>{for(const r of Array.isArray(value)?value:[value]){trace.rows_read=(trace.rows_read??0)+(r?.meta?.rows_read??0);trace.rows_written=(trace.rows_written??0)+(r?.meta?.rows_written??0);}return value;};
  const prepared=(statement,sql)=>{const proxy=new Proxy(statement,{get(target,key){
    if(key==='constructor')return target.constructor;
    if(key==='bind')return (...args)=>prepared(target.bind(...args),sql);
    if(['run','first','all','raw'].includes(key))return async (...args)=>{trace.d1++;if(trace.d1>1000)throw Error('query limit');if(sql.includes('UPDATE n_observation SET preparation_key=')){fail('before_checkpoint');const result=measured(await target[key](...args));fail('after_checkpoint');return result;}if(key==='first'){const result=measured(await target.all());const row=result.results[0]??null;return args[0]&&row?row[args[0]]:row;}return measured(await target[key](...args));};
    const value=Reflect.get(target,key);return typeof value==='function'?value.bind(target):value;
  }});originals.set(proxy,statement);queries.set(proxy,sql);return proxy;};
  const db=new Proxy(env.APP_ATTEST_DB,{get(target,key){
    if(key==='constructor')return target.constructor;
    if(key==='prepare')return sql=>prepared(target.prepare(sql),sql);
    if(key==='batch')return async statements=>{
      trace.d1+=statements.length;if(trace.d1>1000)throw Error('query limit');
      const sql=statements.map(s=>queries.get(s)??'').join(' ');
      if(sql.includes('UPDATE n_feed SET observation_generation=')){
        fail('before_publish');
        if(fault==='publish_rollback'){fault=undefined;return target.batch([...statements.map(s=>originals.get(s)??s),target.prepare('INSERT INTO missing_fixture VALUES(1)')]);}
        if(fault==='stale_eligibility'){fault=undefined;await target.prepare('UPDATE n_feed SET eligibility_generation=eligibility_generation+1').run();}
        if(fault==='stale_owner'){fault=undefined;await target.prepare('UPDATE n_feed SET epoch=epoch+1').run();}
        if(fault==='lost_lease'){fault=undefined;await target.prepare("UPDATE n_feed SET lease_id='replacement' WHERE lease_id IS NOT NULL").run();}
      }
      if(sql.includes('INSERT INTO n_snapshot_ref'))fail('manifest_reserve');
      return measured(await target.batch(statements.map(s=>originals.get(s)??s)));
    };
    const value=Reflect.get(target,key);return typeof value==='function'?value.bind(target):value;
  }});
  const bucket=new Proxy(env.FEED_SNAPSHOTS,{get(target,key){
    if(key==='constructor')return target.constructor;
    if(['get','put','head','delete'].includes(key))return async (...args)=>{trace[key]++;fail(`before_${key}`);const result=await target[key](...args);fail(`after_${key}`);return result;};
    const value=Reflect.get(target,key);return typeof value==='function'?value.bind(target):value;
  }});
  const result={...env,APP_ATTEST_DB:db,FEED_SNAPSHOTS:bucket};
  for(const binding of ['EVENT_QUEUE','EPISODE_DELIVERY_QUEUE','JOB_DELIVERY_QUEUE'])if(env[binding])result[binding]=new Proxy(env[binding],{get(target,key){if(key==='constructor')return target.constructor;const value=Reflect.get(target,key);if(key==='send')return (...args)=>{trace.queue_messages=(trace.queue_messages??0)+1;return value.apply(target,args);};return typeof value==='function'?value.bind(target):value;}});
  return result;
}
export default class extends Worker {
  async fetch(request){
    const path=new URL(request.url).pathname;
    if(path==='/fault'){fault=await request.text();return new Response('ok');}
    if(path==='/clock'){offset=Number(await request.text())*1000;return new Response('ok');}
    if(path==='/traces')return Response.json(traces);
    if(path==='/logcount')return Response.json({log_events:logEvents});
    const trace={path,d1:0,get:0,put:0,head:0,delete:0};traces.push(trace);
    const env=instrument(this.env,trace);
    if(path==='/scheduled'){await new Worker(this.ctx,env).scheduled({scheduledTime:Date.now(),cron:'*/5 * * * *'});return new Response('ok');}
    if(path.startsWith('/control/'))return new FeedControl(this.ctx,env).fetch(new Request(request.url.replace('/control',''),request));
    if(path==='/queue')return new RustWorker(this.ctx,{...env,NOTIFICATION_CAPABILITY:'queue'}).fetch(request);
    if(path.startsWith('/observation/'))return new FeedObservations(this.ctx,env).fetch(new Request(request.url.replace('/observation',''),request));
    if(path==='/v1/events')return new FeedEvents(this.ctx,env).fetch(request);
    return new Worker(this.ctx,env).fetch(request);
  }
}
