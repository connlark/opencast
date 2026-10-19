// Timing controls beside the wire proxy's eight storage hooks, attached at
// proxy.mjs's marked extension points. An arming here names its operation by
// a prefix of the operation's first application statement (a read's own
// statement) instead of an entry's fault name, takes the accepted arming and
// fire ids, and is held to the same teardown rules: an arming that never
// fired, or a fired hold neither released nor expected, fails dispose().
//
//  {op:'arm', kind:'statement', action, match, skip?, release_after_ms?, forever?, side?}
//     One-shot: fires on the first operation whose first application
//     statement starts with `match`, after `skip` such operations passed. It
//     takes the operation before an entry's fault arming would. The accepted
//     actions keep their meaning exactly: close-before, fail-in-place,
//     drop-commit-ack, side-write-first (with `side`), hold-request,
//     hold-forever, hold-response. Added:
//   hold-commit-reply   the whole transaction is forwarded and the replies of
//     BEGIN, the gate and every application unit are relayed as they arrive;
//     only the COMMIT unit's reply is held, so one release completes the
//     write (the accepted hold-response holds every unit and releases one per
//     release). `forever: true` never releases.
//   hold-unit-reply:<index>   the same, holding the reply of the application
//     unit at <index> (0: the first after BEGIN and the gate) instead; BEGIN's
//     and the gate's replies are relayed, the later units' and COMMIT's wait
//     behind it in the wire's order. The server has run the whole
//     transaction meanwhile: like any held reply it conceals the outcome.
//   interactive-hold   for the interactive transaction (its client awaits
//     each reply: AbandonPoisoned's), the proxy's interactive-prefix rules
//     first, then its first application unit, after BEGIN's and the gate's
//     replies, is held unforwarded until release. A pipelined transaction
//     never fires it. A unit the client sends while it is held (its ROLLBACK
//     after a deadline) discards the hold and is forwarded, as the accepted
//     holds do.
//  {op:'arm', kind:'startup', action:'startup-hold'|'startup-close', skip?, release_after_ms?}
//     A handshake hook on the alias: the next StartupMessage (after `skip`)
//     is held before anything goes upstream, or the proxy closes on it
//     server-first with no upstream connection. Witnessed by startup-seen
//     (every StartupMessage once the alias has an arming), fire, release or
//     close, and on the connection's relay witness as `startup`.
//  {op:'release', fire}  releases one of these holds; release_after_ms on the
//     arming has the proxy release it that long after its fire (for
//     hold-response, operation-wide as below); 0 releases it on the turn
//     after the fire, once the operation holds it.
//  {op:'release-operation', operation|fire}  releases every held reply of one
//     operation (alias, operation id) in order at the moment of the call and
//     sets a persistent released flag on it, so a reply of that operation
//     that arrives later is relayed at once: the operation-wide release an
//     accepted hold-response on a multi-unit write needs to complete at one
//     instant. It also releases the operation's hold-request or reply hold,
//     and, named by its fire, a held startup.
//  {op:'discard', fire}  closes a held reply's connection server-first,
//     relaying nothing of the held reply.
//  controls.stall(alias, {after, start_ms, ms, run})  Node only (a function
//     cannot cross TEST_STORAGE): when the arming `after` on that alias fires,
//     run(ms) is called start_ms after the fire, to stall the Worker's isolate
//     synchronously for ms (the FeedPolling test entry's /test/stall). Its own
//     arming and fire carry the measured stamps: the named fire, the stall's
//     start and end on this clock, and run()'s own report.
//
// The witness: each operation these armings act on carries `timing` (every
// relayed reply with its unit index, sequence number and time; the held
// reply with its CommandComplete tag and the operation's commit_tag; the
// release; a unit the client sent while the reply was held, its ROLLBACK
// after a deadline; after release-operation, released_at and late_relays,
// the replies relayed after the call returned, each relay marked late), and the alias's `timing.events` order the fires, relays,
// held replies, releases and discards by one proxy-wide sequence.
import {ACTIONS,GATE_PREFIX,HOLDS,SIDE,isApplication} from './hooks.mjs';

