// The storage timing witness's cancellation controls on the storage-fixture
// Worker: both forms on an ordinary write and on the interactive executor,
// each fired only after the proxy's fire witness of a hold on the statement in
// flight. The core token (/test/cancel-core) ends the held race Cancelled while
// the invocation answers with its storage_phases line; the owner abort disposes
// the invocation at once, and the line its drop logs names the in-flight race.
// Then the readback controls on slice_d's and slice_f's executors: a failed
// readback after a lost COMMIT acknowledgement, and on slice_d a readback the
// core token cancels or the owner abort drops while its read is held.
// Run from the repo root: node Server/NotificationsWorker/tests/postgres/test-witness.mjs
// It needs the storage-fixture build at OPENCAST_FIXTURE_BUILD (default
// /tmp/opencast-storage-fixture-build): in Server/NotificationsWorker,
// worker-build --release --out-dir <dir> --no-default-features --features storage-fixture
import assert from 'node:assert/strict';
import {existsSync,readFileSync} from 'node:fs';
import {randomBytes,createHash} from 'node:crypto';
import {setTimeout as sleep} from 'node:timers/promises';
import {Miniflare,convertV4MiniflareOptions} from 'miniflare';
import {Client} from './pg.mjs';
import {openStorage} from '../storage.mjs';

const port=Number(process.env.OPENCAST_PG_PORT??55432),host=process.env.OPENCAST_PG_HOST??'127.0.0.1';
const FIXTURE_BUILD=process.env.OPENCAST_FIXTURE_BUILD??'/tmp/opencast-storage-fixture-build';
for(const file of [FIXTURE_BUILD+'/index.js',FIXTURE_BUILD+'/index_bg.wasm'])
 if(!existsSync(file)){console.log(`not ok missing ${file}`);process.exit(1);}
// The local topology's fixed fixture password (local-postgres.sh), never a secret.
const OWNER='opencast_local_owner',OWNER_PASSWORD='opencast-local-owner';
const H=(...parts)=>createHash('sha256').update(JSON.stringify(parts)).digest('hex');
let passed=0,failed=0;
const report=[];
async function test(name,fn,ms=30000){
 let timer;
 try{await Promise.race([fn(),new Promise((_,reject)=>{timer=setTimeout(()=>reject(Error(`timed out after ${ms} ms`)),ms);})]);passed++;console.log('PASS',name);}
 catch(error){failed++;console.log('FAIL',name);console.log(error);}
 finally{clearTimeout(timer);}
}
const waitFor=async(what,fn,ms=10000)=>{const end=Date.now()+ms;for(;;){const v=await fn();if(v)return v;if(Date.now()>end)throw Error(`timed out waiting for ${what}`);await sleep(5);}};

const storage=await openStorage();
const owner=await Client.connect({host,port,user:OWNER,password:OWNER_PASSWORD,database:storage.databaseName,application:'test-witness-owner',searchPath:'opencast, pg_catalog'});
const FEED=H('witness-cancel');
await owner.query('INSERT INTO n_feed(feed_id,canonical_url,epoch,due_at) VALUES($1,$2,1,0)',[FEED,`https://fixture.example/${FEED}.xml`]);
const TOKEN=randomBytes(16).toString('hex');
const ENTRY=readFileSync(new URL('./fixture-entry.mjs',import.meta.url));
const logs=[];
const mf=new Miniflare(convertV4MiniflareOptions({cf:false,inspectorPort:0,
 handleStructuredLogs:({message})=>{try{const event=JSON.parse(message);if(event?.event)logs.push(event);}catch{}},
 workers:[storage.bind({name:'fixture',modulesRoot:FIXTURE_BUILD,
  modules:[{type:'ESModule',path:FIXTURE_BUILD+'/fixture-entry.mjs',contents:ENTRY},{type:'ESModule',path:FIXTURE_BUILD+'/index.js'},{type:'CompiledWasm',path:FIXTURE_BUILD+'/index_bg.wasm'}],
  compatibilityDate:'2026-09-30',compatibilityFlags:['enable_request_signal'],bindings:{SLICE_TOKEN:TOKEN}})]}));
const fixture=storage.testStorage('fixture');
const post=async(path,body,headers={})=>{const worker=await mf.getWorker('fixture');const r=await worker.fetch('https://fixture.invalid'+path,{method:'POST',headers:{authorization:`Bearer ${TOKEN}`,...headers},body:typeof body==='string'?body:JSON.stringify(body)});const text=await r.text();let parsed;try{parsed=JSON.parse(text);}catch{parsed=text;}return {status:r.status,body:parsed};};

