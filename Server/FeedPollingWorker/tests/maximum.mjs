import assert from 'node:assert/strict';
import { Readable } from 'node:stream';
import { writeFile } from 'node:fs/promises';
import { harness, item, rss } from './harness.mjs';
import { sampleRuntimeMemory } from '../../NotificationsWorker/tests/runtime-memory.mjs';
import { summarizeCPU } from './cpu.mjs';
const count=100000,bytes=128*1024*1024;
let version=1;
const h=await harness(request=>{
  if(new URL(request.url).hostname!=='maximum.example.com')return new Response(rss([item('healthy',h.now-10)]));
  const header='<rss><channel><title>Maximum queued feed</title>',footer='</channel></rss>';
  let overhead=header.length+footer.length;
  for(let i=0;i<count;i++)overhead+=item(`max-${i}`,h.now-100).length+19;
  const padding=Math.floor((bytes-overhead)/count),remainder=(bytes-overhead)%count;
  async function* chunks(){
    yield Buffer.from(header);
    for(let start=0;start<count;start+=50){if(version===2&&start%500===0)await new Promise(resolve=>setTimeout(resolve,50));let chunk='';for(let i=start;i<start+50;i++)chunk+=item(`max-${i}`,h.now-100).replace('</item>',`<padding>${'x'.repeat(padding+(i<remainder?1:0))}</padding></item>`);yield Buffer.from(chunk);}
    yield Buffer.from(footer);
  }
  // Miniflare compresses the Node response on its local transport.
  return new Response(Readable.toWeb(Readable.from(chunks())),{headers:{etag:`"v${version}"`,'content-encoding':'gzip','content-type':'application/rss+xml'}});
},{replicas:2});
let stop;
async function drainBoth(maxJob){
  for(let round=0;round<3000;round++){
    const wakes=[...await h.invoke('wakeups'),...await h.invoke('wakeups',undefined,undefined,1)];
    if(!wakes.length)return;
    const lanes=[wakes.filter(w=>w.feed_id===maxJob),wakes.filter(w=>w.feed_id!==maxJob)];
    await Promise.all(lanes.map(async(list,replica)=>{for(const wake of list)assert.equal((await h.consume(wake,{replica})).status,200);}));
  }throw Error('maximum-feed queue did not drain');
}
try{
  const feed=await h.add('https://maximum.example.com/feed');
  for(let i=0;i<100;i++)await h.add(`https://healthy-${i}.example.com/feed`,h.now+7200);
  await h.invoke('test/stats',undefined,undefined,1);
  stop=await sampleRuntimeMemory(await h.instance.getInspectorURL(),'polling-runtime',30000);
  const phases=[];
  for(version=1;version<=2;version++){
    await h.run('UPDATE n_feed SET due_at=? WHERE feed_id=?',h.now,feed);
    const stopCPU=await stop.profileCPU();
    const start=performance.now();await h.invoke('test/dispatch');
    const maximumJob=feed;
    let healthyAtScanEnd=0;
    if(version===2){
      const wake=(await h.invoke('wakeups')).find(w=>w.feed_id===maximumJob);
      const scanning=h.consume(wake).then(async result=>{assert.equal(result.outcome,'unchanged');healthyAtScanEnd=(await h.first('SELECT COUNT(*) AS n FROM n_feed WHERE feed_id<>? AND snapshot_key IS NOT NULL',feed)).n;});
      await new Promise(resolve=>setTimeout(resolve,25));
      await h.run('UPDATE n_feed SET due_at=? WHERE feed_id<>?',h.now,feed);
      // Dispatch/read the other isolate's queue without first awaiting a request
      // to the busy scanning isolate; that would serialize the test coordinator.
      await h.invoke('test/dispatch',undefined,undefined,1);
      for(let round=0;round<100;round++){
        const healthy=await h.invoke('wakeups',undefined,undefined,1);if(!healthy.length)break;
        for(const message of healthy)await h.consume(message,{replica:1});
      }
      await scanning;await drainBoth(maximumJob);
    }else await drainBoth(maximumJob);
    const captured=await stopCPU();const cpu=summarizeCPU(captured.profile,captured.target);
    await writeFile(`/private/tmp/opencast-pass045-maximum-${version}.cpuprofile`,JSON.stringify(cpu.profile));delete cpu.profile;
    // The rescan is a complete, unchanged 200: exact membership is compared in
    // the isolate and the generation does not move.
    assert.equal((await h.first('SELECT observation_generation FROM n_feed WHERE feed_id=?',feed)).observation_generation,1);
    if(version===2){
      assert.deepEqual(await h.first("SELECT (SELECT COUNT(*) FROM n_observation WHERE feed_id=?1) AS observations,(SELECT last_poll_outcome FROM n_feed WHERE feed_id=?1) AS outcome",feed),{observations:1,outcome:'unchanged'});
      assert.equal((await(await h.instance.getR2Bucket('FEED_SNAPSHOTS','polling-runtime')).list({prefix:'scratch/'})).objects.length,0);
    }
    assert.equal((await h.first('SELECT COUNT(*) AS n FROM n_event')).n,0);
    if(version===2)assert.ok(healthyAtScanEnd>0,'healthy consumer must progress during the maximum scan');
    phases.push({version,wall_ms:performance.now()-start,healthyAtScanEnd,cpu,metrics:await h.invoke('metrics'),memory:await stop.snapshot()});
    console.log(`PASS queued 128 MiB/100000-item gzip ${version===1?'baseline':'complete unchanged rescan through scratch'}`);
  }
  const memory=await stop();stop=undefined;
  assert.ok(memory.peakCombined.wasmBytes>0,'must include real Wasm linear memory');
  assert.ok(memory.peakCombined.totalBytes<128*1024*1024,'platform memory limit');
  const metrics=await h.invoke('metrics');assert.ok(metrics.max_d1<800);
  await writeFile('/private/tmp/opencast-pass045-maximum.json',JSON.stringify({count,decoded_bytes:bytes,phases,memory,metrics},null,2));
}finally{if(stop)await stop();await h.instance.dispose();}
