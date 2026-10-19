// The Miniflare suites' storage: the Worker binding, the database's lifetime
// and prune.
//
// Storage is PostgreSQL: one clone of opencast_template per storage on the
// local topology (postgres/local/local-postgres.sh), registered by COMMENT ON
// DATABASE {kind, run, persist, created_at, owner_claimed_at, identity}:
// transient opencast_t_<run>_<n> is dropped by dispose(); persistent
// opencast_p_<name> is claimed by openStorage({persist}) and released
// (identity cleared) by dispose(). OPENCAST_TEST_STORAGE may be unset or
// postgres; it is read at the first openStorage(), never at import (a suite's
// own header runs after its static imports), and any other value, d1
// included, throws before a socket opens. A Worker that declares D1 bindings is
// refused at bind(). Each openStorage() and bind() prints one line to stderr
// naming the endpoint, the database and the routing.
// A killed run leaves its databases to `node storage.mjs prune [--persistent
// <name>]` (local-postgres.sh prune): it drops only a database whose registered
// owner is dead by ownerState's rule and that has no backend, never WITH (FORCE).
// Nothing relies on process.on('exit').
// bind(worker) routes the Worker through the process's one wire proxy
// (postgres/proxy.mjs) on its alias <database>.<worker name>; an instrumented
// test entry also gets TEST_STORAGE, the Node function that arms the alias's
// storage hooks and answers its state, counters and witness. dispose() rejects
// the witness (an unfired arming, an unexpected unreleased hold, any proxy
// error) after cleanup. bind(worker, {direct: true}) bypasses the proxy: only
// for a suite that arms no storage hook and reads no storage counter, verified
// from the suite's source, not assumed.
import {execFileSync} from 'node:child_process';
import {randomBytes} from 'node:crypto';
import {readFileSync,readlinkSync} from 'node:fs';
import os from 'node:os';
import {setTimeout as sleep} from 'node:timers/promises';
import {Client,PostgresError} from './postgres/pg.mjs';
import {Database} from './postgres/database.mjs';
import {WireProxy} from './postgres/proxy.mjs';
import {ENTRIES,entryOf} from './postgres/hooks.mjs';

// OPENCAST_PG_HOST reaches a database outside this host's loopback (a CI
// service container): the maintenance and owner clients, a direct binding and
// the wire proxy's upstream use it. The proxy itself listens on loopback, so a
// proxied binding names the proxy's listener, never this host.
const HOST=process.env.OPENCAST_PG_HOST??'127.0.0.1',TEMPLATE='opencast_template',OWNER='opencast_local_owner',RUNTIME='opencast_local_runtime';
// The local topology's fixed fixture passwords (local-postgres.sh), never secrets.
const PASSWORD={postgres:'opencast-local-postgres',[OWNER]:'opencast-local-owner',[RUNTIME]:'opencast-local-runtime'};
const DRAIN_MS=5000,LOCK_SPACE='opencast-storage';
// Once per process, not the pid: a pid is reused after a crash.
const RUN=randomBytes(6).toString('hex');
const PERSIST_NAME=/^[a-z0-9_]{1,52}$/; // opencast_p_ + 52 = PostgreSQL's 63
let instances=0,wire=null;

function readMode(){
 const value=process.env.OPENCAST_TEST_STORAGE;
 if(value==='d1')throw Error('D1 storage was removed; the suites run on the local PostgreSQL topology: launch without OPENCAST_TEST_STORAGE');
 if(value!==undefined&&value!=='postgres')throw Error(`OPENCAST_TEST_STORAGE must be postgres or unset, not ${JSON.stringify(value)}`);
 return 'postgres';
}
const banner=line=>process.stderr.write(`storage: ${line}\n`);
function pgPort(){
 const raw=process.env.OPENCAST_PG_PORT??'55432';
 if(!/^[0-9]{1,5}$/.test(raw)||Number(raw)<1||Number(raw)>65535)throw Error(`OPENCAST_PG_PORT must be a port number, not ${raw}`);
 return Number(raw);
}

