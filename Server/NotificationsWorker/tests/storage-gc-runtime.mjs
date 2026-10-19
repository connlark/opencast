// The shipped collector and bridge hydration on the current schema, seeded
// directly through storage.database():
//  - preserved delivery history hydrates duplicate suppression (n_legacy_bridge)
//    when its feed first enrolls, and again for a feed enrolled later under
//    the history's URL;
//  - a page shared by a rooted manifest and an unrooted one survives three
//    collector runs, while the unrooted manifest and its only page are
//    reclaimed (R2 object and n_snapshot row), and the history, bridge,
//    events, observations and feed roots are untouched.
// The schema's foreign keys are installed and enforced at statement time, so
// a dangling reference fails the statement that makes it.
import assert from 'node:assert/strict';
import {fileURLToPath} from 'node:url';
import {Miniflare,convertV4MiniflareOptions} from 'miniflare';
import {compatibilityDate,compatibilityFlags} from './runtime-compatibility.mjs';
import {openStorage} from './storage.mjs';
const root=fileURLToPath(new URL('../',import.meta.url));
const now=Math.floor(Date.now()/1000);
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
 const one=(query,...args)=>statement(query,...args).first();
 // Accepted, uncertain (no APNs answer) and failed sends of one feed URL.
 for(const [id,install,status,error,fingerprint] of [['accepted','real',200,null,'fp'],['uncertain','real',null,null,null],['failed','other',400,'BadDeviceToken','other-fp']])
  await run('INSERT INTO n_delivery_history(send_id,install_id,device_token_hash,feed_url,episode_id,apns_environment,apns_status,apns_id,apns_error,created_at,updated_at,episode_fingerprint) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)',id,install,'hash','https://fixture.example/history.xml',id,'production',status,'apns-'+id,error,now-100,now-50,fingerprint);
 const enroll=id=>run('INSERT INTO n_feed(feed_id,canonical_url,epoch,due_at) VALUES(?,?,1,?)',id,'https://fixture.example/history.xml',now);
 await enroll('feed');
 // Three episode identities and two fingerprints.
 const bridge=await rows('SELECT * FROM n_legacy_bridge ORDER BY install_id,identity_key');
 assert.equal(bridge.length,5);
 assert.equal(bridge.find(r=>r.identity_key==='episode:accepted').disposition,'accepted');
 assert.equal(bridge.find(r=>r.identity_key==='episode:uncertain').disposition,'uncertain');
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
 // The insert trigger hydrates again for a feed enrolled later under the
 // history's URL, once the first feed has moved off it.
 await run("UPDATE n_feed SET canonical_url='https://fixture.example/current.xml' WHERE feed_id='feed'");
 await enroll('reenrolled');
 assert.equal((await one("SELECT COUNT(*) AS n FROM n_legacy_bridge WHERE feed_id='reenrolled'")).n,5);
 // Every read carries its own order: PostgreSQL's heap order moves when the
 // collector updates a row.
 const preserved=async()=>({
  history:await rows('SELECT * FROM n_delivery_history ORDER BY send_id'),
  bridge:await rows('SELECT * FROM n_legacy_bridge ORDER BY install_id,feed_id,identity_key'),
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
 console.log(`PASS current-schema bridge hydration and shared-page GC on ${storage.mode}: history hydrates suppression at first and later enrolment, a shared page survives while an unrooted manifest and its page are reclaimed, history, bridge, events, observations and roots preserved, foreign keys enforced`);
} finally {try{await mf.dispose();}finally{await storage.dispose();}}