const now=()=>performance.timeOrigin+performance.now();
const plain=value=>JSON.parse(JSON.stringify(value));
// fail-and-arm's follow-up is the entry's own fault variable: it stays an entry hook.
const ACCEPTED=new Set([...ACTIONS].filter(action=>action!=='fail-and-arm'));
const UNIT_REPLY=/^hold-unit-reply:(0|[1-9][0-9]{0,2})$/;
const replyHold=action=>action==='hold-commit-reply'||UNIT_REPLY.test(action??'');
const releasable=action=>action==='hold-request'||action==='hold-response'||action==='interactive-hold'||replyHold(action);
// Run fn at the proxy clock's `time`, never before (a Node timer may fire up
// to a millisecond early against performance.now()) and never inside the
// call: a fire's controls run before the proxy has stored the fire on its
// operation and registered its hold, so even a time already passed waits for
// the next turn.
const at=(time,fn)=>{const tick=()=>{const left=time-now();if(left>0)setTimeout(tick,Math.ceil(left)).unref();else fn();};setImmediate(tick).unref();};
const label=sql=>sql?.startsWith(GATE_PREFIX)?'gate':sql??null;
// The CommandComplete tag of one buffered unit reply.
const tagOf=reply=>{const c=reply.find(m=>m[0]===0x43);return c?c.subarray(5,c.length-1).toString():null;};

export class Controls {
 constructor(proxy,I){
  Object.assign(this,{proxy,I});
  this.seq=0;this.aliases=new WeakMap(); // alias -> {armings, events}, made by the first arming
  this.flushing=null; // the operation whose release-operation call is relaying now
 }
 state(a){let s=this.aliases.get(a);if(!s){s={armings:[],events:[]};this.aliases.set(a,s);}return s;}
 event(a,kind,fields={}){const e={seq:++this.seq,kind,at:now(),...fields};this.state(a).events.push(e);return e;}
 refuse(a,op,message){a.error('unknown-action',{op:plain(op??null),message});throw Error(message);}
 timingOf(f){return f?.[this.I]?.timing??null;}
 opOf(a,id){return a.operations.find(o=>o.id===id)??null;}

 // ---- TEST_STORAGE ops this module owns; undefined hands the op to the proxy.
 handle(a,op){
  const kind=op?.op;
  if(kind==='arm'&&op.kind==='statement')return this.arm(a,op);
  if(kind==='arm'&&op.kind==='startup')return this.armStartup(a,op);
  if(kind==='discard')return this.discard(a,op);
  if(kind==='release-operation')return this.releaseOperation(a,op,'release-operation');
  if(kind==='release'&&op.fire!==undefined){const f=a.fires.find(x=>x.id===op.fire);if(this.timingOf(f))return this.release(a,f,'release');}
  return undefined;
 }
 arm(a,op){
  const refuse=message=>this.refuse(a,op,message),action=op.action;
  if(!ACCEPTED.has(action)&&!replyHold(action)&&action!=='interactive-hold')refuse(`unknown statement action ${JSON.stringify(action)}`);
  if(typeof op.match!=='string'||!op.match)refuse('a statement arming needs a match prefix');
  const count=(name,value)=>{if(value!==undefined&&!(Number.isSafeInteger(value)&&value>=0))refuse(`${name} must be a non-negative integer`);return value;};
  const skip=count('skip',op.skip)??0,after=count('release_after_ms',op.release_after_ms)??null;
  if(op.forever!==undefined&&typeof op.forever!=='boolean')refuse('forever is a boolean');
  const forever=op.forever===true;
  if(forever&&!replyHold(action))refuse('forever belongs to hold-commit-reply and hold-unit-reply; the accepted variant is hold-forever');
  if(after!==null&&(forever||!releasable(action)))refuse(`release_after_ms needs a releasable hold, not ${action}${forever?' forever':''}`);
  if(action==='side-write-first'?!Object.hasOwn(SIDE,op.side??''):op.side!==undefined)refuse(`only side-write-first takes a side, one of ${Object.keys(SIDE).join(', ')}`);
  const m=this.proxy.arming(a,{kind:'statement',name:action,match:op.match,skip,seen:0,release_after_ms:after,forever,side:op.side??null,parent:null,consumed:null});
  this.state(a).armings.push(m);
  return {arming:m.id,cleared:[]};
 }

