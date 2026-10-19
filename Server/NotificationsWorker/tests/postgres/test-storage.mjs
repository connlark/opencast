// storage.mjs against the local topology (Server/NotificationsWorker/postgres/
// local/local-postgres.sh status exits 0): the database cases (sharing,
// persistence, concurrent runs, prune), prune's ownership rule (when a
// registered owner counts as dead), four fresh-process controls of the
// storage mode, which is read at the first openStorage(), never at import,
// and one of the routing under an upstream host other than the proxy's.
// Children are small inline ESM scripts; prune runs through
// local-postgres.sh prune. Every database this test creates is gone at the end:
// dropped by dispose, by prune, or (the ones prune must keep) by this test.
// Run: node Server/NotificationsWorker/tests/postgres/test-storage.mjs
// (OPENCAST_PG_HOST and OPENCAST_PG_PORT override 127.0.0.1:55432). Miniflare needs loopback sockets.
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {randomBytes} from 'node:crypto';
import {mkdtempSync,rmSync,writeFileSync} from 'node:fs';
import net from 'node:net';
import {tmpdir} from 'node:os';
import {dirname,join} from 'node:path';
import {fileURLToPath} from 'node:url';
import {setTimeout as sleep} from 'node:timers/promises';
import {Miniflare,convertV4MiniflareOptions} from 'miniflare';
import {Client} from './pg.mjs';
import {openStorage,processIdentity,statStartTicks,ownerState,prune} from '../storage.mjs';

if(process.env.OPENCAST_TEST_STORAGE!==undefined&&process.env.OPENCAST_TEST_STORAGE!=='postgres')throw Error('test-storage.mjs runs postgres storage: launch it without OPENCAST_TEST_STORAGE');
const port=Number(process.env.OPENCAST_PG_PORT??55432),host=process.env.OPENCAST_PG_HOST??'127.0.0.1';
const repo=fileURLToPath(new URL('../../../../',import.meta.url));
const storageUrl=new URL('../storage.mjs',import.meta.url).href,clientUrl=new URL('./pg.mjs',import.meta.url).href;
const script=fileURLToPath(new URL('../../postgres/local/local-postgres.sh',import.meta.url));
const probePath=fileURLToPath(new URL('./storage-probe-worker.mjs',import.meta.url)); // contents inline, never on disk
// The local topology's fixed fixture passwords (local-postgres.sh).
const POSTGRES='opencast-local-postgres',OWNER='opencast_local_owner',OWNER_PASSWORD='opencast-local-owner';
const tag=randomBytes(4).toString('hex'),self=processIdentity();
const created=new Set(),expectedLeft=new Set(); // every database name this test made; those prune must keep
let failed=0;
async function test(name,fn,ms=60000){
 let timer;
 try{await Promise.race([fn(),new Promise((_,reject)=>{timer=setTimeout(()=>reject(Error(`timed out after ${ms} ms`)),ms);})]);console.log('ok',name);}
 catch(error){failed++;console.log('not ok',name);console.log(error);}
 finally{clearTimeout(timer);}
}

// ---- Helpers.
const admin=await Client.connect({host,port,user:'postgres',password:POSTGRES,database:'postgres',application:`storage-test-${tag}-admin`})
 .catch(error=>{console.log(`not ok live topology at ${host}:${port}: ${error.message} (is local-postgres.sh status 0?)`);process.exit(1);});
