// The shipped collector on the current schema, seeded directly through
// storage.database():
//  - preserved delivery history is untouched by its feed's first enrolment and
//    by a feed enrolled later under the history's URL (the n_feed insert
//    trigger reads none of it since migration 0006);
//  - a page shared by a rooted manifest and an unrooted one survives three
//    collector runs, while the unrooted manifest and its only page are
//    reclaimed (R2 object and n_snapshot row), and the history, events,
//    observations and feed roots are untouched;
//  - PruneFeeds (B06), through the storage-fixture build's slice E route,
//    returns one D1 change count per statement, its interest deletions then its
//    feed deletions (n_burst rows the feed key cascades included): zero on an
//    empty schema, and the derived counts on a seeded one.
// The schema's foreign keys are installed and enforced at statement time, so
// a dangling reference fails the statement that makes it.
// PruneFeeds needs the storage-fixture build at OPENCAST_FIXTURE_BUILD (default
// /tmp/opencast-storage-fixture-build): in Server/NotificationsWorker,
// worker-build --release --out-dir <dir> --no-default-features --features storage-fixture
import assert from 'node:assert/strict';
import {randomBytes} from 'node:crypto';
import {existsSync,readFileSync} from 'node:fs';
import {fileURLToPath} from 'node:url';
import {Miniflare,convertV4MiniflareOptions} from 'miniflare';
import {compatibilityDate,compatibilityFlags} from './runtime-compatibility.mjs';
import {openStorage} from './storage.mjs';
const root=fileURLToPath(new URL('../',import.meta.url));
const now=Math.floor(Date.now()/1000);
const FIXTURE_BUILD=process.env.OPENCAST_FIXTURE_BUILD??'/tmp/opencast-storage-fixture-build';
for(const file of [FIXTURE_BUILD+'/index.js',FIXTURE_BUILD+'/index_bg.wasm'])
 if(!existsSync(file)){console.log(`not ok missing ${file}`);process.exit(1);}
