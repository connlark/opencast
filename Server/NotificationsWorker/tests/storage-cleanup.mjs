// Upgrade populated pre-cleanup storage, including the old-binary delete window.
import assert from 'node:assert/strict';
import {readFile,readdir} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import {Miniflare,convertV4MiniflareOptions} from 'miniflare';
import {unstable_splitSqlQuery} from 'wrangler';
import {compatibilityDate,compatibilityFlags} from './runtime-compatibility.mjs';
const root=fileURLToPath(new URL('../',import.meta.url));
const directory=new URL('../migrations/',import.meta.url);
const now=Math.floor(Date.now()/1000);
const mf=new Miniflare(convertV4MiniflareOptions({cf:false,inspectorPort:0,workers:[{
 name:'storage-cleanup',modulesRoot:root,
 modules:[...['tests/observation-entry.mjs','adapter/index.js','build/index.js'].map(path=>({type:'ESModule',path:root+path})),{type:'CompiledWasm',path:root+'build/index_bg.wasm'}],
 compatibilityDate,compatibilityFlags,d1Databases:{APP_ATTEST_DB:'cleanup'},r2Buckets:{FEED_SNAPSHOTS:'cleanup'},
 bindings:{NOTIFICATION_ENVIRONMENT:'development',NOTIFICATION_CLEANUP:'true',NOTIFICATION_FEED_OBSERVATION:'true'},
}]}));
try {
 await mf.ready;
 const db=await mf.getD1Database('APP_ATTEST_DB'),bucket=await mf.getR2Bucket('FEED_SNAPSHOTS');
 const statement=(query,...args)=>db.prepare(query).bind(...args);
 const run=(query,...args)=>statement(query,...args).run();
 const rows=async(query,...args)=>(await statement(query,...args).all()).results;
 const one=(query,...args)=>statement(query,...args).first();
 const apply=async file=>db.batch(unstable_splitSqlQuery(await readFile(new URL(file,directory),'utf8')).map(query=>db.prepare(query)));
 const files=(await readdir(directory)).filter(f=>f.endsWith('.sql')).sort();
 for(const file of files.filter(f=>f<'0022'))await apply(file);
 for(const [id,install,status,error,fingerprint] of [['accepted','real',200,null,'fp'],['uncertain','real',null,null,null],['failed','other',400,'BadDeviceToken','other-fp'],['erase','erased',200,null,null]]){
  await run('INSERT INTO episode_notification_sends(send_id,install_id,device_token_hash,feed_url,episode_id,apns_environment,apns_status,apns_id,apns_error,created_at,updated_at,episode_fingerprint) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)',id,install,'hash','https://fixture.example/history.xml',id,'production',status,'apns-'+id,error,now-100,now-50,fingerprint);
 }
 const history=await rows('SELECT * FROM episode_notification_sends ORDER BY send_id');
 await apply('0022_preserve_delivery_history.sql');
 assert.deepEqual(await rows('SELECT * FROM n_delivery_history ORDER BY send_id'),history);
 await run("DELETE FROM episode_notification_sends WHERE install_id='erased'");
 assert.deepEqual(await rows('SELECT * FROM n_delivery_history ORDER BY send_id'),history.filter(r=>r.install_id!=='erased'));
 // A pre-existing history entry still hydrates duplicate suppression when its
 // feed first enrolls, both before and after the old-name view disappears.
 const enroll=id=>run("INSERT INTO n_feed(feed_id,canonical_url,owner,epoch,due_at) VALUES(?,?,'queued',1,?)",id,'https://fixture.example/history.xml',now);
 await enroll('feed');
 const bridge=await rows('SELECT * FROM n_legacy_bridge ORDER BY install_id,identity_key');
 assert.equal(bridge.length,5);
 assert.equal(bridge.find(r=>r.identity_key==='episode:accepted').disposition,'accepted');
 assert.equal(bridge.find(r=>r.identity_key==='episode:uncertain').disposition,'uncertain');
 const activeUntil=now+86400;
 await run("INSERT INTO n_install(install_id,epoch,enabled) VALUES('real',1,1)");
 await run("INSERT INTO n_interest(install_id,feed_id,generation,activated_at,enabled) VALUES('real','feed',1,?,1)",now);
 for(const [key,lease,pages] of [['current','current-lease',1],['shared','old-lease',0],['shadow','old-lease',1],['obsolete','old-lease',0]]){
  await run("INSERT INTO n_snapshot(object_key,feed_id,owner_epoch,lease_id,sha256,bytes,state,created_at,gc_after,expected_pages) VALUES(?,'feed',1,?,'hash',1,'referenced',?,?,?)",key,lease,now-86400,now-1,pages);
  await bucket.put(key,key);
 }
 await run("INSERT INTO n_snapshot_ref VALUES('current','shared'),('shadow','shared'),('shadow','obsolete')");
 await run("UPDATE n_feed SET snapshot_key='current',observation_generation=1 WHERE feed_id='feed'");
 await run("INSERT INTO n_shadow_feed(feed_id,generation,snapshot_key) VALUES('feed',1,'shadow')");
 await run("INSERT INTO n_observation(observation_id,feed_id,generation,owner_epoch,lease_id,expected_generation,snapshot_key,scan_started_at,candidate_count,state,mode,valid_eof,drain_complete) VALUES('observation','feed',1,1,'current-lease',0,'current',?,0,'published','queued',1,1)",now-60);
 await run("INSERT INTO n_event(source,event_id,schema_version,kind,payload_digest,occurred_at,eligible_at,expires_at,receipt_id,feed_id,fanout_complete) VALUES('feed_polling','event',1,'episode','digest',?,?,?,'receipt','feed',1)",now-60,now-60,activeUntil);
 const preserved=async()=>({
  history:await rows('SELECT * FROM n_delivery_history ORDER BY send_id'),
  bridge:await rows('SELECT * FROM n_legacy_bridge ORDER BY install_id,identity_key'),
  events:await rows('SELECT * FROM n_event'),observations:await rows('SELECT * FROM n_observation'),
  roots:await rows('SELECT feed_id,snapshot_key,observation_generation FROM n_feed'),
 });
 const before=await preserved();
 const schema=await rows('SELECT name,sql FROM sqlite_master ORDER BY name');
 await run("INSERT INTO n_recovery_seed VALUES('feed','unresolved')");
 await assert.rejects(apply('0023_drop_retired_notification_storage.sql'),/CHECK constraint failed/);
 assert.deepEqual(await rows('SELECT name,sql FROM sqlite_master ORDER BY name'),schema,'failed readiness must roll back the whole migration');
 assert.deepEqual(await preserved(),before);
 await run('DELETE FROM n_recovery_seed');
 await apply('0023_drop_retired_notification_storage.sql');
 assert.deepEqual(await preserved(),before);
 for(const name of ['episode_notification_sends','feed_poll_attempts','n_shadow_feed','n_shadow_absence','n_cutover_receipt','n_idle_cutover_receipt','n_recovery_cutover_receipt','n_recovery_seed','n_origin_permit','n_poll','n_candidate','n_legacy_outcome','n_history_transition_delete'])assert.equal(await one('SELECT name FROM sqlite_master WHERE name=?',name),null,name);
 const columns=(await rows('PRAGMA table_info(n_feed)')).map(r=>r.name);
 for(const column of ['cutover_token','cutover_paused_at','cohort_bucket'])assert.ok(!columns.includes(column));
 assert.equal((await one("SELECT sql FROM sqlite_master WHERE name='n_feed_insert'")).sql.includes('episode_notification_sends'),false);
 // The external-reader cutover contracts only one column. In particular a
 // paused/dormant feed must not evade readiness, and a failure must leave no
 // readiness table or partial schema change behind.
 await run("INSERT INTO n_feed(feed_id,canonical_url,owner,epoch,due_at,admission_paused,send_paused,no_interest_since) VALUES('dormant','https://fixture.example/dormant.xml','queued',3,?,1,1,?)",now,now);
 await run("INSERT INTO n_delivery(delivery_id,presentation_id,install_id,install_epoch,interest_key,interest_generation,state,expires_at,next_attempt_at,apns_id,collapse_id,event_id,terminal_at) VALUES('delivery','presentation','real',1,'feed',1,'accepted',?,?,'apns','collapse','event',?)",activeUntil,now,now);
 const deliveryBefore=await rows('SELECT * FROM n_delivery');
 const schemaBefore24=await rows('SELECT name,sql FROM sqlite_master ORDER BY name');
 for(const id of ['feed','dormant']){
  await run('UPDATE n_feed SET recovery_pending=1 WHERE feed_id=?',id);
  const feedsBefore=await rows('SELECT * FROM n_feed ORDER BY feed_id');
  await assert.rejects(apply('0024_drop_recovery_pending.sql'),/CHECK constraint failed/);
  assert.deepEqual(await rows('SELECT name,sql FROM sqlite_master ORDER BY name'),schemaBefore24);
  assert.deepEqual(await rows('SELECT * FROM n_feed ORDER BY feed_id'),feedsBefore);
  assert.deepEqual(await rows('SELECT * FROM n_delivery'),deliveryBefore);
  await run('UPDATE n_feed SET recovery_pending=0 WHERE feed_id=?',id);
 }
 const feedsBefore24=(await rows('SELECT * FROM n_feed ORDER BY feed_id')).map(({recovery_pending,...feed})=>feed);
 const preservedBefore24=await preserved();
 await apply('0024_drop_recovery_pending.sql');
 assert.deepEqual(await rows('SELECT * FROM n_feed ORDER BY feed_id'),feedsBefore24);
 assert.deepEqual(await preserved(),preservedBefore24);
 assert.deepEqual(await rows('SELECT * FROM n_delivery'),deliveryBefore);
 assert.equal(await one("SELECT name FROM sqlite_master WHERE sql LIKE '%recovery_pending%'"),null);
 assert.deepEqual(await rows('PRAGMA foreign_key_check'),[]);
 await run("DELETE FROM n_feed WHERE feed_id='dormant'");
 await run("UPDATE n_control SET enabled=1 WHERE name IN('cleanup','feed_observation')");
 // The current Rust collector must preserve a page shared with a retired
 // shadow manifest, while actually reclaiming shadow-only objects and roots.
 for(let i=0;i<3;i++){
  const response=await mf.dispatchFetch('https://fixture.invalid/observation/gc',{method:'POST',body:JSON.stringify({feed_id:'f'.repeat(64)})});
  assert.equal(response.status,200,await response.text());
 }
 for(const key of ['current','shared'])assert.ok(await bucket.head(key),key);
 for(const key of ['shadow','obsolete'])assert.equal(await bucket.head(key),null,key);
 assert.deepEqual(await rows('SELECT object_key FROM n_snapshot ORDER BY object_key'),[{object_key:'current'},{object_key:'shared'}]);
 assert.deepEqual(await preserved(),before);
 assert.deepEqual(await rows('PRAGMA foreign_key_check'),[]);
 // Exercise the final trigger after the compatibility view has been removed.
 await run("UPDATE n_feed SET canonical_url='https://fixture.example/current.xml' WHERE feed_id='feed'");
 await enroll('reenrolled');
 assert.equal((await one("SELECT COUNT(*) n FROM n_legacy_bridge WHERE feed_id='reenrolled'")).n,5);
 console.log('PASS populated 0021→0024 upgrade: exact history, transitional deletion, bridge hydration, active/dormant readiness rollback, preserved feed/delivery state, shared-page GC, current events and foreign keys');
} finally {await mf.dispose();}
