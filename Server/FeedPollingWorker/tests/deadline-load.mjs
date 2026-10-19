// Native cancellation of hanging publisher streams under sustained load, in
// ONE isolate served by TWO consumer pumps (Cloudflare does not promise one
// isolate per consumer invocation), at the fastest production cadence
// (15 minutes). 1,000 subscribed feeds, the healthy ones as capacity.mjs's;
// feed index % 200 === 7 streams a partial body and then nothing (the 5 s
// inactivity timeout) and === 107 drips one byte a second (the 15 s scan
// deadline), each on its own origin: 5 + 5 hanging feeds every cycle. 30
// measured ticks are 2 cycles, then a 30-minute executor outage and its
// recovery. The Node outbound bridge does not relay cancellation to its source
// stream, so the transports are read inside workerd (runtime-memory.mjs).
// Asserted: both timeout classes fired (counted here and logged by the Worker),
// no native transport left active after steady work and after recovery, at
// most two concurrent requests per origin, the memory target, and the
// pipeline's own outcomes (every release accepted, nothing dead-lettered, no
// duplicate on replay). No throughput or latency bound: capacity.mjs owns
// those, so a throughput miss cannot hide a cancellation failure here. The
// whole run is bounded at 2,100 s, about twice its first measured wall on the
// local PostgreSQL topology (1,038 s): past that it fails rather than runs on.
import assert from 'node:assert/strict';
import { writeFile } from 'node:fs/promises';
import { setTimeout } from 'node:timers/promises';
import { harness, item, rss } from './harness.mjs';
import { sampleRuntimeMemory } from '../../NotificationsWorker/tests/runtime-memory.mjs';

