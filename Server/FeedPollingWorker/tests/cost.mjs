// Measured unit costs per poll outcome on the packaged Workers, isolated D1/R2
// and mocked APNs. It reports the per-outcome units a cost model consumes.
import assert from 'node:assert/strict';
import { writeFile } from 'node:fs/promises';
import { harness,item,rss } from './harness.mjs';
import { processCPU } from './cpu.mjs';
// Each class is its own origin set, so one class can be made due at a time.
const classes={
  matched304:{feeds:70,items:10},
  unchanged200:{feeds:15,items:10},
  unchanged200_large:{feeds:5,items:1000},
  // One new episode in a 100-item catalog: the ordinary production release.
  changed200_single:{feeds:10,items:100,releases:1},
  // The stress case: a five-member burst, deliberately prolific.
  changed200_burst:{feeds:10,items:10,releases:5},
  publisher_failed:{feeds:10,items:10},
  // Crash after the fetch, before the fenced settle: the Queue redelivers and
  // the whole conditional poll runs again.
  redelivered304:{feeds:10,items:10},
};
let round=1;
const h=await harness(request=>{
  const url=new URL(request.url),name=url.hostname.split('.')[0].replace(/-\d+$/,''),index=Number(url.pathname.slice(1)),spec=classes[name];
  if(name==='publisher_failed'&&round>1)return new Response('unavailable',{status:503});
  const releases=spec.releases?(round-1)*spec.releases:0,tag=`"${spec.releases?round:1}"`;
  if(['matched304','redelivered304'].includes(name)&&request.headers.get('if-none-match')===tag)return new Response(null,{status:304});
  const items=[...Array.from({length:spec.items},(_,i)=>item(`${name}-${index}-base-${i}`,h.now-86400-i*3600)),...Array.from({length:releases},(_,i)=>item(`${name}-${index}-release-${i}`,h.now-10+i))];
  // Unchanged 200s come from publishers without usable validators.
  return new Response(rss(items),name.startsWith('unchanged200')?{}:{headers:{etag:tag}});
});
const KEYS=['calls','log_events','d1','rows_read','rows_written','get','put','head','delete','list','multipart','queue_messages'];
const deliveryWorker=await h.instance.getWorker('delivery-runtime');
const delivery=async()=>{
  const traces=await(await deliveryWorker.fetch('https://delivery.invalid/traces')).json();
  const total={calls:traces.length,log_events:(await(await deliveryWorker.fetch('https://delivery.invalid/logcount')).json()).log_events};
  for(const key of ['d1','rows_read','rows_written','queue_messages'])total[key]=traces.reduce((n,t)=>n+(t[key]??0),0);
  total.max_d1=Math.max(0,...traces.map(t=>t.d1));return total;
};
const storage=async()=>({...(await h.first("SELECT COALESCE(SUM(bytes),0) AS r2_bytes,COUNT(*) AS r2_objects FROM n_snapshot WHERE state<>'deleted'")),d1_bytes:(await h.run('UPDATE n_poll_dispatch SET id=id WHERE id=1')).meta.size_after});
const delta=(after,before)=>Object.fromEntries(Object.keys(after).filter(k=>typeof after[k]==='number').map(k=>[k,after[k]-(before[k]??0)]));
async function measure(work){
  const before={polling:await h.invoke('metrics'),delivery:await delivery(),storage:await storage(),cpu:await processCPU(),sends:h.sends.length};
  const start=performance.now();await work();
  const after={polling:await h.invoke('metrics'),delivery:await delivery(),storage:await storage(),cpu:await processCPU()};
  assert.equal(after.cpu.pid,before.cpu.pid);
  const polling=delta(after.polling,before.polling);
  polling.outcomes=Object.fromEntries(Object.entries(after.polling.outcomes).map(([k,n])=>[k,n-(before.polling.outcomes[k]??0)]).filter(([,n])=>n));
  return {polling:Object.fromEntries(Object.entries(polling).filter(([k])=>KEYS.includes(k)||k==='outcomes')),delivery:delta(after.delivery,before.delivery),storage:delta(after.storage,before.storage),workerd_process_cpu_ms:after.cpu.milliseconds-before.cpu.milliseconds,wall_ms:performance.now()-start,apns_sends:h.sends.length-before.sends,max_d1:Math.max(after.polling.max_d1,after.delivery.max_d1)};
}
try{
  // Collection is measured by cleanup.mjs and modeled per interval; keep its
  // fifteen-minute wakeup out of the per-outcome unit costs.
  await h.run("UPDATE n_control SET enabled=0 WHERE name='cleanup'");
  const ids={};let user=0;
  for(const [name,spec] of Object.entries(classes)){
    ids[name]=[];
    for(let i=0;i<spec.feeds;i++,user++){
      await h.run("INSERT INTO devices(install_id,key_id,device_token,device_token_hash,apns_environment,bundle_id,notifications_enabled,created_at,last_seen_at) VALUES(?,?,?,?, 'development','com.example.opencast',1,?,?)",`user-${user}`,`key-${user}`,user.toString(16).padStart(64,'0'),`hash-${user}`,h.now-100000,h.now);
      ids[name].push(await h.add(`https://${name}-${i%10}.example.com/${i}`,h.now,`user-${user}`));
    }
  }
  const total=Object.values(ids).flat().length;
  const result={schema_version:2,measured_at:new Date().toISOString(),feeds:total,classes:{}};
  result.baseline=await measure(async()=>{await h.invoke('test/dispatch');await h.drain();});
  assert.equal((await h.first('SELECT COUNT(*) AS n FROM n_feed WHERE snapshot_key IS NOT NULL')).n,total);
  result.baseline.storage_total=await storage();
  // The dispatcher's fixed cost: a minute with nothing due.
  await h.run('UPDATE n_feed SET due_at=?',h.now+90000);
  result.idle_dispatch_tick=await measure(async()=>{await h.invoke('test/dispatch');});
  assert.equal(result.idle_dispatch_tick.polling.rows_written,0,'an idle minute writes nothing');
  round=2;
  for(const [name,spec] of Object.entries(classes)){
    await h.run('UPDATE n_feed SET due_at=?,dispatch_until=0 WHERE feed_id IN(SELECT value FROM json_each(?))',h.now,JSON.stringify(ids[name]));
    const sample=await measure(async()=>{
      await h.invoke('test/dispatch');
      if(name==='redelivered304'){
        for(const wake of await h.polls()){
          await h.invoke('fault','before_settle');assert.equal((await h.consume(wake)).status,500);
          assert.equal((await h.consume(wake,{attempts:2})).outcome,'not_modified');
        }
      }
      await h.drain();await h.deliver(true);
    });
    await h.run('UPDATE n_feed SET due_at=?,retry_at=0 WHERE feed_id IN(SELECT value FROM json_each(?))',h.now+90000,JSON.stringify(ids[name]));
    const expected={matched304:{not_modified:spec.feeds},unchanged200:{unchanged:spec.feeds},unchanged200_large:{unchanged:spec.feeds},publisher_failed:{publisher_failed:spec.feeds},redelivered304:{not_modified:spec.feeds}}[name];
    if(expected)assert.deepEqual(sample.polling.outcomes,expected,name);
    if(name.startsWith('matched')||name.startsWith('unchanged')){
      // The Required Verification line, measured rather than asserted by hand.
      assert.deepEqual([sample.polling.put,sample.polling.get,sample.polling.head,sample.polling.multipart,sample.storage.r2_objects,sample.storage.r2_bytes],[0,0,0,0,0,0],name);
      assert.ok(sample.polling.rows_written<=3*spec.feeds,`${name} wrote ${sample.polling.rows_written} rows`);
    }
    if(spec.releases){
      assert.equal(sample.apns_sends,spec.feeds,name);
      assert.equal((await h.first("SELECT COUNT(*) AS n FROM n_episode_release WHERE feed_id IN(SELECT value FROM json_each(?))",JSON.stringify(ids[name]))).n,spec.feeds*spec.releases,name);
    }
    result.classes[name]={polls:spec.feeds,items:spec.items,releases_per_poll:spec.releases??0,...sample};
    console.log(`MEASURED ${name}: ${(sample.polling.rows_written/spec.feeds).toFixed(1)} polling rows written/poll, ${((sample.polling.put+sample.polling.multipart+sample.polling.list)/spec.feeds).toFixed(1)} R2 class A/poll, ${(sample.polling.calls/spec.feeds).toFixed(1)} invocations/poll`);
  }
  // The only empty reservations are the failed scans' first-observed bounds.
  assert.equal((await h.first("SELECT COUNT(*) AS n FROM n_snapshot s WHERE s.state='reserved' AND s.sha256='' AND NOT EXISTS(SELECT 1 FROM n_observation o WHERE o.snapshot_key=s.object_key AND o.state='staging' AND o.valid_eof=0)")).n,0,'no unused reservations');
  assert.equal((await h.first("SELECT COUNT(*) AS n FROM sqlite_master WHERE name='n_poll'")).n+(await h.first("SELECT COUNT(*) AS n FROM sqlite_master WHERE name='n_origin_permit'")).n,0);
  result.storage_total=await storage();
  await writeFile('/private/tmp/opencast-pass045-cost.json',JSON.stringify(result,null,2));
  console.log('PASS measured unit costs per poll outcome, source/delivery work, storage growth and workerd CPU');
}finally{await h.instance.dispose();}