const exists=async name=>(await admin.query('SELECT 1 AS x FROM pg_database WHERE datname=$1',[name])).rows.length===1;
const registryOf=async name=>JSON.parse((await admin.query("SELECT shobj_description(oid,'pg_database') AS c FROM pg_database WHERE datname=$1",[name])).rows[0]?.c??'null');
const backendsOn=async name=>(await admin.query("SELECT application_name FROM pg_stat_activity WHERE datname=$1 AND backend_type<>'autovacuum worker'",[name])).rows.map(r=>r.application_name);
async function drained(name,ms=5000){const end=Date.now()+ms;while((await backendsOn(name)).length){if(Date.now()>end)throw Error(`backends stay on ${name}`);await sleep(50);}}
const ownerClient=(database,application)=>Client.connect({host,port,user:OWNER,password:OWNER_PASSWORD,database,application});
// A database registered by hand: comment null (none), a string (verbatim) or a registry object.
const fakeRun=()=>randomBytes(6).toString('hex');
async function fake(name,comment){
 created.add(name);
 await admin.simple(`CREATE DATABASE "${name}" TEMPLATE opencast_template OWNER ${OWNER}`);
 if(comment!==null)await admin.simple(`COMMENT ON DATABASE "${name}" IS '${(typeof comment==='string'?comment:JSON.stringify(comment)).replace(/'/g,"''")}'`);
 return name;
}
const entry=identity=>({kind:'transient',run:'fake',persist:null,created_at:new Date().toISOString(),owner_claimed_at:new Date().toISOString(),identity});
// A pid that existed and was reaped: kill(pid, 0) is ESRCH.
async function deadPid(){const c=spawn(process.execPath,['-e','']);await new Promise(r=>c.once('exit',r));return c.pid;}
function run(file,args,{env={},input}={}){
 return new Promise((resolve,reject)=>{
  const c=spawn(file,args,{cwd:repo,env:{...process.env,...env}});let stdout='',stderr='';
  c.stdout.on('data',d=>{stdout+=d;});c.stderr.on('data',d=>{stderr+=d;});c.on('error',reject);
  c.on('close',code=>resolve({code,stdout,stderr}));
  c.stdin.on('error',()=>{});c.stdin.end(input??'');
 });
}
// local-postgres.sh prune: one "<database> <verdict>: <reason>" line each.
async function prunes(...args){
 const r=await run(script,['prune',...args]);
 const lines=new Map();
 for(const line of r.stdout.split('\n').filter(Boolean)){const m=/^(\S+) (\w+): (.*)$/.exec(line);assert.ok(m,`prune line ${line}`);lines.set(m[1],{verdict:m[2],reason:m[3]});}
 return {...r,lines};
}
const verdict=(r,name)=>{const v=r.lines.get(name);assert.ok(v,`prune printed no line for ${name}:\n${r.stdout}${r.stderr}`);return v;};
// Children: the inline ESM below, run from a scratch file and not through
// `node --input-type=module -e`: a Worker thread inherits execArgv, so that
// flag turns Miniflare's eval'd CommonJS SynchronousFetcher into ESM, which
// dies. Imports are absolute
// URLs; env without OPENCAST_TEST_STORAGE unless given; JSON lines on stdout.
const scratch=mkdtempSync(join(tmpdir(),'opencast-test-storage-'));let scripts=0;
const childEnv=env=>{const out={...process.env,...env};if(env.OPENCAST_TEST_STORAGE===undefined)delete out.OPENCAST_TEST_STORAGE;return out;};
function child(code,env={}){
 const file=join(scratch,`child-${++scripts}.mjs`);writeFileSync(file,code);
 const c=spawn(process.execPath,[file],{cwd:repo,env:childEnv(env),stdio:['pipe','pipe','pipe']});
 let buffer='',stderr='',ended=false;const lines=[],waiters=[];
 const pump=()=>{
  while(lines.length&&waiters.length)waiters.shift().resolve(lines.shift());
  if(ended)for(const w of waiters.splice(0))w.reject(Error(`child exited before a line: ${stderr}`));
 };
 c.stdout.on('data',d=>{buffer+=d;let i;while((i=buffer.indexOf('\n'))>=0){const line=buffer.slice(0,i);buffer=buffer.slice(i+1);try{lines.push(JSON.parse(line));}catch{lines.push({text:line});}}pump();});
 c.stderr.on('data',d=>{stderr+=d;});
 // 'close': stdout is fully read, so every line it printed is queued.
 const exit=new Promise(resolve=>c.once('close',(code,signal)=>{ended=true;pump();resolve({code,signal,stderr});}));
 c.stdin.on('error',()=>{});
 return {pid:c.pid,exit,get stderr(){return stderr;},
  next:()=>new Promise((resolve,reject)=>{waiters.push({resolve,reject});pump();}),
  send:text=>c.stdin.write(text),kill:signal=>c.kill(signal)};
}
async function result(code,env){const c=child(code,env);const line=await c.next();const end=await c.exit;assert.equal(end.code,0,`child failed: ${end.stderr}`);return line;}
// Counts net.connect / net.createConnection / Socket#connect calls to the
// PostgreSQL ports (the topology's and OPENCAST_PG_PORT) in the child.
const COUNT=`
const pgPorts=new Set([${port},Number(process.env.OPENCAST_PG_PORT??55432)]);
const contacts={connect:0,createConnection:0,socketConnect:0};
const portOf=args=>{const a=Array.isArray(args[0])?args[0]:args;const o=a[0];return Number(o&&typeof o==='object'?o.port:o);};
for(const [counter,target,key] of [['connect',net,'connect'],['createConnection',net,'createConnection'],['socketConnect',net.Socket.prototype,'connect']]){
 const original=target[key];target[key]=function(...args){if(pgPorts.has(portOf(args)))contacts[counter]++;return original.apply(this,args);};
}`;
const PROBE="export default {fetch(request,env){return Response.json({authority:env.STORAGE_AUTHORITY??null,db:'DB' in env,database:env.DB?.database??null,d1:'APP_ATTEST_DB' in env});}};";
const probeWorker=name=>({name,modulesRoot:dirname(probePath),modules:[{type:'ESModule',path:probePath,contents:PROBE}],compatibilityDate:'2026-09-30'});
const closedPort=async()=>{const s=net.createServer();await new Promise(r=>s.listen(0,'127.0.0.1',r));const p=s.address().port;await new Promise(r=>s.close(r));return p;};
const TRANSIENT_CHILD=`
import {openStorage} from '${storageUrl}';
const storage=await openStorage();
const db=await storage.database(null,'APP_ATTEST_DB');
await db.prepare('SELECT COUNT(*) AS n FROM n_control').first(); // the owner backend is connected
console.log(JSON.stringify({name:storage.databaseName,run:storage.run,pid:process.pid}));
process.stdin.once('data',async()=>{await storage.dispose();console.log(JSON.stringify({disposed:true}));process.stdin.destroy();});`;

