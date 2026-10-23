// proxy.mjs, hooks.mjs and storage.mjs's proxied bind against the local
// topology (Server/NotificationsWorker/postgres/local/local-postgres.sh status
// exits 0). Synthetic clients drive the wire; real Workers drive the
// authentication gate and the companion probe:
//  - the authentication relay: SCRAM through the proxy (two p, a Z), repeated
//    SSLRequest/GSSENCRequest, one-byte frames, coalesced frames, a wrong
//    password (28P01 relayed, the server closes first), an unknown alias;
//  - the eight actions, fragmented and delayed pipelining, the interactive
//    prefix, the side-write rules, a hold whose client closed first, the three
//    state answers, the arming and fire witness rules, teardown through
//    storage.dispose, the counters (rows from tags, exclusivity over the whole
//    invocation window, the 800/799 control);
//  - the deadline bands' delayed-frame control (synthetic) and slow-rollback
//    control (the storage-fixture Worker), and the companion probe of the held
//    RecordPollStat's error kind, phase and outcome;
//  - THE AUTHENTICATION GATE: a proxied runtime-role Worker identity, read and
//    write: the packaged Notifications Worker on opencast_local_runtime,
//    pinned, through the proxy and, in its own Miniflare, direct.
// Run from the repo root: node Server/NotificationsWorker/tests/postgres/test-proxy.mjs
// It needs Server/NotificationsWorker/build (the packaged Worker) and the
// storage-fixture build at OPENCAST_FIXTURE_BUILD (default
// /tmp/opencast-storage-fixture-build): in Server/NotificationsWorker,
// worker-build --release --out-dir <dir> --no-default-features --features storage-fixture
// OPENCAST_PG_HOST and OPENCAST_PG_PORT override 127.0.0.1:55432. Miniflare and the proxy need loopback sockets.
import assert from 'node:assert/strict';
import net from 'node:net';
import {once} from 'node:events';
import {existsSync} from 'node:fs';
import {randomBytes,createHash} from 'node:crypto';
import {fileURLToPath} from 'node:url';
import {setTimeout as sleep} from 'node:timers/promises';
import {Miniflare,convertV4MiniflareOptions} from 'miniflare';
import {Client,GATE,encodeParameter,scramClientFirst,scramClientFinal,verifyServerFinal,PostgresError} from './pg.mjs';
import {INTERACTIVE_FIRST} from './hooks.mjs';
import {DESTROY_MS} from './proxy.mjs';
import {until} from './timing.mjs';
import {openStorage} from '../storage.mjs';
import {compatibilityDate,compatibilityFlags} from '../runtime-compatibility.mjs';

if(process.env.OPENCAST_TEST_STORAGE!==undefined&&process.env.OPENCAST_TEST_STORAGE!=='postgres')throw Error('test-proxy.mjs runs postgres storage: launch it without OPENCAST_TEST_STORAGE');
const port=Number(process.env.OPENCAST_PG_PORT??55432),host=process.env.OPENCAST_PG_HOST??'127.0.0.1';
const root=fileURLToPath(new URL('../../',import.meta.url)); // Server/NotificationsWorker/
const FIXTURE_BUILD=process.env.OPENCAST_FIXTURE_BUILD??'/tmp/opencast-storage-fixture-build';
for(const file of [root+'build/index.js',root+'build/index_bg.wasm',FIXTURE_BUILD+'/index.js',FIXTURE_BUILD+'/index_bg.wasm'])
 if(!existsSync(file)){console.log(`not ok missing ${file}`);process.exit(1);}
// The local topology's fixed fixture passwords (local-postgres.sh), never secrets.
const RUNTIME='opencast_local_runtime',RUNTIME_PASSWORD='opencast-local-runtime',OWNER='opencast_local_owner',OWNER_PASSWORD='opencast-local-owner';
// Scheduling allowance between workerd's timers and the proxy's stamps on this
// process's event loop (loopback delivery, two event loops). The deadline
// bands are derived from the operations' caps; this is the only slack, and
// every measured value is printed.
const EPSILON_MS=250;
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

// ---- One storage: its database carries every synthetic alias and the Workers.
const storage=await openStorage().catch(error=>{console.log(`not ok open storage: ${error.message}`);process.exit(1);});
const proxy=storage.proxy,db=storage.databaseName,handle=await storage.database(null);
const owner=await Client.connect({host,port,user:OWNER,password:OWNER_PASSWORD,database:db,application:'test-proxy-owner',searchPath:'opencast, pg_catalog'});
const SYSTEM=(await owner.query('SELECT system_identifier::text AS s FROM pg_control_system()')).rows[0].s;
const feed=async(id,{dispatchUntil=0}={})=>{await owner.query('INSERT INTO n_feed(feed_id,canonical_url,epoch,due_at,dispatch_until) VALUES($1,$2,1,0,$3)',[id,`https://fixture.example/${id}.xml`,dispatchUntil]);return id;};
const row=async id=>(await owner.query('SELECT epoch,observation_generation,schedule_generation,last_success_at,admission_paused FROM n_feed WHERE feed_id=$1',[id])).rows[0];
const FEED=await feed(H('feed-a')),OTHER=await feed(H('feed-b'));
// Synthetic aliases on this database, one per case, outside storage's teardown.
const synthetic=[];
function syn(entry){
 const alias=`${db}.synthetic-${synthetic.length+1}-${entry}`;
 const a=proxy.register({alias,database:db,entry,worker:null});synthetic.push(alias);
 const ts=op=>proxy.handle(alias,op);
 return {alias,a,ts,witness:()=>ts({op:'witness'}),problems:()=>proxy.problems(a)};
}
const viaProxy=alias=>Client.connect({port:proxy.listenPort,user:RUNTIME,password:RUNTIME_PASSWORD,database:alias,application:'test-proxy'});
// The Workers' statement shapes (the hook matchers' prefixes).
const SETTLE='UPDATE n_feed SET last_success_at=$1 WHERE feed_id=$2';
const PUBLISH='UPDATE n_feed SET observation_generation=observation_generation+1 WHERE feed_id=$1';
const CLAIM='SELECT f.origin_key,f.due_at FROM n_feed f WHERE f.feed_id=$1';
const STAT='INSERT INTO n_poll_stat(bucket,handling_failures) VALUES($1,1) ON CONFLICT(bucket) DO UPDATE SET handling_failures=n_poll_stat.handling_failures+1';
const WATCHDOG='SELECT 1 AS late_900';
const READ_OBJECT='SELECT sha256,bytes FROM n_snapshot WHERE object_key=$1';
const REGISTER="INSERT INTO devices(install_id,key_id,device_token,device_token_hash,apns_environment,bundle_id,notifications_enabled,created_at,last_seen_at) VALUES($1,'key',$2,'hash','development','com.example.opencast',1,0,0)";
const txn=(sql,values)=>[['BEGIN'],[GATE],[sql,values],['COMMIT']];
const opOf=(w,fire)=>w.operations.find(o=>o.id===w.fires.find(f=>f.id===fire).op);
const connOf=(w,id)=>w.connections.find(c=>c.conn===id);
const serverFirst=c=>c.terminate_sent!==null&&c.upstream_end!==null&&c.upstream_destroyed===null&&c.upstream_end-c.terminate_sent<DESTROY_MS;