 armStartup(a,op){
  const refuse=message=>this.refuse(a,op,message),action=op.action;
  if(action!=='startup-hold'&&action!=='startup-close')refuse(`unknown startup action ${JSON.stringify(action)}`);
  if(op.match!==undefined)refuse('a startup arming takes the next StartupMessage, not a statement');
  const count=(name,value)=>{if(value!==undefined&&!(Number.isSafeInteger(value)&&value>=0))refuse(`${name} must be a non-negative integer`);return value;};
  const skip=count('skip',op.skip)??0,after=count('release_after_ms',op.release_after_ms)??null;
  if(after!==null&&action!=='startup-hold')refuse('release_after_ms needs startup-hold');
  const m=this.proxy.arming(a,{kind:'startup',name:action,skip,seen:0,release_after_ms:after,parent:null,consumed:null});
  this.state(a).armings.push(m);
  return {arming:m.id,cleared:[]};
 }

 // ---- Dispatch. Every active arming whose prefix matches counts the
 // operation; the first one past its skip fires.
 decide(conn,o){
  const s=this.aliases.get(conn.alias),sql=o.statements[0];
  if(!s||sql===undefined)return undefined;
  let chosen=null;
  for(const m of s.armings){
   if(m.kind!=='statement'||m.name==='interactive-hold'||m.consumed!==null||m.cleared||!sql.startsWith(m.match))continue;
   m.seen++;
   if(!chosen&&m.seen>m.skip)chosen=m;
  }
  if(!chosen)return undefined;
  chosen.consumed=now();
  const d={arming:chosen,hook:'statement',action:chosen.name,consume:true};
  if(chosen.side)d.side=chosen.side;
  if(replyHold(chosen.name))d.timing=true;
  return d;
 }
 // The unit whose reply waits: the one COMMIT of a pipelined transaction.
 target(o,action){
  const units=o[this.I].units;
  if(o.type!=='txn')return {error:`${action} needs a transaction, not a read`};
  if(action==='hold-commit-reply'){
   const commits=units.flatMap((u,k)=>u.sql==='COMMIT'?[k]:[]);
   return commits.length===1?{unit:commits[0]}:{error:`${commits.length} COMMIT units`};
  }
  const index=UNIT_REPLY.exec(action);
  if(index){
   const apps=units.flatMap((u,k)=>isApplication(u.sql)?[k]:[]),n=Number(index[1]);
   return n<apps.length?{unit:apps[n]}:{error:`application unit ${n} of ${apps.length}`};
  }
  return {error:`no reply target for ${action}`};
 }
 dispatch(conn,o,d){
  const a=conn.alias,I=this.I,m=d.arming,t=this.target(o,d.action);
  if(t.error!==undefined){a.error('statement-shape',{op:o.id,conn:conn.id,arming:m.id,action:d.action,reason:t.error});conn.shutdown('error');return;}
  const f=this.proxy.fire(a,d,o,conn);Object.assign(o,{hook:d.hook,action:d.action,fire_id:f.id,fire:f.at});o[I].fire=f;
  const gate={open:false,unit:t.unit,reached:false};
  f[I].timing={kind:'reply',conn,op:o,gate,hold:true,forever:m.forever};
  o.timing={arming:m.id,unit:t.unit,relays:[],held_reply:null,released:null,rollback:null,discarded:null};
  this.event(a,'fire',{fire:f.id,op:o.id,conn:conn.id,unit:t.unit});
  if(conn.closed)return;
  o.forwarded=now();f.forwarded??=o.forwarded;
  o[I].units.forEach((u,k)=>conn.forward(o,u,{isCommit:u.sql==='COMMIT',gate:k===t.unit?gate:null}));
  if(m.release_after_ms!==null)at(f.at+m.release_after_ms,()=>this.open(a,f,'timer'));
 }
 stall(name,{after,start_ms,ms,run}){
  const a=this.proxy.alias(name),op={op:'stall',after,start_ms,ms};
  if(!a.armings.some(m=>m.id===after))this.refuse(a,op,`no arming ${after} to stall after`);
  for(const [k,v] of [['start_ms',start_ms],['ms',ms]])if(!(Number.isSafeInteger(v)&&v>=0))this.refuse(a,op,`${k} must be a non-negative integer`);
  if(typeof run!=='function')this.refuse(a,op,'stall needs a run(ms) function');
  const m=this.proxy.arming(a,{kind:'stall',name:`stall:${start_ms}:${ms}`,after,start_ms,ms,parent:null,consumed:null});
  m[this.I]={run};this.state(a).armings.push(m);
  return {arming:m.id};
 }
 // The stalls after this fire, and an accepted hold armed here with release_after_ms.
 fired(a,f){
  for(const m of this.aliases.get(a)?.armings??[]){
   if(m.kind!=='stall'||m.after!==f.arming||m.consumed!==null)continue;
   m.consumed=now();
   at(f.at+m.start_ms,async()=>{
    const g={id:`F${++this.proxy.seq.fire}`,arming:m.id,hook:'stall',action:m.name,alias:a.alias,conn:null,op:null,at:now(),statement:null,follow_up:false,parent:f.id,released:null,discarded:null,forwarded:null,expected:null,
     stall:{after_fire:f.id,after_at:f.at,start:null,end:null,worker:null}};
    g[this.I]={decision:{arming:m,hook:'stall',action:m.name},timing:{kind:'stall',hold:false}};
    m.fires.push(g.id);a.fires.push(g);
    g.stall.start=now();this.event(a,'stall-start',{fire:g.id,after:f.id});
    try{g.stall.worker=await m[this.I].run(m.ms);}catch(error){a.error('stall-error',{arming:m.id,message:error.message});}
    g.stall.end=g.released=now();this.event(a,'stall-end',{fire:g.id});
   });
  }
  const m=this.aliases.get(a)?.armings.find(x=>x.id===f.arming);
  if(m?.release_after_ms==null)return;
  if(m.name==='hold-request')at(f.at+m.release_after_ms,()=>{const h=f[this.I].hold;if(h&&a.holds.has(h))this.proxy.release(a,h,'timer');});
  if(m.name==='hold-response')at(f.at+m.release_after_ms,()=>{if(f.released===null&&f.discarded===null)this.releaseOperation(a,{op:'release-operation',fire:f.id},'timer');});
 }