// ---- Pure readers.
await test('processIdentity: this platform reader, a stable identity, unreadable pids as null; statStartTicks reads field 22',async()=>{
 assert.equal(self.platform,process.platform);
 for(const key of ['host','boot','start'])assert.ok(typeof self[key]==='string'&&self[key].length>0,key);
 if(self.platform==='linux')assert.match(self.pid_ns,/^pid:\[\d+\]$/);
 assert.deepEqual(processIdentity(),self);
 const gone=await deadPid();assert.equal(processIdentity(gone).start,null);
 assert.throws(()=>processIdentity(0),TypeError);assert.throws(()=>processIdentity(-1),TypeError);
 // Sampled from the Podman VM's /proc/self/stat; a command with spaces and parentheses.
 const tail='R 47303 47303 47303 0 -1 4194304 114 0 0 0 0 0 0 0 20 0 1 0 7853145 4669440 343';
 assert.equal(statStartTicks(`47340 (cat) ${tail}`),'7853145');
 assert.equal(statStartTicks(`47340 (a) (b c) ${tail}`),'7853145');
 assert.equal(statStartTicks('garbage'),null);assert.equal(statStartTicks(null),null);
 assert.deepEqual(ownerState(self,self),{dead:false,reason:`owner pid ${process.pid} is alive, signalable`});
});

// ---- The mode, each control a fresh process.
await test('mode (1) d1 at a closed OPENCAST_PG_PORT: the removal is refused before any socket',async()=>{
 const closed=await closedPort();
 const r=await result(`
import net from 'node:net';
import {openStorage} from '${storageUrl}';
${COUNT}
let message=null;try{await openStorage();}catch(error){message=error.message;}
console.log(JSON.stringify({message,contacts}));`,{OPENCAST_TEST_STORAGE:'d1',OPENCAST_PG_PORT:String(closed)});
 assert.match(r.message??'',/D1 storage was removed; the suites run on the local PostgreSQL topology/);
 assert.deepEqual(r.contacts,{connect:0,createConnection:0,socketConnect:0});
});
for(const [label,env] of [['(2) explicit postgres',{OPENCAST_TEST_STORAGE:'postgres'}],['(3) unset',{}]])
 await test(`mode ${label} binds the topology; a Worker declaring d1Databases is refused before any connection`,async()=>{
  const r=await result(`
import net from 'node:net';
import {openStorage} from '${storageUrl}';
${COUNT}
const storage=await openStorage();
const worker=storage.bind({name:'probe'},{direct:true});
const opened={...contacts};
let refused=null;try{storage.bind({name:'forbidden',d1Databases:{APP_ATTEST_DB:'x'}});}catch(error){refused=error.message;}
const afterRefusal={...contacts};
const row=await (await storage.database(null,'APP_ATTEST_DB','probe')).prepare('SELECT COUNT(*) AS n FROM n_control').first();
await storage.dispose();
console.log(JSON.stringify({mode:storage.mode,name:storage.databaseName,url:worker.hyperdrives.DB,authority:worker.bindings.STORAGE_AUTHORITY,d1:worker.d1Databases===undefined?'absent':worker.d1Databases,refused,opened,afterRefusal,n:row.n,contacts}));`,env);
  created.add(r.name);
  assert.deepEqual([r.mode,r.authority,r.d1],['postgres','postgres','absent']);
  assert.match(r.refused??'',/bind: Worker forbidden declares d1Databases .*D1 storage was removed/);
  assert.deepEqual(r.afterRefusal,r.opened,'the refused bind opened no connection');
  assert.match(r.name,/^opencast_t_[0-9a-f]{12}_1$/);
  assert.equal(r.url,`postgresql://opencast_local_runtime:opencast-local-runtime@${host}:${port}/${r.name}?sslmode=disable`);
  assert.ok(r.n>0);
  assert.ok(r.contacts.socketConnect>0&&r.contacts.connect===r.contacts.socketConnect,JSON.stringify(r.contacts));
  assert.equal(await exists(r.name),false,'dispose dropped it');
 });