const cases=[
 ['an ordinary write','/witness/operation',()=>({request:{operation:'record_poll_stat',counter:'redeliveries',now:Math.floor(Date.now()/1000)}}),'hold-unit-reply:0','INSERT INTO n_poll_stat(bucket,redeliveries)','operation','transaction'],
 ['the interactive executor','/witness/slice-e/operation',()=>({request:{operation:'abandon_poisoned',feed:FEED,now:Math.floor(Date.now()/1000)}}),'interactive-hold','SELECT observation_id,reason_counts_json','interactive','statement'],
];
try{
 for(const [what,route,body,action,match,role,boundary] of cases){
  await test(`${what}: the core token after the hold fired ends the held ${boundary} race Cancelled; the line names it`,async()=>{
   const arm=fixture({op:'arm',kind:'statement',action,match}),pending=post(route,body());
   const fire=await waitFor('the fire',()=>fixture({op:'witness'}).fires.find(f=>f.arming===arm.arming));
   await sleep(100);
   assert.equal((await post('/test/cancel-core','')).status,200);
   const x=await pending;
   assert.equal(x.status,200,JSON.stringify(x.body));
   const line=x.body.line;
   assert.equal(x.body.ok,false);
   assert.equal(line.outcome,'failed');
   assert.deepEqual([line.primary.role,line.primary.kind,line.primary.race.boundary,line.primary.race.status],[role,'Cancelled',boundary,'cancelled'],JSON.stringify(line.primary));
   await waitFor('the close',()=>fixture({op:'witness'}).operations.find(o=>o.id===fire.op)?.close);
   fixture({op:'expect',fire:fire.id,outcome:'discarded'});
   report.push(`${what} cancel-core: ${line.primary.op} ${line.primary.race.boundary} ${line.primary.race.status} after ${line.primary.race.end_ms-line.primary.race.start_ms} ms`);
  });
  await test(`${what}: the owner abort after the hold fired disposes the invocation (499); the line its drop logs reads dropped with the in-flight ${boundary} race named`,async()=>{
   const key=`witness-${role}`,from=logs.length;
   const arm=fixture({op:'arm',kind:'statement',action,match}),pending=post(route,body(),{'x-test-execution':key});
   const fire=await waitFor('the fire',()=>fixture({op:'witness'}).fires.find(f=>f.arming===arm.arming));
   await sleep(100);
   assert.deepEqual((await post('/__abort',key)).body,{found:true});
   const x=await pending;
   assert.equal(x.status,499);
   const line=await waitFor('the dropped line',()=>logs.slice(from).find(e=>e.event==='storage_phases'));
   assert.equal(line.outcome,'cancelled');
   assert.deepEqual([line.primary.role,line.primary.status,line.primary.race.boundary,line.primary.race.status],[role,'dropped',boundary,'dropped'],JSON.stringify(line.primary));
   assert.ok(line.ops.dropped>=1);
   await waitFor('the close',()=>fixture({op:'witness'}).operations.find(o=>o.id===fire.op)?.close);
   fixture({op:'expect',fire:fire.id,outcome:'discarded'});
   report.push(`${what} owner abort: ${line.primary.op} ${line.primary.status}, in-flight ${line.primary.race.boundary} ${line.primary.race.status}`);
  });
 }
 // A readback after a lost COMMIT acknowledgement on slice_d's and slice_f's
 // own executors (slice_e's is the polling cleanup's RetireObservations in
 // FeedPolling's witness-runtime.mjs). The initiating guard stays primary; the
 // readback has its own guard, whose parent is the initiating ordinal.
 const readbacks=[
  ['slice_d','/witness/slice-d/operation',()=>({request:{operation:'repair_feed',feed:FEED}}),'repair_feed','UPDATE n_feed SET handling_failures=0','read_feed_repair','SELECT feed_id,handling_failures,retry_at,last_poll_error FROM n_feed'],
  ['slice_f','/witness/slice-f/operation',()=>({request:{operation:'change_feed',feed:FEED,epoch:1,now:Math.floor(Date.now()/1000),action:'pause_sends'}}),'change_feed','UPDATE n_feed SET send_paused=1','inspect_feed','SELECT epoch,admission_paused,send_paused'],
 ];
 const arm=(action,match)=>fixture({op:'arm',kind:'statement',action,match}).arming;
 const settle=async armings=>{
  for(const fire of fixture({op:'witness'}).fires.filter(f=>armings.includes(f.arming))){
   await waitFor('the close',()=>fixture({op:'witness'}).operations.find(o=>o.id===fire.op)?.close);
   if(fixture({op:'witness'}).fires.find(f=>f.id===fire.id)?.discarded!=null)fixture({op:'expect',fire:fire.id,outcome:'discarded'});
  }
 };
 // The initiating operation failed Driver / commit / Unknown and stays primary;
 // the readback's entry follows it with the initiating ordinal as its parent,
 // both intervals lie inside durations.storage, and with no other interval
 // the idle residual is the wall less that union.
 const lost=(line,initiating,readback)=>{
  const primary=line.primary;
  assert.deepEqual([primary.op,primary.role,primary.kind,primary.phase,primary.outcome],[initiating,'operation','Driver','commit','Unknown'],JSON.stringify(primary));
  const first=line.op.find(o=>o.ordinal===primary.ordinal),entry=line.op.find(o=>o.role==='readback');
  assert.ok(first&&entry,JSON.stringify(line.op));
  assert.deepEqual([entry.op,entry.parent],[readback,primary.ordinal],JSON.stringify(entry));
  assert.ok(entry.start_ms>=first.end_ms,`the readback ${entry.start_ms} after the initiating end ${first.end_ms}`);
  const spans=(first.end_ms-first.start_ms)+(entry.end_ms-entry.start_ms);
  assert.ok(line.durations.storage>=spans-1&&line.durations.storage<=line.wall_ms,`storage ${line.durations.storage}, spans ${spans}, wall ${line.wall_ms}`);
  assert.ok(Math.abs(line.durations.idle-(line.wall_ms-line.durations.storage))<=1,`idle ${line.durations.idle}, wall ${line.wall_ms}, storage ${line.durations.storage}`);
  return entry;
 };
 for(const [slice,route,body,initiating,write,readback,read] of readbacks){
  await test(`${slice}: a readback failure after a lost COMMIT acknowledgement: the initiating guard stays primary, the readback guard is failures[0] with the initiating ordinal as its parent and its interval inside durations.storage; the public string unchanged`,async()=>{
   const from=logs.length,armings=[arm('drop-commit-ack',write),arm('close-before',read)];
   const x=await post(route,body());
   assert.equal(x.status,200,JSON.stringify(x.body));
   assert.equal(x.body.ok,false);
   assert.match(x.body.error,new RegExp(`storage_${initiating}_Driver_Unknown$`));
   const line=x.body.line;
   assert.equal(line.outcome,'failed');
   const entry=lost(line,initiating,readback);
   assert.equal(entry.status,'failed');
   assert.deepEqual([line.failures[0]?.role,line.failures[0]?.op,line.failures[0]?.parent],['readback',readback,line.primary.ordinal],JSON.stringify(line.failures));
   assert.ok(logs.slice(from).some(e=>e.event==='storage_unknown_readback'&&e.operation===initiating&&e.observed===false),'the readback line is kept');
   await settle(armings);
   report.push(`${slice} readback failure: ${line.primary.op} ${line.primary.kind}/${line.primary.phase}/${line.primary.outcome}; failures[0] ${line.failures[0].op} ${line.failures[0].kind}; storage ${line.durations.storage} ms, idle ${line.durations.idle} of wall ${line.wall_ms}`);
  });
 }
 {
  const [,route,body,initiating,write,readback,read]=readbacks[0];
  // The read race ends cancelled; the close race that follows it completes.
  await test('slice_d: a cancelled readback, the core token while the readback read is held: its read race ends cancelled, its interval inside durations.storage, idle the wall less the union',async()=>{
   const armings=[arm('drop-commit-ack',write),arm('hold-forever',read)],pending=post(route,body());
   await waitFor('the readback hold',()=>fixture({op:'witness'}).fires.find(f=>f.arming===armings[1]));
   await sleep(100);
   assert.equal((await post('/test/cancel-core','')).status,200);
   const x=await pending;
   assert.equal(x.status,200,JSON.stringify(x.body));
   assert.match(x.body.error,new RegExp(`storage_${initiating}_Driver_Unknown$`));
   const line=x.body.line;
   const entry=lost(line,initiating,readback),race=entry.race.find(r=>r.boundary==='read');
   assert.deepEqual([entry.status,race.boundary,race.status],['failed','read','cancelled'],JSON.stringify(entry));
   assert.deepEqual([line.failures[0]?.op,line.failures[0]?.kind],[readback,'Cancelled'],JSON.stringify(line.failures));
   await settle(armings);
   report.push(`slice_d cancelled readback: ${entry.op} read ${race.status} after ${race.end_ms-race.start_ms} ms; storage ${line.durations.storage} ms, idle ${line.durations.idle} of wall ${line.wall_ms}`);
  });
  await test('slice_d: the owner abort while the readback read is held: the line its drop logs keeps the initiating primary and reads the readback dropped, its in-flight read named',async()=>{
   const key='witness-readback',from=logs.length;
   const armings=[arm('drop-commit-ack',write),arm('hold-forever',read)],pending=post(route,body(),{'x-test-execution':key});
   await waitFor('the readback hold',()=>fixture({op:'witness'}).fires.find(f=>f.arming===armings[1]));
   await sleep(100);
   assert.deepEqual((await post('/__abort',key)).body,{found:true});
   assert.equal((await pending).status,499);
   const line=await waitFor('the dropped line',()=>logs.slice(from).find(e=>e.event==='storage_phases'));
   assert.equal(line.outcome,'cancelled');
   const entry=lost(line,initiating,readback),race=entry.race.find(r=>r.boundary==='read');
   assert.deepEqual([entry.status,race.boundary,race.status],['dropped','read','dropped'],JSON.stringify(entry));
   assert.ok(line.ops.dropped>=1);
   await settle(armings);
   report.push(`slice_d owner abort during the readback: ${entry.op} ${entry.status}, in-flight ${race.boundary} ${race.status}; storage ${line.durations.storage} ms, idle ${line.durations.idle} of wall ${line.wall_ms}`);
  });
 }
}finally{
 await mf.dispose();
 await owner.close().catch(()=>{});
 await test('storage.dispose: the fixture alias carries a clean witness, and the database is dropped',()=>storage.dispose());
}
for(const line of report)console.log('REPORT',line);
console.log(`${passed} passed, ${failed} failed`);
process.exitCode=failed?1:0;