// ---- Process identity: the one reader used to register and to judge.
const ENV_C={...process.env,LC_ALL:'C',TZ:'UTC'}; // ps lstart's text must not vary with locale or zone
const output=(file,args)=>{try{return execFileSync(file,args,{encoding:'utf8',stdio:['ignore','pipe','ignore'],env:ENV_C}).trim()||null;}catch{return null;}};
const text=path=>{try{return readFileSync(path,'utf8').trim()||null;}catch{return null;}};
const link=path=>{try{return readlinkSync(path)||null;}catch{return null;}};
let boot=null;
// Field 22 of /proc/<pid>/stat, starttime in clock ticks since boot. Field 2,
// the command, is parenthesized and may itself hold spaces and parentheses.
export function statStartTicks(stat){
 const close=typeof stat==='string'?stat.lastIndexOf(')'):-1;
 if(close<0)return null;
 const value=stat.slice(close+2).split(' ')[19]; // index 0 is field 3
 return /^[0-9]+$/.test(value??'')?value:null;
}
// darwin: kern.bootsessionuuid and ps lstart (the kernel's start time at second
// resolution, what proc_pidinfo exposes, read without native code). linux: the
// boot id, the pid namespace and the start ticks. An unreadable value is null.
export function processIdentity(pid=process.pid){
 if(!Number.isSafeInteger(pid)||pid<=0)throw TypeError(`processIdentity needs a positive pid, not ${pid}`);
 const host=os.hostname();
 if(process.platform==='darwin'){
  boot??=output('/usr/sbin/sysctl',['-n','kern.bootsessionuuid']);
  return {platform:'darwin',host,boot,pid,start:output('/bin/ps',['-p',String(pid),'-o','lstart='])};
 }
 if(process.platform==='linux'){
  boot??=text('/proc/sys/kernel/random/boot_id');
  return {platform:'linux',host,boot,pid_ns:link(`/proc/${pid}/ns/pid`),pid,start:statStartTicks(text(`/proc/${pid}/stat`))};
 }
 throw Error(`processIdentity: unsupported platform ${process.platform}`);
}
const filled=v=>typeof v==='string'&&v.length>0;
function validIdentity(id){
 return !!id&&typeof id==='object'&&(id.platform==='darwin'||id.platform==='linux')&&filled(id.host)&&filled(id.boot)
  &&Number.isSafeInteger(id.pid)&&id.pid>0&&filled(id.start)&&(id.platform!=='linux'||filled(id.pid_ns));
}
const sameOwner=(a,b)=>!!a&&!!b&&['platform','host','boot','pid_ns','pid','start'].every(k=>a[k]===b[k]);
// The death rule. The owner is DEAD only when kill(pid, 0) throws ESRCH, or
// the pid exists (success or EPERM) on this host, boot and (linux) pid
// namespace with another start time: a reused pid. Everything else keeps the
// database: EPERM with a matching or unreadable start, a foreign host, boot or
// namespace (checked first: there the pid names another process), or a
// missing or malformed identity.
export function ownerState(identity,self=processIdentity()){
 if(!validIdentity(identity))return {dead:false,reason:'unknown owner: missing or malformed identity'};
 if(!validIdentity(self))return {dead:false,reason:'this process identity is unreadable'};
 for(const key of ['platform','host','boot',...(self.platform==='linux'?['pid_ns']:[])])
  if(identity[key]!==self[key])return {dead:false,reason:`foreign ${key} ${identity[key]} (here ${self[key]})`};
 const {pid}=identity;let signal='signalable';
 try{process.kill(pid,0);}catch(error){
  if(error.code==='ESRCH')return {dead:true,reason:`owner pid ${pid} is gone (ESRCH)`};
  if(error.code!=='EPERM')return {dead:false,reason:`kill(${pid}, 0) failed with ${error.code}`};
  signal='unsignalable (EPERM)';
 }
 const start=processIdentity(pid).start;
 if(start===null)return {dead:false,reason:`owner pid ${pid} is alive, ${signal}, start unreadable`};
 if(start!==identity.start)return {dead:true,reason:`owner pid ${pid} was reused: started ${start}, registered ${identity.start}`};
 return {dead:false,reason:`owner pid ${pid} is alive, ${signal}`};
}

