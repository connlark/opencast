// timing.mjs's controls against the local topology
// (Server/NotificationsWorker/postgres/local/local-postgres.sh status exits 0),
// beside test-proxy.mjs's accepted actions. Synthetic clients drive the wire
// for each control's own witness; the storage-fixture Worker drives the held
// writes whose deadline and cleanup budgets the controls must account for:
// after a held reply the Worker's ROLLBACK is a cleanup operation of its own
// (CLOSE_MS, 500 ms) whose reply waits behind the held one, then finish()
// closes within its own CLOSE_MS. The interactive executor's ROLLBACK is an
// ordinary query instead: its reply, consumed against the held statement,
// leaves it to wait out its statement cap or the transaction's remaining
// TRANSACTION_MS, whichever ends first.
// Run from the repo root: node Server/NotificationsWorker/tests/postgres/test-timing.mjs
// It needs the storage-fixture build at OPENCAST_FIXTURE_BUILD (default
// /tmp/opencast-storage-fixture-build): in Server/NotificationsWorker,
// worker-build --release --out-dir <dir> --no-default-features --features storage-fixture
// OPENCAST_PG_HOST and OPENCAST_PG_PORT override 127.0.0.1:55432. Miniflare and the proxy need loopback sockets.
import assert from 'node:assert/strict';
import net from 'node:net';
import {once} from 'node:events';
import {existsSync,readFileSync} from 'node:fs';
import {randomBytes,createHash} from 'node:crypto';
import {setTimeout as sleep} from 'node:timers/promises';
import {Miniflare,convertV4MiniflareOptions} from 'miniflare';
import {Client,GATE,encodeParameter,scramClientFirst,scramClientFinal,verifyServerFinal,PostgresError} from './pg.mjs';
import {DESTROY_MS,WireProxy} from './proxy.mjs';
import {INTERACTIVE_FIRST} from './hooks.mjs';
import {openStorage} from '../storage.mjs';

if(process.env.OPENCAST_TEST_STORAGE!==undefined&&process.env.OPENCAST_TEST_STORAGE!=='postgres')throw Error('test-timing.mjs runs postgres storage: launch it without OPENCAST_TEST_STORAGE');
const port=Number(process.env.OPENCAST_PG_PORT??55432),host=process.env.OPENCAST_PG_HOST??'127.0.0.1';
const FIXTURE_BUILD=process.env.OPENCAST_FIXTURE_BUILD??'/tmp/opencast-storage-fixture-build';
for(const file of [FIXTURE_BUILD+'/index.js',FIXTURE_BUILD+'/index_bg.wasm'])
 if(!existsSync(file)){console.log(`not ok missing ${file}`);process.exit(1);}
// The local topology's fixed fixture passwords (local-postgres.sh), never secrets.
const RUNTIME='opencast_local_runtime',RUNTIME_PASSWORD='opencast-local-runtime',OWNER='opencast_local_owner',OWNER_PASSWORD='opencast-local-owner';
// The Worker's cleanup and close budgets (WorkerDatabaseCore lifecycle::CLOSE_MS)
// and its statement cap (STATEMENT_MS); EPSILON_MS is the only scheduling
// slack between workerd's timers and the proxy's stamps, as in test-proxy.mjs.
const CLOSE_MS=500,STATEMENT_MS=4000,TRANSACTION_MS=8000,EPSILON_MS=250;
const now=()=>performance.timeOrigin+performance.now();
let failed=0,passed=0;
const report=[];
async function test(name,fn,ms=60000){
 let timer;
 try{await Promise.race([fn(),new Promise((_,reject)=>{timer=setTimeout(()=>reject(Error(`timed out after ${ms} ms`)),ms);})]);passed++;console.log('PASS',name);}
 catch(error){failed++;console.log('FAIL',name);console.log(error);}
 finally{clearTimeout(timer);}
}
const waitFor=async(what,fn,ms=10000)=>{const end=Date.now()+ms;for(;;){const v=await fn();if(v)return v;if(Date.now()>end)throw Error(`timed out waiting for ${what}`);await sleep(5);}};
const H=(...parts)=>createHash('sha256').update(JSON.stringify(parts)).digest('hex');

const storage=await openStorage().catch(error=>{console.log(`not ok open storage: ${error.message}`);process.exit(1);});
const proxy=storage.proxy,db=storage.databaseName;
const owner=await Client.connect({host,port,user:OWNER,password:OWNER_PASSWORD,database:db,application:'test-timing-owner',searchPath:'opencast, pg_catalog'});
const feed=async id=>{await owner.query('INSERT INTO n_feed(feed_id,canonical_url,epoch,due_at) VALUES($1,$2,1,0)',[id,`https://fixture.example/${id}.xml`]);return id;};
const success=async id=>(await owner.query('SELECT last_success_at FROM n_feed WHERE feed_id=$1',[id])).rows[0].last_success_at;
const FEED=await feed(H('timing-a'));
const synthetic=[];
function syn(name,px=proxy){
 const alias=`${db}.timing-${synthetic.length+1}-${name}`;
 const a=px.register({alias,database:db,entry:null,worker:null});synthetic.push([px,alias]);
 const ts=op=>px.handle(alias,op);
 return {alias,a,ts,port:px.listenPort,witness:()=>ts({op:'witness'}),problems:()=>px.problems(a)};
}
const viaProxy=(alias,listen=proxy.listenPort)=>Client.connect({port:listen,user:RUNTIME,password:RUNTIME_PASSWORD,database:alias,application:'test-timing'});
const SETTLE='UPDATE n_feed SET last_success_at=$1 WHERE feed_id=$2';
const CLAIM='SELECT f.origin_key,f.due_at FROM n_feed f WHERE f.feed_id=$1';
const STAT='INSERT INTO n_poll_stat(bucket,handling_failures) VALUES($1,1) ON CONFLICT(bucket) DO UPDATE SET handling_failures=n_poll_stat.handling_failures+1';
const REDELIVERY='INSERT INTO n_poll_stat(bucket,redeliveries)';
const opOf=(w,fire)=>w.operations.find(o=>o.id===w.fires.find(f=>f.id===fire).op);
const tagsOf=(s,arming)=>{const w=s.witness(),f=w.fires.find(x=>x.arming===arming);return f?opOf(w,f.id):null;};
const serverFirst=c=>c.terminate_sent!==null&&c.upstream_end!==null&&c.upstream_destroyed===null&&c.upstream_end-c.terminate_sent<DESTROY_MS;
// BEGIN, the gate, two application units and COMMIT: units 0..4.
const writeOf=(value,bucket)=>[['BEGIN'],[GATE],[SETTLE,[value,FEED]],[STAT,[bucket]],['COMMIT']];