const storage=await openStorage();
const mf=new Miniflare(convertV4MiniflareOptions({cf:false,inspectorPort:0,workers:[storage.bind({
 name:'storage-gc',modulesRoot:root,
 modules:[...['tests/observation-entry.mjs','adapter/index.js','build/index.js'].map(path=>({type:'ESModule',path:root+path})),{type:'CompiledWasm',path:root+'build/index_bg.wasm'}],
 compatibilityDate,compatibilityFlags,r2Buckets:{FEED_SNAPSHOTS:'storage-gc'},
 bindings:{NOTIFICATION_ENVIRONMENT:'development',NOTIFICATION_CLEANUP:'true',NOTIFICATION_FEED_OBSERVATION:'true'},
})]}));
try {
 await mf.ready;
 const db=await storage.database(mf),bucket=await mf.getR2Bucket('FEED_SNAPSHOTS');
 const statement=(query,...args)=>db.prepare(query).bind(...args);
 const run=(query,...args)=>statement(query,...args).run();
 const rows=async(query,...args)=>(await statement(query,...args).all()).results;
 // Accepted, uncertain (no APNs answer) and failed sends of one feed URL.
 for(const [id,install,status,error,fingerprint] of [['accepted','real',200,null,'fp'],['uncertain','real',null,null,null],['failed','other',400,'BadDeviceToken','other-fp']])
  await run('INSERT INTO n_delivery_history(send_id,install_id,device_token_hash,feed_url,episode_id,apns_environment,apns_status,apns_id,apns_error,created_at,updated_at,episode_fingerprint) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)',id,install,'hash','https://fixture.example/history.xml',id,'production',status,'apns-'+id,error,now-100,now-50,fingerprint);
 const history=()=>rows('SELECT * FROM n_delivery_history ORDER BY send_id');
 const seeded=await history();
 assert.equal(seeded.length,3);
 const enroll=id=>run('INSERT INTO n_feed(feed_id,canonical_url,epoch,due_at) VALUES(?,?,1,?)',id,'https://fixture.example/history.xml',now);
 await enroll('feed');
 assert.deepEqual(await history(),seeded);
 const activeUntil=now+86400;
 await run("INSERT INTO n_install(install_id,epoch,enabled) VALUES('real',1,1)");
 await run("INSERT INTO n_interest(install_id,feed_id,generation,activated_at,enabled) VALUES('real','feed',1,?,1)",now);
 // current (the feed's root) and shadow (rooted by nothing) both reference
 // shared; obsolete is shadow's only other page. Every object is past gc_after.
 for(const [key,lease,pages] of [['current','current-lease',1],['shared','old-lease',0],['shadow','old-lease',1],['obsolete','old-lease',0]]){
  await run("INSERT INTO n_snapshot(object_key,feed_id,owner_epoch,lease_id,sha256,bytes,state,created_at,gc_after,expected_pages) VALUES(?,'feed',1,?,'hash',1,'referenced',?,?,?)",key,lease,now-86400,now-1,pages);
  await bucket.put(key,key);
 }
 await run("INSERT INTO n_snapshot_ref VALUES('current','shared'),('shadow','shared'),('shadow','obsolete')");
 await run("UPDATE n_feed SET snapshot_key='current',observation_generation=1 WHERE feed_id='feed'");
 await run("INSERT INTO n_observation(observation_id,feed_id,generation,owner_epoch,lease_id,expected_generation,snapshot_key,scan_started_at,candidate_count,state,valid_eof,drain_complete) VALUES('observation','feed',1,1,'current-lease',0,'current',?,0,'published',1,1)",now-60);
 await run("INSERT INTO n_event(source,event_id,schema_version,kind,payload_digest,occurred_at,eligible_at,expires_at,receipt_id,feed_id,fanout_complete) VALUES('feed_polling','event',1,'episode','digest',?,?,?,'receipt','feed',1)",now-60,now-60,activeUntil);
 // A feed enrolled later under the history's URL, once the first feed has
 // moved off it, leaves the history as seeded too.
 await run("UPDATE n_feed SET canonical_url='https://fixture.example/current.xml' WHERE feed_id='feed'");
 await enroll('reenrolled');
 assert.deepEqual(await history(),seeded);
 // Every read carries its own order: PostgreSQL's heap order moves when the
 // collector updates a row.
 const preserved=async()=>({
  history:await history(),
  events:await rows('SELECT * FROM n_event ORDER BY source,event_id'),observations:await rows('SELECT * FROM n_observation ORDER BY observation_id'),
  roots:await rows('SELECT feed_id,snapshot_key,observation_generation FROM n_feed ORDER BY feed_id'),
 });
 const before=await preserved();
 await run("UPDATE n_control SET enabled=1 WHERE name IN('cleanup','feed_observation')");
 for(let i=0;i<3;i++){
  const response=await mf.dispatchFetch('https://fixture.invalid/observation/gc',{method:'POST',body:JSON.stringify({feed_id:'f'.repeat(64)})});
  assert.equal(response.status,200,await response.text());
 }
 for(const key of ['current','shared'])assert.ok(await bucket.head(key),key);
 for(const key of ['shadow','obsolete'])assert.equal(await bucket.head(key),null,key);
 assert.deepEqual(await rows('SELECT object_key FROM n_snapshot ORDER BY object_key'),[{object_key:'current'},{object_key:'shared'}]);
 assert.deepEqual(await preserved(),before);
 assert.deepEqual(await history(),seeded);
 console.log(`PASS current-schema history preservation and shared-page GC on ${storage.mode}: history untouched by first and later enrolment, a shared page survives while an unrooted manifest and its page are reclaimed, history, events, observations and roots preserved, foreign keys enforced`);
} finally {try{await mf.dispose();}finally{await storage.dispose();}}

