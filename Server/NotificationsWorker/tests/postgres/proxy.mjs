// The wire proxy between the Workers' Hyperdrive sockets and the local
// PostgreSQL topology, promoted from the earlier PostgreSQL integration
// harness's proxy without its ledger, driver-armed lost-acknowledgement hook or
// Miniflare mirror. Beyond that proxy it relays SCRAM authentication, never
// lets an interactive transaction bypass an armed hook, stamps each operation's
// deadline anchors (Z_relay, fire, close), names every arming and fire by id,
// judges exclusivity over whole invocation windows and records each operation's
// own COMMIT reply. One loopback listener per process (listenHost:listenPort,
// whatever the upstream host); each Worker connects to its own alias
// `<database>.<worker>` (storage.mjs), which names the hook table, the witness
// and the counters.
//
// Each connection is startup -> authenticating -> operations:
//  startup        SSLRequest and GSSENCRequest are answered N, as often as
//                 they come, until the StartupMessage, whose database is
//                 rewritten from the alias before it goes upstream.
//  authenticating every message both ways is relayed whole (reassembled across
//                 chunks, split out of coalesced ones) until the first backend
//                 Z; a backend E is relayed and the server closes first. The
//                 relay witness counts the frontend p messages and lists the
//                 backend kinds; a p payload (the client proof) is never kept.
//  operations     typed messages grouped into Sync/Query units. An autocommit
//                 read is one unit; BEGIN ... COMMIT arrives pipelined before
//                 any reply, so the proxy sees the whole transaction before
//                 forwarding any of it, and acts on it as the entry's D1 hook
//                 would (hooks.mjs). Every operation is its own Worker
//                 connection (WorkerDatabaseCore opens one per operation).
// Closing is server-first: Terminate goes upstream and PostgreSQL closes,
// leaving the TIME_WAIT on its side, with a DESTROY_MS fallback.
// The timing controls (timing.mjs) attach at the calls marked `controls.`:
// each returns undefined (or false) when nothing of theirs is armed, which
// leaves the behaviour above as it is.
import net from 'node:net';
import {once} from 'node:events';
import {setTimeout as sleep} from 'node:timers/promises';
import {Client,gatedTransaction} from './pg.mjs';
import {SEARCH_PATH} from './database.mjs';
import {GATE_PREFIX,INTERACTIVE_FIRST,M,SIDE,ACTIONS,HOLDS,isApplication,isStorageHook,match} from './hooks.mjs';
import {Controls} from './timing.mjs';

const i32=n=>{const b=Buffer.alloc(4);b.writeInt32BE(n);return b;};
const frame=(kind,body)=>Buffer.concat([Buffer.from(kind),i32(body.length+4),body]);
const now=()=>performance.timeOrigin+performance.now();
const SSL_REQUEST=80877103,GSSENC_REQUEST=80877104,PROTOCOL=196608,MAX_STARTUP=10000;
// Pipelined units arrive within one client poll (at most 0.13 ms apart in the
// earlier harness's recorded runs); an interactive client waits on each reply.
export const INTERACTIVE_IDLE_MS=50;
// After Terminate, how long PostgreSQL gets to close before the proxy does.
export const DESTROY_MS=2000;
const errorResponse=(severity,code,message)=>frame('E',Buffer.from(`S${severity}\0V${severity}\0C${code}\0M${message}\0\0`));
// fail-in-place: the last application statement's reply becomes 42P01.
const error42P01=()=>Buffer.concat([errorResponse('ERROR','42P01','relation "missing_fixture_table" does not exist'),frame('Z',Buffer.from('E'))]);
const sqlstateOf=msg=>msg.subarray(5).toString().split('\0').find(x=>x.startsWith('C'))?.slice(1)??null;
// rows_written: the trailing count of INSERT/UPDATE/DELETE CommandComplete tags.
const writtenBy=tag=>{const m=/^(?:INSERT \d+|UPDATE|DELETE) (\d+)$/.exec(tag);return m?Number(m[1]):0;};
function rewriteParse(m,sql){const end=m.indexOf(0,5);return frame('P',Buffer.concat([m.subarray(5,end+1),Buffer.from(sql+'\0'),Buffer.from([0,0])]));}
// Internal state rides on a symbol key: JSON (the witness op) never sees it.
const I=Symbol('internal');
const plain=value=>JSON.parse(JSON.stringify(value));

