// Native transport lifetime regression: the Node service bridge does not relay
// cancellation to its source stream, so observe fetch/reader disposal in workerd.
//
// The hung storage cases: every operation is its own connection:
// connect <= 3 s, then the read or transaction <= min(4 s, handler end - now),
// cleanup ROLLBACK and finish <= 0.5 s each (WorkerDatabaseCore). The wire
// proxy holds the operation unforwarded, so neither the server's
// statement_timeout nor the connect cap can end it; its own 4 s deadline does:
//  hang_claim       the ReadClaim read is held and fails with the Deadline kind;
//                   the failure branch records its stat normally: 500,
//                   poll_handling_failed reason storage_A04_Deadline_NotApplicable,
//                   bookkeeping_failed false; claim_ms = connect + 4 s + finish
//                   in [4000, 7500 + EPSILON_MS]; storage_ms is the healthy stat
//                   operation, < 7500 + EPSILON_MS by its caps (3500 is only the
//                   local expectation, reported); wall in [4000, 15000 + EPSILON_MS].
//  hang_bookkeeping the proxy closes the ReadClaim before forwarding it (a Driver
//                   failure) and holds the failure branch's stat transaction,
//                   which fails at its 4 s deadline, then its ROLLBACK and finish:
//                   500, the claim's reason storage_A04_Driver_NotApplicable,
//                   bookkeeping_failed true; claim_ms < 3500 + EPSILON_MS,
//                   storage_ms >= 4000, wall in [4000, 11500 + EPSILON_MS]. The
//                   20 s bookkeeping deadline is never reached. The held stat's
//                   own error is consumed by that boolean; its kind and phase
//                   (deadline, commit) are proven by the companion probe in
//                   NotificationsWorker/tests/postgres/test-proxy.mjs.
// The attribution is the wire witness, not the band: the held operation was
// never forwarded and its connection closed at least 4 s after its
// ReadyForQuery was relayed (which precedes the operation's timer) and at most
// the deadline plus its bounded cleanup after the hold fired.
import assert from 'node:assert/strict';
import { setTimeout as sleep } from 'node:timers/promises';
import { harness, item, rss } from './harness.mjs';
import { sampleRuntimeMemory } from '../../NotificationsWorker/tests/runtime-memory.mjs';