await test('mode (4) OPENCAST_TEST_STORAGE assigned after a static import of storage.mjs is seen; a later change throws',async()=>{
 const r=await result(`
import net from 'node:net';
import {openStorage} from '${storageUrl}';
const refusal=async work=>{try{await work();return null;}catch(error){return error.message;}};
process.env.OPENCAST_TEST_STORAGE='d1';
${COUNT}
const lazy=await refusal(()=>openStorage()),beforeOpen={...contacts};
process.env.OPENCAST_TEST_STORAGE='postgres';
const storage=await openStorage();
const worker=storage.bind({name:'probe'});
process.env.OPENCAST_TEST_STORAGE='d1';
const reopen=await refusal(()=>openStorage()),rebind=await refusal(()=>storage.bind({name:'p2'}));
process.env.OPENCAST_TEST_STORAGE='postgres';
await storage.dispose();
console.log(JSON.stringify({name:storage.databaseName,mode:storage.mode,authority:worker.bindings.STORAGE_AUTHORITY,lazy,beforeOpen,reopen,rebind}));`);
 created.add(r.name);
 assert.deepEqual([r.mode,r.authority],['postgres','postgres']);
 for(const message of [r.lazy,r.reopen,r.rebind])assert.match(message??'',/D1 storage was removed/);
 assert.deepEqual(r.beforeOpen,{connect:0,createConnection:0,socketConnect:0},'the refused open made no socket');
 assert.equal(await exists(r.name),false,'dispose dropped it');
});
await test('mode: a value other than postgres throws before any socket',async()=>{
 const r=await result(`
import net from 'node:net';
import {openStorage} from '${storageUrl}';
${COUNT}
let message=null;try{await openStorage();}catch(error){message=error.message;}
console.log(JSON.stringify({message,contacts}));`,{OPENCAST_TEST_STORAGE:'sqlite'});
 assert.match(r.message,/OPENCAST_TEST_STORAGE must be postgres or unset, not "sqlite"/);
 assert.equal(r.contacts.socketConnect,0);
});