// ---- A raw frontend: exact control of bytes and timing.
const i32=n=>{const b=Buffer.alloc(4);b.writeInt32BE(n);return b;};
const i16=n=>{const b=Buffer.alloc(2);b.writeInt16BE(n);return b;};
const cstr=s=>Buffer.from(s+'\0');
const frame=(kind,body)=>Buffer.concat([Buffer.from(kind),i32(body.length+4),body]);
function fields(body){const out={};let i=0;while(i<body.length&&body[i]!==0){const end=body.indexOf(0,i+1);out[String.fromCharCode(body[i])]=body.subarray(i+1,end).toString();i=end+1;}return out;}
// One extended-protocol unit, as tokio-postgres writes a statement.
function unit(sql,values=[]){
 const p=values.map(encodeParameter);
 return Buffer.concat([frame('P',Buffer.concat([cstr(''),cstr(sql),i16(p.length),...p.map(x=>i32(x.oid))])),
  frame('B',Buffer.concat([cstr(''),cstr(''),i16(0),i16(p.length),...p.map(x=>x.text===null?i32(-1):Buffer.concat([i32(Buffer.byteLength(x.text)),Buffer.from(x.text)])),i16(0)])),
  frame('D',Buffer.concat([Buffer.from('P'),cstr('')])),frame('E',Buffer.concat([cstr(''),i32(0)])),frame('S',Buffer.alloc(0))]);
}
class Raw {
 constructor(socket){
  Object.assign(this,{socket,buffer:Buffer.alloc(0),waiters:[],closed:false,closedAt:null});
  socket.on('data',c=>{this.buffer=Buffer.concat([this.buffer,c]);this.pump();});
  socket.on('close',()=>{this.closed=true;this.closedAt=now();this.pump();});socket.on('error',()=>{});
 }
 pump(){
  while(this.waiters.length){const w=this.waiters[0],v=w.take();
   if(v===undefined){if(!this.closed)return;this.waiters.shift();w.reject(Error('connection closed'));continue;}
   this.waiters.shift();w.resolve(v);}
 }
 wait(take){return new Promise((resolve,reject)=>{this.waiters.push({take,resolve,reject});this.pump();});}
 byte(){return this.wait(()=>{if(!this.buffer.length)return;const b=this.buffer[0];this.buffer=this.buffer.subarray(1);return String.fromCharCode(b);});}
 message(){return this.wait(()=>{if(this.buffer.length<5)return;const size=this.buffer.readInt32BE(1);if(this.buffer.length<size+1)return;
  const m={kind:String.fromCharCode(this.buffer[0]),body:this.buffer.subarray(5,size+1)};this.buffer=this.buffer.subarray(size+1);return m;});}
 // One unit's reply up to ReadyForQuery.
 async reply(){const out={tags:[],rows:0,error:null};for(;;){const m=await this.message();if(m.kind==='C')out.tags.push(m.body.subarray(0,-1).toString());if(m.kind==='D')out.rows++;if(m.kind==='E')out.error??=fields(m.body).C;if(m.kind==='Z')return out;}}
 async write(buf,{fragment=false}={}){if(!fragment){this.socket.write(buf);return;}for(const b of buf){this.socket.write(Buffer.from([b]));await sleep(1);}}
 async query(sql,values){await this.write(unit(sql,values));return this.reply();}
}
async function raw(alias,{password=RUNTIME_PASSWORD,negotiate=[],fragment=false,coalesce=false}={}){
 const socket=net.connect({host:'127.0.0.1',port:proxy.listenPort});socket.setNoDelay(true);await once(socket,'connect');
 const r=new Raw(socket);
 for(const code of negotiate){socket.write(Buffer.concat([i32(8),i32(code)]));r.negotiated=(r.negotiated??'')+await r.byte();}
 const params=Buffer.concat([cstr('user'),cstr(RUNTIME),cstr('database'),cstr(alias),cstr('application_name'),cstr('test-proxy-raw'),Buffer.from([0])]);
 const startup=Buffer.concat([i32(params.length+8),i32(196608),params]);
 const first=scramClientFirst();
 const initial=frame('p',Buffer.concat([cstr('SCRAM-SHA-256'),i32(Buffer.byteLength(first.message)),Buffer.from(first.message)]));
 const auth=async code=>{const m=await r.message();if(m.kind==='E')throw new PostgresError(fields(m.body));assert.equal(m.kind,'R');assert.equal(m.body.readInt32BE(0),code);return m.body.subarray(4);};
 if(coalesce){await r.write(Buffer.concat([startup,initial]));await auth(10);}
 else{await r.write(startup,{fragment});await auth(10);await r.write(initial,{fragment});}
 const final=await scramClientFinal({password,clientNonce:first.nonce,clientFirstBare:first.bare,serverFirst:(await auth(11)).toString()});
 await r.write(frame('p',Buffer.from(final.message)),{fragment});
 verifyServerFinal((await auth(12)).toString(),final.serverSignature);await auth(0);
 for(;;){const m=await r.message();if(m.kind==='E')throw new PostgresError(fields(m.body));if(m.kind==='Z'){r.readyAt=now();return r;}}
}
const relayOf=(s,r)=>s.witness().connections.at(-1);

