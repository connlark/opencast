import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { writeFile } from 'node:fs/promises';
import { harness,item,rss } from './harness.mjs';
let version=1;
const h=await harness(()=>new Response(rss([item('base',h.now-100),...(version>1?[item('stale-backfill',h.now-9*86400)]:[])])));
// Invoke the pinned workerd scheduled event endpoint with each real cron.
const scheduled=async cron=>{
  const response=await h.instance.dispatchFetch('http://localhost/cdn-cgi/local/scheduled?cron='+encodeURIComponent(cron));
  assert.equal(response.status,200,await response.text());
};
const cleanup=()=>scheduled('*/2 * * * *');
const collectible=async()=>(await h.invoke('test/stats')).snapshot_orphan_total;
try {
  const feed=await h.add('https://cleanup.example.com/feed');
  await h.invoke('test/dispatch');await h.drain();
  const bucket=await h.instance.getR2Bucket('FEED_SNAPSHOTS','polling-runtime');
  await h.run('UPDATE n_feed SET due_at=?',h.now+90000);
  await scheduled('* * * * *');
  assert.equal((await h.invoke('metrics')).cleanup.length,0,'one-minute cron only dispatches');
  const legacy={schema_version:2,environment:'development',kind:'cleanup',feed_id:'',owner_epoch:0,generation:Math.floor(h.now/60),due_at:h.now,step:0};
  const beforeLegacy=await h.invoke('metrics');
  assert.equal((await h.consume(legacy)).outcome,'cleanup_ignored');
  const afterLegacy=await h.invoke('metrics');
  assert.equal(afterLegacy.d1,beforeLegacy.d1,'retained cleanup message performs no storage work');
  const live=(await h.first('SELECT snapshot_key FROM n_feed')).snapshot_key;
  const keys=Array.from({length:650},()=>randomUUID());
  await h.run("INSERT INTO n_snapshot(object_key,feed_id,owner_epoch,lease_id,sha256,bytes,state,created_at,gc_after) SELECT value,?,1,?,'',0,'reserved',?,? FROM json_each(?)",feed,randomUUID(),h.now-864000,h.now-1,JSON.stringify(keys));
  for(const key of keys.slice(0,5))await bucket.put(key,'orphan');
  // A non-current recovery object stays protected for seven days by its lease.
  const recoveryKey=randomUUID(),recoveryLease=randomUUID();
  await bucket.put(recoveryKey,'recovery');
  await h.run("INSERT INTO n_snapshot(object_key,feed_id,owner_epoch,lease_id,sha256,bytes,state,created_at,gc_after) VALUES(?,?,1,?,'',8,'uploaded',?,?)",recoveryKey,feed,recoveryLease,h.now-864000,h.now-1);
  const recovery={...await h.first('SELECT * FROM n_observation WHERE feed_id=?',feed),observation_id:randomUUID(),lease_id:recoveryLease,snapshot_key:recoveryKey,state:'abandoned',valid_eof:1,recovery_evidence:1,scan_started_at:h.now};
  const columns=Object.keys(recovery);
  await h.run(`INSERT INTO n_observation(${columns.join(',')}) VALUES(${columns.map(()=>'?').join(',')})`,...columns.map(k=>recovery[k]));
  // A scan that crashed between completing scratch and deleting it.
  await bucket.put(`scratch/${feed}/${randomUUID()}`,'crashed-copy');
  await h.run('UPDATE n_feed SET due_at=?',h.now+90000);
  assert.ok(await collectible()>=650);
  let offset=3700;await h.invoke('clock',String(offset));
  await h.invoke('fault','cleanup_budget');
  const previousGeneration=(await h.first('SELECT cleanup_generation FROM n_poll_dispatch')).cleanup_generation;
  await cleanup();
  assert.equal((await h.first('SELECT cleanup_generation FROM n_poll_dispatch')).cleanup_generation,previousGeneration,'scratch budget stop leaves cursor unadvanced');
  assert.equal((await h.invoke('metrics')).cleanup.at(-1).budget_exhausted,true);
  assert.ok(await collectible()>=650,'no snapshot starts after scratch used the budget');
  await h.invoke('fault','cleanup_budget');await cleanup();
  assert.equal((await h.first('SELECT cleanup_generation FROM n_poll_dispatch')).cleanup_generation,previousGeneration,'object budget stop leaves cursor unadvanced');
  assert.ok(await collectible()>=649,'only one snapshot starts before the object budget expires');
  for(let i=0;i<10 && await collectible();i++)await cleanup();
  assert.equal((await h.invoke('wakeups')).length,0,'cleanup never enqueues or chains work');
  assert.deepEqual([...new Set((await h.invoke('metrics')).cron)],['* * * * *','*/2 * * * *']);
  assert.equal((await h.first('SELECT COUNT(*) AS n FROM n_snapshot WHERE object_key IN(SELECT value FROM json_each(?))',JSON.stringify(keys))).n,0);
  assert.ok(await bucket.get(live),'current manifest survives scheduled collection');
  for(const key of keys.slice(0,5))assert.equal(await bucket.get(key),null);
  assert.equal((await bucket.list({prefix:'scratch/'})).objects.length,0,'no permanent scratch object');
  assert.equal(await collectible(),0);
  assert.ok(await bucket.get(recoveryKey),'unexpired complete recovery evidence survives GC');
  console.log('PASS independent cron cleanup collects 650 obsolete reservations/objects, sweeps crashed scratch and preserves current data');

  // A real changed publication leaves replaced pages and preparation objects.
  // After their grace they are collected: no growth across two intervals.
  version=2;await h.run('UPDATE n_feed SET due_at=?',h.now+offset);
  await h.invoke('test/dispatch');await h.drain();
  assert.equal((await h.first('SELECT observation_generation FROM n_feed')).observation_generation,2);
  const objects=(await bucket.list()).objects.length;
  const growth=[];
  for(const days of [8,16]){
    await h.run('UPDATE n_feed SET due_at=?',h.now+90*86400);
    offset=days*86400;await h.invoke('clock',String(offset));await cleanup();
    growth.push(await collectible());
  }
  assert.equal(await bucket.get(recoveryKey),null,'recovery evidence becomes collectible after its existing grace');
  assert.deepEqual(growth,[0,0],'collectible objects do not grow across two cleanup intervals');
  assert.ok((await bucket.list()).objects.length<objects,'superseded pages and preparation objects were deleted');
  assert.ok(await bucket.get((await h.first('SELECT snapshot_key FROM n_feed')).snapshot_key));
  const metrics=await h.invoke('metrics');
  assert.ok(metrics.max_d1<800,`largest invocation used ${metrics.max_d1} D1 statements`);
  assert.ok(metrics.delete>=650);
  await writeFile('/private/tmp/opencast-pass045-cleanup.json',JSON.stringify(metrics,null,2));
  await h.run("UPDATE n_control SET enabled=0 WHERE name='cleanup'");
  const beforeDisabled=await h.invoke('metrics');await cleanup();
  assert.equal((await h.invoke('metrics')).delete,beforeDisabled.delete,'disabled cleanup cron deletes nothing');
  console.log(`PASS no positive growth of collectible objects across two intervals; largest invocation ${metrics.max_d1} D1 statements`);
}finally {await h.instance.dispose();}