// ---- Sharing, the live binding, persistence, concurrent runs, prune.
let shared=null,workers=null;
const NAMES=['polling-runtime','polling-runtime-1','delivery-runtime'];
await test('shared Workers plus two replicas on one database: three distinct aliases, one URL',async()=>{
 shared=await openStorage();created.add(shared.databaseName);
 assert.deepEqual([shared.mode,shared.kind,shared.fresh,shared.persist],['postgres','transient',true,null]);
 assert.match(shared.databaseName,new RegExp(`^opencast_t_${shared.run}_\\d+$`));
 const given=probeWorker('polling-runtime');
 workers=NAMES.map(name=>shared.bind({...given,name},{direct:true}));
 assert.equal(given.bindings,undefined,'bind copies, never mutates its input');
 const url=`postgresql://opencast_local_runtime:opencast-local-runtime@${host}:${port}/${shared.databaseName}?sslmode=disable`;
 for(const w of workers){assert.equal(w.hyperdrives.DB,url);assert.equal(w.d1Databases,undefined);assert.equal(w.bindings.STORAGE_AUTHORITY,'postgres');}
 const aliases=NAMES.map(name=>shared.alias(name));
 assert.deepEqual(aliases,NAMES.map(name=>`${shared.databaseName}.${name}`));assert.equal(new Set(aliases).size,3);
 assert.equal((await admin.query("SELECT COUNT(*) AS n FROM pg_database WHERE datname LIKE $1",[`opencast\\_t\\_${shared.run}\\_%`])).rows[0].n,1,'one database for the three Workers');
 // Without direct: the Worker's alias on the wire proxy (test-proxy.mjs covers it); not an entry, so no TEST_STORAGE.
 const proxied=shared.bind(given);
 assert.equal(proxied.hyperdrives.DB,`postgresql://opencast_local_runtime:opencast-local-runtime@127.0.0.1:${shared.proxy.listenPort}/${shared.databaseName}.polling-runtime?sslmode=disable`);
 assert.equal(proxied.serviceBindings?.TEST_STORAGE,undefined);
 const db=await shared.database(null,'APP_ATTEST_DB','polling-runtime');
 assert.equal(await shared.database(null,'APP_ATTEST_DB','delivery-runtime'),db,'one owner handle per storage');
 await assert.rejects(shared.database(null,'OTHER_DB'),/only APP_ATTEST_DB/);
 assert.ok((await db.prepare('SELECT COUNT(*) AS n FROM n_control').first('n'))>0);
 assert.deepEqual(await backendsOn(shared.databaseName),[shared.application],'the owner backend names the run');
 const registry=await registryOf(shared.databaseName);
 assert.deepEqual(Object.keys(registry),['kind','run','persist','created_at','owner_claimed_at','identity']);
 assert.deepEqual([registry.kind,registry.run,registry.persist,registry.identity],['transient',shared.run,null,self]);
});
// The URL above under an upstream host that is not the proxy's loopback (as a
// CI service is): a relay on another loopback address reaches this server, and
// a fresh process names it as OPENCAST_PG_HOST. 127.0.0.2 where the whole
// 127/8 is loopback (Linux), else `localhost` held to ::1 alone, so a URL
// naming it cannot fall back to the proxy's 127.0.0.1.
async function relay(){
 for(const [address,alias] of [['127.0.0.2','127.0.0.2'],['::1','localhost']]){
  const accepted=[],server=net.createServer(down=>{
   accepted.push(down);const up=net.connect({host,port});
   for(const [a,b] of [[down,up],[up,down]])a.on('error',()=>b.destroy()).on('close',()=>b.destroy());
   down.pipe(up).pipe(down);
  });
  try{await new Promise((resolve,reject)=>{server.once('error',reject);server.listen(0,address,resolve);});}
  catch(error){if(error.code==='EADDRNOTAVAIL'||error.code==='EAFNOSUPPORT')continue;throw error;}
  return {alias,port:server.address().port,accepted,close:()=>new Promise(resolve=>{for(const s of accepted)s.destroy();server.close(resolve);})};
 }
 throw Error('no loopback address but 127.0.0.1 here (neither 127.0.0.2 nor ::1) to relay from');
}
await test('a distinct upstream host: owner, maintenance, direct and the proxy\'s upstream name it; the proxied binding names the proxy\'s listener; both runtime-role queries succeed',async()=>{
 const hop=await relay();
 try{
  const r=await result(`
import dns from 'node:dns';
import net from 'node:net';
import {openStorage} from '${storageUrl}';
import {Client} from '${clientUrl}';
dns.setDefaultResultOrder('ipv6first');net.setDefaultAutoSelectFamily(false);
const targets=[],connect=net.connect;
net.connect=function(...args){const o=args[0];if(o&&typeof o==='object')targets.push(o.host+':'+o.port);return connect.apply(this,args);};
const phase=async work=>{const from=targets.length,value=await work();return {value:value??null,targets:targets.slice(from)};};
const query=async url=>{
 const u=new URL(url),c=await Client.connect({host:u.hostname,port:Number(u.port),user:decodeURIComponent(u.username),password:decodeURIComponent(u.password),database:decodeURIComponent(u.pathname.slice(1)),application:'storage-test-routing'});
 try{return (await c.query('SELECT current_user::text AS role,current_database()::text AS database')).rows[0];}finally{await c.close();}
};
const open=await phase(()=>openStorage()),storage=open.value;
const out={name:storage.databaseName,listener:storage.proxy.server.address(),open:open.targets};
try{
 const direct=storage.bind({name:'routing-direct'},{direct:true}),proxied=storage.bind({name:'routing-proxied'});
 Object.assign(out,{direct:direct.hyperdrives.DB,proxied:proxied.hyperdrives.DB});
 out.owner=await phase(async()=>(await storage.database()).prepare('SELECT COUNT(*) AS n FROM n_control').first('n'));
 out.viaDirect=await phase(()=>query(out.direct));
 out.viaProxy=await phase(()=>query(out.proxied));
}catch(error){out.error=error.code??error.message;}
finally{const d=await phase(()=>storage.dispose().catch(error=>error.message));out.dispose=d.targets;if(d.value)out.disposeError=d.value;}
console.log(JSON.stringify(out));`,{OPENCAST_PG_HOST:hop.alias,OPENCAST_PG_PORT:String(hop.port)});
  created.add(r.name);
  assert.deepEqual([r.error,r.disposeError],[undefined,undefined],`${r.error}: direct ${r.direct}, proxied ${r.proxied}`);
  const upstream=`${hop.alias}:${hop.port}`,listener=`${r.listener.address}:${r.listener.port}`,runtime='postgresql://opencast_local_runtime:opencast-local-runtime';
  assert.equal(r.listener.address,'127.0.0.1','the proxy listens on loopback');
  assert.equal(r.direct,`${runtime}@${upstream}/${r.name}?sslmode=disable`);
  assert.equal(r.proxied,`${runtime}@${listener}/${r.name}.routing-proxied?sslmode=disable`);
  for(const via of [r.viaDirect,r.viaProxy])assert.deepEqual(via.value,{role:'opencast_local_runtime',database:r.name});
  assert.deepEqual(r.viaDirect.targets,[upstream]);
  assert.deepEqual(r.viaProxy.targets,[listener,upstream],'the client reaches the listener, the proxy the upstream');
  assert.ok(r.owner.value>0);
  assert.deepEqual([r.open,r.owner.targets,r.dispose],[[upstream],[upstream],[upstream]],'maintenance, owner handle, maintenance');
  assert.equal(hop.accepted.length,5,'each upstream connection reached the server through the configured host');
  assert.equal(await exists(r.name),false,'dispose dropped it');
 }finally{await hop.close();}
});
await test('live postgres: Miniflare Workers bound direct see STORAGE_AUTHORITY=postgres, DB on the one database, no APP_ATTEST_DB',async()=>{
 const mf=new Miniflare(convertV4MiniflareOptions({cf:false,workers}));
 try{
  await mf.ready;
  for(const name of NAMES){
   const env=await (await (await mf.getWorker(name)).fetch('https://probe.invalid/')).json();
   assert.deepEqual(env,{authority:'postgres',db:true,database:shared.databaseName,d1:false},name);
  }
 }finally{await mf.dispose();}
 await shared.dispose();
 assert.equal(await exists(shared.databaseName),false,'dispose dropped it');
 await shared.dispose(); // idempotent
 assert.throws(()=>shared.bind(workers[0],{direct:true}),/disposed/);
},120000);