try {
// ================================================================ authentication
await test('relay: a SCRAM client through the proxy sends two p and the relay stops at Z',async()=>{
 const s=syn('polling'),c=await viaProxy(s.alias);
 assert.equal(c.mechanism,'SCRAM-SHA-256');
 assert.deepEqual((await c.query('SELECT current_database()::text AS d, current_user::text AS u')).rows,[{d:db,u:RUNTIME}]);
 await c.close();
 const r=await waitFor('the upstream close',()=>{const x=s.witness().connections[0];return x?.upstream_close&&x;});
 assert.equal(r.frontend_p,2);assert.deepEqual(r.backend.slice(0,4),['R10','R11','R12','R0']);assert.equal(r.backend.at(-1),'Z');assert.equal(r.backend.at(-2),'K');
 assert.ok(r.Z_relay>r.opened);assert.ok(!JSON.stringify(r).includes('p=')); // never a proof
 assert.equal(r.closed_by,'terminate');assert.ok(serverFirst(r),`server-first Terminate: ${JSON.stringify(r)}`);
});
await test('relay: repeated SSLRequest and GSSENCRequest are answered N until the StartupMessage',async()=>{
 const s=syn('polling'),r=await raw(s.alias,{negotiate:[80877103,80877104,80877103]});
 assert.equal(r.negotiated,'NNN');assert.equal((await r.query('SELECT 1 AS one')).rows,1);
 r.socket.destroy();
 const x=s.witness().connections[0];assert.deepEqual(x.negotiation,['SSLRequest','GSSENCRequest','SSLRequest']);assert.equal(x.frontend_p,2);
});
await test('relay: StartupMessage and each p written one byte per write are reassembled',async()=>{
 const s=syn('polling'),r=await raw(s.alias,{fragment:true});
 assert.equal((await r.query('SELECT 1 AS one')).rows,1);r.socket.destroy();
 const x=s.witness().connections[0];assert.equal(x.frontend_p,2);
 assert.ok(x.frontend_chunks>=150,`the proxy read ${x.frontend_chunks} chunks before Z`);
 report.push(`fragmented auth: ${x.frontend_chunks} frontend chunks before Z`);
});
await test('relay: StartupMessage and the first p in one write are split',async()=>{
 const s=syn('polling'),r=await raw(s.alias,{coalesce:true});
 assert.equal((await r.query('SELECT 1 AS one')).rows,1);r.socket.destroy();
 const x=s.witness().connections[0];assert.equal(x.frontend_p,2);assert.equal(x.frontend_chunks,2);
});
await test('relay: a wrong password relays 28P01 and PostgreSQL closes first',async()=>{
 const s=syn('polling');
 await assert.rejects(Client.connect({port:proxy.listenPort,user:RUNTIME,password:'wrong-password',database:s.alias}),e=>e instanceof PostgresError&&e.code==='28P01');
 const x=await waitFor('the close',()=>{const c=s.witness().connections[0];return c?.close&&c;});
 assert.equal(x.auth_error,'28P01');assert.deepEqual(x.backend,['R10','R11','E']);assert.equal(x.closed_by,'server');assert.equal(x.terminate_sent,null);assert.equal(x.Z_relay,null);
});
await test('an unknown alias is refused 3D000 before any upstream connection',async()=>{
 const before=proxy.unrouted.length;
 await assert.rejects(Client.connect({port:proxy.listenPort,user:RUNTIME,password:RUNTIME_PASSWORD,database:`${db}.nobody`}),e=>e instanceof PostgresError&&e.code==='3D000');
 assert.equal(proxy.unrouted.length,before+1);
});

// ================================================================ the eight actions
await test('close-before (P-before_settle): nothing forwarded, the server closes first',async()=>{
 const s=syn('polling'),arm=s.ts({op:'arm',kind:'fault',name:'before_settle'}),c=await viaProxy(s.alias);
 const out=await c.pipeline(txn(SETTLE,[101,FEED]));
 assert.ok(out[0].error&&c.closed);
 const x=await waitFor('the upstream close',()=>{const c0=s.witness().connections[0];return c0.upstream_close&&c0;});
 const w=s.witness(),f=w.fires[0],o=opOf(w,f.id);
 assert.deepEqual([f.arming,f.hook,f.action,o.forwarded,o.closed_by,o.statements],[arm.arming,'P-before_settle','close-before',null,'hook',[SETTLE]]);
 assert.ok(serverFirst(x),JSON.stringify(x));assert.notEqual((await row(FEED)).last_success_at,101);assert.deepEqual(s.problems(),[]);
});
await test('fail-in-place (O-publish_rollback): 42P01 on the last statement, COMMIT becomes ROLLBACK',async()=>{
 const s=syn('observation');s.ts({op:'arm',kind:'fault',name:'publish_rollback'});
 const before=await row(FEED),c=await viaProxy(s.alias),out=await c.pipeline(txn(PUBLISH,[FEED]));await c.close();
 assert.equal(out[2].error.code,'42P01');assert.equal(out[3].result.tag,'ROLLBACK');
 const w=s.witness(),o=opOf(w,w.fires[0].id);
 assert.deepEqual([o.commit_tag,o.commit_relayed,o.action],['ROLLBACK',true,'fail-in-place']);
 assert.equal((await row(FEED)).observation_generation,before.observation_generation);assert.deepEqual(s.problems(),[]);
});
await test('drop-commit-ack (P-after_settle): committed, the COMMIT reply never reaches the client',async()=>{
 const s=syn('polling');s.ts({op:'arm',kind:'fault',name:'after_settle'});
 const c=await viaProxy(s.alias),out=await c.pipeline(txn(SETTLE,[103,FEED]));
 assert.ok(out.slice(0,3).every(x=>x.result)&&out[3].error);
 const w=s.witness(),o=opOf(w,w.fires[0].id);
 assert.deepEqual([o.commit_tag,o.commit_relayed,o.closed_by],['COMMIT',false,'hook']);
 assert.equal((await row(FEED)).last_success_at,103);
});
await test('side-write-first (P-stale_generation): the counted owner write, then the operation',async()=>{
 await owner.query('UPDATE n_feed SET dispatch_until=CASE WHEN feed_id=$1 THEN 5 ELSE 0 END',[OTHER]);
 const s=syn('polling');s.ts({op:'arm',kind:'fault',name:'stale_generation'});
 const before={feed:await row(FEED),other:await row(OTHER)},c=await viaProxy(s.alias),out=await c.pipeline(txn(PUBLISH,[FEED]));await c.close();
 assert.ok(out.every(x=>x.result));
 assert.equal((await row(OTHER)).schedule_generation,before.other.schedule_generation+1);
 assert.equal((await row(FEED)).observation_generation,before.feed.observation_generation+1);
 const f=s.witness().fires[0];assert.equal(f.side.changes,1);assert.deepEqual(f.side.rule,[1,null]);assert.deepEqual(s.problems(),[]);
});
await test('hold-request (P-hang_claim): fault-state from the fired hold; release-hang forwards it',async()=>{
 const s=syn('polling');s.ts({op:'arm',kind:'fault',name:'hang_claim'});
 assert.deepEqual(s.ts({op:'state',which:'fault-state'}),{value:null});
 const c=await viaProxy(s.alias),pending=c.query(CLAIM,[FEED]);
 const f=await waitFor('the fire',()=>s.witness().fires[0]);
 assert.deepEqual(s.ts({op:'state',which:'fault-state'}),{value:'claim_active',fire:f.id});
 const released=s.ts({op:'release',kind:'release-hang'});assert.deepEqual(released.released,[f.id]);
 assert.equal((await pending).rows.length,1);await c.close();
 const w=s.witness(),o=opOf(w,f.id);assert.ok(o.released&&o.forwarded>=o.released);
 assert.deepEqual(s.ts({op:'state',which:'fault-state'}),{value:null});assert.deepEqual(s.problems(),[]);
});
await test('hold-forever (O-watchdog_read_hang): no release; the client\'s close discards it',async()=>{
 const s=syn('observation');s.ts({op:'arm',kind:'fault',name:'watchdog_read_hang'});
 const c=await viaProxy(s.alias);c.query(WATCHDOG).catch(()=>{});
 const f=await waitFor('the fire',()=>s.witness().fires[0]);
 assert.deepEqual(s.ts({op:'release',fire:f.id}).refused,[f.id]);
 c.socket.destroy();await waitFor('the discard',()=>s.witness().fires[0].discarded);
 assert.match(s.problems().join(),/discarded and not expected/);
 s.ts({op:'expect',fire:f.id,outcome:'discarded'});assert.deepEqual(s.problems(),[]);
});
await test('hold-response (C-postscan): the reply is held, counted, then released',async()=>{
 const s=syn('cancellation'),arm=s.ts({op:'arm',kind:'postscan'});
 assert.deepEqual(s.ts({op:'state',which:'postscan-reads'}),{value:null});
 const c=await viaProxy(s.alias);let done=false;const pending=c.query(READ_OBJECT,['missing']).then(r=>{done=true;return r;});
 const held=await waitFor('the held reply',()=>{const v=s.ts({op:'state',which:'postscan-reads'});return v.value&&v;});
 assert.equal(held.value,1);await sleep(50);assert.equal(done,false);
 assert.deepEqual(s.ts({op:'release',kind:'release-postscan'}).released,held.fires);
 assert.deepEqual((await pending).rows,[]);await c.close();
 s.ts({op:'arm',kind:'postscan-done',arming:arm.arming});
 assert.deepEqual(s.ts({op:'state',which:'postscan-reads'}),{value:null});assert.deepEqual(s.problems(),[]);
});
await test('fail-and-arm (P-hang_bookkeeping): the claim closes, the follow-up is its own arming and fire',async()=>{
 const s=syn('polling'),arm=s.ts({op:'arm',kind:'fault',name:'hang_bookkeeping'});
 const c1=await viaProxy(s.alias);await assert.rejects(c1.query(CLAIM,[FEED]));
 let w=s.witness();const parent=w.fires[0],follow=w.armings.find(m=>m.id===parent.follow_up_arming);
 assert.deepEqual([parent.arming,parent.action,follow.name,follow.parent,follow.follow_up_of],[arm.arming,'fail-and-arm','bookkeeping_active',arm.arming,parent.id]);
 const bucket=Math.floor(Date.now()/3600000)+1000;
 const c2=await viaProxy(s.alias),pending=c2.pipeline(txn(STAT,[bucket]));
 const f=await waitFor('the follow-up fire',()=>s.witness().fires[1]);
 assert.deepEqual([f.arming,f.hook,f.action,f.follow_up,f.parent],[follow.id,'P-hang_bookkeeping','hold-request',true,arm.arming]);
 assert.deepEqual(s.ts({op:'state',which:'fault-state'}),{value:'bookkeeping_active',fire:f.id});
 const released=s.ts({op:'release',kind:'release-hang'});assert.deepEqual([released.released,released.cleared],[[f.id],[follow.id]]);
 assert.ok((await pending).every(x=>x.result));await c2.close();
 assert.deepEqual((await owner.query('SELECT handling_failures FROM n_poll_stat WHERE bucket=$1',[bucket])).rows,[{handling_failures:1}]);
 assert.deepEqual(s.problems(),[]);
});
await test('hold-request (D-hold_auth_write): auth-write-held from the fired hold only',async()=>{
 const s=syn('delivery');s.ts({op:'arm',kind:'hold-auth-write',path:'/v1/devices/register'});
 assert.deepEqual(s.ts({op:'state',which:'auth-write-held'}),{value:null});
 const c=await viaProxy(s.alias),pending=c.pipeline(txn(REGISTER,['held-install','c'.repeat(64)]));
 const f=await waitFor('the fire',()=>s.witness().fires[0]);
 assert.deepEqual(s.ts({op:'state',which:'auth-write-held'}),{value:true,fire:f.id});
 assert.deepEqual(s.ts({op:'release',kind:'release-auth-write'}).released,[f.id]);
 assert.ok((await pending).every(x=>x.result));await c.close();
 const o=opOf(s.witness(),f.id);assert.deepEqual([o.commit_tag,o.commit_relayed],['COMMIT',true]);
 assert.deepEqual(s.ts({op:'state',which:'auth-write-held'}),{value:null});assert.deepEqual(s.problems(),[]);
});

// ================================================================ framing
await test('fragmented units: Parse/Bind/Describe/Execute/Sync one byte per write form one operation',async()=>{
 const s=syn('polling'),r=await raw(s.alias);
 await r.write(Buffer.concat(txn(SETTLE,[104,FEED]).map(([q,v])=>unit(q,v))),{fragment:true});
 for(let k=0;k<4;k++)assert.equal((await r.reply()).error,null);
 r.socket.destroy();
 const ops=s.witness().operations;assert.equal(ops.length,1);
 assert.deepEqual([ops[0].type,ops[0].statements,ops[0].interactive,ops[0].commit_tag],['txn',[SETTLE],null,'COMMIT']);
 assert.equal((await row(FEED)).last_success_at,104);
});
await test('delayed pipelining (BEGIN, 10 ms, gate, 10 ms, statement and COMMIT) is still one operation',async()=>{
 const s=syn('polling'),r=await raw(s.alias);
 await r.write(unit('BEGIN'));await sleep(10);await r.write(unit(GATE));await sleep(10);await r.write(Buffer.concat([unit(SETTLE,[105,FEED]),unit('COMMIT')]));
 for(let k=0;k<4;k++)assert.equal((await r.reply()).error,null);
 r.socket.destroy();
 const ops=s.witness().operations;assert.equal(ops.length,1);assert.deepEqual([ops[0].statements,ops[0].interactive],[[SETTLE],null]);
});

// ================================================================ interactive prefix
const interactiveSteps=async(r,steps)=>{const out=[];for(const [q,v] of steps){await r.write(unit(q,v));out.push(await r.reply());}return out;};
await test('interactive: the B17 transaction, awaiting each reply, is forwarded with no error',async()=>{
 const s=syn('observation'),r=await raw(s.alias);
 const out=await interactiveSteps(r,[['BEGIN'],[GATE],[INTERACTIVE_FIRST,[FEED,Math.floor(Date.now()/1000)]],['COMMIT']]);
 assert.ok(out.every(x=>x.error===null));r.socket.destroy();
 const o=s.witness().operations[0];
 assert.deepEqual([o.interactive.prefix,o.interactive.shape,o.statements,o.commit_tag],[['BEGIN'],'B17',[INTERACTIVE_FIRST],'COMMIT']);
 assert.deepEqual(s.problems(),[]);
});
await test('interactive: a transaction whose first statement differs is recorded and closed',async()=>{
 const s=syn('observation'),r=await raw(s.alias);
 await interactiveSteps(r,[['BEGIN'],[GATE]]);await r.write(unit('SELECT 2 AS other'));await assert.rejects(r.reply());
 const w=s.witness();assert.deepEqual(w.errors.map(e=>[e.kind,e.reason,e.statement]),[['interactive-shape','first application statement','SELECT 2 AS other']]);
 assert.equal(w.operations[0].closed_by,'error');
});
await test('interactive: BEGIN, gate, COMMIT with no application statement is forwarded and recorded at completion',async()=>{
 const s=syn('observation'),r=await raw(s.alias);
 const out=await interactiveSteps(r,[['BEGIN'],[GATE],['COMMIT']]);assert.ok(out.every(x=>x.error===null));r.socket.destroy();
 const w=s.witness();assert.deepEqual(w.errors.map(e=>[e.kind,e.reason]),[['interactive-shape','no application statement']]);
 assert.equal(w.operations[0].commit_tag,'COMMIT');assert.equal(s.problems().length,1);
});
await test('interactive: a delayed ordinary transaction with its hook armed is armed-hook-bypassed, nothing past the prefix forwarded',async()=>{
 const s=syn('polling'),arm=s.ts({op:'arm',kind:'fault',name:'before_settle'}),r=await raw(s.alias);
 await r.write(Buffer.concat([unit('BEGIN'),unit(GATE)]));await r.reply();await r.reply();
 await r.write(Buffer.concat([unit(SETTLE,[106,FEED]),unit('COMMIT')]));await assert.rejects(r.reply());
 const w=s.witness(),o=w.operations[0];
 assert.deepEqual(w.errors.map(e=>[e.kind,e.hook,e.arming]),[['armed-hook-bypassed','P-before_settle',arm.arming]]);
 assert.deepEqual([o.interactive.prefix,o.interactive.shape,o.commit_tag,o.tags],[['BEGIN','gate'],'bypassed',null,['BEGIN','SELECT 1']]);
 assert.notEqual((await row(FEED)).last_success_at,106);
});
await test('interactive: the same delayed transaction with no hook armed is interactive-shape and closed',async()=>{
 const s=syn('polling'),r=await raw(s.alias);
 await r.write(Buffer.concat([unit('BEGIN'),unit(GATE)]));await r.reply();await r.reply();
 await r.write(Buffer.concat([unit(SETTLE,[107,FEED]),unit('COMMIT')]));await assert.rejects(r.reply());
 assert.deepEqual(s.witness().errors.map(e=>[e.kind,e.statement]),[['interactive-shape',SETTLE]]);
 assert.notEqual((await row(FEED)).last_success_at,107);
});

// ================================================================ side writes, discards
await test('a side-write count outside its rule records side-write-count and closes, nothing forwarded',async()=>{
 await owner.query('UPDATE n_feed SET dispatch_until=0');
 const s=syn('polling');s.ts({op:'arm',kind:'fault',name:'stale_epoch'});
 const before=await row(FEED),c=await viaProxy(s.alias),out=await c.pipeline(txn(PUBLISH,[FEED]));
 assert.ok(out[0].error&&c.closed);
 assert.deepEqual(s.witness().errors.map(e=>[e.kind,e.changes,e.min]),[['side-write-count',0,1]]);
 assert.deepEqual(await row(FEED),before);
});
await test('an owner error records side-write-error and closes, nothing forwarded',async()=>{
 const s=syn('polling');s.ts({op:'arm',kind:'fault',name:'stale_generation'});
 const ownerWrite=proxy.ownerWrite;proxy.ownerWrite=async()=>{throw Error('injected owner failure');};
 try{const before=await row(FEED),c=await viaProxy(s.alias),out=await c.pipeline(txn(PUBLISH,[FEED]));assert.ok(out[0].error&&c.closed);assert.deepEqual(await row(FEED),before);}
 finally{proxy.ownerWrite=ownerWrite;}
 assert.deepEqual(s.witness().errors.map(e=>[e.kind,e.message]),[['side-write-error','injected owner failure']]);
});
await test('a hold whose client closed first is discarded; release reports it; expect accepts it',async()=>{
 const s=syn('polling');s.ts({op:'arm',kind:'fault',name:'hang_claim'});
 const c=await viaProxy(s.alias);c.query(CLAIM,[FEED]).catch(()=>{});
 const f=await waitFor('the fire',()=>s.witness().fires[0]);c.socket.destroy();
 await waitFor('the discard',()=>s.witness().fires[0].discarded);
 assert.deepEqual(s.ts({op:'state',which:'fault-state'}),{value:null});
 assert.deepEqual(s.ts({op:'release',kind:'release-hang'}).discarded,[f.id]);
 assert.equal(s.witness().discarded[0].reason,'client');
 assert.match(s.problems().join(),new RegExp(`fire ${f.id} .*discarded and not expected`));
 s.ts({op:'expect',fire:f.id,outcome:'discarded'});assert.deepEqual(s.problems(),[]);
});

// ================================================================ arming and fire witness rules
await test('witness: arming ids, re-arming, always:, fault none, unknown ops',async()=>{
 const s=syn('polling'),settle=async v=>{const c=await viaProxy(s.alias);await c.pipeline(txn(SETTLE,[v,FEED]));};
 const first=s.ts({op:'arm',kind:'fault',name:'before_settle'}),second=s.ts({op:'arm',kind:'fault',name:'before_settle'});
 assert.deepEqual(second.cleared,[first.arming]);
 await settle(110);assert.equal(s.witness().fires[0].arming,second.arming);
 assert.match(s.problems().join(),new RegExp(`arming ${first.arming} \\(fault before_settle\\) never fired, cleared by fault "before_settle"`));
 s.ts({op:'expect',arming:first.arming});assert.deepEqual(s.problems(),[]);
 const always=s.ts({op:'arm',kind:'fault',name:'always:before_settle'});
 await settle(111);await settle(112);
 const none=s.ts({op:'arm',kind:'fault',name:'none'});assert.deepEqual([none.arming,none.cleared,none.local],[null,[always.arming],true]);
 let w=s.witness();
 assert.deepEqual(w.fires.filter(f=>f.arming===always.arming).length,2);
 assert.deepEqual(w.cleared.at(-1),{arming:always.arming,at:w.cleared.at(-1).at,by:'fault "none"',fires:2});
 assert.equal(w.armings.find(m=>m.id===always.arming).fires.length,2);assert.deepEqual(s.problems(),[]);
 const unfired=s.ts({op:'arm',kind:'fault',name:'before_publish'});s.ts({op:'arm',kind:'fault',name:'none'});
 assert.match(s.problems().join(),new RegExp(`arming ${unfired.arming} .*cleared by fault "none"`));s.ts({op:'expect',arming:unfired.arming});
 assert.throws(()=>s.ts({op:'bogus'}),/unknown TEST_STORAGE op/);
 assert.throws(()=>s.ts({op:'release',fire:'F0'}),/no fired hold F0/);
 assert.deepEqual(s.witness().errors.map(e=>e.kind),['unknown-action','unknown-action']);
 assert.equal(s.problems().length,2);
});
await test('witness: storage.dispose rejects an unfired arming, an unexpected hold and a proxy error, and still drops',async()=>{
 const probe={name:'teardown-probe',modules:[{type:'ESModule',path:root+'tests/observation-entry.mjs'}]};
 const exists=async name=>(await owner.query('SELECT 1 AS x FROM pg_database WHERE datname=$1',[name])).rows.length===1;
 const unfired=await openStorage(),bound=unfired.bind(probe);
 assert.equal(typeof bound.serviceBindings.TEST_STORAGE,'function');assert.match(bound.hyperdrives.DB,new RegExp(`:${proxy.listenPort}/${unfired.databaseName}\\.teardown-probe\\?`));
 unfired.testStorage('teardown-probe')({op:'arm',kind:'fault',name:'before_publish'});
 await assert.rejects(unfired.dispose(),/arming A\d+ \(fault before_publish\) never fired/);assert.equal(await exists(unfired.databaseName),false);
 const held=await openStorage();held.bind(probe);held.testStorage('teardown-probe')({op:'arm',kind:'fault',name:'watchdog_read_hang'});
 const c=await viaProxy(held.alias('teardown-probe'));c.query(WATCHDOG).catch(()=>{});
 await waitFor('the fire',()=>held.testStorage('teardown-probe')({op:'witness'}).fires[0]);c.socket.destroy();
 await assert.rejects(held.dispose(),/O-watchdog_read_hang hold-forever\) was discarded and not expected/);assert.equal(await exists(held.databaseName),false);
 const erred=await openStorage();erred.bind(probe);assert.throws(()=>erred.testStorage('teardown-probe')({op:'state',which:'nothing'}));
 await assert.rejects(erred.dispose(),/error unknown-action/);assert.equal(await exists(erred.databaseName),false);
});

