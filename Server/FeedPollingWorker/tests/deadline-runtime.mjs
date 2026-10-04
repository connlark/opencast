// Native transport lifetime regression: the Node service bridge does not relay
// cancellation to its source stream, so observe fetch/reader disposal in workerd.
import assert from 'node:assert/strict';
import { harness, item, rss } from './harness.mjs';
import { sampleRuntimeMemory } from '../../NotificationsWorker/tests/runtime-memory.mjs';

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
});
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
  // Hung D1 claims previously escaped the 200-second budget entirely. A
  // bookkeeping stall has its own shared 20 seconds, even if the claim failed.
  failing=false;
  await h.run('UPDATE n_feed SET due_at=?,dispatch_until=0,retry_at=0',h.now+3600);
  const bounded=feeds.get('healthy');
  await h.run('UPDATE n_feed SET due_at=0 WHERE feed_id=?',bounded);
  await h.invoke('test/dispatch');const [wake]=await h.polls();
  for(const [fault,minimum,maximum,status] of [['hang_claim',199000,220000,503],['hang_bookkeeping',19000,23000,500]]){
    await h.invoke('fault',fault);const before=h.fetches.length,start=performance.now();
    const result=await h.consume(wake,{headers:{'x-poll-enqueued-ms':String(Date.now()-121000)}});
    const wall=performance.now()-start;
    assert.equal(result.status,status,result.text);assert.ok(wall>=minimum&&wall<=maximum,`${fault}: ${wall}ms`);
    assert.equal(h.fetches.length,before,'a hung/failed claim never reaches the publisher');
    const entry=(await h.invoke('metrics')).deliveries.at(-1);
    assert.ok(entry.initial_queue_wait_ms>=120000);assert.equal(entry.publisher_fetch_ms,0);
    if(fault==='hang_claim')assert.ok(entry.claim_ms>=199000);
    else assert.ok(entry.storage_ms>=19000);
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