// Per-alias hook state, witness and counters.
class Alias {
 constructor({alias,database,entry,worker}){
  Object.assign(this,{alias,database,entry,worker});
  // The active armings: the entry's one fault slot, the delivery hold, the
  // cancellation header's (one per request in flight).
  this.slot=null;this.auth=null;this.postscans=[];
  this.holds=new Set(); // fired holds not yet released or discarded
  this.counters={statements:0,operations:0,rows_written:0,watchdog_reads:0,in_flight:0};
  this.invocations=new Map();this.invocationSeq=0;
  this.armings=[];this.fires=[];this.released=[];this.discarded=[];this.cleared=[];this.errors=[];this.connections=[];this.operations=[];
  this.open=new Set();
  // Test seam (test-proxy.mjs's slow-rollback control): delay the reply to
  // a client ROLLBACK that follows a held transaction by this many ms.
  this.delays={rollbackReplyMs:0};
 }
 get state(){return {entry:this.entry,slot:this.slot,auth:this.auth,postscan:this.postscans.at(-1)??null};}
 error(kind,detail){const e={kind,at:now(),...detail};this.errors.push(e);return e;}
}

export class WireProxy {
 constructor({host='127.0.0.1',port,owner}){
  Object.assign(this,{host,port:Number(port),owner});
  this.aliases=new Map();this.owners=new Map();this.connections=new Set();this.unrouted=[];
  this.seq={arming:0,fire:0,op:0,conn:0};this.server=null;this.listenHost=null;this.listenPort=null;
  this.controls=new Controls(this,I);
 }
 async listen(){
  if(this.server)return this.listenPort;
  this.server=net.createServer(socket=>new Connection(this,socket));
  this.server.listen(0,'127.0.0.1');await once(this.server,'listening');
  this.server.unref(); // Miniflare's own handles keep a suite alive while it runs
  ({address:this.listenHost,port:this.listenPort}=this.server.address());
  return this.listenPort;
 }
 register({alias,database,entry=null,worker=null}){
  const known=this.aliases.get(alias);
  if(known){if(known.database!==database||known.entry!==entry)throw Error(`proxy alias ${alias} is registered to ${known.database} (${known.entry})`);return known;}
  const a=new Alias({alias,database,entry,worker});this.aliases.set(alias,a);return a;
 }
 unregister(alias){this.aliases.delete(alias);}
 alias(name){const a=this.aliases.get(name);if(!a)throw Error(`no proxy alias ${name}`);return a;}

 // ---- Armings and fires, each with its own id. An arming id is consumed by
 // fires that name it.
 arming(a,fields){const m={id:`A${++this.seq.arming}`,at:now(),fires:[],cleared:null,ended:null,expected:false,...fields};a.armings.push(m);return m;}
 clear(a,m,by){if(!m||m.cleared)return null;m.cleared={at:now(),by};a.cleared.push({arming:m.id,at:m.cleared.at,by,fires:m.fires.length});return m.id;}
 fire(a,d,o,conn){
  const f={id:`F${++this.seq.fire}`,arming:d.arming.id,hook:d.hook,action:d.action,alias:a.alias,conn:conn.id,op:o.id,at:now(),
   statement:o.type==='read'?o.sql:(o.statements[0]??null),follow_up:!!d.follow_up,parent:d.arming.parent??null,released:null,discarded:null,forwarded:null,expected:null};
  f[I]={decision:d};d.arming.fires.push(f.id);a.fires.push(f);
  if(d.consume){if(a.slot===d.arming)a.slot=null;if(a.auth===d.arming)a.auth=null;d.arming.consumed=f.at;}
  // fail-and-arm's follow-up is its own arming, linked to its parent and fire.
  if(d.followUp){const follow=this.arming(a,{kind:'fault',name:d.followUp,always:false,parent:d.arming.id,follow_up_of:f.id});a.slot=follow;f.follow_up_arming=follow.id;}
  this.controls.fired(a,f);
  return f;
 }
 release(a,h,how){
  const f=h.fire;
  if(f.discarded!==null)return 'discarded';
  if(f.released!==null)return 'released';
  f.released=h.op.released=now();a.released.push({fire:f.id,at:f.released,how});a.holds.delete(h);
  h.forward();f.forwarded??=f.released;
  return 'released';
 }
 discard(a,h,reason){
  const f=h.fire;if(f.released!==null||f.discarded!==null)return;
  f.discarded=h.op.discarded=now();a.discarded.push({fire:f.id,at:f.discarded,reason});a.holds.delete(h);
 }