 // ---- Replies. A gated unit's complete reply stops the relay queue, as
 // the wire's order demands; the replies behind it wait with it.
 holds(conn,p){
  // A released operation's reply that arrives after the call goes at once.
  if(p.op.timing?.released_at!=null){if(p.holdReply)p.releasedReply=true;if(p.gate)p.gate.open=true;return false;}
  const g=p.gate;if(!g||g.open)return false;
  if(!g.reached){
   g.reached=true;const o=p.op;
   const e=this.event(conn.alias,'held-reply',{fire:o.fire_id,op:o.id,unit:g.unit,tag:tagOf(p.reply),commit_tag:o.commit_tag});
   o.timing.held_reply={seq:e.seq,at:e.at,unit:g.unit,tag:e.tag,commit_tag:e.commit_tag};
  }
  return true;
 }
 relayed(conn,p){
  const o=p.op;if(!o.timing)return;
  const late=o.timing.released_at!=null&&this.flushing!==o;if(late)o.timing.late_relays++;
  const unit=o[this.I].units.indexOf(p.unit),e=this.event(conn.alias,'relay',{op:o.id,unit,sql:label(p.unit.sql),late});
  o.timing.relays.push({unit,sql:e.sql,seq:e.seq,at:e.at,late});
 }
 // A unit after the operation while its reply is held: the client gave up
 // (its ROLLBACK after a deadline). It is forwarded as the proxy forwards it;
 // its reply waits behind the held one.
 after(conn,o,u){
  const f=o[this.I].fire,t=this.timingOf(f);
  if(!t||o.timing.rollback||f.released!==null||f.discarded!==null)return;
  const e=this.event(conn.alias,'rollback',{fire:f.id,op:o.id,sql:label(u.sql)});
  o.timing.rollback={seq:e.seq,at:e.at,sql:e.sql};
 }