// ---- Maintenance: the superuser on the postgres database, orchestration only.
async function maintenance(application){
 const port=pgPort();
 try{return await Client.connect({host:HOST,port,user:'postgres',password:PASSWORD.postgres,database:'postgres',application});}
 catch(error){throw Error(`local PostgreSQL at ${HOST}:${port}: ${error.message} (is local-postgres.sh status 0?)`,{cause:error});}
}
const quote=name=>{if(!/^opencast_[tp]_[a-z0-9_]+$/.test(name)||name.length>63)throw Error(`not a storage database name: ${name}`);return `"${name}"`;};
const literal=s=>`'${s.replace(/'/g,"''")}'`;
// Per-name session lock: create+register, claim, release and prune's
// judge+drop never interleave, so two openers cannot both claim one name.
async function locked(client,name,work){
 await client.query('SELECT pg_advisory_lock(hashtext($1),hashtext($2))',[LOCK_SPACE,name]);
 try{return await work();}
 finally{await client.query('SELECT pg_advisory_unlock(hashtext($1),hashtext($2))',[LOCK_SPACE,name]).catch(()=>{});}
}
async function registry(client,name){
 const {rows}=await client.query("SELECT shobj_description(oid,'pg_database') AS comment FROM pg_database WHERE datname=$1",[name]);
 if(!rows.length)return {exists:false,entry:null};
 let entry=null;try{entry=JSON.parse(rows[0].comment);}catch{}
 return {exists:true,entry:entry&&typeof entry==='object'&&!Array.isArray(entry)?entry:null};
}
const register=(client,name,entry)=>client.simple(`COMMENT ON DATABASE ${quote(name)} IS ${literal(JSON.stringify(entry))}`);
// DROP DATABASE stops autovacuum workers itself; every other backend is a session.
const backends=async(client,name)=>(await client.query("SELECT pid,application_name,backend_type FROM pg_stat_activity WHERE datname=$1 AND backend_type<>'autovacuum worker' ORDER BY pid",[name])).rows;
const sessions=rows=>rows.map(r=>`pid ${r.pid} application_name '${r.application_name}' (${r.backend_type})`).join(', ');
const failure=(what,errors)=>new AggregateError(errors,`${what}: ${errors.map(e=>e.message).join('; ')}`);
async function runHooks(hooks){
 const errors=[];
 for(const fn of hooks){try{await fn();}catch(error){errors.push(error instanceof Error?error:Error(String(error)));}}
 return errors;
}

// The wire proxy, started by the process's first postgres storage (so bind()
// stays synchronous) and unreferenced: it never keeps a finished suite alive.
function wireProxy(){
 wire??=(async()=>{const proxy=new WireProxy({host:HOST,port:pgPort(),owner:{user:OWNER,password:PASSWORD[OWNER]}});await proxy.listen();return proxy;})()
  .catch(error=>{wire=null;throw error;});
 return wire;
}

// ---- The storage.
export async function openStorage({persist}={}){
 readMode();
 if(persist!==undefined&&(typeof persist!=='string'||!PERSIST_NAME.test(persist)))throw TypeError(`persist must match ${PERSIST_NAME}, not ${JSON.stringify(persist)}`);
 const storage=await PostgresStorage.open(persist);
 banner(`postgres ${HOST}:${storage.port} database ${storage.databaseName} (${storage.kind}), wire proxy on ${storage.proxy.listenHost}:${storage.proxy.listenPort}`);
 return storage;
}

class Storage {
 constructor(){this.hooks=[];this.disposed=null;}
 // Awaited first in dispose(); a failure is collected and thrown after cleanup.
 onDispose(fn){
  if(typeof fn!=='function')throw TypeError('onDispose takes a function');
  if(this.disposed)throw Error('storage is already disposed');
  this.hooks.push(fn);
 }
 check(){if(this.disposed)throw Error('storage is disposed');readMode();}
 // In the suite's finally, AFTER mf.dispose(). Idempotent.
 dispose(){return this.disposed??=this.release();}
}