 // ---- TEST_STORAGE (storage.mjs binds it per instrumented Worker).
 async serve(name,request){
  let op;try{op=await request.json();}catch{return Response.json({error:'TEST_STORAGE takes one JSON op'},{status:400});}
  try{return Response.json(this.handle(name,op));}
  catch(error){return Response.json({error:error.message},{status:400});}
 }
 handle(name,op){
  const a=this.alias(name),kind=op?.op;
  const refuse=message=>{a.error('unknown-action',{op:plain(op??null),message});throw Error(message);};
  const controlled=this.controls.handle(a,op);if(controlled!==undefined)return controlled;
  if(kind==='arm'){
   if(op.kind==='fault'){
    if(typeof op.name!=='string')refuse('arm fault needs a name');
    // The entry's one fault variable: any new value replaces the active
    // arming (fault 'none' clears it, queue.mjs:33); a local name arms nothing here.
    const cleared=a.slot?[this.clear(a,a.slot,`fault ${JSON.stringify(op.name)}`)]:[];a.slot=null;
    if(!isStorageHook(a.entry,op.name))return {arming:null,cleared,local:true};
    a.slot=this.arming(a,{kind:'fault',name:op.name,always:op.name.startsWith('always:'),parent:null});
    return {arming:a.slot.id,cleared};
   }
   if(op.kind==='hold-auth-write'){
    if(a.entry!=='delivery'||typeof op.path!=='string')refuse('hold-auth-write is the delivery entry\'s, with a path');
    const cleared=a.auth?[this.clear(a,a.auth,'hold-auth-write')]:[];
    a.auth=this.arming(a,{kind:'hold-auth-write',path:op.path,parent:null});
    return {arming:a.auth.id,cleared};
   }
   if(op.kind==='postscan'){
    if(a.entry!=='cancellation')refuse('postscan is the cancellation entry\'s');
    const m=this.arming(a,{kind:'postscan',parent:null});a.postscans.push(m);return {arming:m.id,cleared:[]};
   }
   if(op.kind==='postscan-done'){
    const m=a.postscans.find(x=>x.id===op.arming);if(!m)refuse(`no active postscan arming ${op.arming}`);
    m.ended=now();a.postscans=a.postscans.filter(x=>x!==m);return {arming:m.id,ended:true};
   }
   refuse(`unknown arm kind ${op.kind}`);
  }
  if(kind==='release'){
   const out={released:[],discarded:[],refused:[]};
   const take=h=>{const r=h.releasable?this.release(a,h,op.fire??op.kind):'refused';out[r==='refused'?'refused':r==='discarded'?'discarded':'released'].push(h.fire.id);};
   if(op.fire!==undefined){
    const f=a.fires.find(x=>x.id===op.fire);if(!f||!HOLDS.has(f.action))refuse(`no fired hold ${op.fire}`);
    const h=f[I].hold;
    if(h)take(h);else if(f.discarded!==null)out.discarded.push(f.id);else if(f.released!==null)out.released.push(f.id);else out.refused.push(f.id);
    return out;
   }
   const route={'release-hang':'hang','release-auth-write':'auth','release-postscan':'postscan'}[op.kind];
   if(!route)refuse(`unknown release kind ${op.kind}`);
   // Holds that already ended on their client's close are reported, not released.
   for(const f of a.fires)if(f[I].decision.release===route&&f.discarded!==null&&!f[I].reported){f[I].reported=true;out.discarded.push(f.id);}
   for(const h of [...a.holds])if(h.fire[I].decision.release===route&&(route!=='postscan'||h.registered))take(h);
   // The polling entry's release-hang also empties its fault variable.
   if(route==='hang'){const c=this.clear(a,a.slot,'release-hang');a.slot=null;if(c)out.cleared=[c];}
   return out;
  }
  if(kind==='state'){
   // Only a FIRED, UNRELEASED hold answers (the earlier harness's rule, kept);
   // null means the entry answers from its own variable.
   const outstanding=route=>[...a.holds].filter(h=>h.fire[I].decision.release===route&&(route!=='postscan'||h.registered));
   if(op.which==='fault-state'){const h=outstanding('hang').at(-1);return h?{value:h.fire[I].decision.active,fire:h.fire.id}:{value:null};}
   if(op.which==='auth-write-held'){const h=outstanding('auth').at(-1);return h?{value:true,fire:h.fire.id}:{value:null};}
   if(op.which==='postscan-reads'){const hs=outstanding('postscan');return hs.length?{value:hs.length,fires:hs.map(h=>h.fire.id)}:{value:null};}
   refuse(`unknown state ${op.which}`);
  }
  if(kind==='counters'){
   const snapshot=()=>({...a.counters,in_flight:a.invocations.size});
   // Exclusivity spans the whole invocation window: one overlapping another
   // marks BOTH non-exclusive, whichever ends first; only these measured
   // invocations count.
   if(op.begin){
    const inv={id:++a.invocationSeq,overlapped:a.invocations.size>0,at:now()};
    for(const other of a.invocations.values())other.overlapped=true;
    a.invocations.set(inv.id,inv);return {invocation:inv.id,...snapshot()};
   }
   if(op.end!==undefined){
    const inv=a.invocations.get(op.end);if(!inv)refuse(`no open invocation ${op.end}`);
    a.invocations.delete(op.end);return {...snapshot(),exclusive:!inv.overlapped};
   }
   return snapshot();
  }
  if(kind==='witness')return this.witness(a);
  if(kind==='expect'){
   // A suite accepts one named outcome by fire or arming id, never by hook
   // name alone.
   if(op.fire!==undefined){const f=a.fires.find(x=>x.id===op.fire);if(!f)refuse(`no fire ${op.fire}`);f.expected=op.outcome??'any';return {fire:f.id,expected:f.expected};}
   if(op.arming!==undefined){const m=a.armings.find(x=>x.id===op.arming);if(!m)refuse(`no arming ${op.arming}`);m.expected=true;return {arming:m.id,expected:true};}
   refuse('expect names a fire or an arming');
  }
  refuse(`unknown TEST_STORAGE op ${JSON.stringify(kind)}`);
 }
 witness(a){
  const {alias,database,entry,worker,counters,armings,fires,released,discarded,cleared,errors,connections,operations}=a;
  const timing=this.controls.witness(a);
  return plain({alias,database,entry,worker,counters:{...counters,in_flight:a.invocations.size},armings,fires,released,discarded,cleared,errors,connections,operations,...(timing?{timing}:{})});
 }
 // Teardown (storage.onDispose): every arming fired (or was expected), every
 // fired hold was released (or its outcome expected), and no error.
 problems(a){
  const out=[];
  for(const m of a.armings)if(!m.fires.length&&!m.expected)out.push(`arming ${m.id} (${m.kind} ${m.name??m.path??''}) never fired${m.cleared?`, cleared by ${m.cleared.by}`:''}`);
  for(const f of a.fires)if(HOLDS.has(f.action)&&f.released===null&&!f.expected)out.push(`fire ${f.id} (${f.hook} ${f.action}) was ${f.discarded!==null?'discarded':'never released'} and not expected`);
  for(const e of a.errors)out.push(`error ${e.kind}: ${JSON.stringify({...e,at:undefined})}`);
  out.push(...this.controls.problems(a));
  return out.map(p=>`${a.alias}: ${p}`);
 }
 async teardown(names,{waitMs=DESTROY_MS+1000}={}){
  const aliases=names.map(n=>this.aliases.get(n)).filter(Boolean);
  // mf.dispose() closed the Workers' sockets; let their upstreams close first.
  const deadline=Date.now()+waitMs;
  while(aliases.some(a=>a.open.size)&&Date.now()<deadline)await sleep(20);
  const out=[];
  for(const a of aliases){
   for(const c of a.open){out.push(`${a.alias}: connection ${c.id} still open at teardown`);c.shutdown('teardown');}
   out.push(...this.problems(a));
  }
  return out;
 }

