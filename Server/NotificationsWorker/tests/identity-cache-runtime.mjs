// The identity gate's per-isolate verdict cache on PostgreSQL. Four packaged
// Notifications Workers (FeedControl) share one PostgreSQL clone through the
// wire proxy, each its own isolate and alias; the alias's statement counter
// counts every application statement submitted, the identity read included,
// so a cached verdict is +0.
//  (1) a valid pin: /identity accepted and +1 (the identity read), again
//      accepted and +0;
//  (2) an ordinary storage error: a trigger installed by a raw owner client
//      refuses the write, so /pause answers 500 with the sanitized
//      storage_change_feed_Database_NotCommitted, submitted (>= +1), the row
//      unchanged and no storage_identity line; /identity stays accepted, +0.
//      A second, fresh isolate then reads the changed schema: refused/schema,
//      +1. The trigger and its function are dropped by the same client, which
//      is closed before dispose;
//  (3) a pin naming another database: refused/database, +1; /inspect and
//      /pause then answer the Identity refusals and submit nothing, the row
//      unchanged; /identity stays refused, +0;
//  (4) a malformed pin: refused/pin, +0 on every call.
// Run: node Server/NotificationsWorker/tests/identity-cache-runtime.mjs (the
// packaged build/ from a dry run and the local topology up).
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {fileURLToPath} from 'node:url';
import {Miniflare,convertV4MiniflareOptions} from 'miniflare';
import {Client} from './postgres/pg.mjs';
import {openStorage} from './storage.mjs';
import {compatibilityDate,compatibilityFlags} from './runtime-compatibility.mjs';

const root=fileURLToPath(new URL('../',import.meta.url));
// The local topology's fixed fixture passwords (local-postgres.sh), never secrets.
const OWNER='opencast_local_owner',OWNER_PASSWORD='opencast-local-owner',APPLICATION='identity-cache-owner';
const HOST=process.env.OPENCAST_PG_HOST??'127.0.0.1';
const entry=`import {WorkerEntrypoint} from 'cloudflare:workers';import RustWorker from './index.js';
let lines=[];
for(const level of ['log','warn','error']){const native=console[level].bind(console);console[level]=(...args)=>{lines.push(args.map(String).join(' '));native(...args);};}
export default class extends WorkerEntrypoint { async fetch(request) {
 const {path,value}=await request.json();lines=[];
 const r=await new RustWorker(this.ctx,{...this.env,NOTIFICATION_CAPABILITY:'feed_control'}).fetch(new Request('https://local.invalid'+path,{method:'POST',body:JSON.stringify(value)}));
 return Response.json({status:r.status,body:await r.text(),log:lines.join('\\n')});
} }`;
const storage=await openStorage(),db=storage.databaseName;
const PINS={accepted:`v1;development;postgres;pg:${db}`,fresh:`v1;development;postgres;pg:${db}`,other:'v1;development;postgres;pg:not_this_database',malformed:'v1;development;postgres;pg:Not-A-Database'};
const worker=name=>storage.bind({name:`identity-${name}`,modulesRoot:root+'build',
 modules:[{type:'ESModule',path:root+'build/identity-cache-entry.mjs',contents:entry},{type:'ESModule',path:root+'build/index.js'},{type:'CompiledWasm',path:root+'build/index_bg.wasm'}],
 compatibilityDate,compatibilityFlags,bindings:{NOTIFICATION_ENVIRONMENT:'development',STORAGE_IDENTITY:PINS[name]},
 outboundService:()=>{throw Error('external networking forbidden');}},{hooks:null});
