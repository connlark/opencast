import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { writeFile } from 'node:fs/promises';
import { harness,item,rss } from './harness.mjs';
let version=1;
const h=await harness(()=>new Response(rss([item('base',h.now-100),...(version>1?[item('stale-backfill',h.now-9*86400)]:[])])));
// Cleanup is admitted on a fifteen-minute boundary, not every minute.
const boundary=async after=>{const minute=Math.floor((Date.now()/1000+after)/60);const offset=after+((15-minute%15)%15)*60+5;await h.invoke('clock',String(offset));return offset;};
const collectible=async()=>(await h.invoke('test/stats')).snapshot_orphan_total;
try {
  const feed=await h.add('https://cleanup.example.com/feed');
  await h.invoke('test/dispatch');await h.drain();
  const bucket=await h.instance.getR2Bucket('FEED_SNAPSHOTS','polling-runtime');
  // Off the boundary nothing is enqueued: no per-minute cleanup wakeup or lease.
  const minute=Math.floor(Date.now()/60000);await h.invoke('clock',String(((minute%15===14?2:1))*60));
  if(Math.floor((Date.now()/1000+((minute%15===14?2:1))*60)/60)%15!==0){await h.run('UPDATE n_feed SET due_at=?',h.now+90000);await h.invoke('test/dispatch');assert.equal((await h.invoke('wakeups')).filter(w=>w.kind==='cleanup').length,0);}
  const live=(await h.first('SELECT snapshot_key FROM n_feed')).snapshot_key;
  const keys=Array.from({length:650},()=>randomUUID());
  await h.run("INSERT INTO n_snapshot(object_key,feed_id,owner_epoch,lease_id,sha256,bytes,state,created_at,gc_after) SELECT value,?,1,?,'',0,'reserved',?,? FROM json_each(?)",feed,randomUUID(),h.now-864000,h.now-1,JSON.stringify(keys));
  for(const key of keys.slice(0,5))await bucket.put(key,'orphan');
  // A scan that crashed between completing scratch and deleting it.
  await bucket.put(`scratch/${feed}/${randomUUID()}`,'crashed-copy');
  await h.run('UPDATE n_feed SET due_at=?',h.now+90000);
  assert.ok(await collectible()>=650);
  let offset=await boundary(3700);await h.invoke('test/dispatch');
  assert.equal((await h.invoke('wakeups')).filter(w=>w.kind==='cleanup').length,1,'one cleanup wakeup per interval');
  await h.invoke('test/dispatch');await h.drain();
  assert.equal((await h.first('SELECT COUNT(*) AS n FROM n_snapshot WHERE object_key IN(SELECT value FROM json_each(?))',JSON.stringify(keys))).n,0);
  assert.ok(await bucket.get(live),'current manifest survives chained collection');
  for(const key of keys.slice(0,5))assert.equal(await bucket.get(key),null);
  assert.equal((await bucket.list({prefix:'scratch/'})).objects.length,0,'no permanent scratch object');
  assert.equal(await collectible(),0);
  console.log('PASS interval cleanup chains 650 obsolete reservations/objects, sweeps crashed scratch and preserves current data');

  // A real changed publication leaves replaced pages and preparation objects.
  // After their grace they are collected: no growth across two intervals.
  version=2;await h.run('UPDATE n_feed SET due_at=?',h.now+offset);
  await h.invoke('test/dispatch');await h.drain();
  assert.equal((await h.first('SELECT observation_generation FROM n_feed')).observation_generation,2);
  const objects=(await bucket.list()).objects.length;
  const growth=[];
  for(const days of [8,16]){
    await h.run('UPDATE n_feed SET due_at=?',h.now+90*86400);
    offset=await boundary(days*86400);await h.invoke('test/dispatch');await h.drain();
    growth.push(await collectible());
  }
  assert.deepEqual(growth,[0,0],'collectible objects do not grow across two cleanup intervals');
  assert.ok((await bucket.list()).objects.length<objects,'superseded pages and preparation objects were deleted');
  assert.ok(await bucket.get((await h.first('SELECT snapshot_key FROM n_feed')).snapshot_key));
  const metrics=await h.invoke('metrics');
  assert.ok(metrics.max_d1<800,`largest invocation used ${metrics.max_d1} D1 statements`);
  assert.ok(metrics.delete>=650);
  await writeFile('/private/tmp/opencast-pass045-cleanup.json',JSON.stringify(metrics,null,2));
  console.log(`PASS no positive growth of collectible objects across two intervals; largest invocation ${metrics.max_d1} D1 statements`);
}finally {await h.instance.dispose();}