 // ---- Release and discard.
 open(a,f,how){
  const t=this.timingOf(f);
  if(f.released!==null||f.discarded!==null)return false;
  f.released=now();a.released.push({fire:f.id,at:f.released,how});
  const e=this.event(a,'release',{fire:f.id,op:f.op,conn:f.conn,how});
  if(t.kind==='startup'){if(!t.conn.closed){f.forwarded=now();t.go();}return true;}
  t.op.released=f.released;t.op.timing.released={seq:e.seq,at:e.at,how};
  if(t.kind==='interactive'){if(!t.conn.closed){f.forwarded=now();t.conn.forward(t.op,t.unit,{});}return true;}
  t.gate.open=true;t.conn.flush();
  return true;
 }
 release(a,f,how){
  const out={released:[],discarded:[],refused:[]};
  if(f.discarded!==null)out.discarded.push(f.id);
  else if(f.released!==null)out.released.push(f.id);
  else if(!this.timingOf(f).hold)this.refuse(a,{op:'release',fire:f.id},`no fired hold ${f.id}`);
  else if(this.timingOf(f).forever)out.refused.push(f.id);
  else{this.open(a,f,how);out.released.push(f.id);}
  return out;
 }
 // Operation-wide: the operation's own hold (a hold-response's lazily
 // registered hold, a hold-request, a reply hold) is released, and every
 // reply flag of the operation opened now and, through holds(), later.
 releaseOperation(a,op,how){
  const I=this.I,named=op.fire===undefined?null:a.fires.find(x=>x.id===op.fire);
  if(this.timingOf(named)?.kind==='startup')return {fire:named.id,released:this.open(a,named,how)?[named.id]:[]};
  const id=op.operation??named?.op;
  const o=id===undefined?null:this.opOf(a,id),f=o?.[I].fire,t=this.timingOf(f);
  if(!o)this.refuse(a,op,`no operation ${op.operation??op.fire}`);
  if(!f||!(HOLDS.has(f.action)||t))this.refuse(a,op,`operation ${o.id} holds nothing`);
  if(f.action==='hold-forever'||t?.forever)return {operation:o.id,refused:[f.id]};
  o.timing??={arming:null,unit:null,relays:[],held_reply:null,released:null,rollback:null,discarded:null};
  if(o.timing.released_at!=null)return {operation:o.id,released_at:o.timing.released_at,relayed:[]};
  o.timing.released_at=now();o.timing.late_relays=0;
  const e=this.event(a,'release-operation',{fire:f.id,op:o.id,how}),before=o.timing.relays.length;
  o.timing.released={seq:e.seq,at:e.at,how};
  const conn=[...this.proxy.connections].find(c=>c.ops.includes(o));
  this.flushing=o;
  try{
   if(f.released===null&&f.discarded===null){
    const h=f[I].hold;
    if(t)this.open(a,f,how);
    else if(h&&a.holds.has(h))this.proxy.release(a,h,how); // a hold-request forwards its units here
    else{f.released=o.released=now();a.released.push({fire:f.id,at:f.released,how});}
   }
   if(conn&&!conn.closed){
    for(const p of [...conn.pending,...conn.relayQueue])if(p.op===o){if(p.holdReply)p.releasedReply=true;if(p.gate)p.gate.open=true;}
    conn.flush();
   }
  }finally{this.flushing=null;}
  return {operation:o.id,released_at:o.timing.released_at,relayed:o.timing.relays.slice(before).map(r=>r.unit)};
 }
 discard(a,op){
  const f=a.fires.find(x=>x.id===op.fire),t=this.timingOf(f);
  if(t?.kind!=='reply')this.refuse(a,op,`no held reply ${op.fire}`);
  if(f.released===null&&f.discarded===null)t.conn.shutdown('discard');
  return {released:f.released!==null?[f.id]:[],discarded:f.discarded!==null?[f.id]:[]};
 }
 closed(conn,reason){
  const a=conn.alias;if(!a)return;
  if(!conn.upstream){
   // A held or closed startup never opened its upstream; nothing else will drop it.
   a.open.delete(conn);
   for(const f of a.fires){
    const t=this.timingOf(f);if(t?.kind!=='startup'||t.conn!==conn||!t.hold||f.released!==null||f.discarded!==null)continue;
    f.discarded=now();a.discarded.push({fire:f.id,at:f.discarded,reason});this.event(a,'discard',{fire:f.id,conn:conn.id,reason});
   }
  }
  for(const o of conn.ops){
   const f=o[this.I].fire;if(!this.timingOf(f)||f.released!==null||f.discarded!==null)continue;
   f.discarded=o.discarded=now();a.discarded.push({fire:f.id,at:f.discarded,reason});
   const e=this.event(a,'discard',{fire:f.id,op:o.id,reason});
   o.timing.discarded={seq:e.seq,at:e.at,reason};
  }
 }