// ================================================================ counters
await test('counters: statements, operations, rows from INSERT/UPDATE/DELETE tags, watchdog reads',async()=>{
 const s=syn('observation'),c=await viaProxy(s.alias),b=s.ts({op:'counters',begin:true});
 await c.pipeline([['BEGIN'],[GATE],['UPDATE n_feed SET poll_failures=poll_failures WHERE feed_id IN($1,$2)',[FEED,OTHER]],[STAT,[7]],['DELETE FROM n_poll_stat WHERE bucket=$1',[7]],['COMMIT']]);
 await c.query(WATCHDOG);await c.close();
 const e=s.ts({op:'counters',end:b.invocation});
 assert.deepEqual([e.statements-b.statements,e.operations-b.operations,e.rows_written-b.rows_written,e.watchdog_reads-b.watchdog_reads,e.exclusive],[4,2,4,1,true]);
});
await test('counters: exclusivity over the whole window marks both overlapping invocations non-exclusive, whichever ends first',async()=>{
 const s=syn('observation'),outer=s.ts({op:'counters',begin:true}),inner=s.ts({op:'counters',begin:true});
 assert.equal(inner.in_flight,2);
 assert.equal(s.ts({op:'counters',end:inner.invocation}).exclusive,false);assert.equal(s.ts({op:'counters',end:outer.invocation}).exclusive,false);
 const alone=s.ts({op:'counters',begin:true});assert.equal(s.ts({op:'counters',end:alone.invocation}).exclusive,true);
});
await test('counters: 800 single-statement reads in one window report 800 and fail < 800; 799 passes',async()=>{
 const s=syn('polling'),c=await viaProxy(s.alias);
 const window=async n=>{const b=s.ts({op:'counters',begin:true});for(let k=0;k<n;k++)await c.query('SELECT $1::int8 AS n',[k]);const e=s.ts({op:'counters',end:b.invocation});return {d1:e.statements-b.statements,operations:e.operations-b.operations,exclusive:e.exclusive};};
 const at800=await window(800),at799=await window(799);await c.close();
 assert.deepEqual([at800,at800.d1<800],[{d1:800,operations:800,exclusive:true},false]);
 assert.deepEqual([at799,at799.d1<800],[{d1:799,operations:799,exclusive:true},true]);
});