await test('dispose: onDispose hooks run first and in order; a failing hook is thrown after cleanup completes',async()=>{
 const s=await openStorage();created.add(s.databaseName);
 const db=await s.database();await db.prepare('SELECT COUNT(*) AS n FROM n_control').first();
 const order=[];
 s.onDispose(async()=>{order.push(['first',await backendsOn(s.databaseName)]);await sleep(20);});
 s.onDispose(()=>{order.push(['second']);throw Error('witness: an unfired arming');});
 s.onDispose(()=>{order.push(['third']);});
 await assert.rejects(s.dispose(),error=>error instanceof AggregateError&&/witness: an unfired arming/.test(error.message)&&error.errors.length===1);
 assert.deepEqual(order,[['first',[s.application]],['second'],['third']],'hooks ran before the owner handle closed');
 assert.equal(await exists(s.databaseName),false,'the drop still ran');
 assert.throws(()=>s.onDispose(()=>{}),/already disposed/);
});
await test('dispose: a remaining backend fails dispose, named by application_name, and the database is not dropped (no FORCE)',async()=>{
 const s=await openStorage();created.add(s.databaseName);
 const straggler=await ownerClient(s.databaseName,`storage-test-${tag}-straggler`);
 const started=Date.now();
 await assert.rejects(s.dispose(),new RegExp(`backends remain on ${s.databaseName} after 5000 ms: pid \\d+ application_name 'storage-test-${tag}-straggler' \\(client backend\\)`));
 assert.ok(Date.now()-started>=5000,'the bounded wait ran');
 assert.equal(await exists(s.databaseName),true);
 assert.deepEqual((await straggler.query('SELECT 1 AS one')).rows,[{one:1}],'nothing terminated');
 await straggler.close();await drained(s.databaseName);
 await admin.simple(`DROP DATABASE "${s.databaseName}"`);
},30000);

const persist=`t3test_${tag}`,persistent=`opencast_p_${persist}`;
const feed=`https://storage-test.invalid/${tag}`;
let claim=null;
await test('persistent: created fresh and registered with this process as owner',async()=>{
 created.add(persistent);
 const a=await openStorage({persist});
 assert.deepEqual([a.kind,a.databaseName,a.fresh,a.persist],['persistent',persistent,true,persist]);
 const registry=await registryOf(persistent);
 assert.deepEqual([registry.kind,registry.persist,registry.identity],['persistent',persist,self]);
 const now=Math.floor(Date.now()/1000);
 await (await a.database()).prepare('INSERT INTO n_feed_catalog(feed_url,source_url,created_at,updated_at) VALUES(?,?,?,?)').bind(feed,feed,now,now).run();
 claim=a;
});
await test('ownership: a live persistent reopen is refused (another process), and so is --persistent while its owner is alive',async()=>{
 const r=await result(`
import {openStorage} from '${storageUrl}';
let refused=null;try{const s=await openStorage({persist:'${persist}'});await s.dispose();}catch(error){refused=error.message;}
console.log(JSON.stringify({refused}));`);
 assert.equal(r.refused,`persistent database ${persistent} is claimed: owner pid ${process.pid} is alive, signalable`);
 const p=await prunes('--persistent',persist);
 assert.equal(p.code,1,'a refusal exits 1');
 assert.deepEqual(verdict(p,persistent),{verdict:'refused',reason:`owner pid ${process.pid} is alive, signalable`});
 assert.equal(await exists(persistent),true);
 const plain=await prunes();
 assert.equal(plain.lines.has(persistent),false,'prune without --persistent never touches opencast_p_*');
});
await test('persistent: dispose releases the claim; the reopen claims it again and shows the same rows',async()=>{
 const before=await registryOf(persistent);
 await claim.dispose();
 const released=await registryOf(persistent);
 assert.deepEqual(released,{...before,identity:null});
 const b=await openStorage({persist});
 assert.equal(b.fresh,false,'reopened, not cloned');
 const claimed=await registryOf(persistent);
 assert.deepEqual([claimed.identity,claimed.created_at],[self,before.created_at]);
 assert.ok(claimed.owner_claimed_at>before.owner_claimed_at);
 assert.deepEqual((await (await b.database()).prepare('SELECT feed_url,source_url FROM n_feed_catalog WHERE feed_url=?').bind(feed).all()).results,[{feed_url:feed,source_url:feed}]);
 await b.dispose();
 assert.equal((await registryOf(persistent)).identity,null);
});
await test('ownership: a dead owner\'s persistent claim is taken over; --persistent drops a released one',async()=>{
 const c=child(`
import {openStorage} from '${storageUrl}';
const s=await openStorage({persist:'${persist}'});
console.log(JSON.stringify({pid:process.pid}));
setInterval(()=>{},1000);`);
 assert.equal((await c.next()).pid,c.pid);
 assert.equal((await registryOf(persistent)).identity.pid,c.pid);
 c.kill('SIGKILL');await c.exit;
 const t=await openStorage({persist});
 assert.deepEqual((await registryOf(persistent)).identity,self,'the claim names this process');
 await t.dispose();
 const p=await prunes('--persistent',persist);
 assert.deepEqual(verdict(p,persistent),{verdict:'dropped',reason:'released'});
 assert.equal(await exists(persistent),false);
});

