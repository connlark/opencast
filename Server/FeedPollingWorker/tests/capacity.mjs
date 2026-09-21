// Sustained real packaged work with a virtual dispatcher clock. No publisher
// network traffic: every RSS body, delay, status and APNs response is controlled.
// This is the bounded fixture experiment for the disabled five-minute switch:
// it drives every feed at the fastest cadence to measure throughput and outage
// recovery, not the production schedule.
import assert from 'node:assert/strict';
import { writeFile } from 'node:fs/promises';
import { setTimeout } from 'node:timers/promises';
import { harness, item, rss } from './harness.mjs';
import { sampleRuntimeMemory } from '../../NotificationsWorker/tests/runtime-memory.mjs';

const count=Number(process.env.OPENCAST_POLL_FEEDS??2000);
const ticks=Number(process.env.OPENCAST_POLL_TICKS??30);
assert.ok(ticks>0&&ticks%5===0,'measure whole five-minute cycles');
const concurrency=Number(process.env.OPENCAST_POLL_CONCURRENCY??2);
const replicas=process.env.OPENCAST_POLL_SHARED==='1'?1:concurrency;
const deadlines=process.env.OPENCAST_POLL_DEADLINES==='1';
assert.ok(!deadlines||replicas===1,'deadline fixture audits native cancellation in its shared isolate');
const suffix=deadlines?'deadline-shared':replicas===1?'shared':'separate';
let deadlineFailures=0,inactivityFailures=0;
const unhealthy=index=>deadlines&&(index%200===7||index%200===107);
let cycle=0,logicalNow,requests=0,changed=0,unchanged=0,slow=0,bytes=0;
const active=new Map(),originPeak=new Map(),releaseTimes=new Map(),fixtureReleases=new Set();
const h=await harness(async request=>{
  const url=new URL(request.url),index=Number(url.pathname.slice(1));
  const origin=url.origin;active.set(origin,(active.get(origin)??0)+1);originPeak.set(origin,Math.max(originPeak.get(origin)??0,active.get(origin)));
  let streaming=false;
  try {
    requests++;
    if(cycle>0 && unhealthy(index)) {
      streaming=true;
      const drip=index%200===107;
      if(drip)deadlineFailures++;else inactivityFailures++;
      let timer,closed=false,controller;
      const close=()=>{if(closed)return;closed=true;clearInterval(timer);active.set(origin,active.get(origin)-1);fixtureReleases.delete(close);try{controller?.close();}catch{}};
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
  }finally{if(!streaming)active.set(origin,active.get(origin)-1);}
},{replicas,fiveMinute:true});
logicalNow=h.now;
let stopMemory,clockAnchor=performance.now();
const samples=[],lag=[],deliveryLag=[];
async function clock(at){
  at=Math.max(at,logicalNow+Math.floor((performance.now()-clockAnchor)/1000));
  logicalNow=at;clockAnchor=performance.now();
  const offset=at-Math.floor(Date.now()/1000);
  for(let i=0;i<replicas;i++)await h.invoke('clock',String(offset),undefined,i);
  const delivery=await h.instance.getWorker('delivery-runtime');
  await (await delivery.fetch('https://delivery.invalid/clock',{method:'POST',body:String(offset)})).text();
}
const SETTLED=new Set(['not_modified','unchanged','published']);
let measuring=false,completedPolls=0;
// One Queue delivery under the consumer's policy: a failed response is retried
// three times, then dead-lettered. The envelope's due time gives the lag.
async function deliverWake(wake,replica){
  for(let attempts=1;;attempts++){
    const result=await h.consume(wake,{attempts,replica});
    if(result.status===200||result.status===400){
      if(measuring&&wake.kind==='poll'&&SETTLED.has(result.outcome)){completedPolls++;lag.push(Math.max(0,logicalNow+Math.floor((performance.now()-clockAnchor)/1000)-wake.due_at));}
      return;
    }
    if(attempts>3){await h.invoke('test/dead-letter',wake,undefined,replica);return;}
  }
}
async function pump(){
  let invocations=0;
  for(let round=0;round<10000;round++){
    const work=[];
    for(let i=0;i<replicas;i++)work.push(...await h.invoke('wakeups',undefined,undefined,i));
    if(!work.length)return invocations;
    // Independent pumps may share the same isolate; Cloudflare does not
    // promise one isolate per consumer invocation.
    let cursor=0;
    await Promise.all(Array.from({length:concurrency},async(_,replica)=>{
      while(cursor<work.length){const wake=work[cursor++];invocations++;await deliverWake(wake,replica%replicas);}
    }));
  }throw Error('capacity pump failed to drain');
}
try{
  // Multiple hosts plus 25% concentration on five origins, not one host per feed.
  for(let i=0;i<100;i++)await h.run("INSERT INTO devices(install_id,key_id,device_token,device_token_hash,apns_environment,bundle_id,notifications_enabled,created_at,last_seen_at) VALUES(?,? ,?,?,'development','com.example.opencast',1,?,?)",`user-${i}`,`key-${i}`,i.toString(16).padStart(64,'0'),`token-${i}`,h.now-100000,h.now);
  for(let i=0;i<count;i++)await h.add(`https://${unhealthy(i)?'deadline-'+i:i%4===0?'shared-'+i%5:'host-'+i%100}.example.com/${i}`,h.now,`user-${i%97}`);
  console.log(`SEED ${count} actual subscribed feeds, ${concurrency} consumers`);
  stopMemory=await sampleRuntimeMemory(await h.instance.getInspectorURL(),'polling-runtime',30000);
  for(let i=0;i<100;i++){
    await h.invoke('test/dispatch');await pump();
    if((await h.first('SELECT COUNT(*) AS n FROM n_feed WHERE snapshot_key IS NOT NULL')).n===count)break;
  }
  assert.equal((await h.first('SELECT COUNT(*) AS n FROM n_feed WHERE snapshot_key IS NOT NULL')).n,count);
  assert.equal((await h.first('SELECT COUNT(*) AS n FROM n_event')).n,0);
  // Stabilize all phases after baseline admission before measured recurrence.
  const initial=await h.first('SELECT MIN(due_at) AS at FROM n_feed');
  for(let tick=0;tick<5;tick++){await clock(initial.at+tick*60);await h.invoke('test/dispatch');await pump();}
  const start=initial.at+300;
  const beforeMetrics=await Promise.all(Array.from({length:replicas},(_,i)=>h.invoke('metrics',undefined,undefined,i)));
  const beforeRequests=requests;measuring=true;
  const wallStart=performance.now(),cpuStart=process.cpuUsage();
  for(let tick=0;tick<ticks;tick++){
    cycle=Math.floor(tick/5)+1;await clock(start+tick*60);
    // Publisher availability exists independently of whether a consumer sees
    // that cycle. A delayed scan must recover each earlier immutable release.
    for(let index=0;index<count;index+=10)if(!releaseTimes.has(`${index}:${cycle}`))releaseTimes.set(`${index}:${cycle}`,start+(cycle-1)*300-1);
    const tickStart=performance.now();await h.invoke('test/dispatch');const invocations=await pump();await h.deliver(true);
    // Every generation admitted this minute settled before the next tick.
    const outstanding=await h.first('SELECT COUNT(*) AS n FROM n_feed WHERE dispatch_until>0 AND poll_failures=0');
    samples.push({tick,cycle,wall_ms:performance.now()-tickStart,invocations,completed:completedPolls,outstanding:outstanding.n,fetches:requests-beforeRequests});
    console.log('TICK '+JSON.stringify(samples.at(-1)));
  }
  const steadyWall=(performance.now()-wallStart)/1000;
  const cpu=process.cpuUsage(cpuStart);
  measuring=false;const completed={length:completedPolls};
  deliveryLag.push(...(await h.rows("SELECT d.terminal_at-e.eligible_at AS lag FROM n_delivery d JOIN n_event e ON e.source=d.source AND e.event_id=d.event_id WHERE d.state='accepted'")).map(r=>r.lag));
  const expected=releaseTimes.size;
  assert.equal((await h.first('SELECT COUNT(*) AS n FROM n_event')).n,expected,'every observed release accepted');
  assert.equal((await h.first('SELECT COUNT(*) AS n FROM n_delivery_member')).n,expected,'every event has its immutable presentation');
  assert.equal((await h.first("SELECT COUNT(*) AS n FROM n_delivery WHERE state<>'accepted'")).n,0);
  assert.equal((await h.first('SELECT COUNT(*) AS n FROM n_feed WHERE handling_failures>0')).n,0,'nothing dead-lettered');
  assert.equal((await h.first("SELECT COUNT(*) AS n FROM sqlite_master WHERE name='n_poll'")).n+(await h.first("SELECT COUNT(*) AS n FROM sqlite_master WHERE name='n_origin_permit'")).n,0);
  const transport=await stopMemory.transportAudit();
  // The Node outbound bridge retains source streams after workerd cancels.
  // Use native fetch/reader lifetimes for the shared-isolate timeout workload.
  const maximumOriginRequests=()=>replicas===1?Math.max(...Object.values(transport.peakByOrigin)):Math.max(...originPeak.values());
  assert.ok(maximumOriginRequests()<=2,'publisher concurrency');
  if(replicas===1)assert.ok(Object.values(transport.activeByOrigin).every(n=>n===0),'native transports released after steady work');
  // Pause executors for 30 simulated minutes while dispatch continues. A
  // reservation expires every five minutes, so each feed is re-dispatched under
  // a newer generation. Schedules must coalesce, and every retained message of
  // a superseded generation must be rejected without a fetch.
  const outageStart=start+ticks*60;
  const outageWakeups=[];
  for(let tick=0;tick<30;tick++){await clock(outageStart+tick*60);await h.invoke('test/dispatch');for(let i=0;i<replicas;i++)outageWakeups.push(...await h.invoke('wakeups',undefined,undefined,i));}
  assert.ok((await h.first('SELECT COUNT(*) AS n FROM n_feed WHERE dispatch_until>0')).n<=count);
  const live=new Map((await h.rows('SELECT feed_id,schedule_generation FROM n_feed')).map(f=>[f.feed_id,f.schedule_generation]));
  const superseded=outageWakeups.filter(w=>w.kind==='poll'&&w.generation<live.get(w.feed_id)).length,replayRequests=requests;
  const recoverWall=performance.now();let recoveryTicks=0;
  // Replay retained duplicates as well as reconciling lost wakeups.
  await clock(outageStart+1800);
  let replay=0;
  await Promise.all(Array.from({length:concurrency},async(_,i)=>{while(replay<outageWakeups.length)await deliverWake(outageWakeups[replay++],i%replicas);}));
  assert.ok(requests-replayRequests<=outageWakeups.length-superseded,'a superseded generation never fetches');
  for(;recoveryTicks<15;recoveryTicks++){
    await clock(outageStart+1800+recoveryTicks*60);await h.invoke('test/dispatch');await pump();await h.deliver(true);
    const remaining=await h.first("SELECT COUNT(*) AS n FROM n_feed WHERE last_success_at<? AND poll_failures=0",outageStart+1800);
    console.log(`RECOVERY ${recoveryTicks} stale=${remaining.n}`);if(!remaining.n)break;
  }
  assert.ok(recoveryTicks<15,'outage recovery deadline');
  const memory=await stopMemory();stopMemory=undefined;
  const metrics=await Promise.all(Array.from({length:replicas},(_,i)=>h.invoke('metrics',undefined,undefined,i)));
  const percentile=(values,p)=>values.toSorted((a,b)=>a-b)[Math.floor(values.length*p)]??0;
  const report={count,concurrency,replicas,deadline_fixture_percent:deadlines?1:0,deadlineFailures,inactivityFailures,retained_outage_wakeups:outageWakeups.length,superseded_outage_wakeups:superseded,ticks,virtual_steady_minutes:ticks,completed_polls:completed.length,steady_wall_seconds:steadyWall,polls_per_second:completed.length/steadyWall,p95_due_seconds:percentile(lag,.95),max_due_seconds:Math.max(...lag),p95_event_to_apns_seconds:percentile(deliveryLag,.95),expected_events:expected,requests,changed,unchanged,slow,decoded_bytes:bytes,maximum_origin_requests:replicas===1?Math.max(...Object.values(memory.transportAudit.peakByOrigin)):Math.max(...originPeak.values()),origin_measurement:replicas===1?'native fetch/body lifetime':'node outbound across replicas',recovery_virtual_seconds:Math.max(60,Math.ceil((logicalNow-outageStart-1800+(performance.now()-clockAnchor)/1000)/60)*60),recovery_wall_seconds:(performance.now()-recoverWall)/1000,memory,metrics,beforeMetrics,samples,node_driver_cpu_us:cpu};
  await writeFile(`/private/tmp/opencast-pass045-capacity-${suffix}.json`,JSON.stringify(report,null,2));
  assert.ok(report.p95_due_seconds<60,`due p95 ${report.p95_due_seconds}`);
  assert.ok(report.p95_event_to_apns_seconds<60,`APNs p95 ${report.p95_event_to_apns_seconds}`);
  assert.ok(report.polls_per_second>=1000/300*2,`required steady throughput ${report.polls_per_second}`);
  assert.ok(report.maximum_origin_requests<=2,'publisher concurrency including recovery');
  if(replicas===1)assert.ok(Object.values(memory.transportAudit.activeByOrigin).every(n=>n===0),'native transports released after recovery');
  if(deadlines){
    assert.ok(deadlineFailures>0&&inactivityFailures>0,'both real timeout classes exercised');
    assert.ok(metrics.some(m=>m.logged['invalid_scan:feed_inactivity_timeout']>0),'real inactivity deadline fired');
    assert.ok(metrics.some(m=>m.logged['upstream_error:fetch_failed']>0),'real absolute deadline fired');
  }
  assert.ok(memory.peakCombined.wasmBytes>0,'must include real Wasm linear memory');
  assert.ok(memory.peakCombined.totalBytes<96*1024*1024,'ordinary memory target');
  console.log('PASS sustained whole-pipeline capacity and outage recovery '+JSON.stringify({polls:report.completed_polls,rate:report.polls_per_second,p95:report.p95_due_seconds,recovery:report.recovery_virtual_seconds}));
}finally{for(const release of fixtureReleases)release();if(stopMemory)await stopMemory();await h.instance.dispose();}