// ================================================================ deadline bands: delayed-frame control
// The lower bound is measured from Z_relay, which precedes the Worker's
// operation timer, never from fire: a frame written late puts fire after the
// timer started, so close - fire falls short of 4,000 by that much.
await test('deadline delayed frame: the held unit 300 ms after Z; close - Z_relay >= 4000 while close - fire < 4000',async()=>{
 const s=syn('polling');s.ts({op:'arm',kind:'fault',name:'hang_claim'});
 const r=await raw(s.alias);await until(r.readyAt+300);await r.write(unit(CLAIM,[FEED]));
 // The Worker's operation timer started at its connect (after Z): its 4,000 ms deadline, then finish closes.
 await until(r.readyAt+4000);r.socket.destroy();
 const f=await waitFor('the discard',()=>{const x=s.witness().fires[0];return x?.discarded&&x;});
 const o=opOf(s.witness(),f.id),offset=o.fire-o.Z_relay,lower=o.close-o.Z_relay,span=o.close-o.fire;
 report.push(`deadline delayed frame: fire-Z_relay ${offset.toFixed(1)} ms, close-Z_relay ${lower.toFixed(1)} ms, close-fire ${span.toFixed(1)} ms`);
 assert.ok(offset>=300,`fire - Z_relay ${offset}`);assert.ok(lower>=4000,`close - Z_relay ${lower}`);
 assert.ok(span<=4500+EPSILON_MS,`close - fire ${span}`);assert.ok(span<4000,`a fire-anchored lower bound would fail here: ${span}`);
 assert.equal(o.forwarded,null);s.ts({op:'expect',fire:f.id,outcome:'discarded'});assert.deepEqual(s.problems(),[]);
},15000);