// Scheduling allowance between workerd's timers and the proxy's stamps, the
// same as tests/postgres/test-proxy.mjs's.
const EPSILON_MS=250;
let failing=false;
const releases=new Set();
const h=await harness(request=>{
  const name=new URL(request.url).pathname;
  if(!failing||name==='/healthy')return new Response(rss([item('base',h.now-100)]),{headers:{etag:'"v1"'}});
  let timer,controller;
  const close=()=>{clearInterval(timer);releases.delete(close);try{controller.close();}catch{}};
  releases.add(close);
  return new Response(new ReadableStream({
    start(source){
      controller=source;controller.enqueue(new TextEncoder().encode('<rss><channel>'));
      if(name==='/cancel-deadline')timer=setInterval(()=>{try{controller.enqueue(new Uint8Array([32]));}catch{close();}},1000);
    },cancel:close,
  }),{headers:{'content-type':'application/rss+xml'}});
},{logs:true});
const ts=h.storage.testStorage('polling-runtime');
// One hung consume's runtime-exposed failure and wire witness.
// `from` is the alias's operation count and `logsFrom` h.logs' length before it.
async function attributed(fault,entry,wall,from,logsFrom){
  let failed;
  for(let i=0;i<200&&!(failed=h.logs.slice(logsFrom).find(e=>e.event==='poll_handling_failed'));i++)await sleep(10);
  for(let i=0;i<200&&ts({op:'witness'}).operations.slice(from).some(o=>o.close===null);i++)await sleep(10);
  const w=ts({op:'witness'}),mine=w.operations.slice(from),fireOf=o=>w.fires.find(f=>f.op===o?.id);
  const claim=mine.find(o=>o.type==='read'&&o.sql?.startsWith('SELECT f.origin_key,f.due_at'));
  const stat=mine.find(o=>o.type==='txn'&&o.statements.some(s=>s.startsWith('INSERT INTO n_poll_stat(bucket,handling_failures)')));
  assert.ok(claim&&stat,`${fault}: the claim read and the HandlingFailures stat on the wire: ${JSON.stringify(mine.map(o=>o.sql??o.statements))}`);
  const anchors=o=>({fire_Z_relay:o.fire-o.Z_relay,close_Z_relay:o.close-o.Z_relay,close_fire:o.close-o.fire});
  const round=x=>Object.fromEntries(Object.entries(x).map(([k,v])=>[k,Math.round(v*10)/10]));
  const measured={wall:Math.round(wall),claim_ms:entry.claim_ms,storage_ms:entry.storage_ms,wall_ms:entry.wall_ms,reason:failed?.reason,bookkeeping_failed:failed?.bookkeeping_failed};
  if(fault==='hang_claim'){
    const f=fireOf(claim),a=anchors(claim);
    console.log(`${fault} measured ${JSON.stringify({...measured,claim:round(a),stat_op_ms:Math.round(stat.ended-stat.started),stat_Z_relay_close_ms:Math.round(stat.close-stat.Z_relay),storage_ms_local_expectation:'< 3500'})}`);
    assert.deepEqual([failed?.reason,failed?.bookkeeping_failed],['storage_A04_Deadline_NotApplicable',false],JSON.stringify(failed));
    assert.deepEqual([f?.hook,f?.action,claim.forwarded,f?.forwarded,f?.discarded!=null],['P-hang_claim','hold-request',null,null,true],JSON.stringify(f));
    assert.ok(a.close_Z_relay>=4000,`claim close - Z_relay ${a.close_Z_relay}`);
    assert.ok(a.close_fire<=4500+EPSILON_MS,`claim close - fire ${a.close_fire}`);
    assert.ok(fireOf(stat)===undefined&&stat.forwarded!==null&&stat.commit_tag==='COMMIT',`the stat operation was not forwarded and committed: ${JSON.stringify(stat)}`);
    assert.ok(entry.claim_ms>=4000&&entry.claim_ms<=7500+EPSILON_MS,`claim_ms ${entry.claim_ms}`);
    assert.ok(entry.storage_ms<7500+EPSILON_MS,`storage_ms ${entry.storage_ms}`);
    // Discarded on the client's close; release-hang has nothing to release.
    ts({op:'expect',fire:f.id,outcome:'discarded'});
  }else{
    const cf=fireOf(claim),sf=fireOf(stat),a=anchors(stat);
    console.log(`${fault} measured ${JSON.stringify({...measured,stat:round(a),rollback_after_hold_ms:Math.round(stat.rollback_after_hold-stat.fire)})}`);
    assert.deepEqual([failed?.reason,failed?.bookkeeping_failed],['storage_A04_Driver_NotApplicable',true],JSON.stringify(failed));
    assert.deepEqual([cf?.hook,cf?.action,claim.forwarded,claim.closed_by],['P-hang_bookkeeping','fail-and-arm',null,'hook'],JSON.stringify({cf,claim}));
    assert.deepEqual([sf?.hook,sf?.action,sf?.follow_up,sf?.parent,stat.forwarded,sf?.forwarded,sf?.discarded!=null],['P-hang_bookkeeping','hold-request',true,cf.arming,null,null,true],JSON.stringify(sf));
    assert.ok(stat.rollback_after_hold!==null,'the Worker rolled back the held stat transaction');
    assert.ok(a.close_Z_relay>=4000,`stat close - Z_relay ${a.close_Z_relay}`);
    assert.ok(a.close_fire<=5000+EPSILON_MS,`stat close - fire ${a.close_fire}`);
    assert.ok(entry.claim_ms<3500+EPSILON_MS,`claim_ms ${entry.claim_ms}`);
    assert.ok(entry.storage_ms>=4000,`storage_ms ${entry.storage_ms}`);
    ts({op:'expect',fire:sf.id,outcome:'discarded'});
  }
}
let stop;
try{
  stop=await sampleRuntimeMemory(await h.instance.getInspectorURL(),'polling-runtime');
  const feeds=new Map();
  for(const name of ['cancel-inactivity','cancel-deadline','healthy'])feeds.set(name,await h.add(`https://deadlines.example.com/${name}`));
  await h.invoke('test/dispatch');await h.drain();
  // Each probe admits exactly its selected feed, independent of stable phases.
  await h.run('UPDATE n_feed SET due_at=?',h.now+3600);
  const baselineAudit=await stop.transportAudit();
  failing=true;
  for(let iteration=0;iteration<2;iteration++)for(const name of ['cancel-inactivity','cancel-deadline']){
    await h.run('UPDATE n_poll_origin SET cooldown_until=0');
    await h.run('UPDATE n_feed SET due_at=0,retry_at=0,dispatch_until=0 WHERE feed_id=?',feeds.get(name));
    await h.invoke('test/dispatch');await h.drain();
    assert.equal((await h.first('SELECT poll_failures FROM n_feed WHERE feed_id=?',feeds.get(name))).poll_failures,iteration+1);
    const audit=await stop.transportAudit();
    assert.equal(audit.activeByOrigin['https://deadlines.example.com'],0);
    assert.equal(audit.peakByOrigin['https://deadlines.example.com'],1);
    assert.equal(audit.aborted.filter(x=>x===`/${name}`).length-baselineAudit.aborted.filter(x=>x===`/${name}`).length,iteration+1);
    assert.equal(audit.readersCancelled.filter(x=>x===`/${name}`).length-baselineAudit.readersCancelled.filter(x=>x===`/${name}`).length,iteration+1);
    console.log(`PASS native ${name} cancellation ${iteration+1} releases its transport`);
  }
  await h.run('UPDATE n_poll_origin SET cooldown_until=0');
  await h.run('UPDATE n_feed SET due_at=0,retry_at=0,dispatch_until=0 WHERE feed_id=?',feeds.get('healthy'));
  const healthyFetches=h.fetches.filter(url=>url.endsWith('/healthy')).length;
  await h.invoke('test/dispatch');await h.drain();
  assert.equal(h.fetches.filter(url=>url.endsWith('/healthy')).length,healthyFetches+1);
  const audit=await stop.transportAudit(),metrics=await h.invoke('metrics');
  assert.equal(audit.activeByOrigin['https://deadlines.example.com'],0);
  assert.equal(audit.peakByOrigin['https://deadlines.example.com'],1);
  assert.equal(metrics.logged['invalid_scan:feed_inactivity_timeout'],2);
  assert.equal(metrics.logged['upstream_error:fetch_failed'],2);
  assert.equal(metrics.outcomes.publisher_failed,4);
  // A timed-out scan publishes nothing. Each failing feed keeps one inert
  // first-observed bound for its whole streak, not one row per failure.
  assert.deepEqual(await h.rows("SELECT state,valid_eof,COUNT(*) AS n FROM n_observation WHERE state<>'published' GROUP BY state,valid_eof"),[{state:'staging',valid_eof:0,n:2}]);
  assert.equal((await h.first("SELECT COUNT(*) AS n FROM sqlite_master WHERE name='n_poll'")).n+(await h.first("SELECT COUNT(*) AS n FROM sqlite_master WHERE name='n_origin_permit'")).n,0);
  assert.equal((await h.first('SELECT poll_failures FROM n_feed WHERE feed_id=?',feeds.get('healthy'))).poll_failures,0);
  // A hung claim ends at its operation deadline, inside the 200-second step
  // budget; a bookkeeping stall has its own shared 20 seconds, even if the
  // claim failed.
  failing=false;
  await h.run('UPDATE n_feed SET due_at=?,dispatch_until=0,retry_at=0',h.now+3600);
  const bounded=feeds.get('healthy');
  await h.run('UPDATE n_feed SET due_at=0 WHERE feed_id=?',bounded);
  await h.invoke('test/dispatch');const [wake]=await h.polls();
  const bands=[['hang_claim',4000,15000+EPSILON_MS,500],['hang_bookkeeping',4000,11500+EPSILON_MS,500]];
  for(const [fault,minimum,maximum,status] of bands){
    const from=ts({op:'witness'}).operations.length,logsFrom=h.logs.length;
    await h.invoke('fault',fault);const before=h.fetches.length,start=performance.now();
    const result=await h.consume(wake,{headers:{'x-poll-enqueued-ms':String(Date.now()-121000)}});
    const wall=performance.now()-start;
    assert.equal(result.status,status,result.text);assert.ok(wall>=minimum&&wall<=maximum,`${fault}: ${wall}ms`);
    assert.equal(h.fetches.length,before,'a hung/failed claim never reaches the publisher');
    const entry=(await h.invoke('metrics')).deliveries.at(-1);
    assert.ok(entry.initial_queue_wait_ms>=120000);assert.equal(entry.publisher_fetch_ms,0);
    await attributed(fault,entry,wall,from,logsFrom);
    await h.invoke('release-hang');
    console.log(`PASS ${fault} returns a retryable failure within its whole invocation budget (${Math.round(wall)}ms)`);
  }
  const retry=await h.consume(wake,{attempts:2,headers:{'x-poll-enqueued-ms':String(Date.now()-121000)}});
  assert.equal(retry.status,200,retry.text);await h.drain();
  // Redelivery age includes retry backoff, so it does not force a plain
  // success into the undelayed-admission Queue-wait sample.
  const logs=(await h.invoke('metrics')).deliveries;
  for(const log of logs.filter(log=>log.attempts>1))assert.equal(log.initial_queue_wait_ms,null);
  assert.ok(logs.every(log=>log.claim_ms>=0&&log.publisher_fetch_ms>=0&&log.storage_ms>=0));
  console.log('PASS both queued timeout classes, repeat transport reuse and healthy follow-up');
}finally{for(const release of releases)release();if(stop)await stop();await h.instance.dispose();}