class PostgresStorage extends Storage {
 static async open(persist){
  const kind=persist===undefined?'transient':'persistent',n=kind==='transient'?++instances:null;
  const name=kind==='transient'?`opencast_t_${RUN}_${n}`:`opencast_p_${persist}`;
  const identity=processIdentity();
  if(!validIdentity(identity))throw Error(`this process identity is unreadable: ${JSON.stringify(identity)}`);
  const proxy=await wireProxy();
  const client=await maintenance(`opencast-storage-${RUN}-open`);
  try{
   const fresh=await locked(client,name,async()=>{
    const now=new Date().toISOString();
    if(kind==='persistent'){
     const {exists,entry}=await registry(client,name);
     if(exists){
      if(entry?.kind!=='persistent'||entry.persist!==persist)throw Error(`database ${name} carries no persistent storage registry: drop it or run local-postgres.sh reset`);
      if(entry.identity!==null){const owner=ownerState(entry.identity,identity);if(!owner.dead)throw Error(`persistent database ${name} is claimed: ${owner.reason}`);}
      await register(client,name,{...entry,owner_claimed_at:now,identity});
      return false;
     }
    }
    try{await client.simple(`CREATE DATABASE ${quote(name)} TEMPLATE ${TEMPLATE} OWNER ${OWNER}`);}
    catch(error){
     if(error instanceof PostgresError&&error.code==='42P04')throw Error(`stale database ${name}: run local-postgres.sh prune`,{cause:error});
     throw error;
    }
    try{await register(client,name,{kind,run:RUN,persist:persist??null,created_at:now,owner_claimed_at:now,identity});}
    catch(error){await client.simple(`DROP DATABASE ${quote(name)}`).catch(()=>{});throw error;}
    return true;
   });
   return new PostgresStorage({kind,name,n,persist,identity,fresh,proxy});
  }finally{await client.close().catch(()=>{});}
 }
 constructor({kind,name,n,persist,identity,fresh,proxy}){
  super();
  Object.assign(this,{mode:'postgres',kind,databaseName:name,run:RUN,persist:persist??null,fresh,identity,port:pgPort(),proxy});
  this.aliases=new Set(); // this storage's proxied Workers
  // Names the run, so pg_stat_activity attributes the backend in dispose and prune.
  this.application=`opencast-storage-${RUN}-${n??'p'}-owner`;
  this.handle=null;
 }
 // The wire proxy routes by it; in direct mode the URL names the database.
 alias(workerName){
  if(typeof workerName!=='string'||!workerName)throw TypeError('storage.alias needs a Worker name');
  return `${this.databaseName}.${workerName}`;
 }
 url(target=this.databaseName,{host=HOST,port=this.port}={}){return `postgresql://${RUNTIME}:${PASSWORD[RUNTIME]}@${host}:${port}/${encodeURIComponent(target)}?sslmode=disable`;}
 // bind: the authority explicit, DB on the runtime role; every Worker bound
 // to this storage shares its one database. A Worker that still declares
 // d1Databases is refused before anything starts. Proxied, DB names the
 // Worker's alias on the proxy's listener (its loopback host and port, not
 // OPENCAST_PG_HOST); `hooks` overrides the hook table its entry module implies (null: none; the storage-fixture
 // Worker of test-proxy.mjs's companion probe borrows 'polling'). Miniflare
 // names its Hyperdrive service after the binding (hyperdrive:DB), not the
 // Worker, so all Workers of one instance reach ONE address: never mix direct
 // and proxied Workers in one Miniflare (the loser's startup names an unknown
 // alias or database, loudly).
 bind(worker,{direct=false,hooks}={}){
  this.check();
  if(worker.d1Databases!==undefined)throw Error(`bind: Worker ${worker.name} declares d1Databases (${JSON.stringify(worker.d1Databases)}): D1 storage was removed, so bind no Worker to it`);
  const out={...worker,bindings:{...worker.bindings,STORAGE_AUTHORITY:'postgres'}};
  if(direct){out.hyperdrives={...worker.hyperdrives,DB:this.url()};banner(`bind ${worker.name} direct to ${HOST}:${this.port}/${this.databaseName}`);}
  else{
   const entry=hooks===undefined?entryOf(worker):hooks;
   if(entry!==null&&!ENTRIES.some(([,kind])=>kind===entry))throw TypeError(`bind: hooks must be one of ${ENTRIES.map(([,k])=>k).join(', ')} or null, not ${JSON.stringify(entry)}`);
   const alias=this.alias(worker.name);
   this.proxy.register({alias,database:this.databaseName,entry,worker:worker.name});
   if(!this.aliases.size)this.onDispose(()=>this.teardown());
   this.aliases.add(alias);
   out.hyperdrives={...worker.hyperdrives,DB:this.url(alias,{host:this.proxy.listenHost,port:this.proxy.listenPort})};
   banner(`bind ${worker.name} proxied as ${alias} via ${this.proxy.listenHost}:${this.proxy.listenPort}`);
   if(entryOf(worker)){
    if(worker.serviceBindings?.TEST_STORAGE)throw Error(`bind: Worker ${worker.name} already has a TEST_STORAGE binding`);
    out.serviceBindings={...worker.serviceBindings,TEST_STORAGE:request=>this.proxy.serve(alias,request)};
   }
  }
  return out;
 }
 // TEST_STORAGE's op handler for a proxied Worker, for the suite itself:
 // {op:'witness'|'expect'|'state'|'counters'|'arm'|'release', ...}.
 testStorage(workerName){
  const alias=this.alias(workerName);
  if(!this.aliases.has(alias))throw Error(`storage.testStorage: Worker ${workerName} is not bound through the proxy`);
  return op=>this.proxy.handle(alias,op);
 }
 // The onDispose hook of the first proxied bind: the witness checked once the
 // Workers' connections have closed, then the aliases and the side-write
 // client released whatever it found.
 async teardown(){
  try{
   const problems=await this.proxy.teardown([...this.aliases]);
   if(problems.length)throw Error(`proxy witness on ${this.databaseName}: ${problems.join('; ')}`);
  }finally{
   for(const alias of this.aliases)this.proxy.unregister(alias);
   await this.proxy.closeOwner(this.databaseName);
  }
 }
 // The owner handle on this storage's database (the D1-shaped test API of
 // postgres/database.mjs), one per storage.
 async database(mf,binding='APP_ATTEST_DB'){
  this.check();
  if(binding!=='APP_ATTEST_DB')throw Error(`storage.database: only APP_ATTEST_DB moves to PostgreSQL, not ${binding}`);
  return this.handle??=new Database({host:HOST,port:this.port,database:this.databaseName,user:OWNER,password:PASSWORD[OWNER],application:this.application});
 }
 // The order after mf.dispose(): the hooks (the proxy witness teardown),
 // the owner handle, a bounded wait for zero backends (a remaining one fails,
 // named; never FORCE), then DROP (transient) or the claim released
 // (persistent). Failures are collected and thrown once cleanup has finished.
 async release(){
  const errors=await runHooks(this.hooks),name=this.databaseName;
  const step=async(what,work)=>{try{return await work();}catch(error){errors.push(Error(`${what}: ${error.message}`,{cause:error}));}};
  if(this.handle)await step('close the owner handle',()=>this.handle.close());
  const client=await step('connect',()=>maintenance(`opencast-storage-${RUN}-dispose`));
  if(client){
   const drained=await step('drain',async()=>{
    const deadline=Date.now()+DRAIN_MS;
    for(;;){
     const remaining=await backends(client,name);
     if(!remaining.length)return true;
     if(Date.now()>=deadline)throw Error(`backends remain on ${name} after ${DRAIN_MS} ms: ${sessions(remaining)}`);
     await sleep(100);
    }
   });
   if(this.kind==='transient'){if(drained)await step(`DROP DATABASE ${name}`,()=>locked(client,name,()=>client.simple(`DROP DATABASE ${quote(name)}`)));}
   else await step(`release ${name}`,()=>locked(client,name,async()=>{
    const {exists,entry}=await registry(client,name);
    if(!exists)throw Error('the database is gone');
    if(!sameOwner(entry?.identity,this.identity))throw Error('its registry no longer names this process');
    await register(client,name,{...entry,identity:null});
   }));
   await client.close().catch(()=>{});
  }
  if(errors.length)throw failure(`storage dispose ${name}`,errors);
 }
}