// ---- A raw frontend, for exact control of what the client sends when.
const i32=n=>{const b=Buffer.alloc(4);b.writeInt32BE(n);return b;};
const i16=n=>{const b=Buffer.alloc(2);b.writeInt16BE(n);return b;};
const cstr=s=>Buffer.from(s+'\0');
const frame=(kind,body)=>Buffer.concat([Buffer.from(kind),i32(body.length+4),body]);
function fields(body){const out={};let i=0;while(i<body.length&&body[i]!==0){const end=body.indexOf(0,i+1);out[String.fromCharCode(body[i])]=body.subarray(i+1,end).toString();i=end+1;}return out;}
function unit(sql,values=[]){
 const p=values.map(encodeParameter);
 return Buffer.concat([frame('P',Buffer.concat([cstr(''),cstr(sql),i16(p.length),...p.map(x=>i32(x.oid))])),
  frame('B',Buffer.concat([cstr(''),cstr(''),i16(0),i16(p.length),...p.map(x=>x.text===null?i32(-1):Buffer.concat([i32(Buffer.byteLength(x.text)),Buffer.from(x.text)])),i16(0)])),
  frame('D',Buffer.concat([Buffer.from('P'),cstr('')])),frame('E',Buffer.concat([cstr(''),i32(0)])),frame('S',Buffer.alloc(0))]);
}
class Raw {
 constructor(socket){
  Object.assign(this,{socket,buffer:Buffer.alloc(0),waiters:[],closed:false});
  socket.on('data',c=>{this.buffer=Buffer.concat([this.buffer,c]);this.pump();});
  socket.on('close',()=>{this.closed=true;this.pump();});socket.on('error',()=>{});
 }
 pump(){
  while(this.waiters.length){const w=this.waiters[0],v=w.take();
   if(v===undefined){if(!this.closed)return;this.waiters.shift();w.reject(Error('connection closed'));continue;}
   this.waiters.shift();w.resolve(v);}
 }
 wait(take){return new Promise((resolve,reject)=>{this.waiters.push({take,resolve,reject});this.pump();});}
 message(){return this.wait(()=>{if(this.buffer.length<5)return;const size=this.buffer.readInt32BE(1);if(this.buffer.length<size+1)return;
  const m={kind:String.fromCharCode(this.buffer[0]),body:this.buffer.subarray(5,size+1)};this.buffer=this.buffer.subarray(size+1);return m;});}
 async reply(){const out={tags:[],rows:0,error:null};for(;;){const m=await this.message();if(m.kind==='C')out.tags.push(m.body.subarray(0,-1).toString());if(m.kind==='D')out.rows++;if(m.kind==='E')out.error??=fields(m.body).C;if(m.kind==='Z')return out;}}
 write(buf){this.socket.write(buf);}
}
async function raw(alias){
 const socket=net.connect({host:'127.0.0.1',port:proxy.listenPort});socket.setNoDelay(true);await once(socket,'connect');
 const r=new Raw(socket);
 const params=Buffer.concat([cstr('user'),cstr(RUNTIME),cstr('database'),cstr(alias),cstr('application_name'),cstr('test-timing-raw'),Buffer.from([0])]);
 const first=scramClientFirst();
 const auth=async code=>{const m=await r.message();if(m.kind==='E')throw new PostgresError(fields(m.body));assert.equal(m.kind,'R');assert.equal(m.body.readInt32BE(0),code);return m.body.subarray(4);};
 r.write(Buffer.concat([i32(params.length+8),i32(196608),params]));await auth(10);
 r.write(frame('p',Buffer.concat([cstr('SCRAM-SHA-256'),i32(Buffer.byteLength(first.message)),Buffer.from(first.message)])));
 const final=await scramClientFinal({password:RUNTIME_PASSWORD,clientNonce:first.nonce,clientFirstBare:first.bare,serverFirst:(await auth(11)).toString()});
 r.write(frame('p',Buffer.from(final.message)));
 verifyServerFinal((await auth(12)).toString(),final.serverSignature);await auth(0);
 for(;;){const m=await r.message();if(m.kind==='E')throw new PostgresError(fields(m.body));if(m.kind==='Z')return r;}
}
const bucketOf=k=>Math.floor(Date.now()/3600000)+2000+k;
let relay=null,fragmenting=null;