const mf=new Miniflare(convertV4MiniflareOptions({cf:false,inspectorPort:0,workers:Object.keys(PINS).map(worker)}));
let owner,passed=0;
const check=async(name,fn)=>{await fn();passed++;console.log(`PASS ${name}`);};
const record={};
try{
 await mf.ready;
 const feed=createHash('sha256').update('identity-cache').digest('hex'),command={feed_id:feed,expected_epoch:1};
 const handle=await storage.database(mf);
 await handle.prepare('INSERT INTO n_feed(feed_id,canonical_url,epoch,due_at) VALUES(?,?,1,?)').bind(feed,'https://fixture.example/identity-cache.xml',0).run();
 owner=await Client.connect({host:HOST,port:storage.port,user:OWNER,password:OWNER_PASSWORD,database:db,application:APPLICATION,searchPath:'opencast, pg_catalog'});
 const paused=async()=>(await owner.query('SELECT admission_paused FROM opencast.n_feed WHERE feed_id=$1',[feed])).rows[0].admission_paused;
 // One call and the application statements its alias submitted meanwhile.
 const call=async(name,path,value=command)=>{
  const counter=storage.testStorage(`identity-${name}`),before=counter({op:'counters'}).statements;
  const r=await (await mf.getWorker(`identity-${name}`)).fetch('https://fixture.invalid/',{method:'POST',body:JSON.stringify({path,value})}).then(x=>x.json());
  const delta=counter({op:'counters'}).statements-before,report=path==='/identity'&&r.status===200?JSON.parse(r.body):null;
  return {...r,report,delta};
 };
 const verdict=r=>[r.status,r.report?.verdict,r.report?.reason];
 await check('(1) a warm acceptance is reused: the second /identity submits nothing',async()=>{
  const first=await call('accepted','/identity'),again=await call('accepted','/identity');
  record.accepted={first:first.delta,again:again.delta};
  assert.deepEqual(verdict(first),[200,'accepted',null]);assert.equal(first.delta,1,'one identity read');
  assert.deepEqual([first.report.backend,first.report.database,first.report.schema===first.report.expected_schema,first.report.fence],['postgres',`pg:${db}`,true,null]);
  assert.deepEqual(verdict(again),[200,'accepted',null]);assert.equal(again.delta,0,'the cached verdict');
 });
 await check('(2) an ordinary storage error keeps the warm acceptance; a fresh isolate refuses the changed schema',async()=>{
  await owner.simple("CREATE FUNCTION opencast.fixture_refuse() RETURNS trigger LANGUAGE plpgsql AS $f$BEGIN RAISE EXCEPTION 'fixture_refused'; END$f$");
  await owner.simple('CREATE TRIGGER fixture_refusal BEFORE UPDATE ON opencast.n_feed FOR EACH ROW EXECUTE FUNCTION opencast.fixture_refuse()');
  const pause=await call('accepted','/pause');
  record.failure={status:pause.status,submitted:pause.delta,code:pause.log.match(/storage_change_feed_\w+/)?.[0]??null};
  assert.equal(pause.status,500,pause.body);
  assert.match(pause.log,/storage_change_feed_Database_NotCommitted/);
  assert.doesNotMatch(pause.log,/fixture_refused/,'the server message never reaches the log');
  assert.doesNotMatch(pause.log,/storage_identity/,'no identity line: the verdict is cached');
  assert.ok(pause.delta>=1,`the write was submitted: +${pause.delta}`);
  assert.equal(await paused(),0,'the refused write changed nothing');
  const after=await call('accepted','/identity');
  record.afterFailure=after.delta;
  assert.deepEqual(verdict(after),[200,'accepted',null]);assert.equal(after.delta,0,'the acceptance survived with zero identity reads');
  const fresh=await call('fresh','/identity');
  record.freshSchema=fresh.delta;
  assert.deepEqual(verdict(fresh),[200,'refused','schema']);assert.equal(fresh.delta,1,'a fresh isolate reads the identity once');
  assert.notEqual(fresh.report.schema,fresh.report.expected_schema);
  await owner.simple('DROP TRIGGER fixture_refusal ON opencast.n_feed');
  await owner.simple('DROP FUNCTION opencast.fixture_refuse()');
 });
 await check('(3) a pin naming another database refuses, and a cached refusal submits nothing',async()=>{
  const identity=await call('other','/identity');
  assert.deepEqual(verdict(identity),[200,'refused','database']);assert.equal(identity.delta,1);
  const inspect=await call('other','/inspect'),pause=await call('other','/pause'),again=await call('other','/identity');
  record.refused={identity:identity.delta,inspect:inspect.delta,pause:pause.delta,again:again.delta};
  assert.equal(inspect.status,500);assert.match(inspect.log,/storage_inspect_feed_Identity_NotApplicable/);assert.equal(inspect.delta,0);
  assert.equal(pause.status,500);assert.match(pause.log,/storage_change_feed_Identity_NotCommitted/);assert.equal(pause.delta,0);
  assert.equal(await paused(),0,'the refused write was never submitted');
  assert.deepEqual(verdict(again),[200,'refused','database']);assert.equal(again.delta,0);
 });
 await check('(4) a malformed pin refuses before any read',async()=>{
  const deltas=[];
  for(const path of ['/identity','/inspect','/pause','/identity']){
   const r=await call('malformed',path);deltas.push(r.delta);
   if(path==='/identity')assert.deepEqual(verdict(r),[200,'refused','pin']);
   else{assert.equal(r.status,500);assert.match(r.log,/_Identity_Not/);}
  }
  record.malformed=deltas;
  assert.deepEqual(deltas,[0,0,0,0]);
 });
 await check('the fixture DDL and the raw owner connection are gone before dispose',async()=>{
  const left=(await owner.query("SELECT (SELECT COUNT(*) FROM pg_trigger WHERE tgname='fixture_refusal')::int AS triggers,(SELECT COUNT(*) FROM pg_proc WHERE proname='fixture_refuse')::int AS functions")).rows[0];
  assert.deepEqual(left,{triggers:0,functions:0});
  await owner.close();owner=undefined;
  const checker=await Client.connect({host:HOST,port:storage.port,user:OWNER,password:OWNER_PASSWORD,database:db,application:'identity-cache-check'});
  try{
   for(let i=0;i<50&&(await checker.query('SELECT COUNT(*)::int AS n FROM pg_stat_activity WHERE application_name=$1',[APPLICATION])).rows[0].n;i++)await new Promise(resolve=>setTimeout(resolve,20));
   assert.equal((await checker.query('SELECT COUNT(*)::int AS n FROM pg_stat_activity WHERE application_name=$1',[APPLICATION])).rows[0].n,0);
  }finally{await checker.close();}
 });
 console.log(`IDENTITY_CACHE ${JSON.stringify(record)}`);
}finally{
 try{
  if(owner){
   await owner.simple('DROP TRIGGER IF EXISTS fixture_refusal ON opencast.n_feed').catch(()=>{});
   await owner.simple('DROP FUNCTION IF EXISTS opencast.fixture_refuse()').catch(()=>{});
   await owner.close();
  }
 }finally{try{await mf.dispose();}finally{await storage.dispose();}}
}
console.log(`${passed} identity cache checks passed`);