 // ---- Interactive transactions and the handshake.
 // An interactive transaction never bypasses a statement arming that would
 // match its first application statement: the proxy's own guard asks this.
 probe(conn,statements){
  const s=this.aliases.get(conn.alias),sql=statements[0];
  if(!s||sql===undefined)return null;
  const m=s.armings.find(x=>x.kind==='statement'&&x.name!=='interactive-hold'&&x.consumed===null&&!x.cleared&&sql.startsWith(x.match));
  return m?{hook:'statement',arming:m,action:m.name}:null;
 }
 // Called for each interactive unit the proxy would forward next.
 interactive(conn,o,u){
  const a=conn.alias,s=this.aliases.get(a),I=this.I;if(!s)return undefined;
  const held=o[I].fire,t=this.timingOf(held);
  if(t?.kind==='interactive'){
   if(held.released===null&&held.discarded===null){
    const r=this.event(a,'rollback',{fire:held.id,op:o.id,sql:label(u.sql)});o.timing.rollback={seq:r.seq,at:r.at,sql:r.sql};
    held.discarded=o.discarded=o.rollback_after_hold=now();a.discarded.push({fire:held.id,at:held.discarded,reason:'client-rollback'});
    const e=this.event(a,'discard',{fire:held.id,op:o.id,reason:'client-rollback'});o.timing.discarded={seq:e.seq,at:e.at,reason:'client-rollback'};
   }
   return undefined;
  }
  if(!isApplication(u.sql)||o.statements.length!==1)return undefined;
  let chosen=null;
  for(const m of s.armings){
   if(m.name!=='interactive-hold'||m.consumed!==null||m.cleared||!u.sql.startsWith(m.match))continue;
   m.seen++;if(!chosen&&m.seen>m.skip)chosen=m;
  }
  if(!chosen)return undefined;
  chosen.consumed=now();
  const d={arming:chosen,hook:'statement',action:'interactive-hold',consume:true};
  const f=this.proxy.fire(a,d,o,conn);Object.assign(o,{hook:d.hook,action:d.action,fire_id:f.id,fire:f.at});o[I].fire=f;
  const unit=o[I].units.indexOf(u);
  f[I].timing={kind:'interactive',conn,op:o,unit:u,hold:true,forever:false};
  // prefix_relayed: every prefix unit forwarded so far has had its reply relayed.
  o.timing={arming:chosen.id,unit,relays:[],held_reply:null,released:null,rollback:null,discarded:null,
   prefix:o.interactive.prefix,prefix_tags:[...o.tags],prefix_relayed:o[I].outstanding===0};
  this.event(a,'fire',{fire:f.id,op:o.id,conn:conn.id,unit});
  if(chosen.release_after_ms!==null)at(f.at+chosen.release_after_ms,()=>this.open(a,f,'timer'));
  return true;
 }
 startup(conn,go){
  const a=conn.alias,s=this.aliases.get(a);if(!s)return false;
  this.event(a,'startup-seen',{conn:conn.id});
  let chosen=null;
  for(const m of s.armings){
   if(m.kind!=='startup'||m.consumed!==null||m.cleared)continue;
   m.seen++;if(!chosen&&m.seen>m.skip)chosen=m;
  }
  if(!chosen)return false;
  const hold=chosen.name==='startup-hold';
  const f={id:`F${++this.proxy.seq.fire}`,arming:chosen.id,hook:'startup',action:chosen.name,alias:a.alias,conn:conn.id,op:null,at:now(),
   statement:null,follow_up:false,parent:null,released:null,discarded:null,forwarded:null,expected:null};
  f[this.I]={decision:{arming:chosen,hook:'startup',action:chosen.name,consume:true},timing:{kind:'startup',conn,go,hold,forever:false}};
  chosen.fires.push(f.id);chosen.consumed=f.at;a.fires.push(f);
  conn.relay.startup={fire:f.id,action:chosen.name};
  this.event(a,'fire',{fire:f.id,conn:conn.id});
  this.fired(a,f);
  if(!hold){this.event(a,'close',{fire:f.id,conn:conn.id});conn.shutdown('startup-close');return true;}
  if(chosen.release_after_ms!==null)at(f.at+chosen.release_after_ms,()=>this.open(a,f,'timer'));
  return true;
 }

 // ---- Teardown and witness.
 problems(a){
  if(!this.aliases.has(a))return [];
  return a.fires.filter(f=>this.timingOf(f)?.hold&&f.released===null&&!f.expected)
   .map(f=>`fire ${f.id} (${f.hook} ${f.action}) was ${f.discarded!==null?'discarded':'never released'} and not expected`);
 }
 witness(a){const s=this.aliases.get(a);return s?{events:s.events}:undefined;}
}