// PruneFeeds on its own clone, through the storage-fixture build's slice E route.
{
 const prune=await openStorage(),TOKEN=randomBytes(16).toString('hex');
 const ENTRY=readFileSync(new URL('./postgres/fixture-entry.mjs',import.meta.url));
 const fixture=new Miniflare(convertV4MiniflareOptions({cf:false,inspectorPort:0,workers:[prune.bind({name:'prune-feeds',modulesRoot:FIXTURE_BUILD,
  modules:[{type:'ESModule',path:FIXTURE_BUILD+'/fixture-entry.mjs',contents:ENTRY},{type:'ESModule',path:FIXTURE_BUILD+'/index.js'},{type:'CompiledWasm',path:FIXTURE_BUILD+'/index_bg.wasm'}],
  compatibilityDate,compatibilityFlags,bindings:{SLICE_TOKEN:TOKEN}})]}));
 try {
  await fixture.ready;
  const db=await prune.database(fixture);
  const run=(query,...args)=>db.prepare(query).bind(...args).run();
  const rows=async(query,...args)=>(await db.prepare(query).bind(...args).all()).results;
  const DAY=86400,before=now-30*DAY;
  const pruneFeeds=async()=>{
   const worker=await fixture.getWorker('prune-feeds');
   const response=await worker.fetch('https://fixture.invalid/slice-e/operation',{method:'POST',headers:{authorization:`Bearer ${TOKEN}`},body:JSON.stringify({request:{operation:'prune_feeds',before}})});
   const body=await response.json();
   assert.equal(body.ok,true,JSON.stringify(body));
   return body.response.replies;
  };
  // Empty: one count row per statement, both zero, no rows exposed.
  assert.deepEqual(await pruneFeeds(),[{rows:[],count:0},{rows:[],count:0}]);
  // gone-1 (two disabled interests, two bursts) and gone-2 (nothing) qualify;
  // kept-enabled has an enabled interest, kept-recent lost its interest after
  // the bound, kept-event still holds an event.
  for(const feed of ['gone-1','gone-2','kept-enabled','kept-recent','kept-event'])
   await run('INSERT INTO n_feed(feed_id,canonical_url,epoch,due_at) VALUES(?,?,1,?)',feed,`https://fixture.example/${feed}.xml`,now);
  for(const install of ['prune-a','prune-b'])await run('INSERT INTO n_install(install_id,epoch,enabled) VALUES(?,1,1)',install);
  for(const install of ['prune-a','prune-b'])await run("INSERT INTO n_interest(install_id,feed_id,generation,activated_at,enabled) VALUES(?,'gone-1',1,?,0)",install,now-40*DAY);
  await run("INSERT INTO n_interest(install_id,feed_id,generation,activated_at,enabled) VALUES('prune-a','kept-enabled',1,?,1)",now-40*DAY);
  for(const [feed,since] of [['gone-1',now-40*DAY],['gone-2',now-35*DAY],['kept-enabled',now-40*DAY],['kept-recent',now-10*DAY],['kept-event',now-40*DAY]])
   await run('UPDATE n_feed SET no_interest_since=? WHERE feed_id=?',since,feed);
  for(const [key,feed] of [['burst-1','gone-1'],['burst-2','gone-1'],['burst-3','kept-recent']])
   await run('INSERT INTO n_burst(presentation_key,feed_id,owner_epoch) VALUES(?,?,1)',key,feed);
  await run("INSERT INTO n_event(source,event_id,schema_version,kind,payload_digest,occurred_at,eligible_at,expires_at,receipt_id,feed_id,fanout_complete) VALUES('feed_polling','prune-event',1,'episode','digest',?,?,?,'receipt','kept-event',1)",now-60,now-60,now+DAY);
  // Interests: per deleted row 1, plus 1 for its feed, plus 1 for that feed
  // with no enabled interest left (the n_interest_removed trigger's two
  // updates): 2 x 3. Feeds: per deleted feed 1 plus its cascaded bursts:
  // gone-1 3, gone-2 1.
  assert.deepEqual(await pruneFeeds(),[{rows:[],count:6},{rows:[],count:4}]);
  assert.deepEqual((await rows('SELECT feed_id FROM n_feed ORDER BY feed_id')).map(r=>r.feed_id),['kept-enabled','kept-event','kept-recent']);
  assert.deepEqual((await rows('SELECT presentation_key FROM n_burst ORDER BY presentation_key')).map(r=>r.presentation_key),['burst-3']);
  assert.deepEqual(await rows('SELECT install_id,feed_id FROM n_interest ORDER BY install_id,feed_id'),[{install_id:'prune-a',feed_id:'kept-enabled'}]);
  // A second run finds nothing left to prune.
  assert.deepEqual(await pruneFeeds(),[{rows:[],count:0},{rows:[],count:0}]);
  console.log(`PASS PruneFeeds on ${prune.mode}: two count replies, zero on an empty schema, 6 interest and 4 feed changes (bursts cascaded) on a seeded one, the ineligible feeds kept, then zero`);
 } finally {try{await fixture.dispose();}finally{await prune.dispose();}}
}