try {
// ================================================================ statement armings
await test('statement arming: an accepted action by prefix, one-shot after skip, with the accepted ids',async()=>{
 const s=syn('arm'),arm=s.ts({op:'arm',kind:'statement',action:'close-before',match:'SELECT f.origin_key',skip:1});
 assert.match(arm.arming,/^A\d+$/);
 const c1=await viaProxy(s.alias);assert.equal((await c1.query(CLAIM,[FEED])).rows.length,1);await c1.close();
 const c2=await viaProxy(s.alias);await assert.rejects(c2.query(CLAIM,[FEED]));
 const c3=await viaProxy(s.alias);assert.equal((await c3.query(CLAIM,[FEED])).rows.length,1);await c3.close();
 const w=s.witness(),f=w.fires[0],o=opOf(w,f.id),m=w.armings.find(x=>x.id===arm.arming);
 assert.equal(w.fires.length,1);
 assert.deepEqual([f.arming,f.hook,f.action,f.statement,o.forwarded,o.closed_by],[arm.arming,'statement','close-before',CLAIM,null,'hook']);
 assert.deepEqual([m.kind,m.name,m.match,m.skip,m.seen,m.fires],['statement','close-before','SELECT f.origin_key',1,2,[f.id]]);
 assert.deepEqual(s.problems(),[]);
});
await test('statement arming: an accepted hold-request released by release_after_ms 300',async()=>{
 const s=syn('timed'),started=now();s.ts({op:'arm',kind:'statement',action:'hold-request',match:'SELECT f.origin_key',release_after_ms:300});
 const c=await viaProxy(s.alias),begin=now();assert.equal((await c.query(CLAIM,[FEED])).rows.length,1);const waited=now()-begin;await c.close();
 const w=s.witness(),f=w.fires[0],o=opOf(w,f.id);
 assert.deepEqual([f.action,w.released[0].how],['hold-request','timer']);
 assert.ok(f.released-f.at>=300&&f.released-f.at<300+EPSILON_MS,`released ${f.released-f.at} ms after the fire`);
 assert.ok(o.forwarded>=f.released&&waited>=300,`waited ${waited}`);
 report.push(`timed hold-request: released ${(f.released-f.at).toFixed(1)} ms after fire, query ${waited.toFixed(1)} ms (armed ${(f.at-started).toFixed(1)} ms before the fire)`);
 assert.deepEqual(s.problems(),[]);
});
// A zero delay is already due at the fire, which runs before the proxy has
// stored the fire on its operation and registered the hold: the timer must
// still find the hold.
await test('statement arming: an accepted hold-request with release_after_ms 0 is released by its timer once its hold exists',async()=>{
 const s=syn('timed-zero');s.ts({op:'arm',kind:'statement',action:'hold-request',match:'SELECT f.origin_key',release_after_ms:0});
 const c=await viaProxy(s.alias);assert.equal((await c.query(CLAIM,[FEED])).rows.length,1);await c.close();
 const w=s.witness(),f=w.fires[0],o=opOf(w,f.id);
 assert.deepEqual([w.fires.length,f.action,w.released.map(r=>[r.fire,r.how]),s.a.holds.size,w.errors],[1,'hold-request',[[f.id,'timer']],0,[]]);
 assert.ok(f.released>=f.at&&f.released-f.at<EPSILON_MS&&o.forwarded>=f.released,`released ${f.released-f.at} ms, forwarded ${o.forwarded-f.at} ms after the fire`);
 report.push(`zero-delay hold-request: released ${(f.released-f.at).toFixed(2)} ms after fire, forwarded at the release`);
 assert.deepEqual(await proxy.teardown([s.alias]),[]);
},10000);
await test('statement arming: malformed armings are refused and recorded; an unfired one fails teardown until expected',async()=>{
 const s=syn('refused');
 for(const [op,message] of [
  [{action:'fail-and-arm',match:'SELECT'},/unknown statement action/],[{action:'close-before'},/needs a match prefix/],
  [{action:'hold-request',match:'SELECT',forever:true},/forever belongs to hold-commit-reply/],
  [{action:'close-before',match:'SELECT',release_after_ms:5},/release_after_ms needs a releasable hold/],
  [{action:'hold-commit-reply',match:'UPDATE',forever:true,release_after_ms:5},/releasable hold, not hold-commit-reply forever/],
  [{action:'side-write-first',match:'UPDATE'},/only side-write-first takes a side/],[{action:'close-before',match:'SELECT',side:'lost_lease'},/only side-write-first/],
  [{action:'close-before',match:'SELECT',skip:-1},/skip must be a non-negative integer/],
 ])assert.throws(()=>s.ts({op:'arm',kind:'statement',...op}),message);
 assert.equal(s.witness().errors.filter(e=>e.kind==='unknown-action').length,8);
 const t=syn('unfired'),arm=t.ts({op:'arm',kind:'statement',action:'hold-commit-reply',match:'UPDATE n_feed'});
 assert.match(t.problems().join(),new RegExp(`arming ${arm.arming} \\(statement hold-commit-reply\\) never fired`));
 t.ts({op:'expect',arming:arm.arming});assert.deepEqual(t.problems(),[]);
});

await test('controls.stall: run(ms) starts start_ms after the named arming\'s fire, with its own arming and fire; refused shapes; an unfired stall fails teardown',async()=>{
 const s=syn('stall'),arm=s.ts({op:'arm',kind:'statement',action:'hold-request',match:'SELECT f.origin_key',release_after_ms:400});
 const runs=[],stall=proxy.controls.stall(s.alias,{after:arm.arming,start_ms:50,ms:100,run:async ms=>{runs.push(now());await sleep(ms);return {ms};}});
 const c=await viaProxy(s.alias);assert.equal((await c.query(CLAIM,[FEED])).rows.length,1);await c.close();
 const w=await waitFor('the stall end',()=>{const v=s.witness(),g=v.fires.find(x=>x.arming===stall.arming);return g?.stall.end&&v;});
 const f=w.fires.find(x=>x.arming===arm.arming),g=w.fires.find(x=>x.arming===stall.arming);
 assert.deepEqual([g.hook,g.action,g.parent,g.stall.after_fire,g.stall.worker,runs.length],['stall','stall:50:100',f.id,f.id,{ms:100},1]);
 assert.ok(g.stall.start-f.at>=50&&g.stall.start-f.at<50+EPSILON_MS/5&&g.stall.end-g.stall.start>=100,JSON.stringify(g.stall));
 assert.deepEqual(w.timing.events.filter(e=>e.kind.startsWith('stall')).map(e=>e.kind),['stall-start','stall-end']);
 assert.throws(()=>proxy.controls.stall(s.alias,{after:'A0',start_ms:0,ms:1,run:()=>{}}),/no arming A0/);
 assert.throws(()=>proxy.controls.stall(s.alias,{after:arm.arming,start_ms:-1,ms:1,run:()=>{}}),/start_ms must be/);
 assert.throws(()=>proxy.controls.stall(s.alias,{after:arm.arming,start_ms:0,ms:1}),/run\(ms\) function/);
 const t=syn('stall-unfired'),held=t.ts({op:'arm',kind:'statement',action:'close-before',match:'SELECT nothing'}),unfired=proxy.controls.stall(t.alias,{after:held.arming,start_ms:0,ms:1,run:async()=>null});
 assert.match(t.problems().join(),new RegExp(`arming ${unfired.arming} \\(stall stall:0:1\\) never fired`));
 t.ts({op:'expect',arming:held.arming});t.ts({op:'expect',arming:unfired.arming});assert.deepEqual(t.problems(),[]);
 assert.equal(s.problems().length,3,'the three refusals are recorded');
});

// ================================================================ hold-commit-reply
await test('hold-commit-reply: BEGIN, gate and both application replies relayed (Z_relay x4), the COMMIT reply held with its tag, relayed on release',async()=>{
 const s=syn('commit'),arm=s.ts({op:'arm',kind:'statement',action:'hold-commit-reply',match:'UPDATE n_feed SET last_success_at='});
 const c=await viaProxy(s.alias);let done=false;const pending=c.pipeline(writeOf(201,bucketOf(1))).then(r=>{done=true;return r;});
 const held=await waitFor('the held COMMIT reply',()=>{const w=s.witness(),o=w.operations.at(-1);return o?.timing?.held_reply&&{w,o};});
 const {o}=held,f=held.w.fires[0];
 assert.deepEqual([f.arming,f.hook,f.action],[arm.arming,'statement','hold-commit-reply']);
 assert.deepEqual(o.timing.relays.map(r=>[r.unit,r.sql]),[[0,'BEGIN'],[1,'gate'],[2,SETTLE],[3,STAT]]);
 assert.ok(o.timing.relays.every(r=>r.seq<o.timing.held_reply.seq),'every Z_relay precedes held-reply');
 assert.deepEqual([o.timing.unit,o.timing.held_reply.unit,o.timing.held_reply.tag,o.commit_tag,o.commit_relayed],[4,4,'COMMIT','COMMIT',false]);
 // The server committed before the client could know it: the concealed commit.
 assert.equal(await success(FEED),201);
 await sleep(50);assert.equal(done,false);
 assert.deepEqual(s.ts({op:'release',fire:f.id}),{released:[f.id],discarded:[],refused:[]});
 assert.ok((await pending).every(x=>x.result));await c.close();
 const w=s.witness(),after=opOf(w,f.id),release=w.timing.events.find(e=>e.kind==='release');
 assert.equal(after.commit_relayed,true);
 const commit=after.timing.relays.find(r=>r.unit===4);assert.ok(commit&&commit.seq>release.seq&&release.seq>after.timing.held_reply.seq);
 const fireSeq=w.timing.events.find(e=>e.kind==='fire').seq;assert.ok(after.timing.relays.every(r=>r.seq>fireSeq));
 assert.deepEqual([w.released[0].how,after.timing.released.how],['release','release']);
 assert.deepEqual(s.problems(),[]);
});
await test('hold-commit-reply discard: the connection closes server-first, nothing of the held reply relayed, commit_relayed false',async()=>{
 const s=syn('discard');s.ts({op:'arm',kind:'statement',action:'hold-commit-reply',match:'UPDATE n_feed SET last_success_at='});
 const c=await viaProxy(s.alias),pending=c.pipeline(writeOf(202,bucketOf(2)));
 const f=await waitFor('the held reply',()=>{const w=s.witness();return w.operations.at(-1)?.timing?.held_reply&&w.fires[0];});
 assert.deepEqual(s.ts({op:'discard',fire:f.id}),{released:[],discarded:[f.id]});
 const out=await pending;assert.ok(out.slice(0,4).every(x=>x.result)&&out[4]?.error,JSON.stringify(out.map(x=>!!x.result)));
 const x=await waitFor('the upstream close',()=>{const c0=s.witness().connections[0];return c0.upstream_close&&c0;});
 const w=s.witness(),o=opOf(w,f.id);
 assert.deepEqual([o.closed_by,o.commit_tag,o.commit_relayed,o.timing.relays.map(r=>r.unit),o.timing.discarded.reason,w.discarded[0].reason],['discard','COMMIT',false,[0,1,2,3],'discard','discard']);
 assert.ok(serverFirst(x),JSON.stringify(x));assert.equal(await success(FEED),202);
 assert.match(s.problems().join(),new RegExp(`fire ${f.id} \\(statement hold-commit-reply\\) was discarded and not expected`));
 s.ts({op:'expect',fire:f.id,outcome:'discarded'});assert.deepEqual(s.problems(),[]);
});
await test('hold-commit-reply forever: release refused; the client\'s ROLLBACK is forwarded and its reply waits behind the held COMMIT reply',async()=>{
 const s=syn('forever');s.ts({op:'arm',kind:'statement',action:'hold-commit-reply',match:'UPDATE n_feed SET last_success_at=',forever:true});
 const r=await raw(s.alias);r.write(Buffer.concat(writeOf(203,bucketOf(3)).map(([q,v])=>unit(q,v))));
 for(let k=0;k<4;k++)assert.equal((await r.reply()).error,null);
 const f=await waitFor('the held reply',()=>{const w=s.witness();return w.operations.at(-1)?.timing?.held_reply&&w.fires[0];});
 assert.deepEqual(s.ts({op:'release',fire:f.id}).refused,[f.id]);
 r.write(unit('ROLLBACK'));
 const o=await waitFor('the ROLLBACK reply behind the hold',()=>{const x=opOf(s.witness(),f.id);return x.tags.includes('ROLLBACK')&&x;});
 await sleep(100);assert.equal(r.buffer.length,0,'nothing relayed after the held reply');
 assert.deepEqual([o.timing.rollback.sql,o.timing.relays.map(x=>x.unit),o.commit_relayed,o.commit_tag],['ROLLBACK',[0,1,2,3],false,'COMMIT']);
 assert.ok(o.timing.rollback.seq>o.timing.held_reply.seq);
 r.socket.destroy();await waitFor('the discard',()=>opOf(s.witness(),f.id).timing.discarded);
 assert.equal(opOf(s.witness(),f.id).timing.discarded.reason,'client');assert.equal(await success(FEED),203);
 s.ts({op:'expect',fire:f.id,outcome:'discarded'});assert.deepEqual(s.problems(),[]);
});
await test('a statement arming is never bypassed by a delayed (interactive) transaction',async()=>{
 const s=syn('bypass'),arm=s.ts({op:'arm',kind:'statement',action:'hold-commit-reply',match:'UPDATE n_feed SET last_success_at='}),r=await raw(s.alias);
 r.write(Buffer.concat([unit('BEGIN'),unit(GATE)]));await r.reply();await r.reply();
 await sleep(80);r.write(Buffer.concat([unit(SETTLE,[204,FEED]),unit('COMMIT')]));await assert.rejects(r.reply());
 const w=s.witness();
 assert.deepEqual(w.errors.map(e=>[e.kind,e.hook,e.arming]),[['armed-hook-bypassed','statement',arm.arming]]);
 assert.deepEqual([w.operations[0].interactive.shape,w.fires.length],['bypassed',0]);assert.notEqual(await success(FEED),204);
});

// ================================================================ hold-unit-reply
await test('hold-unit-reply:0: BEGIN and gate replies relayed, the first application reply held, the later replies behind it; release relays all three',async()=>{
 const s=syn('unit0'),arm=s.ts({op:'arm',kind:'statement',action:'hold-unit-reply:0',match:'UPDATE n_feed SET last_success_at='});
 const c=await viaProxy(s.alias),pending=c.pipeline(writeOf(211,bucketOf(21)));
 const o=await waitFor('every reply at the proxy',()=>{const x=tagsOf(s,arm.arming);return x?.timing?.held_reply&&x.tags.length===5&&x;});
 assert.deepEqual([o.timing.unit,o.timing.held_reply.tag,o.timing.relays.map(r=>r.sql),o.commit_tag,o.commit_relayed],[2,'UPDATE 1',['BEGIN','gate'],'COMMIT',false]);
 assert.ok(o.timing.relays.every(r=>r.seq<o.timing.held_reply.seq));
 // The server ran the whole transaction: the hold conceals a committed write.
 assert.equal(await success(FEED),211);
 assert.deepEqual(s.ts({op:'release',fire:o.fire_id}).released,[o.fire_id]);
 assert.ok((await pending).every(x=>x.result));await c.close();
 assert.deepEqual(opOf(s.witness(),o.fire_id).timing.relays.map(r=>r.unit),[0,1,2,3,4]);assert.deepEqual(s.problems(),[]);
});
await test('hold-unit-reply:1 holds the second application reply; an index past the last application unit is a recorded shape error',async()=>{
 const s=syn('unit1'),arm=s.ts({op:'arm',kind:'statement',action:'hold-unit-reply:1',match:'UPDATE n_feed SET last_success_at=',release_after_ms:100});
 const c=await viaProxy(s.alias);assert.ok((await c.pipeline(writeOf(212,bucketOf(22)))).every(x=>x.result));await c.close();
 const o=tagsOf(s,arm.arming);
 assert.deepEqual([o.timing.unit,o.timing.held_reply.tag,o.timing.relays.filter(r=>r.seq<o.timing.held_reply.seq).map(r=>r.unit),o.timing.released.how],[3,'INSERT 0 1',[0,1,2],'timer']);
 const t=syn('unit-past'),past=t.ts({op:'arm',kind:'statement',action:'hold-unit-reply:2',match:'UPDATE n_feed SET last_success_at='});
 const c2=await viaProxy(t.alias),out=await c2.pipeline(writeOf(213,bucketOf(23)));assert.ok(out[0].error);
 assert.deepEqual(t.witness().errors.map(e=>[e.kind,e.arming,e.reason]),[['statement-shape',past.arming,'application unit 2 of 2']]);
 assert.notEqual(await success(FEED),213);
 assert.throws(()=>t.ts({op:'arm',kind:'statement',action:'hold-unit-reply:x',match:'UPDATE'}),/unknown statement action/);
});

// ================================================================ interactive-hold
const interactiveSteps=async(r,steps)=>{const out=[];for(const [q,v] of steps){r.write(unit(q,v));out.push(await r.reply());}return out;};
const FIRST_PREFIX='SELECT observation_id,reason_counts_json';
await test('interactive-hold: the B17 transaction awaiting each reply, BEGIN and gate relayed, its first application unit held unforwarded until release',async()=>{
 const s=syn('interactive'),arm=s.ts({op:'arm',kind:'statement',action:'interactive-hold',match:FIRST_PREFIX}),r=await raw(s.alias);
 const prefix=await interactiveSteps(r,[['BEGIN'],[GATE]]);assert.ok(prefix.every(x=>x.error===null));
 let answered=false;r.write(unit(INTERACTIVE_FIRST,[FEED,Math.floor(Date.now()/1000)]));const reply=r.reply().then(x=>{answered=true;return x;});
 const o=await waitFor('the hold',()=>tagsOf(s,arm.arming));
 await sleep(100);assert.equal(answered,false);
 assert.deepEqual([o.action,o.interactive.prefix,o.interactive.shape,o.statements,o.timing.prefix_relayed,o.timing.prefix_tags,o.timing.unit],['interactive-hold',['BEGIN'],'B17',[INTERACTIVE_FIRST],true,['BEGIN','SELECT 1'],2]);
 assert.equal(o.tags.length,2,'the held unit was not forwarded');assert.deepEqual(s.witness().errors,[]);
 assert.deepEqual(s.ts({op:'release',fire:o.fire_id}).released,[o.fire_id]);
 assert.equal((await reply).error,null);assert.equal((await interactiveSteps(r,[['COMMIT']]))[0].error,null);r.socket.destroy();
 const after=opOf(s.witness(),o.fire_id);
 assert.deepEqual([after.commit_tag,after.timing.relays.map(x=>x.sql),after.timing.released.how],['COMMIT',[INTERACTIVE_FIRST,'COMMIT'],'release']);
 assert.ok(after.forwarded<=o.fire&&s.witness().fires[0].forwarded>=s.witness().fires[0].released);
 assert.deepEqual(s.problems(),[]);
});
await test('interactive-hold never fires on a pipelined transaction, and a different first statement is still the interactive-shape error',async()=>{
 const s=syn('interactive-pipelined'),arm=s.ts({op:'arm',kind:'statement',action:'interactive-hold',match:FIRST_PREFIX});
 const c=await viaProxy(s.alias);assert.ok((await c.pipeline([['BEGIN'],[GATE],[INTERACTIVE_FIRST,[FEED,0]],['COMMIT']])).every(x=>x.result));await c.close();
 assert.deepEqual([s.witness().fires.length,s.witness().errors.length],[0,0]);
 const r=await raw(s.alias);await interactiveSteps(r,[['BEGIN'],[GATE]]);r.write(unit('SELECT 2 AS other'));await assert.rejects(r.reply());
 assert.deepEqual(s.witness().errors.map(e=>[e.kind,e.reason]),[['interactive-shape','first application statement']]);
 s.ts({op:'expect',arming:arm.arming});assert.equal(s.problems().length,1);
});

// ================================================================ release-operation
// A relay between a second proxy and PostgreSQL that writes every backend
// chunk to the proxy in 1-5 byte pieces, one event-loop turn apart: the
// proxy reassembles each reply from fragments.
async function fragmentingRelay(){
 let pieces=0,bytes=0;
 const server=net.createServer(client=>{
  const up=net.connect({host,port});up.setNoDelay(true);client.setNoDelay(true);
  let queue=Promise.resolve();
  client.on('data',d=>up.write(d));
  up.on('data',d=>{queue=queue.then(async()=>{for(let i=0;i<d.length;){const n=1+(i%5);client.write(d.subarray(i,i+n));pieces++;i+=n;await new Promise(r=>setImmediate(r));}bytes+=d.length;});});
  client.on('close',()=>up.end());up.on('close',()=>queue.then(()=>client.end()));
  client.on('error',()=>{});up.on('error',()=>{});
 });
 server.listen(0,'127.0.0.1');await once(server,'listening');server.unref();
 return {port:server.address().port,stats:()=>({pieces,bytes}),close:()=>server.close()};
}
relay=await fragmentingRelay();
fragmenting=new WireProxy({host:'127.0.0.1',port:relay.port,owner:{user:OWNER,password:OWNER_PASSWORD}});await fragmenting.listen();
for(const [px,via] of [[proxy,'direct'],[fragmenting,'fragmented']]){
 await test(`release-operation (${via}): every reply already buffered is relayed in order at one instant`,async()=>{
  const s=syn(`all-${via}`,px),arm=s.ts({op:'arm',kind:'statement',action:'hold-response',match:'UPDATE n_feed SET last_success_at='});
  const before=relay.stats(),c=await viaProxy(s.alias,s.port);let done=false;const pending=c.pipeline(writeOf(301,bucketOf(11))).then(r=>{done=true;return r;});
  const o=await waitFor('every reply buffered',()=>{const x=tagsOf(s,arm.arming);return x?.tags.length===5&&x;});
  await sleep(50);assert.equal(done,false);assert.equal(o.timing,undefined,'nothing relayed before the call');
  const out=s.ts({op:'release-operation',operation:o.id});
  assert.deepEqual(out.relayed,[0,1,2,3,4]);
  assert.ok((await pending).every(x=>x.result));await c.close();
  const after=opOf(s.witness(),o.fire_id),spread=after.timing.relays.at(-1).at-after.timing.relays[0].at;
  assert.deepEqual([after.timing.relays.map(r=>[r.unit,r.late]),after.timing.late_relays,after.commit_relayed],[[[0,false],[1,false],[2,false],[3,false],[4,false]],0,true]);
  assert.ok(spread<20,`relayed within ${spread} ms`);
  if(via==='fragmented'){const st=relay.stats();assert.ok(st.pieces-before.pieces>(st.bytes-before.bytes)/5,JSON.stringify(st));}
  report.push(`release-operation ${via}, all buffered: 5 relays within ${spread.toFixed(2)} ms`);
  assert.deepEqual(s.problems(),[]);
 });
 await test(`release-operation (${via}): called when only BEGIN's reply has arrived, the later replies are relayed as they arrive (late_relays)`,async()=>{
  // The gate's row lock, taken by another session, keeps every reply after BEGIN's back.
  const locker=await Client.connect({host,port,user:OWNER,password:OWNER_PASSWORD,database:db,application:'test-timing-locker',searchPath:'opencast, pg_catalog'});
  try{
   await locker.query('BEGIN');await locker.query('SELECT id FROM n_poll_dispatch WHERE id=1 FOR UPDATE');
   const s=syn(`late-${via}`,px),arm=s.ts({op:'arm',kind:'statement',action:'hold-response',match:'UPDATE n_feed SET last_success_at='});
   const c=await viaProxy(s.alias,s.port),pending=c.pipeline(writeOf(302,bucketOf(12)));
   const o=await waitFor('the BEGIN reply',()=>{const x=tagsOf(s,arm.arming);return x?.tags.length===1&&x;});
   await sleep(150);assert.deepEqual(tagsOf(s,arm.arming).tags,['BEGIN'],'the gate is still waiting on the lock');
   const out=s.ts({op:'release-operation',operation:o.id});assert.deepEqual(out.relayed,[0]);
   const released=out.released_at;await sleep(50);
   await locker.query('COMMIT');
   assert.ok((await pending).every(x=>x.result));await c.close();
   const t=opOf(s.witness(),o.fire_id).timing;
   assert.deepEqual([t.relays.map(r=>[r.unit,r.late]),t.late_relays,t.released_at],[[[0,false],[1,true],[2,true],[3,true],[4,true]],4,released]);
   assert.ok(t.relays.slice(1).every(r=>r.at>released+50));
   assert.equal(await success(FEED),302);assert.deepEqual(s.problems(),[]);
  }finally{await locker.close().catch(()=>{});}
 });
}
await test('the accepted hold-response on a multi-unit write relays one unit per release; release-operation relays the rest',async()=>{
 const s=syn('one-per-release'),arm=s.ts({op:'arm',kind:'statement',action:'hold-response',match:'UPDATE n_feed SET last_success_at='});
 const c=await viaProxy(s.alias),pending=c.pipeline(writeOf(303,bucketOf(13)));
 const o=await waitFor('every reply buffered',()=>{const x=tagsOf(s,arm.arming);return x?.tags.length===5&&x;});
 assert.deepEqual(s.ts({op:'release',fire:o.fire_id}).released,[o.fire_id]);
 await sleep(100);assert.equal(opOf(s.witness(),o.fire_id).commit_relayed,false,'one release leaves the write incomplete');
 assert.deepEqual(s.ts({op:'release-operation',fire:o.fire_id}).relayed,[1,2,3,4]);
 assert.ok((await pending).every(x=>x.result));await c.close();assert.deepEqual(s.problems(),[]);
});
await test('release-operation: hold-response with release_after_ms 300 is released operation-wide; a hold-request\'s units are forwarded and all replies late',async()=>{
 const s=syn('timed-op');s.ts({op:'arm',kind:'statement',action:'hold-response',match:'UPDATE n_feed SET last_success_at=',release_after_ms:300});
 const c=await viaProxy(s.alias),begin=now();assert.ok((await c.pipeline(writeOf(304,bucketOf(14)))).every(x=>x.result));const wall=now()-begin;await c.close();
 let w=s.witness(),o=opOf(w,w.fires[0].id);
 assert.deepEqual([o.timing.released.how,o.timing.relays.map(r=>r.unit),o.commit_relayed],['timer',[0,1,2,3,4],true]);assert.ok(wall>=300,`wall ${wall}`);
 const r=syn('request-op'),arm=r.ts({op:'arm',kind:'statement',action:'hold-request',match:'SELECT f.origin_key'});
 const c2=await viaProxy(r.alias),read=c2.query(CLAIM,[FEED]);
 const f=await waitFor('the fire',()=>r.witness().fires[0]);
 assert.deepEqual(r.ts({op:'release-operation',fire:f.id}).relayed,[]);
 assert.equal((await read).rows.length,1);await c2.close();
 w=r.witness();o=opOf(w,f.id);
 assert.deepEqual([o.timing.relays.map(x=>[x.unit,x.late]),o.timing.late_relays,w.released[0].how,f.arming],[[[0,true]],1,'release-operation',arm.arming]);
 assert.deepEqual([s.problems(),r.problems()],[[],[]]);
});
await test('release-operation: hold-response with release_after_ms 0 is released operation-wide by its timer once the operation holds its fire',async()=>{
 const s=syn('timed-op-zero');s.ts({op:'arm',kind:'statement',action:'hold-response',match:'UPDATE n_feed SET last_success_at=',release_after_ms:0});
 const c=await viaProxy(s.alias);assert.ok((await c.pipeline(writeOf(305,bucketOf(15)))).every(x=>x.result));await c.close();
 const w=s.witness(),f=w.fires[0],o=opOf(w,f.id),t=o.timing;
 assert.deepEqual([w.fires.length,f.action,w.released.map(r=>[r.fire,r.how]),t.released.how,t.relays.map(r=>r.unit),o.commit_relayed,w.errors],[1,'hold-response',[[f.id,'timer']],'timer',[0,1,2,3,4],true,[]]);
 assert.ok(t.released_at>=f.at&&t.released_at-f.at<EPSILON_MS&&t.relays.every(r=>r.at>=t.released_at),JSON.stringify({fire:f.at,released_at:t.released_at,relays:t.relays.map(r=>r.at)}));
 assert.equal(await success(FEED),305);
 report.push(`zero-delay hold-response: released operation-wide ${(t.released_at-f.at).toFixed(2)} ms after fire, 5 relays after it (${t.late_relays} late)`);
 assert.deepEqual(await proxy.teardown([s.alias]),[]);
},10000);
await test('release-operation refuses an unknown operation and one that holds nothing, and leaves hold-forever held',async()=>{
 const s=syn('op-refused');
 assert.throws(()=>s.ts({op:'release-operation',operation:'O0'}),/no operation O0/);
 const c=await viaProxy(s.alias);await c.query(CLAIM,[FEED]);await c.close();
 assert.throws(()=>s.ts({op:'release-operation',operation:s.witness().operations[0].id}),/holds nothing/);
 s.ts({op:'arm',kind:'statement',action:'hold-forever',match:'SELECT f.origin_key'});
 const c2=await viaProxy(s.alias);c2.query(CLAIM,[FEED]).catch(()=>{});
 const f=await waitFor('the fire',()=>s.witness().fires[0]);
 assert.deepEqual(s.ts({op:'release-operation',fire:f.id}).refused,[f.id]);
 c2.socket.destroy();await waitFor('the discard',()=>s.witness().fires[0].discarded);
 s.ts({op:'expect',fire:f.id,outcome:'discarded'});
 assert.equal(s.witness().errors.length,2);
});

// ================================================================ handshake hooks
const startupOnly=async alias=>{const socket=net.connect({host:'127.0.0.1',port:proxy.listenPort});await once(socket,'connect');
 const params=Buffer.concat([cstr('user'),cstr(RUNTIME),cstr('database'),cstr(alias),Buffer.from([0])]);
 socket.on('error',()=>{});socket.write(Buffer.concat([i32(params.length+8),i32(196608),params]));return socket;};
const eventsOf=(s,kinds)=>s.witness().timing.events.filter(e=>kinds.includes(e.kind)).map(e=>e.kind);
await test('startup-hold released at 2,000 ms: nothing goes upstream until then, then a normal read',async()=>{
 const s=syn('startup-hold'),arm=s.ts({op:'arm',kind:'startup',action:'startup-hold',release_after_ms:2000});
 const begin=now(),c=await viaProxy(s.alias),connected=now()-begin;
 assert.equal((await c.query(CLAIM,[FEED])).rows.length,1);await c.close();
 const w=s.witness(),f=w.fires[0],r=w.connections[0];
 assert.deepEqual([f.arming,f.hook,f.action,r.startup.fire,w.released[0].how],[arm.arming,'startup','startup-hold',f.id,'timer']);
 assert.ok(f.released-f.at>=2000&&f.released-f.at<2000+EPSILON_MS,`released ${f.released-f.at}`);
 assert.ok(connected>=2000&&r.Z_relay>f.released,`connected after ${connected}`);
 assert.deepEqual(eventsOf(s,['startup-seen','fire','release']),['startup-seen','fire','release']);
 assert.equal(r.frontend_p,2);assert.equal(w.operations.length,1);
 report.push(`startup-hold 2,000 ms: released ${(f.released-f.at).toFixed(1)} ms after fire, connect ${connected.toFixed(1)} ms`);
 assert.deepEqual(s.problems(),[]);
});
await test('startup-hold released by release-operation on its fire, then by release refused as already released',async()=>{
 const s=syn('startup-op');s.ts({op:'arm',kind:'startup',action:'startup-hold'});
 const pending=viaProxy(s.alias),f=await waitFor('the fire',()=>s.witness().fires[0]);
 await sleep(200);assert.equal(s.witness().connections[0].Z_relay,null);
 assert.deepEqual(s.ts({op:'release-operation',fire:f.id}),{fire:f.id,released:[f.id]});
 const c=await pending;assert.equal((await c.query(CLAIM,[FEED])).rows.length,1);await c.close();
 assert.deepEqual(s.ts({op:'release',fire:f.id}).released,[f.id]);assert.deepEqual(s.problems(),[]);
});
await test('startup-close: the proxy closes on the StartupMessage server-first, no upstream; the next connection is untouched',async()=>{
 const s=syn('startup-close'),arm=s.ts({op:'arm',kind:'startup',action:'startup-close'});
 await assert.rejects(viaProxy(s.alias));
 const r=await waitFor('the close',()=>{const x=s.witness().connections[0];return x?.close&&x;});
 const w=s.witness(),f=w.fires[0];
 assert.deepEqual([f.arming,f.action,r.closed_by,r.terminate_sent,r.upstream_close,r.Z_relay,r.startup.fire],[arm.arming,'startup-close','startup-close',null,null,null,f.id]);
 assert.deepEqual(eventsOf(s,['startup-seen','fire','close']),['startup-seen','fire','close']);
 assert.throws(()=>s.ts({op:'release',fire:f.id}),/no fired hold/);
 const c=await viaProxy(s.alias);assert.equal((await c.query(CLAIM,[FEED])).rows.length,1);await c.close();
 await waitFor('every connection closed',()=>s.a.open.size===0);assert.equal(s.witness().errors.length,1);
});
await test('a held startup whose client goes away is discarded; expect accepts it; malformed startup armings are refused',async()=>{
 const s=syn('startup-gone');s.ts({op:'arm',kind:'startup',action:'startup-hold'});
 const socket=await startupOnly(s.alias),f=await waitFor('the fire',()=>s.witness().fires[0]);
 socket.destroy();await waitFor('the discard',()=>s.witness().fires[0].discarded);
 assert.equal(s.witness().discarded[0].reason,'client');assert.equal(s.a.open.size,0);
 assert.match(s.problems().join(),new RegExp(`fire ${f.id} \\(startup startup-hold\\) was discarded and not expected`));
 s.ts({op:'expect',fire:f.id,outcome:'discarded'});assert.deepEqual(s.problems(),[]);
 const t=syn('startup-refused');
 assert.throws(()=>t.ts({op:'arm',kind:'startup',action:'startup-close',release_after_ms:5}),/needs startup-hold/);
 assert.throws(()=>t.ts({op:'arm',kind:'startup',action:'startup-hold',match:'SELECT'}),/not a statement/);
 assert.throws(()=>t.ts({op:'arm',kind:'startup',action:'hold-request'}),/unknown startup action/);
});

// ================================================================ the Worker's held writes
// RecordPollStat (A13) through the storage-fixture build's /operation, with
// no deadline_in_ms: the transaction's STATEMENT_MS cap fires first.
const TOKEN=randomBytes(16).toString('hex');
const ENTRY=readFileSync(new URL('./fixture-entry.mjs',import.meta.url));
const fixtureMf=new Miniflare(convertV4MiniflareOptions({cf:false,inspectorPort:0,workers:[storage.bind({name:'fixture',modulesRoot:FIXTURE_BUILD,
 modules:[{type:'ESModule',path:FIXTURE_BUILD+'/fixture-entry.mjs',contents:ENTRY},{type:'ESModule',path:FIXTURE_BUILD+'/index.js'},{type:'CompiledWasm',path:FIXTURE_BUILD+'/index_bg.wasm'}],
 compatibilityDate:'2026-09-30',compatibilityFlags:['enable_request_signal'],bindings:{SLICE_TOKEN:TOKEN}})]}));
const fixture=storage.testStorage('fixture');
const redeliveries=async t=>(await owner.query('SELECT redeliveries FROM n_poll_stat WHERE bucket=$1',[Math.floor(t/3600)])).rows[0]?.redeliveries??0;
const bodyOf=text=>{try{return JSON.parse(text);}catch{return text;}};
async function stat(headers={}){
 const worker=await fixtureMf.getWorker('fixture'),t=Math.floor(Date.now()/1000),before=await redeliveries(t),started=now();
 const r=await worker.fetch('https://fixture.invalid/operation',{method:'POST',headers:{authorization:`Bearer ${TOKEN}`,...headers},body:JSON.stringify({request:{operation:'record_poll_stat',counter:'redeliveries',now:t}})});
 return {status:r.status,body:bodyOf(await r.text()),wall:now()-started,ended:now(),committed:await redeliveries(t)-before};
}
try{
 await fixtureMf.ready;
 await test('Worker, hold-commit-reply forever: deadline/commit/unknown; the ROLLBACK spends its full CLOSE_MS behind the held reply, then finish closes',async()=>{
  const arm=fixture({op:'arm',kind:'statement',action:'hold-commit-reply',match:REDELIVERY,forever:true});
  const x=await stat();
  assert.deepEqual([x.status,x.body.ok,x.body.retryable,x.body.error?.kind,x.body.error?.phase,x.body.error?.outcome],[200,false,false,'deadline','commit','unknown'],JSON.stringify(x.body));
  const w=await waitFor('the close',()=>{const v=fixture({op:'witness'}),f=v.fires.find(y=>y.arming===arm.arming);return f&&opOf(v,f.id).close&&v;});
  const f=w.fires.find(y=>y.arming===arm.arming),o=opOf(w,f.id);
  assert.deepEqual([o.commit_tag,o.commit_relayed,o.timing.rollback?.sql,o.timing.discarded?.reason,o.timing.relays.map(r=>r.unit),o.timing.unit],['COMMIT',false,'ROLLBACK','client',[0,1,2],3]);
  assert.ok(o.timing.relays[2].sql.startsWith(REDELIVERY),o.timing.relays[2].sql);
  assert.equal(x.committed,1,'the held reply concealed a committed write');
  const lower=o.close-o.Z_relay,span=o.close-o.fire,cleanup=o.close-o.timing.rollback.at,held=o.timing.rollback.at-o.timing.held_reply.at;
  assert.ok(lower>=STATEMENT_MS,`close - Z_relay ${lower}`);
  assert.ok(span<=STATEMENT_MS+2*CLOSE_MS+EPSILON_MS,`close - fire ${span}`);
  // The rollback's reply never reaches the Worker, so its cleanup cap runs out.
  assert.ok(cleanup>=CLOSE_MS-EPSILON_MS/5&&cleanup<=2*CLOSE_MS+EPSILON_MS,`close - rollback ${cleanup}`);
  report.push(`Worker hold-commit-reply forever: handler_ms ${x.body.metrics?.handler_ms}, close-Z_relay ${lower.toFixed(1)}, close-fire ${span.toFixed(1)}, held-reply->rollback ${held.toFixed(1)}, close-rollback ${cleanup.toFixed(1)} ms (CLOSE_MS ${CLOSE_MS})`);
  fixture({op:'expect',fire:f.id,outcome:'discarded'});
 },30000);
 await test('Worker, hold-commit-reply released after 1,000 ms: the write completes, no ROLLBACK, the COMMIT reply relayed',async()=>{
  const arm=fixture({op:'arm',kind:'statement',action:'hold-commit-reply',match:REDELIVERY,release_after_ms:1000});
  const x=await stat();
  assert.deepEqual([x.status,x.body.ok,x.committed],[200,true,1],JSON.stringify(x.body));
  const w=fixture({op:'witness'}),f=w.fires.find(y=>y.arming===arm.arming),o=opOf(w,f.id);
  assert.deepEqual([o.commit_relayed,o.timing.rollback,o.timing.released.how,o.timing.relays.at(-1).unit],[true,null,'timer',o.timing.unit]);
  assert.ok(x.wall>=1000&&x.wall<1000+STATEMENT_MS,`wall ${x.wall}`);
  report.push(`Worker hold-commit-reply 1,000 ms: wall ${x.wall.toFixed(1)} ms, released ${(f.released-f.at).toFixed(1)} ms after fire`);
 },30000);
 await test('Worker, hold-unit-reply:0 forever: the application statement\'s reply never comes; deadline, then the ROLLBACK spends its CLOSE_MS',async()=>{
  const arm=fixture({op:'arm',kind:'statement',action:'hold-unit-reply:0',match:REDELIVERY,forever:true});
  const x=await stat();
  assert.deepEqual([x.status,x.body.ok,x.body.error?.kind,x.body.error?.outcome],[200,false,'deadline','unknown'],JSON.stringify(x.body));
  const w=await waitFor('the close',()=>{const v=fixture({op:'witness'}),f=v.fires.find(y=>y.arming===arm.arming);return f&&opOf(v,f.id).close&&v;});
  const f=w.fires.find(y=>y.arming===arm.arming),o=opOf(w,f.id);
  assert.deepEqual([o.timing.unit,o.timing.relays.map(r=>r.sql),o.commit_tag,o.commit_relayed,o.timing.rollback?.sql],[2,['BEGIN','gate'],'COMMIT',false,'ROLLBACK']);
  const lower=o.close-o.Z_relay,span=o.close-o.fire,cleanup=o.close-o.timing.rollback.at;
  assert.ok(lower>=STATEMENT_MS&&span<=STATEMENT_MS+2*CLOSE_MS+EPSILON_MS,`close - Z_relay ${lower}, close - fire ${span}`);
  assert.ok(cleanup>=CLOSE_MS-EPSILON_MS/5&&cleanup<=2*CLOSE_MS+EPSILON_MS,`close - rollback ${cleanup}`);
  report.push(`Worker hold-unit-reply:0 forever: phase ${x.body.error?.phase}, handler_ms ${x.body.metrics?.handler_ms}, close-fire ${span.toFixed(1)}, close-rollback ${cleanup.toFixed(1)} ms; committed ${x.committed}`);
  fixture({op:'expect',fire:f.id,outcome:'discarded'});
 },30000);
 // The fixture close delay: finish()'s close future waits this long inside
 // its CLOSE_MS race. A read's reply is relayed (the op's `ended`) before the
 // Worker's finish() starts, so close - ended >= the delay.
 const call=async(path,body)=>{const worker=await fixtureMf.getWorker('fixture');const r=await worker.fetch('https://fixture.invalid'+path,{method:'POST',headers:{authorization:`Bearer ${TOKEN}`},body:typeof body==='string'?body:JSON.stringify(body)});return {status:r.status,text:await r.text()};};
 const readClosed=async ms=>{
  assert.deepEqual(await call('/test/close-delay',String(ms)),{status:200,text:JSON.stringify({close_delay_ms:ms})});
  const before=fixture({op:'witness'}).operations.length,r=await call('/operation',{request:{operation:'read_control',control:'cleanup'}});
  assert.equal(r.status,200);assert.equal(JSON.parse(r.text).ok,true,r.text);
  const o=await waitFor('the close',()=>{const x=fixture({op:'witness'}).operations.slice(before).find(y=>y.type==='read');return x?.close&&x;});
  return {span:o.close-o.ended,handler_ms:JSON.parse(r.text).response.metrics.handler_ms};
 };
 await test('fixture close-delay: 400 ms widens the close race by 400 ms; 0 restores it; 600 is cut at CLOSE_MS; a malformed delay is refused',async()=>{
  try{
   const base=await readClosed(0),slow=await readClosed(400),cut=await readClosed(600),again=await readClosed(0);
   assert.ok(base.span<EPSILON_MS/5&&again.span<EPSILON_MS/5,`no delay: ${base.span}, ${again.span}`);
   assert.ok(slow.span>=400&&slow.span<=400+EPSILON_MS,`400 ms delay: close - ended ${slow.span}`);
   assert.ok(cut.span>=CLOSE_MS&&cut.span<=CLOSE_MS+EPSILON_MS,`600 ms delay cut by CLOSE_MS: ${cut.span}`);
   report.push(`fixture close-delay: close - ended ${base.span.toFixed(1)} / ${slow.span.toFixed(1)} / ${cut.span.toFixed(1)} / ${again.span.toFixed(1)} ms for 0 / 400 / 600 / 0; handler_ms ${base.handler_ms} / ${slow.handler_ms} / ${cut.handler_ms} / ${again.handler_ms}`);
   for(const bad of ['-1','x','12001'])assert.equal((await call('/test/close-delay',bad)).status,400);
  }finally{await call('/test/close-delay','0');}
 },30000);
 // AbandonPoisoned (B17) through /slice-e/operation: the one interactive executor.
 const abandon=async(headers={})=>{const worker=await fixtureMf.getWorker('fixture'),started=now();
  const r=await worker.fetch('https://fixture.invalid/slice-e/operation',{method:'POST',headers:{authorization:`Bearer ${TOKEN}`,...headers},body:JSON.stringify({request:{operation:'abandon_poisoned',feed:FEED,now:Math.floor(Date.now()/1000)}})});
  return {status:r.status,body:bodyOf(await r.text()),wall:now()-started,ended:now()};};
 await test('Worker, interactive-hold on AbandonPoisoned released after 500 ms: the prefix relayed, no proxy error, the transaction completes',async()=>{
  const arm=fixture({op:'arm',kind:'statement',action:'interactive-hold',match:FIRST_PREFIX,release_after_ms:500});
  const x=await abandon();assert.deepEqual([x.status,x.body.ok],[200,true],JSON.stringify(x.body));
  const w=fixture({op:'witness'}),f=w.fires.find(y=>y.arming===arm.arming),o=opOf(w,f.id);
  assert.deepEqual([o.interactive.shape,o.timing.prefix_relayed,o.timing.prefix_tags,o.timing.released.how,o.commit_tag,o.commit_relayed],['B17',true,['BEGIN','SELECT 1'],'timer','COMMIT',true]);
  assert.deepEqual(w.errors,[]);assert.ok(x.wall>=500,`wall ${x.wall}`);
  report.push(`Worker interactive-hold 500 ms: wall ${x.wall.toFixed(1)} ms, prefix ${o.interactive.prefix.join(',')}`);
 },30000);
 await test('Worker, interactive-hold never released: the query cap expires, the ROLLBACK discards the hold and waits out the transaction\'s remaining budget',async()=>{
  const arm=fixture({op:'arm',kind:'statement',action:'interactive-hold',match:FIRST_PREFIX});
  const x=await abandon();
  assert.deepEqual([x.status,x.body.ok,x.body.error?.kind],[200,false,'deadline'],JSON.stringify(x.body));
  const w=await waitFor('the close',()=>{const v=fixture({op:'witness'}),f=v.fires.find(y=>y.arming===arm.arming);return f&&opOf(v,f.id).close&&v;});
  const f=w.fires.find(y=>y.arming===arm.arming),o=opOf(w,f.id),cleanup=o.close-o.timing.rollback.at,held=o.timing.rollback.at-o.fire;
  assert.deepEqual([o.timing.rollback.sql,o.timing.discarded.reason,o.tags.at(-1),o.rollback_relayed!==null],['ROLLBACK','client-rollback','ROLLBACK',true]);
  // The held statement's own cap: its timer started before the unit reached the proxy.
  assert.ok(held<=STATEMENT_MS+EPSILON_MS&&o.timing.rollback.at-o.Z_relay>=STATEMENT_MS,`fire -> rollback ${held}`);
  // The transaction's timer starts after connect resolves, after Z_relay, so this
  // remaining budget is a lower bound; the close then takes at most CLOSE_MS.
  const remaining=Math.min(STATEMENT_MS,TRANSACTION_MS-(o.timing.rollback.at-o.Z_relay));
  assert.ok(cleanup>=remaining-EPSILON_MS/5&&cleanup<=remaining+CLOSE_MS+EPSILON_MS,`close - rollback ${cleanup}, remaining ${remaining}`);
  report.push(`Worker interactive-hold forever: ${JSON.stringify(x.body.error)} handler_ms ${x.body.metrics?.handler_ms}, fire->rollback ${held.toFixed(1)}, close-rollback ${cleanup.toFixed(1)} ms against the remaining ${remaining.toFixed(1)} ms (not CLOSE_MS)`);
  fixture({op:'expect',fire:f.id,outcome:'discarded'});
 },30000);
 // Both cancellation forms, each fired only after the proxy's fire witness of
 // the hold on the statement in flight: the core token (/test/cancel-core)
 // ends the core race with Cancelled while the invocation keeps running; the
 // owner abort (the entry's AbortSignal) disposes the whole future at once.
 const cancelCases=[['ordinary write','hold-unit-reply:0',REDELIVERY,stat],['interactive executor','interactive-hold',FIRST_PREFIX,abandon]];
 for(const [what,action,match,run] of cancelCases){
  await test(`Worker, ${what}: /test/cancel-core after the hold fired ends the core race Cancelled; the invocation answers`,async()=>{
   const arm=fixture({op:'arm',kind:'statement',action,match}),pending=run();
   const f=await waitFor('the fire',()=>fixture({op:'witness'}).fires.find(y=>y.arming===arm.arming));
   await sleep(100);const at=now(),r=await call('/test/cancel-core','');assert.equal(r.status,200);
   const x=await pending;
   assert.deepEqual([x.status,x.body.ok,x.body.error?.kind],[200,false,'cancelled'],JSON.stringify(x.body));
   const o=await waitFor('the close',()=>{const y=opOf(fixture({op:'witness'}),f.id);return y.close&&y;});
   assert.ok(o.close-at<=CLOSE_MS+EPSILON_MS,`close ${o.close-at} ms after the cancel`);
   report.push(`Worker ${what} cancel-core: ${JSON.stringify(x.body.error)}, close ${(o.close-at).toFixed(1)} ms and the answer ${(x.ended-at).toFixed(1)} ms after the cancel, closed_by ${o.closed_by}`);
   fixture({op:'expect',fire:f.id,outcome:'discarded'});
  },30000);
  await test(`Worker, ${what}: the owner abort after the hold fired disposes the invocation at once (499) and closes the transport`,async()=>{
   const key=`abort-${action}`,arm=fixture({op:'arm',kind:'statement',action,match}),pending=run({'x-test-execution':key});
   const f=await waitFor('the fire',()=>fixture({op:'witness'}).fires.find(y=>y.arming===arm.arming));
   await sleep(100);const at=now(),r=await call('/__abort',key);assert.deepEqual(JSON.parse(r.text),{found:true});
   const x=await pending;assert.deepEqual([x.status,x.body],[499,'cancelled']);
   const o=await waitFor('the close',()=>{const y=opOf(fixture({op:'witness'}),f.id);return y.close&&y;});
   assert.ok(o.close-at<=EPSILON_MS,`close ${o.close-at} ms after the abort`);
   report.push(`Worker ${what} owner abort: 499, close ${(o.close-at).toFixed(1)} ms and the answer ${(x.ended-at).toFixed(1)} ms after the abort, closed_by ${o.closed_by}`);
   fixture({op:'expect',fire:f.id,outcome:'discarded'});
  },30000);
 }
}finally{await fixtureMf.dispose();}

} finally {
 for(const [px,alias] of synthetic)px.unregister(alias);
 await fragmenting?.close();relay?.close();
 await owner.close().catch(()=>{});
 await test('storage.dispose: the fixture alias carries a clean witness, and the database is dropped',()=>storage.dispose());
}
for(const line of report)console.log('REPORT',line);
console.log(`${passed} passed, ${failed} failed`);
process.exitCode=failed?1:0;