// ================================================================ THE AUTHENTICATION GATE
// A proxied runtime-role Worker identity, read and write, through the SCRAM
// relay, beside a direct control that bypasses the proxy.
const PIN=`v1;development;postgres;pg:${db}:${SYSTEM}`,F1_FEED=H('f1-gate');
await handle.prepare('INSERT INTO n_feed(feed_id,canonical_url,epoch,due_at) VALUES(?,?,1,?)').bind(F1_FEED,'https://fixture.example/f1.xml',0).run();
const notifications=name=>({name,modulesRoot:root,
 modules:[...['tests/observation-entry.mjs','adapter/index.js','build/index.js'].map(path=>({type:'ESModule',path:root+path})),{type:'CompiledWasm',path:root+'build/index_bg.wasm'}],
 compatibilityDate,compatibilityFlags,r2Buckets:{FEED_SNAPSHOTS:'f1-gate'},
 bindings:{NOTIFICATION_ENVIRONMENT:'development',STORAGE_IDENTITY:PIN}});
// /control/* goes to FeedControl (Server/NotificationsWorker/src/feed_control.rs): POST, a 64-hex feed and its epoch.
async function f1(mf,name){
 const worker=await mf.getWorker(name);
 const post=async(path,body)=>{const r=await worker.fetch('https://fixture.invalid/control'+path,{method:'POST',body:JSON.stringify(body)});const text=await r.text();let json=null;try{json=JSON.parse(text);}catch{}return {status:r.status,body:json??text};};
 const command={feed_id:F1_FEED,expected_epoch:1},paused=async()=>(await handle.prepare('SELECT admission_paused FROM n_feed WHERE feed_id=?').bind(F1_FEED).first()).admission_paused;
 const identity=await post('/identity',{}),inspect=await post('/inspect',command),pause=await post('/pause',command),afterPause=await paused(),resume=await post('/resume',command),afterResume=await paused();
 return {identity,inspect,pause,afterPause,resume,afterResume};
}
function gate(name,r){
 assert.equal(r.identity.status,200,JSON.stringify(r.identity));
 assert.deepEqual([r.identity.body.verdict,r.identity.body.backend,r.identity.body.environment,r.identity.body.database],['accepted','postgres','development',`pg:${db}:${SYSTEM}`],`${name} identity`);
 assert.equal(r.identity.body.schema,r.identity.body.expected_schema,`${name}: schema == expected_schema`);
 assert.equal(r.inspect.status,200,JSON.stringify(r.inspect));assert.equal(r.inspect.body.epoch,1);
 assert.deepEqual([r.pause.status,r.pause.body.changed,r.afterPause],[200,1,1],`${name} pause`);
 assert.deepEqual([r.resume.status,r.resume.body.changed,r.afterResume],[200,1,0],`${name} resume`);
}
let proxied=null;
await test('AUTHENTICATION GATE (proxied): the packaged Worker on opencast_local_runtime, pinned: identity accepted, a read, a write read back, two p and a Z',async()=>{
 const mf=new Miniflare(convertV4MiniflareOptions({cf:false,inspectorPort:0,workers:[storage.bind(notifications('f1-proxied')),storage.bind(notifications('f1-proxied-replica'))]}));
 try{
  await mf.ready;
  proxied=await f1(mf,'f1-proxied');gate('proxied',proxied);
  const replica=await (await mf.getWorker('f1-proxied-replica')).fetch('https://fixture.invalid/control/identity',{method:'POST',body:'{}'});
  assert.equal((await replica.json()).verdict,'accepted');
 }finally{await mf.dispose();}
 const w=storage.testStorage('f1-proxied')({op:'witness'}),replica=storage.testStorage('f1-proxied-replica')({op:'witness'});
 // One connection per operation: the identity read, the inspect read, the pause and resume writes.
 assert.ok(w.connections.length>=4,`${w.connections.length} connections`);
 for(const c of [...w.connections,...replica.connections]){assert.equal(c.frontend_p,2,JSON.stringify(c));assert.equal(c.backend.at(-1),'Z');assert.equal(c.user,RUNTIME);assert.equal(c.database,db);}
 assert.ok(replica.connections.every(c=>c.alias===storage.alias('f1-proxied-replica'))&&w.connections.every(c=>c.alias===storage.alias('f1-proxied')));
 const writes=w.operations.filter(o=>o.type==='txn');
 assert.deepEqual(writes.map(o=>[o.commit_tag,o.commit_relayed,o.rows_written]),[['COMMIT',true,1],['COMMIT',true,1]]);
 report.push(`authentication gate proxied: ${w.connections.length} connections, operations ${w.operations.map(o=>o.type).join(',')}, statements ${w.counters.statements}`);
});
await test('AUTHENTICATION GATE (direct control, its own Miniflare): the same three results bypassing the proxy',async()=>{
 const mf=new Miniflare(convertV4MiniflareOptions({cf:false,inspectorPort:0,workers:[storage.bind(notifications('f1-direct'),{direct:true})]}));
 let direct;
 try{await mf.ready;direct=await f1(mf,'f1-direct');gate('direct',direct);}finally{await mf.dispose();}
 assert.ok(proxied,'the proxied gate ran');
 assert.deepEqual(direct,proxied,'proxied and direct give the same results');
});