let a=null,b=null;
await test('two concurrent child suites with disjoint runs; prune keeps both while they are alive',async()=>{
 a=child(TRANSIENT_CHILD);b=child(TRANSIENT_CHILD);
 const [ra,rb]=await Promise.all([a.next(),b.next()]);
 created.add(ra.name);created.add(rb.name);a.info=ra;b.info=rb;
 assert.notEqual(ra.run,rb.run);assert.notEqual(ra.name,rb.name);
 assert.deepEqual([ra.name,rb.name],[`opencast_t_${ra.run}_1`,`opencast_t_${rb.run}_1`]);
 assert.ok(await exists(ra.name)&&await exists(rb.name));
 const p=await prunes();
 assert.equal(p.code,0,p.stderr);
 assert.deepEqual(verdict(p,ra.name),{verdict:'kept',reason:`owner pid ${ra.pid} is alive, signalable`});
 assert.deepEqual(verdict(p,rb.name),{verdict:'kept',reason:`owner pid ${rb.pid} is alive, signalable`});
},60000);
await test('a SIGKILLed child\'s transient database is dropped by prune while the live sibling\'s is kept',async()=>{
 assert.ok(a&&b,'needs the two children');
 a.kill('SIGKILL');assert.equal((await a.exit).signal,'SIGKILL');
 await drained(a.info.name);
 const p=await prunes();
 assert.deepEqual(verdict(p,a.info.name),{verdict:'dropped',reason:`owner pid ${a.info.pid} is gone (ESRCH)`});
 assert.deepEqual(verdict(p,b.info.name).verdict,'kept');
 assert.equal(await exists(a.info.name),false);assert.equal(await exists(b.info.name),true);
 b.send('dispose\n');assert.deepEqual(await b.next(),{disposed:true});assert.equal((await b.exit).code,0);
 assert.equal(await exists(b.info.name),false);
},60000);
await test('a stale-name collision is refused, never dropped and recreated',async()=>{
 const s=await openStorage();created.add(s.databaseName);
 const n=Number(s.databaseName.split('_').at(-1)),next=`opencast_t_${s.run}_${n+1}`;
 await fake(next,null);
 await assert.rejects(openStorage(),new RegExp(`^Error: stale database ${next}: run local-postgres.sh prune$`));
 assert.equal(await exists(next),true);assert.equal(await registryOf(next),null,'left untouched');
 await s.dispose();
 await admin.simple(`DROP DATABASE "${next}"`);
});