 // ---- Owner side writes: one client per database, serialized, search_path at startup.
 ownerWrite(database,sql){
  const entry=this.owners.get(database)??{client:null,queue:Promise.resolve()};this.owners.set(database,entry);
  const run=async()=>{
   entry.client??=Client.connect({host:this.host,port:this.port,user:this.owner.user,password:this.owner.password,database,application:'opencast-proxy-side-write',searchPath:SEARCH_PATH}).catch(error=>{entry.client=null;throw error;});
   const [r]=await gatedTransaction(await entry.client,[[sql,[]]]);return r.changes;
  };
  const next=entry.queue.then(run,run);entry.queue=next.catch(()=>{});return next;
 }
 async closeOwner(database){
  const entry=this.owners.get(database);if(!entry)return;this.owners.delete(database);
  await entry.queue;const c=await entry.client?.catch(()=>null);await c?.close();
 }
 async close(){
  for(const c of [...this.connections])c.shutdown('proxy');
  this.server?.close();
  for(const database of [...this.owners.keys()])await this.closeOwner(database).catch(()=>{});
 }
}

class Connection {
 constructor(proxy,client){
  Object.assign(this,{proxy,client,id:`C${++proxy.seq.conn}`,phase:'startup',alias:null,upstream:null,closed:false,upstreamClosed:false});
  this.fbuf=Buffer.alloc(0);this.bbuf=Buffer.alloc(0);
  this.units=[];this.current=null;this.op=null;this.ops=[];this.pending=[];this.relayQueue=[];this.idle=null;
  // The relay witness. frontend_chunks counts TCP reads before the first Z, so
  // a fragmentation test can see that the proxy reassembled.
  this.relay={conn:this.id,alias:null,database:null,user:null,opened:now(),negotiation:[],frontend_chunks:0,frontend_p:0,backend:[],
   Z_relay:null,auth_error:null,close:null,closed_by:null,terminate_sent:null,upstream_end:null,upstream_close:null,upstream_destroyed:null};
  proxy.connections.add(this);
  client.setNoDelay(true);
  client.on('data',chunk=>this.onFrontend(chunk));
  client.on('error',()=>{});
  // After a relayed authentication failure the server closes first; a client
  // that drops the socket on reading the E does not pre-empt it.
  client.on('close',()=>{if(this.phase==='auth-failed')this.relay.client_gone=now();else this.shutdown(this.terminated?'terminate':'client');});
 }
 onFrontend(chunk){
  if(this.closed)return;
  if(this.phase!=='operations')this.relay.frontend_chunks++;
  this.fbuf=Buffer.concat([this.fbuf,chunk]);clearTimeout(this.idle);
  this.pumpFrontend();
  const o=this.op;
  if(!this.closed&&o&&o.type==='txn'&&!o.complete&&o[I].mode==='buffer')this.idle=setTimeout(()=>this.interactive(),INTERACTIVE_IDLE_MS).unref();
 }
 pumpFrontend(){
  for(;;){
   if(this.closed)return;
   if(this.phase==='startup'){
    if(this.fbuf.length<8)return;
    const size=this.fbuf.readInt32BE(0);
    if(size<8||size>MAX_STARTUP){this.refuse('08P01',`proxy: startup packet length ${size}`);return;}
    if(this.fbuf.length<size)return;
    const code=this.fbuf.readInt32BE(4),msg=this.fbuf.subarray(0,size);this.fbuf=this.fbuf.subarray(size);
    if(code===SSL_REQUEST||code===GSSENC_REQUEST){this.relay.negotiation.push(code===SSL_REQUEST?'SSLRequest':'GSSENCRequest');this.client.write('N');continue;}
    if(code!==PROTOCOL){this.refuse('08P01',`proxy: unsupported startup code ${code}`);return;}
    this.startup(msg);continue;
   }
   if(this.phase!=='authenticating'&&this.phase!=='operations')return;
   if(this.fbuf.length<5)return;
   const size=this.fbuf.readInt32BE(1);
   if(size<4){this.refuse('08P01',`proxy: message length ${size}`);return;}
   if(this.fbuf.length<size+1)return;
   const msg=this.fbuf.subarray(0,size+1),kind=String.fromCharCode(msg[0]);this.fbuf=this.fbuf.subarray(size+1);
   if(this.phase==='authenticating'){if(kind==='p')this.relay.frontend_p++;this.upstream.write(msg);continue;}
   this.frontendMessage(kind,msg);
  }
 }
 // Before routing: an unknown alias or a bad packet gets a FATAL and a close.
 refuse(code,message){
  if(!this.alias)this.proxy.unrouted.push({conn:this.id,at:now(),code,message});
  try{this.client.write(errorResponse('FATAL',code,message));}catch{}
  this.shutdown('refused');
 }
 startup(msg){
  const parts=msg.subarray(8).toString().split('\0'),params={};
  for(let k=0;k+1<parts.length;k+=2)if(parts[k])params[parts[k]]=parts[k+1];
  const a=this.proxy.aliases.get(params.database);
  if(!a){this.refuse('3D000',`proxy: no alias ${JSON.stringify(params.database)}`);return;}
  Object.assign(this.relay,{alias:a.alias,database:a.database,user:params.user??null});
  this.alias=a;a.connections.push(this.relay);a.open.add(this);
  params.database=a.database;
  const body=Buffer.concat([...Object.entries(params).flatMap(([k,v])=>[Buffer.from(k+'\0'),Buffer.from(v+'\0')]),Buffer.from([0])]);
  const go=()=>{
   const up=this.upstream=net.connect({host:this.proxy.host,port:this.proxy.port});up.setNoDelay(true);
   up.on('data',chunk=>this.onBackend(chunk));
   up.on('end',()=>{this.relay.upstream_end??=now();});
   up.on('error',()=>{});
   up.on('close',()=>{this.upstreamClosed=true;this.relay.upstream_close=now();clearTimeout(this.destroyTimer);this.shutdown('server');a.open.delete(this);this.proxy.connections.delete(this);});
   up.write(Buffer.concat([i32(body.length+8),i32(PROTOCOL),body]));
   this.phase='authenticating';
  };
  if(this.proxy.controls.startup(this,go))return;
  go();
 }
 onBackend(chunk){
  this.bbuf=Buffer.concat([this.bbuf,chunk]);
  while(this.bbuf.length>=5){
   const size=this.bbuf.readInt32BE(1);if(this.bbuf.length<size+1)break;
   const msg=this.bbuf.subarray(0,size+1),kind=String.fromCharCode(msg[0]);this.bbuf=this.bbuf.subarray(size+1);
   if(this.closed)continue;
   if(this.phase==='authenticating'){
    this.client.write(msg);
    this.relay.backend.push(kind==='R'&&size>=8?`R${msg.readInt32BE(5)}`:kind);
    // A failed authentication (28P01): relayed, then PostgreSQL closes first.
    if(kind==='E'){this.relay.auth_error=sqlstateOf(msg);this.phase='auth-failed';this.destroyTimer=setTimeout(()=>this.shutdown('auth-timeout'),DESTROY_MS).unref();continue;}
    if(kind==='Z'){this.relay.Z_relay=now();this.phase='operations';}
    continue;
   }
   if(this.phase==='operations')this.backendMessage(kind,msg);
  }
 }
 frontendMessage(kind,msg){
  if(kind==='X'){this.terminated=true;this.shutdown('terminate');return;}
  const u=this.current??={messages:[],sql:null};u.messages.push(msg);
  if(kind==='P'){const end=msg.indexOf(0,5);u.sql=msg.subarray(end+1,msg.indexOf(0,end+1)).toString();this.count(u.sql);}
  if(kind==='Q'){u.sql=msg.subarray(5,msg.length-1).toString();this.count(u.sql);}
  if(kind==='S'||kind==='Q'){this.units.push(u);this.current=null;this.onUnit();}
 }
 // The counters: every application statement as it arrives (the D1 entries
 // count a statement when it is called, before its hook acts).
 count(sql){if(!isApplication(sql))return;const c=this.alias.counters;c.statements++;if(M.watchdog(sql))c.watchdog_reads++;}
 newOp(type,first){
  const o={id:`O${++this.proxy.seq.op}`,alias:this.alias.alias,conn:this.id,type,sql:type==='read'?first.sql:null,statements:type==='read'&&isApplication(first.sql)?[first.sql]:[],
   started:now(),Z_relay:this.relay.Z_relay,hook:null,action:null,fire_id:null,fire:null,forwarded:null,released:null,discarded:null,
   close:null,closed_by:null,rollback_after_hold:null,rollback_relayed:null,commit_tag:null,commit_relayed:false,tags:[],rows_written:0,sqlstate:null,interactive:null,complete:type==='read',ended:null};
  o[I]={units:type==='read'?[first]:[],outstanding:0,mode:'buffer',fire:null};
  this.ops.push(o);this.alias.operations.push(o);return o;
 }
 onUnit(){
  while(this.units.length&&!this.closed){
   const u=this.units[0];
   if(!this.op){
    if(u.sql!=='BEGIN'){this.units.shift();this.dispatch(this.newOp('read',u));continue;}
    this.op=this.newOp('txn');
   }
   const o=this.op;this.units.shift();
   if(o.type==='txn'&&!o.complete&&o[I].mode==='buffer'){
    o[I].units.push(u);if(isApplication(u.sql))o.statements.push(u.sql);
    if(u.sql==='COMMIT'||u.sql==='ROLLBACK'){o.complete=true;clearTimeout(this.idle);this.dispatch(o);}
    continue;
   }
   if(o.type==='txn'&&!o.complete){this.interactiveUnit(o,u);continue;}
   this.afterOperation(o,u);
  }
 }
 dispatch(o){
  const a=this.alias;a.counters.operations++;
  if(o.type==='read')this.op=null;
  const d=this.proxy.controls.decide(this,o)??match(a.state,o);
  if(d?.timing)return this.proxy.controls.dispatch(this,o,d);
  if(d&&!ACTIONS.has(d.action)){a.error('unknown-action',{op:o.id,conn:this.id,hook:d.hook,action:d.action});this.shutdown('error');return;}
  let f=null;
  if(d){f=this.proxy.fire(a,d,o,this);Object.assign(o,{hook:d.hook,action:d.action,fire_id:f.id,fire:f.at});o[I].fire=f;}
  const action=d?.action??'forward';
  if(action==='close-before'||action==='fail-and-arm'){this.shutdown('hook');return;}
  if(action==='side-write-first'){this.sideWrite(o,f,d);return;}
  if(action==='hold-request'||action==='hold-forever'){
   const h={fire:f,op:o,conn:this,releasable:action==='hold-request',registered:true,forward:()=>this.go(o,'forward')};
   f[I].hold=h;a.holds.add(h);return;
  }
  this.go(o,action);
 }
 go(o,action){
  if(this.closed)return false;
  o.forwarded=now();if(o[I].fire)o[I].fire.forwarded??=o.forwarded;
  const units=o[I].units;
  if(action==='fail-in-place'){
   const list=units.map(u=>u.sql==='COMMIT'?{sql:'ROLLBACK',messages:u.messages.map(m=>m[0]===0x50?rewriteParse(m,'ROLLBACK'):m),commit:true}:u);
   const last=Math.max(...list.map((u,k)=>isApplication(u.sql)?k:-1));
   list.forEach((u,k)=>this.forward(o,u,{replaceError:k===last,isCommit:!!u.commit}));
  }else units.forEach(u=>this.forward(o,u,{dropAck:action==='drop-commit-ack'&&u.sql==='COMMIT',isCommit:u.sql==='COMMIT',holdReply:action==='hold-response'}));
  return true;
 }
 forward(o,u,flags){this.pending.push({op:o,unit:u,reply:[],...flags});o[I].outstanding++;this.upstream.write(Buffer.concat(u.messages));}
 async sideWrite(o,f,d){
  const a=this.alias,side=SIDE[d.side];let changes=null,error=null;
  try{changes=await this.proxy.ownerWrite(a.database,side.sql);}catch(e){error=e;}
  f.side={sql:side.sql,changes,error:error?.message??null,rule:[side.min,side.max===Infinity?null:side.max]};
  if(error){a.error('side-write-error',{fire:f.id,hook:d.hook,sql:side.sql,message:error.message});this.shutdown('error');return;}
  if(changes<side.min||changes>side.max){a.error('side-write-count',{fire:f.id,hook:d.hook,sql:side.sql,changes,min:side.min,max:side.max===Infinity?null:side.max});this.shutdown('error');return;}
  this.go(o,'forward');
 }
 // A unit after a dispatched transaction: the Worker's ROLLBACK once a held
 // transaction's deadline fired (rollback_after_hold), forwarded; the server,
 // which never saw the BEGIN, warns and completes. The hold is over: its
 // client gave up.
 afterOperation(o,u){
  const a=this.alias,h=o[I].fire?.[I].hold;
  this.proxy.controls.after(this,o,u);
  if(h&&a.holds.has(h)){o.rollback_after_hold=now();this.proxy.discard(a,h,'client-rollback');}
  const delay=o.rollback_after_hold!==null&&u.sql==='ROLLBACK'?a.delays.rollbackReplyMs:0;
  o[I].units.push(u);this.forward(o,u,delay?{notBefore:now()+delay}:{});
 }
 // The interactive prefix: the client went idle inside an incomplete
 // transaction, so it waits on a reply. Forward only the recognised prefix
 // (BEGIN, then a gate unit) and judge every later unit on arrival, before it
 // is forwarded.
 interactive(){
  const o=this.op;
  if(this.closed||!o||o.type!=='txn'||o.complete||o[I].mode!=='buffer')return;
  const buffered=o[I].units;o[I].units=[];o[I].mode='interactive';o.statements=[];
  let k=0;const prefix=[];
  if(buffered[k]?.sql==='BEGIN'){prefix.push('BEGIN');k++;}
  if(buffered[k]?.sql?.startsWith(GATE_PREFIX)){prefix.push('gate');k++;}
  o.interactive={at:now(),prefix,shape:'pending'};o.forwarded=now();this.alias.counters.operations++;
  for(const u of buffered.slice(0,k)){o[I].units.push(u);this.forward(o,u,{});}
  for(const u of buffered.slice(k))if(!this.interactiveUnit(o,u))return;
 }
 interactiveUnit(o,u){
  const a=this.alias,app=isApplication(u.sql),statements=app?[...o.statements,u.sql]:o.statements;
  o[I].units.push(u);
  // (1) an armed hook that would match is never bypassed by delayed pipelining
  const probe=match(a.state,{type:'txn',statements})??this.proxy.controls.probe(this,statements);
  if(probe){o.statements=statements;o.interactive.shape='bypassed';a.error('armed-hook-bypassed',{op:o.id,conn:this.id,hook:probe.hook,arming:probe.arming?.id??null,statement:u.sql});this.shutdown('error');return false;}
  // (2) the first application statement must be AbandonPoisoned's, before it is forwarded
  if(app&&!o.statements.length&&u.sql!==INTERACTIVE_FIRST){o.statements=statements;o.interactive.shape='mismatch';a.error('interactive-shape',{op:o.id,conn:this.id,reason:'first application statement',statement:u.sql});this.shutdown('error');return false;}
  if(app){o.statements=statements;o.interactive.shape='B17';}
  if(u.sql==='COMMIT'||u.sql==='ROLLBACK'){
   o.complete=true;
   // (4) no application statement at all: forwarded (it has no effect), recorded.
   if(!o.statements.length){o.interactive.shape='missing';a.error('interactive-shape',{op:o.id,conn:this.id,reason:'no application statement',statement:u.sql});}
  }
  const held=this.proxy.controls.interactive(this,o,u);if(held!==undefined)return held;
  this.forward(o,u,{isCommit:u.sql==='COMMIT'});
  return true;
 }
 backendMessage(kind,msg){
  const p=this.pending[0];
  if(!p){this.client.write(msg);return;} // asynchronous NoticeResponse/ParameterStatus
  p.reply.push(msg);const o=p.op;
  if(kind==='C'){
   const tag=msg.subarray(5,msg.length-1).toString();o.tags.push(tag);
   const n=writtenBy(tag);if(n){o.rows_written+=n;this.alias.counters.rows_written+=n;}
   if(p.isCommit)o.commit_tag=tag; // this operation's own COMMIT reply, never another's
  }
  if(kind==='E')o.sqlstate??=sqlstateOf(msg);
  if(kind==='Z'){this.pending.shift();this.relayQueue.push(p);this.flush();}
 }
 flush(){
  while(this.relayQueue.length&&!this.closed){
   const p=this.relayQueue[0],o=p.op;
   if(this.proxy.controls.holds(this,p))return;
   if(p.holdReply&&!p.releasedReply){
    // hold-response: the reply is complete and withheld until release.
    const f=o[I].fire;
    if(!f[I].hold){const h={fire:f,op:o,conn:this,releasable:true,registered:true,forward:()=>{p.releasedReply=true;this.flush();}};f[I].hold=h;this.alias.holds.add(h);}
    return;
   }
   if(p.notBefore>now()){if(!p.timer)p.timer=setTimeout(()=>this.flush(),p.notBefore-now()).unref();return;}
   this.relayQueue.shift();
   if(p.dropAck){this.shutdown('hook');return;} // committed; its acknowledgement is lost
   this.client.write(p.replaceError?error42P01():Buffer.concat(p.reply));
   if(p.isCommit)o.commit_relayed=true;
   this.proxy.controls.relayed(this,p);
   if(o.rollback_after_hold!==null&&p.unit.sql==='ROLLBACK')o.rollback_relayed=now();
   if(--o[I].outstanding===0&&o.complete&&!(o[I].fire?.[I].hold&&this.alias.holds.has(o[I].fire[I].hold))){o.ended=now();if(this.op===o)this.op=null;}
  }
 }
 // Server-first close. Every operation of the connection gets its close and
 // closed_by (close is what the deadline bands measure from Z_relay and from
 // fire); a hold still out is discarded.
 shutdown(reason){
  if(this.closed)return;
  this.closed=true;clearTimeout(this.idle);
  const t=now();Object.assign(this.relay,{close:t,closed_by:reason});
  this.client.end();setTimeout(()=>this.client.destroy(),DESTROY_MS).unref();
  if(this.upstream&&!this.upstreamClosed){
   try{this.upstream.write(frame('X',Buffer.alloc(0)));this.relay.terminate_sent=now();}catch{}
   this.destroyTimer=setTimeout(()=>{if(!this.upstreamClosed){this.relay.upstream_destroyed='timer';this.upstream.destroy();}},DESTROY_MS).unref();
  }else if(!this.upstream)this.proxy.connections.delete(this);
  const a=this.alias;
  for(const o of this.ops){o.close=t;o.closed_by=reason;o.ended??=t;
   const f=o[I].fire;if(!f||!HOLDS.has(f.action))continue;
   const h=f[I].hold;if(h&&a.holds.has(h))this.proxy.discard(a,h,reason);
   else if(f.released===null&&f.discarded===null){f.discarded=o.discarded=t;a.discarded.push({fire:f.id,at:t,reason});}
  }
  this.proxy.controls.closed(this,reason);
 }
}