// ================================================================ the four entries, proxied
// Each entry in postgres mode forwards its storage hook names to TEST_STORAGE,
// answers its state routes from a fired, unreleased hold or else its own
// variable, binds no D1, and fills its counters from the alias.
const polling=fileURLToPath(new URL('../../../FeedPollingWorker/',import.meta.url));
const packaged=(dir,entry)=>[{type:'ESModule',path:dir+entry},{type:'ESModule',path:dir+'adapter/index.js'},{type:'ESModule',path:dir+'build/index.js'},{type:'CompiledWasm',path:dir+'build/index_bg.wasm'}];
await test('entries: arming forwarded by PROXY_NAMES, state answers fall back, counters fill the traces',async()=>{
 const workers=[
  {name:'entry-polling',modulesRoot:polling,modules:packaged(polling,'tests/entry.mjs'),compatibilityDate:'2026-09-30',compatibilityFlags:['enable_request_signal'],
   r2Buckets:{FEED_SNAPSHOTS:'entries'},queueProducers:{POLL_QUEUE:'entries-poll'},bindings:{NOTIFICATION_ENVIRONMENT:'development',TEST_REAL_QUEUE:'false'}},
  {name:'entry-observation',modulesRoot:root,modules:packaged(root,'tests/observation-entry.mjs'),compatibilityDate,compatibilityFlags,r2Buckets:{FEED_SNAPSHOTS:'entries'},bindings:{NOTIFICATION_ENVIRONMENT:'development'}},
  {name:'entry-delivery',modulesRoot:root,modules:packaged(root,'tests/delivery-entry.mjs'),compatibilityDate,compatibilityFlags,bindings:{NOTIFICATION_ENVIRONMENT:'development'}},
  {name:'entry-cancellation',modulesRoot:root,modules:packaged(root,'tests/cancellation-entry.mjs'),compatibilityDate,compatibilityFlags,r2Buckets:{FEED_SNAPSHOTS:'entries'},bindings:{NOTIFICATION_ENVIRONMENT:'development'}},
 ].map(w=>storage.bind(w));
 assert.ok(workers.every(w=>typeof w.serviceBindings.TEST_STORAGE==='function'&&w.d1Databases===undefined));
 const mf=new Miniflare(convertV4MiniflareOptions({cf:false,inspectorPort:0,workers}));
 const ts=name=>storage.testStorage(name),armed=name=>ts(name)({op:'witness'}).armings;
 try{
  await mf.ready;
  const call=async(name,path,body,headers={})=>{const r=await (await mf.getWorker(name)).fetch('https://entries.invalid'+path,{method:'POST',headers,body:body??''});return {status:r.status,text:await r.text()};};
  // FeedPolling: a storage name arms the alias, a local one only clears it; fault-state falls back.
  assert.equal((await call('entry-polling','/fault','hang_claim')).text,'ok');
  assert.deepEqual(armed('entry-polling').map(m=>[m.kind,m.name]),[['fault','hang_claim']]);
  assert.equal((await call('entry-polling','/fault-state')).text,'hang_claim');
  assert.equal((await call('entry-polling','/fault','before_get')).text,'ok');
  assert.equal(armed('entry-polling').length,1);assert.equal(armed('entry-polling')[0].cleared.by,'fault "before_get"');
  assert.equal((await call('entry-polling','/release-hang')).text,'ok');
  const stats=await call('entry-polling','/test/stats','{}');assert.equal(stats.status,200,stats.text);
  const metrics=JSON.parse((await call('entry-polling','/metrics')).text),trace=metrics.recent.at(-1);
  assert.ok(trace.d1>0&&trace.storage_exclusive===true&&trace.rows_read===0,JSON.stringify(trace));assert.equal(metrics.max_d1,trace.d1);
  // Observation: the same slot rule; d1 and rows from the alias; watchdog_reads stays absent.
  await call('entry-observation','/fault','before_publish');await call('entry-observation','/fault','none');
  assert.equal(armed('entry-observation')[0].cleared.by,'fault "none"');
  const inspect=await call('entry-observation','/control/inspect',JSON.stringify({feed_id:F1_FEED,expected_epoch:1}));assert.equal(inspect.status,200,inspect.text);
  const traces=JSON.parse((await call('entry-observation','/traces')).text),last=traces.at(-1);
  assert.deepEqual([last.path,last.d1,last.rows_written,last.storage_exclusive,'watchdog_reads' in last],['/control/inspect',1,0,true,false]);
  // Delivery: hold-auth-write and the fault names; auth-write-held falls back to false.
  await call('entry-delivery','/test/hold-auth-write','/v1/devices/register');
  assert.equal((await call('entry-delivery','/test/auth-write-held')).text,'false');
  await call('entry-delivery','/test/release-auth-write');await call('entry-delivery','/test/fault','reclaim_fanout');
  assert.deepEqual(armed('entry-delivery').map(m=>[m.kind,m.path??m.name]),[['hold-auth-write','/v1/devices/register'],['fault','reclaim_fanout']]);
  // Cancellation: x-test-postscan arms for its request only; the state falls back to the entry's set.
  assert.equal(JSON.parse((await call('entry-cancellation','/__cancellation-state')).text).postscanReads,0);
  await call('entry-cancellation','/observation/none','{}',{'x-test-postscan':'1'});
  assert.equal((await call('entry-cancellation','/__release-postscan')).text,'released');
  const postscan=armed('entry-cancellation');assert.deepEqual([postscan.length,postscan[0].kind,postscan[0].ended!==null],[1,'postscan',true]);
  // None of these armings fired: each is expected by its id, or teardown rejects it.
  for(const name of ['entry-polling','entry-observation','entry-delivery','entry-cancellation'])for(const m of armed(name))ts(name)({op:'expect',arming:m.id});
 }finally{await mf.dispose();}
});