const count=1000,cadenceMinutes=15,ticks=30,concurrency=2,replicas=1,LIMIT_S=2100;
// The global timer: setTimeout here is the promise form from node:timers/promises.
globalThis.setTimeout(()=>{console.error(`deadline-load: still running after its ${LIMIT_S} s bound`);process.exit(1);},LIMIT_S*1000).unref();
let deadlineFailures=0,inactivityFailures=0;
const unhealthy=index=>index%200===7||index%200===107;
let cycle=0,logicalNow,requests=0,changed=0,unchanged=0,slow=0,bytes=0;
const releaseTimes=new Map(),fixtureReleases=new Set();
const wallStart=performance.now();
// PostgreSQL storage is bound direct, past the counting wire proxy: this suite
// arms no storage hook and asserts no storage counter.
const h=await harness(async request=>{
  const url=new URL(request.url),index=Number(url.pathname.slice(1));
  requests++;
  if(cycle>0 && unhealthy(index)) {
    const drip=index%200===107;
    if(drip)deadlineFailures++;else inactivityFailures++;
    let timer,closed=false,controller;
    const close=()=>{if(closed)return;closed=true;clearInterval(timer);fixtureReleases.delete(close);try{controller?.close();}catch{}};
    fixtureReleases.add(close);
    const body=new ReadableStream({
      start(source){
        controller=source;
        controller.enqueue(new TextEncoder().encode('<rss><channel><title>Slow fixture</title>'));
        if(drip)timer=setInterval(()=>{try{controller.enqueue(new TextEncoder().encode(' '));}catch{close();}},1000);
      },cancel(){close();}
    });
    request.signal.addEventListener('abort',close,{once:true});
    return new Response(body,{headers:{'content-type':'application/rss+xml'}});
  }
  const modifies=index%10===0;
  const version=modifies?cycle:0;
  const tag=`"${version}"`;
  if(index%100===7){slow++;await setTimeout(250);}
  if(index%10<8 && request.headers.get('if-none-match')===tag){unchanged++;return new Response(null,{status:304});}
  changed++;
  const size=index%100===3?1000:index%100===4?100:10;
  const items=Array.from({length:size},(_,i)=>item(`${index}-base-${i}`,h.now-86400-i*3600));
  if(modifies&&cycle>0){
    // One new, immutable release per cycle; keep earlier members in the feed.
    for(let c=1;c<=cycle;c++)items.push(item(`${index}-release-${c}`,releaseTimes.get(`${index}:${c}`)));
  }
  const body=rss(items);bytes+=Buffer.byteLength(body);
  return new Response(body,{headers:{etag:tag,'content-type':'application/rss+xml'}});
},{replicas,direct:true});
logicalNow=h.now;
let stopMemory,clockAnchor=performance.now();
async function clock(at){
  at=Math.max(at,logicalNow+Math.floor((performance.now()-clockAnchor)/1000));
  logicalNow=at;clockAnchor=performance.now();
  const offset=at-Math.floor(Date.now()/1000);
  await h.invoke('clock',String(offset));
  const delivery=await h.instance.getWorker('delivery-runtime');
  await (await delivery.fetch('https://delivery.invalid/clock',{method:'POST',body:String(offset)})).text();
}
// One Queue delivery under the consumer's policy: a failed response is retried
// three times, then dead-lettered.
async function deliverWake(wake){
  for(let attempts=1;;attempts++){
    const result=await h.consume(wake,{attempts});
    if(result.status===200||result.status===400)return;
    if(attempts>3){await h.invoke('test/dead-letter',wake);return;}
  }
}
// Both pumps feed the one isolate.
async function pump(){
  for(let round=0;round<10000;round++){
    const work=await h.invoke('wakeups');
    if(!work.length)return;
    let cursor=0;
    await Promise.all(Array.from({length:concurrency},async()=>{while(cursor<work.length)await deliverWake(work[cursor++]);}));
  }throw Error('deadline-load pump failed to drain');
}
const activeTransports=audit=>Object.values(audit.activeByOrigin).reduce((n,v)=>n+v,0);
try{
  for(let i=0;i<100;i++)await h.run("INSERT INTO devices(install_id,key_id,device_token,device_token_hash,apns_environment,bundle_id,notifications_enabled,created_at,last_seen_at) VALUES(?,? ,?,?,'development','com.example.opencast',1,?,?)",`user-${i}`,`key-${i}`,i.toString(16).padStart(64,'0'),`token-${i}`,h.now-100000,h.now);
  for(let i=0;i<count;i++)await h.add(`https://${unhealthy(i)?'deadline-'+i:i%4===0?'shared-'+i%5:'host-'+i%100}.example.com/${i}`,h.now,`user-${i%97}`);
  console.log(`SEED ${count} subscribed feeds (${[...Array(count).keys()].filter(unhealthy).length} hanging from the first cycle), ${concurrency} pumps, ${replicas} isolate`);
  stopMemory=await sampleRuntimeMemory(await h.instance.getInspectorURL(),'polling-runtime',30000);
  for(let i=0;i<100;i++){
    await h.invoke('test/dispatch');await pump();
    if((await h.first('SELECT COUNT(*) AS n FROM n_feed WHERE snapshot_key IS NOT NULL')).n===count)break;
  }
  assert.equal((await h.first('SELECT COUNT(*) AS n FROM n_feed WHERE snapshot_key IS NOT NULL')).n,count);
  // Stabilize all phases after baseline admission before measured recurrence.
  const initial=await h.first('SELECT MIN(due_at) AS at FROM n_feed');
  for(let tick=0;tick<cadenceMinutes;tick++){await clock(initial.at+tick*60);await h.invoke('test/dispatch');await pump();}
  const start=initial.at+cadenceMinutes*60;
  for(let tick=0;tick<ticks;tick++){
    cycle=Math.floor(tick/cadenceMinutes)+1;await clock(start+tick*60);
    for(let index=0;index<count;index+=10)if(!releaseTimes.has(`${index}:${cycle}`))releaseTimes.set(`${index}:${cycle}`,start+(cycle-1)*cadenceMinutes*60-1);
    const tickStart=performance.now();await h.invoke('test/dispatch');await pump();await h.deliver(true);
    console.log('TICK '+JSON.stringify({tick,cycle,wall_ms:Math.round(performance.now()-tickStart),deadlineFailures,inactivityFailures}));
  }
  const expected=releaseTimes.size;
  assert.equal((await h.first('SELECT COUNT(*) AS n FROM n_event')).n,expected,'every observed release accepted');
  assert.equal((await h.first("SELECT COUNT(*) AS n FROM n_delivery WHERE state<>'accepted'")).n,0);
  assert.equal((await h.first('SELECT COUNT(*) AS n FROM n_feed WHERE handling_failures>0')).n,0,'nothing dead-lettered');
  const steady=await stopMemory.transportAudit();
  const steadyActive=activeTransports(steady),steadyPeak=Math.max(...Object.values(steady.peakByOrigin));
  // Pause executors for 30 simulated minutes while dispatch continues, then
  // replay the retained wakeups and recover.
  const outageStart=start+ticks*60,outageWakeups=[];
  for(let tick=0;tick<30;tick++){await clock(outageStart+tick*60);await h.invoke('test/dispatch');outageWakeups.push(...await h.invoke('wakeups'));}
  const eventsBeforeReplay=(await h.first('SELECT COUNT(*) AS n FROM n_event')).n;
  await clock(outageStart+1800);
  let replay=0;
  await Promise.all(Array.from({length:concurrency},async()=>{while(replay<outageWakeups.length)await deliverWake(outageWakeups[replay++]);}));
  assert.equal((await h.first('SELECT COUNT(*) AS n FROM n_event')).n,eventsBeforeReplay,'outage replay publishes no duplicate event');
  let recoveryTicks=0;
  for(;recoveryTicks<15;recoveryTicks++){
    await clock(outageStart+1800+recoveryTicks*60);await h.invoke('test/dispatch');await pump();await h.deliver(true);
    const remaining=await h.first("SELECT COUNT(*) AS n FROM n_feed WHERE last_success_at<? AND poll_failures=0",outageStart+1800);
    console.log(`RECOVERY ${recoveryTicks} stale=${remaining.n}`);if(!remaining.n)break;
  }
  assert.ok(recoveryTicks<15,'outage recovery deadline');
  const memory=await stopMemory();stopMemory=undefined;
  const metrics=await h.invoke('metrics');
  const report={count,cadence_minutes:cadenceMinutes,ticks,cycles:ticks/cadenceMinutes,pumps:concurrency,isolates:replicas,hanging_feeds:[...Array(count).keys()].filter(unhealthy).length,
    deadline_failures:deadlineFailures,inactivity_failures:inactivityFailures,
    logged_inactivity:metrics.logged['invalid_scan:feed_inactivity_timeout']??0,logged_fetch_failed:metrics.logged['upstream_error:fetch_failed']??0,
    native_active_after_steady:steadyActive,native_active_after_recovery:activeTransports(memory.transportAudit),
    origin_peak_steady:steadyPeak,origin_peak:Math.max(...Object.values(memory.transportAudit.peakByOrigin)),
    memory_peak_total_bytes:memory.peakCombined.totalBytes,memory_peak_wasm_bytes:memory.peakCombined.wasmBytes,
    recovery_ticks:recoveryTicks,retained_outage_wakeups:outageWakeups.length,expected_events:expected,requests,changed,unchanged,slow,decoded_bytes:bytes,
    wall_seconds:(performance.now()-wallStart)/1000,storage_counters:'not measured (direct)'};
  await writeFile('/private/tmp/opencast-deadline-load.json',JSON.stringify({...report,memory,metrics},null,2));
  assert.ok(deadlineFailures>0&&inactivityFailures>0,'both real timeout classes exercised');
  assert.ok(report.logged_inactivity>0,'real inactivity deadline fired');
  assert.ok(report.logged_fetch_failed>0,'real absolute deadline fired');
  assert.equal(steadyActive,0,'native transports released after steady work');
  assert.equal(report.native_active_after_recovery,0,'native transports released after recovery');
  assert.ok(report.origin_peak<=2,'publisher concurrency including recovery');
  assert.ok(memory.peakCombined.wasmBytes>0,'must include real Wasm linear memory');
  assert.ok(memory.peakCombined.totalBytes<96*1024*1024,'ordinary memory target');
  console.log('PASS hanging-stream cancellation under load in one isolate '+JSON.stringify(report));
}finally{for(const release of fixtureReleases)release();if(stopMemory)await stopMemory();await h.instance.dispose();}