// ---- The death rule, each case a hand-registered transient.
await test('ownership: a reused pid (a live pid with another start) is pruned as dead',async()=>{
 const name=await fake(`opencast_t_${fakeRun()}_1`,entry({...self,start:'0'}));
 const p=await prunes();
 assert.deepEqual(verdict(p,name),{verdict:'dropped',reason:`owner pid ${process.pid} was reused: started ${self.start}, registered 0`});
 assert.equal(await exists(name),false);
});
await test('ownership: pid 1 (EPERM) is kept and reported',async()=>{
 const name=await fake(`opencast_t_${fakeRun()}_1`,entry({...self,pid:1,start:processIdentity(1).start}));expectedLeft.add(name);
 const p=await prunes();
 const v=verdict(p,name);
 assert.equal(v.verdict,'kept');
 if(process.getuid?.()!==0)assert.equal(v.reason,'owner pid 1 is alive, unsignalable (EPERM)');
 assert.equal(await exists(name),true);
});
await test('ownership: a foreign boot or host is kept and reported, even when the pid is gone here',async()=>{
 const pid=await deadPid();
 const boot=await fake(`opencast_t_${fakeRun()}_1`,entry({...self,pid,boot:'00000000-0000-0000-0000-000000000000'}));expectedLeft.add(boot);
 const host=await fake(`opencast_t_${fakeRun()}_1`,entry({...self,pid,host:'elsewhere.invalid'}));expectedLeft.add(host);
 const control=await fake(`opencast_t_${fakeRun()}_1`,entry({...self,pid}));
 const p=await prunes();
 assert.deepEqual(verdict(p,boot),{verdict:'kept',reason:`foreign boot 00000000-0000-0000-0000-000000000000 (here ${self.boot})`});
 assert.deepEqual(verdict(p,host),{verdict:'kept',reason:`foreign host elsewhere.invalid (here ${self.host})`});
 assert.deepEqual(verdict(p,control),{verdict:'dropped',reason:`owner pid ${pid} is gone (ESRCH)`});
 assert.ok(await exists(boot)&&await exists(host));
});
await test('ownership: missing or malformed registry metadata is kept as unknown',async()=>{
 const none=await fake(`opencast_t_${fakeRun()}_1`,null);expectedLeft.add(none);
 const junk=await fake(`opencast_t_${fakeRun()}_1`,'not json');expectedLeft.add(junk);
 const partial=await fake(`opencast_t_${fakeRun()}_1`,entry({...self,start:undefined}));expectedLeft.add(partial);
 const p=await prunes();
 assert.deepEqual(verdict(p,none),{verdict:'kept',reason:'unknown: no storage registry'});
 assert.deepEqual(verdict(p,junk),{verdict:'kept',reason:'unknown: no storage registry'});
 assert.deepEqual(verdict(p,partial),{verdict:'kept',reason:'unknown owner: missing or malformed identity'});
});
await test('ownership: prune refused on a concurrent backend: the precheck refusal, the DROP\'s 55006, nothing terminated',async()=>{
 const pid=await deadPid();
 const name=await fake(`opencast_t_${fakeRun()}_1`,entry({...self,pid}));
 const held=await ownerClient(name,`storage-test-${tag}-concurrent`);
 const p=await prunes();
 assert.equal(p.code,1,'a refusal exits 1');
 assert.match(verdict(p,name).reason,new RegExp(`^owner pid ${pid} is gone \\(ESRCH\\); 1 backend\\(s\\) connected: pid \\d+ application_name 'storage-test-${tag}-concurrent' \\(client backend\\)$`));
 assert.equal(verdict(p,name).verdict,'refused');
 assert.deepEqual((await held.query('SELECT 1 AS one')).rows,[{one:1}],'the precheck terminated nothing');
 await held.close();await drained(name);
 // A session that arrives after the precheck: DROP without FORCE fails 55006.
 let late=null;
 const results=await prune({beforeDrop:async n=>{if(n===name)late=await ownerClient(name,`storage-test-${tag}-late`);}});
 const r=results.find(x=>x.database===name);
 assert.equal(r.verdict,'refused');assert.equal(r.code,'55006');
 assert.match(r.reason,new RegExp(`^owner pid ${pid} is gone \\(ESRCH\\); DROP DATABASE refused \\(55006\\): database "${name}" is being accessed by other users$`));
 assert.ok(late,'the late session connected');
 assert.deepEqual((await late.query('SELECT 1 AS one')).rows,[{one:1}],'the DROP terminated nothing');
 await late.close();await drained(name);
 const after=await prunes();
 assert.deepEqual(verdict(after,name),{verdict:'dropped',reason:`owner pid ${pid} is gone (ESRCH)`});
 assert.equal(await exists(name),false);
},60000);

// ---- The end: what prune had to keep is dropped here; nothing else may remain.
for(const name of created){
 if(!(await exists(name)))continue;
 if(!expectedLeft.has(name)){failed++;console.log(`not ok ${name} was left behind`);}
 try{await drained(name);await admin.simple(`DROP DATABASE "${name}"`);}catch(error){failed++;console.log(`not ok DROP DATABASE ${name}: ${error.message}`);}
}
const left=(await admin.query('SELECT datname::text AS name FROM pg_database WHERE datname = ANY($1::text[])',[`{${[...created].join(',')}}`])).rows.map(r=>r.name);
if(left.length){failed++;console.log(`not ok databases remain: ${left.join(', ')}`);}
else console.log(`ok all ${created.size} databases this test created are gone`);
await admin.close();
rmSync(scratch,{recursive:true,force:true});
if(failed){console.log(`${failed} failed`);process.exit(1);}
console.log('test-storage: all passed');
