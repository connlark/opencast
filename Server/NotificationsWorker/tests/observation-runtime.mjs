import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {fileURLToPath} from 'node:url';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {Readable} from 'node:stream';
import {writeFile} from 'node:fs/promises';
import {Miniflare,convertV4MiniflareOptions} from 'miniflare';
import {migrate} from './migrations.mjs';
import {compatibilityDate,compatibilityFlags} from './runtime-compatibility.mjs';
import {sampleRuntimeMemory} from './runtime-memory.mjs';
import {reviewRegressions} from './observation-review-cases.mjs';
const root=fileURLToPath(new URL('../',import.meta.url));
const hash=parts=>createHash('sha256').update(JSON.stringify(parts)).digest('hex');
const now=Math.floor(Date.now()/1000);
let url='https://fixture.example.com/feed.xml',feed=hash(['feed-v1',url]);
let items=[],tail='',etag='"v1"',requests=0,large,fetchHook,loseReceipt=false;
const item=(id,date=now-60,title=`Episode ${id}`)=>`<item><guid>${id}</guid><title>${title}</title>${date===null?'':`<pubDate>${new Date(date*1000).toUTCString()}</pubDate>`}<description>Summary ${id}</description><enclosure url="https://audio.example.com/${id}.mp3"/></item>`;
const sends=[];
const mf=new Miniflare(convertV4MiniflareOptions({cf:false,inspectorPort:0,workers:[{
  name:'notifications-observation-runtime',modulesRoot:root,
  modules:[{type:'ESModule',path:root+'tests/observation-entry.mjs'},{type:'ESModule',path:root+'adapter/index.js'},{type:'ESModule',path:root+'build/index.js'},{type:'CompiledWasm',path:root+'build/index_bg.wasm'}],
  compatibilityDate,compatibilityFlags,d1Databases:{APP_ATTEST_DB:'isolated-observations'},r2Buckets:{FEED_SNAPSHOTS:'isolated-snapshots'},
  queueProducers:{EVENT_QUEUE:'opencast-notification-event-development',EPISODE_DELIVERY_QUEUE:'opencast-notification-episode-development',JOB_DELIVERY_QUEUE:'opencast-notification-job-development'},
  bindings:{NOTIFICATION_ENVIRONMENT:'development',NOTIFICATION_CLEANUP:'true',NOTIFICATION_FEED_OBSERVATION:'true',NOTIFICATION_EPISODE_ACTIVATION:'true',NOTIFICATION_EPISODE_SEND:'true',APPLE_TEAM_ID:'EXAMPLETEAM',APPLE_BUNDLE_ID:'com.example.opencast',APP_ATTEST_ENVIRONMENT:'development',APNS_ENVIRONMENT:'development',PUBLIC_NOTIFICATIONS_ENABLED:'false',DEBUG_ENDPOINTS_ENABLED:'true'},
  serviceBindings:{NOTIFICATION_EVENTS:async req=>{const response=await mf.dispatchFetch('https://runtime.example.com/v1/events',{method:'POST',body:await req.text()});if(loseReceipt){loseReceipt=false;await response.text();return new Response('lost receipt',{status:503});}return response;},APNS_CERT:async req=>{sends.push(await req.json());return new Response(null,{status:200});}},
  outboundService:async req=>{
    assert.equal(new URL(req.url).hostname,'fixture.example.com');requests++;
    if(fetchHook){const hook=fetchHook;fetchHook=undefined;const result=await hook();if(result)return result;}
    if(req.headers.get('if-none-match')===etag)return new Response(null,{status:304});
    if(large){
      const {count,bytes,gzip,edited}=large;
      const header='<rss><channel><title>Maximum fixture</title>',footer='</channel></rss>';
      // `edited` changes one fingerprint and no identity: a semantic change
      // that must prepare the whole history and release nothing.
      const entry=i=>item(`maximum-${i}`,undefined,edited&&i===0?'Episode maximum-0 (corrected)':undefined);
      let overhead=header.length+footer.length;
      for(let i=0;i<count;i++)overhead+=entry(i).length+'<padding></padding>'.length;
      const padding=Math.floor((bytes-overhead)/count),remainder=(bytes-overhead)%count;
      assert.ok(padding>=0);
      function* chunks(){
        yield Buffer.from(header);
        for(let start=0;start<count;start+=50){
          let chunk='';for(let i=start;i<Math.min(start+50,count);i++)chunk+=entry(i).replace('</item>',`<padding>${'x'.repeat(padding+(i<remainder?1:0))}</padding></item>`);
          yield Buffer.from(chunk);
        }
        yield Buffer.from(footer);
      }
      // Miniflare compresses this Node response on its loopback wire when
      // Content-Encoding is set; supplying gzip bytes here would double-encode.
      const stream=Readable.from(chunks());
      return new Response(Readable.toWeb(stream),{headers:{etag,'content-type':'application/rss+xml',...(gzip?{'content-encoding':'gzip'}:{})}});
    }
    const body=`<rss><channel><title>Fixture show</title>${items.join('')}${tail||'</channel></rss>'}`;
    return new Response(body,{headers:{etag,'content-type':'application/rss+xml'}});
  },
}]}));
let stop;
try{
  await mf.ready;
  await mf.dispatchFetch('https://runtime.example.com/health');
  stop=await sampleRuntimeMemory(await mf.getInspectorURL(),'notifications-observation-runtime',30000);
  const db=await mf.getD1Database('APP_ATTEST_DB');await migrate(db,new URL('../migrations/',import.meta.url));
  const run=(sql,...args)=>db.prepare(sql).bind(...args).run();
  const first=(sql,...args)=>db.prepare(sql).bind(...args).first();
  await run(`INSERT INTO devices(install_id,key_id,device_token,device_token_hash,apns_environment,bundle_id,notifications_enabled,created_at,last_seen_at) VALUES('local','local',?,'hash','development','com.example.opencast',1,?,?)`,'a'.repeat(64),now-1000,now);
  await run(`INSERT INTO n_feed_catalog(feed_url,source_url,created_at,updated_at) VALUES(?,?,?,?)`,url,url,now,now);
  await run(`INSERT INTO n_feed(feed_id,canonical_url,epoch,due_at) VALUES(?,?,1,?)`,feed,url,now);
  await run(`INSERT INTO feed_subscriptions(install_id,feed_url,notifications_enabled,created_at,updated_at) VALUES('local',?,1,?,?)`,url,now-1000,now);
  await run(`UPDATE n_control SET enabled=1 WHERE name IN('feed_observation','episode_activation','episode_send','cleanup')`);
  async function command(path){const response=await mf.dispatchFetch('https://runtime.example.com/observation/'+path,{method:'POST',body:JSON.stringify({feed_id:feed})});const text=await response.text();assert.equal(response.status,200,text);if(path==='scan'){
    for(let i=0;i<1000;i++){
      const pending=await first("SELECT 1 FROM n_observation o JOIN n_feed f ON f.feed_id=o.feed_id WHERE o.feed_id=? AND o.state='staging' AND o.valid_eof=1 AND o.lease_id=f.lease_id AND o.owner_epoch=f.epoch AND o.eligibility_generation=f.eligibility_generation AND o.expected_generation=f.observation_generation",feed);
      if(!pending)break;
      const result=JSON.parse(await command('prepare'));assert.equal(result.pending,true,'preparation must make durable progress');
      if(result.published)break;
      if(i===999)throw Error('preparation did not finish');
    }
  }return text;}
  async function drain(){for(let i=0;i<1000;i++){if(!(await first(`SELECT 1 FROM n_observation WHERE feed_id=? AND state='published' AND drain_complete=0 UNION ALL SELECT 1 FROM n_episode_release WHERE feed_id=? AND state='ready' LIMIT 1`,feed,feed)))break;await command('drain');if(i===999)throw Error('drain did not finish');}await command('drain');}
  const publicAttempt=await mf.dispatchFetch('https://runtime.example.com/scan',{method:'POST',headers:{'x-notification-capability':'feed_observations'},body:JSON.stringify({feed_id:feed})});
  assert.equal(publicAttempt.status,404);await publicAttempt.text();
  await run("UPDATE n_control SET enabled=0 WHERE name='feed_observation'");
  const disabled=await mf.dispatchFetch('https://runtime.example.com/observation/scan',{method:'POST',body:JSON.stringify({feed_id:feed})});
  assert.equal(disabled.status,409);await disabled.text();
  assert.equal((await first('SELECT COUNT(*) AS n FROM n_observation')).n,0);
  await run("UPDATE n_control SET enabled=1 WHERE name='feed_observation'");
  console.log('PASS private capability and disabled admission');
  items=[item('baseline')];await command('scan');
  assert.equal((await first('SELECT observation_generation FROM n_feed')).observation_generation,1);
  assert.equal((await first('SELECT COUNT(*) AS n FROM n_episode_release')).n,0);
  console.log('PASS quiet complete baseline');
  etag='"v2"';items=[item('baseline'),...Array.from({length:5},(_,i)=>item('new-'+i))];await command('scan');await drain();
  assert.equal((await first('SELECT COUNT(*) AS n FROM n_episode_release')).n,5);
  assert.equal((await first('SELECT COUNT(*) AS n FROM n_outbox')).n,5);
  console.log('PASS pinned top retains all five releases');
  await command('outbox');
  assert.equal((await first('SELECT COUNT(*) AS n FROM n_event')).n,5);
  console.log('PASS source outbox accepted');
  // A private invocation is used only by this harness; queue paths are exercised
  // by the delivery runtime harness against the same production adapter.
  const queue=async(lane,id,generation=1)=>{const response=await mf.dispatchFetch('https://runtime.example.com/queue',{method:'POST',body:JSON.stringify({queue:`opencast-notification-${lane}-development`,message:{schema_version:1,environment:'development',source:'feed_polling',id,generation}})});assert.equal(response.status,200,await response.text());};
  const event=(await first('SELECT event_id FROM n_event')).event_id;
  await queue('event',event);await queue('event',event);await queue('event',event);
  assert.equal((await first('SELECT COUNT(*) AS n FROM n_delivery')).n,1);
  assert.equal((await first('SELECT COUNT(*) AS n FROM n_delivery_member')).n,5);
  assert.equal((await first('SELECT COUNT(*) AS n FROM n_group_member')).n,5);
  const delivery=await first('SELECT * FROM n_delivery');
  await queue('episode',delivery.delivery_id,delivery.interest_generation);
  await queue('episode',delivery.delivery_id,delivery.interest_generation);
  assert.equal(sends.length,1);assert.equal(sends[0].opencast.episode_count,5);
  assert.equal(sends[0].aps.category,'OPENCAST_EPISODE');
  console.log('PASS immutable five-member presentation and replay');
  // Reordering, a missing anchor and return after removal are exact-history hits.
  etag='"v3"';items=items.slice(1).reverse();await command('scan');await drain();
  etag='"v4"';items.push(item('baseline'));await command('scan');await drain();
  assert.equal((await first('SELECT COUNT(*) AS n FROM n_episode_release')).n,5);
  console.log('PASS reordering, missing anchor, and historical return');
  const before304=await first('SELECT observation_generation,snapshot_key FROM n_feed');
  await command('scan');
  assert.deepEqual(await first('SELECT observation_generation,snapshot_key FROM n_feed'),before304);
  const traces304=await(await mf.dispatchFetch('https://runtime.example.com/traces')).json();
  assert.equal(traces304.at(-1).get,0,'304 must not load R2 history');
  console.log('PASS matched 304 does not load history or advance generation');
  // The same visible episode under a changed GUID remains suppressed.
  etag='"v5"';items=[item('baseline').replace('<guid>baseline</guid>','<guid>alias</guid>')];
  await command('scan');await drain();
  assert.equal((await first('SELECT COUNT(*) AS n FROM n_episode_release')).n,5);
  console.log('PASS normalized visible fingerprint blocks GUID churn');
  etag='"v6"';items=[item('undated',null),item('backfill',now-73*3600),item('future',now+3600),item('withdraw',now+3600),item('anomaly',now+8*86400),item('skew',now+600)];
  await command('scan');await drain();
  assert.equal((await first("SELECT COUNT(*) AS n FROM n_episode_release WHERE state='pending_future'")).n,2);
  assert.equal((await first("SELECT COUNT(*) AS n FROM n_episode_release WHERE reason='anomalous_date'")).n,1);
  assert.equal((await first("SELECT COUNT(*) AS n FROM n_episode_release WHERE reason='undated'")).n,1);
  const retainedFuture=await first("SELECT * FROM n_episode_release WHERE reason='future' ORDER BY episode_id LIMIT 1");
  etag='"v7"';items=[item('undated',null),item('future',now+3600)];await command('scan');await drain();
  assert.equal((await first("SELECT COUNT(*) AS n FROM n_episode_release WHERE state='withdrawn'")).n,1);
  console.log('PASS undated, stale, skew, anomaly and future withdrawal');
  await mf.dispatchFetch('https://runtime.example.com/clock',{method:'POST',body:'3601'});
  const fetches=requests;await command('drain');
  assert.equal(requests,fetches,'future maturation must not fetch RSS');
  assert.equal((await first("SELECT COUNT(*) AS n FROM n_episode_release WHERE reason='future' AND state='outboxed'")).n,1);
  const futureRow=await first("SELECT * FROM n_episode_release WHERE reason='future' AND state='outboxed'");
  assert.equal(futureRow.eligible_at,now+3600);assert.equal(futureRow.expires_at,now+3600+86400);
  console.log('PASS fixed future release time and no-refetch maturity');
  const beforeMalformed=await first('SELECT observation_generation,snapshot_key,etag FROM n_feed');
  etag='"bad"';items=[item('partial',null)];tail='<item><title>invalid';
  const bad=await mf.dispatchFetch('https://runtime.example.com/observation/scan',{method:'POST',body:JSON.stringify({feed_id:feed})});assert.equal(bad.status,500);await bad.text();
  assert.deepEqual(await first('SELECT observation_generation,snapshot_key,etag FROM n_feed'),beforeMalformed);
  const partialStart=(await first("SELECT MIN(scan_started_at) AS t FROM n_observation WHERE state='staging' AND recovery_evidence=1")).t;
  await mf.dispatchFetch('https://runtime.example.com/clock',{method:'POST',body:'3900'});
  tail='';etag='"repaired"';await command('scan');await drain();
  const partial=await first("SELECT * FROM n_episode_release WHERE reason='undated' AND first_observed_at=?",partialStart);
  assert.ok(partial);assert.equal(partial.expires_at,partialStart+86400);
  console.log('PASS malformed tail publishes nothing; retry preserves conservative first observation');
  async function newFeed(name,baseline=true){
    url=`https://fixture.example.com/${name}.xml`;feed=hash(['feed-v1',url]);
    await run(`INSERT INTO n_feed_catalog(feed_url,source_url,created_at,updated_at) VALUES(?,?,?,?)`,url,url,now,now);
    await run(`INSERT INTO n_feed(feed_id,canonical_url,epoch,due_at) VALUES(?,?,1,?)`,feed,url,now);
    await run(`INSERT INTO feed_subscriptions(install_id,feed_url,notifications_enabled,created_at,updated_at) VALUES('local',?,1,?,?)`,url,now-1000,now);
    etag=`"${name}-baseline"`;items=[item('baseline')];tail='';if(baseline)await command('scan');
  }
  let clock=3900;
  for(const point of ['before_put','after_put','before_head','after_head','before_checkpoint','after_checkpoint','manifest_reserve','before_publish','publish_rollback','stale_eligibility','stale_owner','lost_lease']){
    await newFeed(point);
    const before=await first('SELECT observation_generation,snapshot_key,etag FROM n_feed WHERE feed_id=?',feed);
    etag=`"${point}-new"`;items=[item('fresh',null)];
    await mf.dispatchFetch('https://runtime.example.com/fault',{method:'POST',body:point});
    try{await command('scan');}catch(error){assert.match(String(error),/500|preparation/);}
    assert.deepEqual(await first('SELECT observation_generation,snapshot_key,etag FROM n_feed WHERE feed_id=?',feed),before,point);
    assert.equal((await first('SELECT COUNT(*) AS n FROM n_episode_release WHERE feed_id=?',feed)).n,0,point);
    clock+=400;await mf.dispatchFetch('https://runtime.example.com/clock',{method:'POST',body:String(clock)});
    const pending=await first("SELECT 1 FROM n_observation o JOIN n_feed f ON f.feed_id=o.feed_id WHERE o.feed_id=? AND o.valid_eof=1 AND o.state='staging' AND o.owner_epoch=f.epoch AND o.lease_id=f.lease_id AND o.eligibility_generation=f.eligibility_generation",feed);
    if(pending){for(let i=0;i<20;i++){const r=JSON.parse(await command('prepare'));if(r.published)break;assert.ok(r.pending);}}else{await command('scan');}
    await drain();assert.equal((await first('SELECT observation_generation FROM n_feed WHERE feed_id=?',feed)).observation_generation,2);
    console.log('PASS fault recovery',point);
  }
  await newFeed('overlap');etag='"overlap-new"';items.push(item('overlap-new',null));
  let entered,releaseFetch;
  const started=new Promise(resolve=>entered=resolve);
  fetchHook=async()=>{entered();await new Promise(resolve=>releaseFetch=resolve);};
  const firstScan=command('scan');await started;
  const concurrent=await mf.dispatchFetch('https://runtime.example.com/observation/scan',{method:'POST',body:JSON.stringify({feed_id:feed})});
  assert.equal(concurrent.status,429);await concurrent.text();releaseFetch();await firstScan;
  const beforeDrain=await mf.dispatchFetch('https://runtime.example.com/observation/scan',{method:'POST',body:JSON.stringify({feed_id:feed})});
  assert.equal(beforeDrain.status,409,'unfinished publication must drain before a later scan can withdraw its future candidates');await beforeDrain.text();await drain();
  assert.equal((await first('SELECT COUNT(*) AS n FROM n_episode_release WHERE feed_id=?',feed)).n,1);
  loseReceipt=true;await command('outbox');
  const saved=await first("SELECT x.* FROM n_outbox x JOIN n_observation o ON o.observation_id=x.observation_id WHERE o.feed_id=?",feed);
  assert.equal(saved.state,'pending');
  clock+=61;await mf.dispatchFetch('https://runtime.example.com/clock',{method:'POST',body:String(clock)});await command('outbox');
  const retried=await first("SELECT x.* FROM n_outbox x JOIN n_observation o ON o.observation_id=x.observation_id WHERE o.feed_id=?",feed);
  assert.equal(retried.state,'accepted');assert.equal(retried.payload_json,saved.payload_json);assert.equal(retried.expires_at,saved.expires_at);
  assert.equal((await first('SELECT COUNT(*) AS n FROM n_event WHERE event_id=?',saved.event_id)).n,1);
  console.log('PASS overlapping scans and lost source receipt retry without renewed expiry');
  await newFeed('stale-validator');
  const beforeStale=await first('SELECT observation_generation,last_success_at FROM n_feed WHERE feed_id=?',feed);
  fetchHook=async()=>{await run('UPDATE n_feed SET etag=? WHERE feed_id=?','"replacement"',feed);};
  assert.equal(JSON.parse(await command('scan')).published,false);
  assert.deepEqual(await first('SELECT observation_generation,last_success_at FROM n_feed WHERE feed_id=?',feed),beforeStale);
  await newFeed('unsolicited-304',false);fetchHook=async()=>new Response(null,{status:304});
  const unsolicited=await mf.dispatchFetch('https://runtime.example.com/observation/scan',{method:'POST',body:JSON.stringify({feed_id:feed})});
  assert.equal(unsolicited.status,500);await unsolicited.text();
  assert.equal((await first('SELECT snapshot_key FROM n_feed WHERE feed_id=?',feed)).snapshot_key,null);
  console.log('PASS stale and unsolicited 304 cannot advance authority');
  await newFeed('metadata-only');etag='"edited"';items=[item('baseline').replace('Summary baseline','Edited description')];await command('scan');await drain();
  const reasons=await first("SELECT reason_counts_json FROM n_observation WHERE feed_id=? AND generation=2 AND state='published'",feed);
  assert.equal(JSON.parse(reasons.reason_counts_json).metadata_only,1);
  assert.equal((await first('SELECT COUNT(*) AS n FROM n_episode_release WHERE feed_id=?',feed)).n,0);
  console.log('PASS metadata edits record their disposition without creating releases');
  // Late subscriptions require a dated release after activation or a prior
  // complete absence observation. Publication itself is not that evidence.
  async function subscribe(install,at){
    await run(`INSERT INTO devices(install_id,key_id,device_token,device_token_hash,apns_environment,bundle_id,notifications_enabled,created_at,last_seen_at) VALUES(?,?,?,?,'development','com.example.opencast',1,?,?)`,install,install,'b'.repeat(64),install,at,at);
    await run(`INSERT INTO feed_subscriptions(install_id,feed_url,notifications_enabled,created_at,updated_at) VALUES(?,?,1,?,?)`,install,url,at,at);
  }
  await newFeed('recipient-timing');await subscribe('late',now+clock-30);
  etag='"recipient-new"';items=[item('older-than-interest',now+clock-60),item('undated-first',null)];
  await command('scan');await drain();await command('outbox');
  let routed=(await first('SELECT event_id FROM n_episode_release WHERE feed_id=?',feed)).event_id;
  for(let i=0;i<4;i++)await queue('event',routed);
  assert.equal((await first("SELECT COUNT(*) AS n FROM n_delivery WHERE interest_key=? AND install_id='late'",feed)).n,0);
  assert.equal((await first("SELECT COUNT(*) AS n FROM n_delivery WHERE interest_key=? AND install_id='local'",feed)).n,2);
  etag='"recipient-next"';items.push(item('undated-next',null));await command('scan');await drain();await command('outbox');
  routed=(await first('SELECT event_id FROM n_episode_release WHERE feed_id=? AND generation=3',feed)).event_id;
  for(let i=0;i<4;i++)await queue('event',routed);
  assert.equal((await first("SELECT COUNT(*) AS n FROM n_delivery WHERE interest_key=? AND install_id='late'",feed)).n,1);
  await run("UPDATE feed_subscriptions SET notifications_enabled=0,updated_at=? WHERE install_id='late' AND feed_url=?",now+clock,url);
  const revoked=await first("SELECT delivery_id,interest_generation FROM n_delivery WHERE interest_key=? AND install_id='late'",feed);
  const sendsBefore=sends.length;await queue('episode',revoked.delivery_id,revoked.interest_generation);assert.equal(sends.length,sendsBefore);
  console.log('PASS subscriber date/absence cutoffs and opt-out before delivery');
  await newFeed('absence-304');await subscribe('matched-304',now+clock-10);await command('scan');
  etag='"after-304"';items.push(item('post-304-undated',null));await command('scan');await drain();await command('outbox');
  routed=(await first('SELECT event_id FROM n_episode_release WHERE feed_id=?',feed)).event_id;
  for(let i=0;i<4;i++)await queue('event',routed);
  assert.equal((await first("SELECT COUNT(*) AS n FROM n_delivery WHERE interest_key=? AND install_id='matched-304'",feed)).n,1);
  console.log('PASS matched 304 supplies per-interest prior absence');
  const review=await reviewRegressions({mf,now,item,hash,newFeed,command,drain,run,first,queue,subscribe,
    feed:()=>feed, clock:()=>clock,
    setClock:async value=>{clock=value;await mf.dispatchFetch('https://runtime.example.com/clock',{method:'POST',body:String(clock)});},
    content:(name,entries,ending='')=>{etag=JSON.stringify(name);items=entries;tail=ending;},
  });
  const ordinaryMemory=await stop.snapshot();
  assert.ok(ordinaryMemory.peakCombined.totalBytes<96*1024*1024,'96-MiB ordinary working target');
  if(process.env.OPENCAST_OBSERVATION_SCALE==='1'){
    await newFeed('maximum',false);large={count:100000,bytes:128*1024*1024,gzip:false};
    const start=performance.now();await command('scan');large=undefined;
    const pointer=await first('SELECT snapshot_key FROM n_feed WHERE feed_id=?',feed);
    const bucket=await mf.getR2Bucket('FEED_SNAPSHOTS');
    const manifest=await(await bucket.get(pointer.snapshot_key)).json();
    assert.equal(manifest.pages.filter(p=>p.index==='identity').reduce((n,p)=>n+p.count,0),100000);
    assert.equal((await first('SELECT COUNT(*) AS n FROM n_episode_release WHERE feed_id=?',feed)).n,0);
    console.log('PASS maximum 128-MiB, 100000-item quiet baseline',Math.round(performance.now()-start),'ms');
    etag='"overflow"';items=[item('maximum-99999'),...Array.from({length:2001},(_,i)=>item(`overflow-${i}`,null))];
    await command('scan');await drain();
    const newer=await first('SELECT snapshot_key FROM n_feed WHERE feed_id=?',feed);
    const grown=await(await bucket.get(newer.snapshot_key)).json();
    assert.equal(grown.pages.filter(p=>p.index==='identity').reduce((n,p)=>n+p.count,0),102001);
    assert.equal(grown.candidate_count,2001);
    assert.equal((await first('SELECT COUNT(*) AS n FROM n_episode_release WHERE feed_id=?',feed)).n,2001);
    assert.equal((await first("SELECT COUNT(*) AS n FROM n_outbox x JOIN n_observation o ON o.observation_id=x.observation_id WHERE o.feed_id=?",feed)).n,2001);
    assert.equal((await first("SELECT COUNT(*) AS n FROM sqlite_master WHERE name='n_candidate'")).n,0);
    let previous;
    for(const page of grown.candidate_pages){
      assert.ok(page.count<=100&&page.bytes<=65536);
      const candidates=await(await bucket.get(page.key)).json();
      for(const c of candidates){const order=`${c.eligible_at}:${c.episode_id}`;if(previous)assert.ok(previous<order);previous=order;}
    }
    console.log('PASS exact historical growth and all 2001 overflow releases, sorted across resumable pages');
    for(let i=0;i<201;i++)await command('outbox');
    const overflowEvent=(await first('SELECT event_id FROM n_episode_release WHERE feed_id=?',feed)).event_id;
    for(let i=0;i<3;i++)await queue('event',overflowEvent);
    assert.equal((await first('SELECT COUNT(*) AS n FROM n_delivery WHERE interest_key=?',feed)).n,1);
    assert.equal((await first('SELECT member_count FROM n_delivery WHERE interest_key=?',feed)).member_count,2001);
    console.log('PASS 2001-member immutable recipient presentation');
    await newFeed('compressed-maximum',false);large={count:100000,bytes:128*1024*1024,gzip:true};await command('scan');large=undefined;
    assert.equal((await first('SELECT observation_generation FROM n_feed WHERE feed_id=?',feed)).observation_generation,1);
    console.log('PASS compressed maximum-size baseline');
    // A new validator over the same membership is a schedule update, even at
    // the maximum size: no generation, observation, snapshot row or object.
    const durable=async()=>({...(await first('SELECT observation_generation,snapshot_key FROM n_feed WHERE feed_id=?',feed)),observations:(await first('SELECT COUNT(*) AS n FROM n_observation WHERE feed_id=?',feed)).n,snapshots:(await first('SELECT COUNT(*) AS n FROM n_snapshot WHERE feed_id=?',feed)).n,scratch:(await (await mf.getR2Bucket('FEED_SNAPSHOTS')).list({prefix:'scratch/'})).objects.length});
    const quiet=await durable();
    etag='"compressed-rescan"';large={count:100000,bytes:128*1024*1024,gzip:true};await command('scan');large=undefined;
    assert.deepEqual(await durable(),quiet);assert.equal(quiet.observation_generation,1);
    assert.equal((await first('SELECT etag FROM n_feed WHERE feed_id=?',feed)).etag,'"compressed-rescan"','the unchanged body refreshed its validator');
    console.log('PASS unchanged maximum-size rescan is a schedule update: no generation, row or object');
    etag='"compressed-edited"';large={count:100000,bytes:128*1024*1024,gzip:true,edited:true};await command('scan');large=undefined;
    assert.equal((await first('SELECT observation_generation FROM n_feed WHERE feed_id=?',feed)).observation_generation,2);
    assert.equal((await first('SELECT COUNT(*) AS n FROM n_episode_release WHERE feed_id=?',feed)).n,0);
    assert.equal((await durable()).scratch,0);
    console.log('PASS full maximum-size changed rescan prepares bounded exact history without false releases');
  }
  // Retired manifests and uploads can be reclaimed; live snapshots and an
  // unfinished published candidate drain remain roots regardless of age.
  await newFeed('gc-roots');
  const baselineKey=(await first('SELECT snapshot_key FROM n_feed WHERE feed_id=?',feed)).snapshot_key;
  etag='"gc-candidates"';items=[item('gc-new',null)];await command('scan');
  const pendingKey=(await first('SELECT snapshot_key FROM n_feed WHERE feed_id=?',feed)).snapshot_key;
  await run('UPDATE n_feed SET snapshot_key=? WHERE feed_id=?',baselineKey,feed);
  clock+=8*86400;await mf.dispatchFetch('https://runtime.example.com/clock',{method:'POST',body:String(clock)});
  await mf.dispatchFetch('https://runtime.example.com/fault',{method:'POST',body:'before_delete'});await command('gc');
  assert.ok((await first("SELECT COUNT(*) AS n FROM n_snapshot WHERE state='gc_claimed'")).n>=1);
  for(let i=0;i<20;i++)await command('gc');
  const bucket=await mf.getR2Bucket('FEED_SNAPSHOTS');
  for(const key of [baselineKey,pendingKey]){
    const object=await bucket.get(key);assert.ok(object,'referenced manifest survives GC');
    const manifest=await object.json();for(const page of [...manifest.pages,...manifest.candidate_pages])assert.ok(await bucket.head(page.key),'referenced page survives GC');
  }
  await run('UPDATE n_feed SET snapshot_key=? WHERE feed_id=?',pendingKey,feed);
  console.log('PASS orphan delete retry and live history/incomplete-drain GC roots');
  await run('UPDATE feed_subscriptions SET notifications_enabled=0,updated_at=? WHERE feed_url=?',now+clock,url);
  clock+=30*86400+1;await mf.dispatchFetch('https://runtime.example.com/clock',{method:'POST',body:String(clock)});await command('gc');
  assert.equal((await first('SELECT snapshot_key FROM n_feed WHERE feed_id=?',feed)).snapshot_key,null);
  await run('UPDATE feed_subscriptions SET notifications_enabled=1,updated_at=? WHERE feed_url=?',now+clock,url);
  etag='"reactivation"';await command('scan');
  assert.equal((await first('SELECT observation_generation FROM n_feed WHERE feed_id=?',feed)).observation_generation,1);
  assert.equal((await first('SELECT COUNT(*) AS n FROM n_episode_release WHERE feed_id=?',feed)).n,0);
  console.log('PASS no-interest history expiry and quiet reactivation');
  const traces=await(await mf.dispatchFetch('https://runtime.example.com/traces')).json();
  const wasm=JSON.parse(await command('stats')).wasm_memory_bytes;
  const memory=await stop();stop=undefined;
  const report={requests,sends:sends.length,review,ordinaryMemory,maxD1:Math.max(...traces.map(t=>t.d1)),maxR2:Math.max(...traces.map(t=>t.get+t.put+t.head+t.delete)),wasm,memory,conservativeMemoryBytes:memory.totalBytes+wasm,traces};
  await writeFile(process.env.OPENCAST_OBSERVATION_REPORT??join(tmpdir(),'opencast-feed-observation-runtime.json'),JSON.stringify(report,null,2));
  console.log('metrics',JSON.stringify({...report,traces:undefined}));
  assert.ok(report.maxD1<=1000);assert.ok(report.maxR2<10000);
  assert.ok(memory.transportAudit.wasmBytes===wasm,'sampler must observe actual final Wasm growth');
  const memoryLimitMiB=process.env.OPENCAST_OBSERVATION_SCALE==='1'?128:96;
  assert.ok(memory.peakCombined.totalBytes<memoryLimitMiB*1024*1024,'working target / maximum-feed platform limit');
}finally{if(stop)await stop();await mf.dispose();}