await test('a Worker declaring d1Databases is refused at bind, before Miniflare starts or the proxy registers it',async()=>{
 assert.throws(()=>storage.bind({...notifications('f1-d1'),d1Databases:{APP_ATTEST_DB:'f1-gate'}}),/bind: Worker f1-d1 declares d1Databases .*D1 storage was removed/);
 assert.throws(()=>storage.testStorage('f1-d1'),/not bound through the proxy/);
});

// ================================================================ companion probe, slow-rollback control
// The runtime's storage_* reason keeps a failure's kind but not its phase, and
// the poll's bookkeeping keeps only a boolean for the held stat's failure. The
// storage-fixture build runs the same postgres::execute adapter and returns the
// serialized Failure (kind, phase, outcome), so this companion probe proves how
// the adapter classifies exactly that held statement; it does not observe the
// runtime's swallowed error directly.
const TOKEN=randomBytes(16).toString('hex');
const fixtureMf=new Miniflare(convertV4MiniflareOptions({cf:false,inspectorPort:0,workers:[storage.bind({name:'fixture',modulesRoot:FIXTURE_BUILD,
 modules:[{type:'ESModule',path:FIXTURE_BUILD+'/index.js'},{type:'CompiledWasm',path:FIXTURE_BUILD+'/index_bg.wasm'}],
 compatibilityDate:'2026-09-30',compatibilityFlags:['enable_request_signal'],bindings:{SLICE_TOKEN:TOKEN}},{hooks:'polling'})]}));
const fixture=storage.testStorage('fixture'),fixtureAlias=proxy.alias(storage.alias('fixture'));
// RecordPollStat (A13) through Server/NotificationsWorker/src/database/fixture.rs
// with no deadline_in_ms:
// the operation's 4,000 ms cap fires first inside the 12 s window.
async function heldStat(rollbackReplyMs){
 fixtureAlias.delays.rollbackReplyMs=rollbackReplyMs;
 const arm=fixture({op:'arm',kind:'fault',name:'hang_redelivery_stat'});
 const worker=await fixtureMf.getWorker('fixture'),started=now();
 const r=await worker.fetch('https://fixture.invalid/operation',{method:'POST',headers:{authorization:`Bearer ${TOKEN}`},body:JSON.stringify({request:{operation:'record_poll_stat',counter:'redeliveries',now:Math.floor(Date.now()/1000)}})});
 const body=await r.json(),wall=now()-started;
 const f=await waitFor('the held connection close',()=>{const x=fixture({op:'witness'}).fires.find(y=>y.arming===arm.arming);return x?.discarded&&x;});
 const o=await waitFor('the close',()=>{const x=opOf(fixture({op:'witness'}),f.id);return x.close&&x;});
 fixture({op:'expect',fire:f.id,outcome:'discarded'});
 return {status:r.status,body,wall,f,o,span:o.close-o.fire,lower:o.close-o.Z_relay,offset:o.fire-o.Z_relay,rollbackToClose:o.close-o.rollback_after_hold,
  rollbackRelayed:o.rollback_relayed===null?null:o.rollback_relayed-o.rollback_after_hold};
}
const a3=x=>{
 assert.equal(x.status,200);
 assert.deepEqual([x.body.ok,x.body.retryable,x.body.error.kind,x.body.error.phase,x.body.error.outcome],[false,false,'deadline','commit','unknown'],JSON.stringify(x.body));
 assert.deepEqual([x.f.hook,x.f.action,x.o.forwarded,x.o.statements.length],['P-hang_redelivery_stat','hold-request',null,1]);
 assert.ok(x.o.rollback_after_hold!==null,'rollback_after_hold');
 assert.ok(x.lower>=4000,`close - Z_relay ${x.lower}`);assert.ok(x.span<=5000+EPSILON_MS,`close - fire ${x.span}`);
};
try{
 await fixtureMf.ready;
 await test('companion probe: the held RecordPollStat is deadline/commit/unknown, not retryable, never forwarded',async()=>{
  const x=await heldStat(0);a3(x);
  assert.deepEqual(fixture({op:'witness'}).discarded.at(-1).reason,'client-rollback');
  assert.ok(x.rollbackRelayed!==null,'the ROLLBACK reply was relayed');
  // Reported, not asserted: the held units were written by the Worker and never
  // answered, so its driver may spend CLOSE_MS on the ROLLBACK even with the reply relayed.
  report.push(`companion probe: ${JSON.stringify(x.body.error)} handler_ms ${x.body.metrics?.handler_ms}; fire-Z_relay ${x.offset.toFixed(1)}, close-Z_relay ${x.lower.toFixed(1)}, close-fire ${x.span.toFixed(1)}, rollback relayed after ${x.rollbackRelayed.toFixed(1)}, close-rollback ${x.rollbackToClose.toFixed(1)} ms`);
 },30000);
 await test('deadline slow rollback: the ROLLBACK reply delayed 1,000 ms; the Worker gives up at CLOSE_MS and close - fire <= 5000 + eps',async()=>{
  const x=await heldStat(1000);a3(x);
  assert.equal(x.rollbackRelayed,null,'the delayed ROLLBACK reply was never relayed');
  assert.ok(x.rollbackToClose<1000,`the client closed before the delayed reply: ${x.rollbackToClose}`);
  report.push(`deadline slow rollback: close-fire ${x.span.toFixed(1)}, close-rollback ${x.rollbackToClose.toFixed(1)}, close-Z_relay ${x.lower.toFixed(1)} ms`);
 },30000);
}finally{await fixtureMf.dispose();}

} finally {
 for(const alias of synthetic)proxy.unregister(alias);
 await owner.close().catch(()=>{});
 await test('storage.dispose: the authentication-gate and fixture aliases carry a clean witness, and the database is dropped',()=>storage.dispose());
}
for(const line of report)console.log('REPORT',line);
console.log(`${passed} passed, ${failed} failed`);
process.exitCode=failed?1:0;