// ---- prune. Every opencast_t_* database, and opencast_p_<name> for each
// --persistent name; one verdict per database: dropped, kept, refused, absent
// or error. A transient is dropped only with a registry naming a DEAD owner
// and zero backends; a persistent one only when released or its owner is
// dead, and with zero backends. DROP has no FORCE: a session that arrives
// after the precheck makes it fail with 55006, reported as a refusal.
// beforeDrop(name) runs between the precheck and the DROP (a test seam).
export async function prune({persistent=[],beforeDrop}={}){
 for(const name of persistent)if(!PERSIST_NAME.test(name))throw TypeError(`--persistent must match ${PERSIST_NAME}, not ${JSON.stringify(name)}`);
 const self=processIdentity(),client=await maintenance(`opencast-storage-prune-${process.pid}`),out=[];
 try{
  const {rows}=await client.query("SELECT datname::text AS name FROM pg_database WHERE starts_with(datname::text,'opencast_t_') ORDER BY 1");
  for(const name of [...rows.map(r=>r.name),...persistent.map(n=>`opencast_p_${n}`)]){
   try{out.push({database:name,...await locked(client,name,()=>judge(client,name,self,beforeDrop))});}
   catch(error){out.push({database:name,verdict:'error',reason:error.message});}
  }
 }finally{await client.close().catch(()=>{});}
 return out;
}
async function judge(client,name,self,beforeDrop){
 quote(name);
 const transient=name.startsWith('opencast_t_'),{exists,entry}=await registry(client,name);
 if(!exists)return {verdict:'absent',reason:'no such database'};
 if(entry?.kind!==(transient?'transient':'persistent')||(!transient&&entry.persist!==name.slice('opencast_p_'.length)))
  return transient?{verdict:'kept',reason:'unknown: no storage registry'}:{verdict:'refused',reason:'no persistent storage registry'};
 const owner=!transient&&entry.identity===null?{dead:true,reason:'released'}:ownerState(entry.identity,self);
 if(!owner.dead)return {verdict:transient?'kept':'refused',reason:owner.reason};
 const connected=await backends(client,name);
 if(connected.length)return {verdict:'refused',reason:`${owner.reason}; ${connected.length} backend(s) connected: ${sessions(connected)}`};
 await beforeDrop?.(name);
 try{await client.simple(`DROP DATABASE ${quote(name)}`);}
 catch(error){
  if(error instanceof PostgresError&&error.code==='55006')return {verdict:'refused',code:'55006',reason:`${owner.reason}; DROP DATABASE refused (55006): ${error.message}`};
  throw error;
 }
 return {verdict:'dropped',reason:owner.reason};
}

if(import.meta.main){
 const [command,...args]=process.argv.slice(2),persistent=[];
 const usage=()=>{console.error('usage: node storage.mjs prune [--persistent <name>]...');process.exit(2);};
 if(command!=='prune')usage();
 for(let i=0;i<args.length;i++){if(args[i]==='--persistent'&&PERSIST_NAME.test(args[i+1]??''))persistent.push(args[++i]);else usage();}
 try{
  const results=await prune({persistent}),count={};
  for(const r of results){console.log(`${r.database} ${r.verdict}: ${r.reason}`);count[r.verdict]=(count[r.verdict]??0)+1;}
  console.error(`prune: ${Object.entries(count).map(([k,v])=>`${v} ${k}`).join(', ')||'no storage databases'}`);
  process.exitCode=results.some(r=>r.verdict==='refused'||r.verdict==='error')?1:0;
 }catch(error){console.error(`prune: ${error.message}`);process.exitCode=1;}
}
