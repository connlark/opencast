// Current-schema populated upgrade and fresh D1 proof, using Wrangler's deployment parser.
import assert from 'node:assert/strict';
import {readFile,readdir} from 'node:fs/promises';
import {Miniflare,convertV4MiniflareOptions} from 'miniflare';
import {unstable_splitSqlQuery} from 'wrangler';
import {compatibilityDate,compatibilityFlags} from './runtime-compatibility.mjs';
const directory=new URL('../migrations/',import.meta.url);
const files=(await readdir(directory)).filter(f=>f.endsWith('.sql')).sort();
const mf=new Miniflare(convertV4MiniflareOptions({cf:false,inspectorPort:0,modules:true,script:'export default {fetch(){return new Response("fixture")}}',compatibilityDate,compatibilityFlags,d1Databases:{DB:'populated',FRESH:'fresh'}}));
try {
 await mf.ready;
 const db=await mf.getD1Database('DB'),fresh=await mf.getD1Database('FRESH');
 const apply=async(db,file)=>db.batch(unstable_splitSqlQuery(await readFile(new URL(file,directory),'utf8')).map(s=>db.prepare(s)));
 const run=(q,...args)=>db.prepare(q).bind(...args).run();
 const rows=async(q,...args)=>(await db.prepare(q).bind(...args).all()).results;
 for(const file of files.filter(f=>f<'0025'))await apply(db,file);
 await run("INSERT INTO n_install(install_id,epoch,enabled) VALUES('real',3,1),('erased',2,1)");
 for(const [id,paused] of [['active',0],['paused',1],['dormant',0]]){
  await run("INSERT INTO n_feed(feed_id,canonical_url,owner,epoch,due_at,admission_paused,send_paused,schedule_generation,eligibility_generation) VALUES(?,?,'queued',7,100,?,?,19,5)",id,`https://example.com/${id}`,paused,paused);
  await run("INSERT INTO feeds(feed_url,source_url,title,website_url,poll_interval_seconds,consecutive_failures,last_error,latest_episode_id,created_at,updated_at) VALUES(?,?,?,NULL,900,9,'retired error','retired checkpoint',30,40)",`https://example.com/${id}`,`http://EXAMPLE.com:80/${id}#source`,'Title '+id);
 }
 await run("INSERT INTO n_interest(install_id,feed_id,generation,activated_at,enabled) VALUES('real','active',2,20,1),('real','paused',2,20,1)");
 for(const id of ['current','shared','preparation'])await run("INSERT INTO n_snapshot(object_key,feed_id,owner_epoch,lease_id,sha256,bytes,state,created_at,gc_after,expected_pages) VALUES(?,'active',7,'lease','hash',15,'referenced',30,9999999999,?)",id,id==='current'?1:0);
 await run("INSERT INTO n_snapshot_ref VALUES('current','shared')");
 await run("UPDATE n_feed SET snapshot_key='current',observation_generation=4,semantic_digest='current:hash',publish_token='token' WHERE feed_id='active'");
 await run("INSERT INTO n_observation(observation_id,feed_id,generation,owner_epoch,lease_id,expected_generation,snapshot_key,scan_started_at,candidate_count,state,mode,valid_eof,preparation_key,processing_failures) VALUES('published','active',4,7,'published',3,'current',50,5,'published','queued',1,NULL,0),('preparing','active',5,7,'lease',4,'preparation',60,0,'staging','queued',1,'preparation',2)");
 for(const [i,state] of ['pending_future','ready','outboxed','withdrawn','expired'].entries())await run("INSERT INTO n_episode_release(feed_id,episode_id,mode,observation_id,generation,owner_epoch,event_id,presentation_key,first_observed_at,eligible_at,expires_at,reason,fingerprint,published_at,metadata_json,state,disposition) VALUES('active',?,'queued','published',4,7,?,'burst',50,60,86460,'recent',NULL,60,?,?,?)",`episode${i}`,`event${i}`,JSON.stringify({title:'shadow is ordinary metadata',source:'exact'}),state,state);
 await run("INSERT INTO n_burst(presentation_key,feed_id,owner_epoch,cursor,failures) VALUES('burst','active',7,'recipient',3)");
 await run("INSERT INTO n_event(source,event_id,schema_version,kind,payload_digest,occurred_at,eligible_at,expires_at,receipt_id,envelope_json,fanout_complete,feed_id,owner_epoch) VALUES('feed_polling','event2',1,'episode','digest',50,60,86460,'receipt','{\"retained\":true}',1,'active',7)");
 await run("INSERT INTO n_outbox(source,event_id,observation_id,payload_digest,occurred_at,expires_at,next_attempt_at,state,payload_json) VALUES('feed_polling','event2','published','digest',50,86460,60,'accepted','{\"exact\":true}')");
 await run("INSERT INTO n_delivery(delivery_id,presentation_id,install_id,install_epoch,interest_key,interest_generation,state,expires_at,next_attempt_at,apns_id,collapse_id,event_id,owner_epoch) VALUES('accepted','burst','real',3,'active',2,'accepted',86460,60,'apns','collapse','event2',7)");
 await run("INSERT INTO n_delivery_member VALUES('accepted','feed_polling','event2','real',3,2)");
 await run("INSERT INTO n_group_member VALUES('burst','feed_polling','event2',0)");
 await run("INSERT INTO n_delivery_history(send_id,install_id,device_token_hash,feed_url,episode_id,apns_environment,apns_status,apns_id,created_at,updated_at) VALUES('historic','real','hash','https://example.com/active','old-episode','production',200,'historic-apns',10,20)");
 await run("INSERT INTO n_legacy_bridge VALUES('real','active','episode:old-episode','accepted',2592020)");
 await run("INSERT INTO feed_admission_attempts VALUES('attempt','real','key','example.com',1,NULL,30)");
 const tableNames=(await rows("SELECT name FROM sqlite_schema WHERE type='table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE '_cf_%' ORDER BY name")).map(r=>r.name);
 const capture=async()=>Object.fromEntries(await Promise.all(tableNames.filter(t=>t!=='feeds').map(async t=>[t,await rows(`SELECT * FROM ${t} ORDER BY rowid`)])));
 const schema=()=>rows('SELECT name,sql FROM sqlite_schema ORDER BY name');
 // Inventory every incoming FK; dropping n_feed would cascade-delete burst.
 const incoming=[];
 for(const table of tableNames)for(const f of await rows(`PRAGMA foreign_key_list(${table})`))incoming.push({child:table,...f});
 assert.deepEqual(incoming.filter(f=>['feeds','n_episode_release'].includes(f.table)),[]);
 assert.deepEqual(incoming.filter(f=>f.table==='n_feed').map(f=>[f.child,f.on_delete]).sort(),[['n_burst','CASCADE'],['n_episode_release','NO ACTION'],['n_observation','NO ACTION'],['n_snapshot','NO ACTION']]);
 await run("INSERT INTO feeds(feed_url,source_url,title,website_url,poll_interval_seconds,consecutive_failures,last_http_status,last_error,last_polled_at,created_at,updated_at) VALUES('https://example.com/unenrolled','http://example.com/unenrolled','Unenrolled',NULL,900,3,503,'http_error',42,30,40)");
 const before=await capture(),schemaBefore=await schema();
 for(const [set,reset] of [
  ["UPDATE n_feed SET owner='legacy' WHERE feed_id='dormant'","UPDATE n_feed SET owner='queued' WHERE feed_id='dormant'"],
  ["UPDATE n_observation SET mode='shadow' WHERE observation_id='preparing'","UPDATE n_observation SET mode='queued' WHERE observation_id='preparing'"],
  ["UPDATE n_episode_release SET mode='shadow' WHERE episode_id='episode0'","UPDATE n_episode_release SET mode='queued' WHERE episode_id='episode0'"],
  ["UPDATE n_episode_release SET state='shadow' WHERE episode_id='episode0'","UPDATE n_episode_release SET state='pending_future' WHERE episode_id='episode0'"],
 ]){
  await run(set);const populated=await capture();
  await assert.rejects(apply(db,'0025_current_schema_expansion.sql'),/CHECK constraint failed/);
  assert.deepEqual(await schema(),schemaBefore);assert.deepEqual(await capture(),populated);
  await run(reset);
 }
 await apply(db,'0025_current_schema_expansion.sql');
 assert.deepEqual(await capture(),before,'expansion preserves every populated child, history and root');
 assert.deepEqual(await rows('PRAGMA foreign_key_check'),[]);
 assert.deepEqual(JSON.parse((await rows("SELECT admission_health_json FROM n_feed_catalog WHERE feed_url='https://example.com/unenrolled'"))[0].admission_health_json),{consecutive_failures:3,last_http_status:503,last_error:'http_error',last_polled_at:42});
 // Both deployed generations can insert, preserving first-writer source values.
 for(const [table,id,extra] of [['feeds','old',',poll_interval_seconds,consecutive_failures'],['n_feed_catalog','new','']]){
  await run("INSERT INTO n_feed(feed_id,canonical_url,epoch,due_at) VALUES(?,?,1,0)",id,`https://example.com/${id}`);
  await run(`INSERT INTO ${table}(feed_url,source_url,created_at,updated_at${extra}) VALUES(?,?,30,40${extra?',900,0':''})`,`https://example.com/${id}`,`http://example.com/${id}#first`);
  const other=table==='feeds'?'n_feed_catalog':'feeds';
  assert.deepEqual(await rows(`SELECT feed_url,source_url,title,website_url,created_at,updated_at FROM ${other} WHERE feed_url=?`,`https://example.com/${id}`),await rows(`SELECT feed_url,source_url,title,website_url,created_at,updated_at FROM n_feed_catalog WHERE feed_url=?`,`https://example.com/${id}`));
 }
 const catalog=await rows('SELECT * FROM n_feed_catalog ORDER BY feed_url');
 const expanded=await capture();
 const withoutChoices=Object.fromEntries(Object.entries(expanded).map(([t,rs])=>[t,rs.map(r=>{const c={...r};if(t==='n_feed')delete c.owner;if(['n_observation','n_episode_release'].includes(t))delete c.mode;return c;})]));
 // A divergence aborts contraction, including trigger/table removal.
 const schemaExpanded=await schema();
 await run("UPDATE feeds SET source_url='http://different.example' WHERE feed_url='https://example.com/old'");
 await assert.rejects(apply(db,'0026_current_schema_contraction.sql'),/CHECK constraint failed/);
 assert.deepEqual(await schema(),schemaExpanded);assert.deepEqual(await capture(),expanded);
 await run("UPDATE feeds SET source_url='http://example.com/old#first' WHERE feed_url='https://example.com/old'");
 await apply(db,'0026_current_schema_contraction.sql');
 assert.deepEqual(await capture(),withoutChoices);
 assert.deepEqual(await rows('SELECT * FROM n_feed_catalog ORDER BY feed_url'),catalog);
 assert.deepEqual(await rows('PRAGMA foreign_key_check'),[]);
 assert.deepEqual(await rows("SELECT name FROM sqlite_schema WHERE name IN('feeds','n_catalog_from_feeds','n_catalog_to_feeds')"),[]);
 for(const [table,column] of [['n_feed','owner'],['n_observation','mode'],['n_episode_release','mode']])assert.ok(!(await rows(`PRAGMA table_info(${table})`)).some(r=>r.name===column));
 assert.deepEqual((await rows('PRAGMA table_info(n_episode_release)')).filter(r=>r.pk).map(r=>r.name),['feed_id','episode_id']);
 // First actual enrollment clears only the obsolete response snapshot.
 await run("INSERT INTO n_feed(feed_id,canonical_url,epoch,due_at) VALUES('unenrolled','https://example.com/unenrolled',1,0)");
 assert.equal((await rows("SELECT admission_health_json FROM n_feed_catalog WHERE feed_url='https://example.com/unenrolled'"))[0].admission_health_json,null);
 // Fresh setup follows immutable lineage and has exactly the final schema.
 const retained=await capture();
 for(const file of files.filter(file=>file>'0026_current_schema_contraction.sql'))await apply(db,file);
 const afterRegistrationMigration=await capture();
 for(const row of afterRegistrationMigration.n_install){assert.equal(row.registration_revision,1);delete row.registration_revision;}
 for(const row of afterRegistrationMigration.n_poll_dispatch){
  assert.deepEqual({stall_state:row.stall_state,stall_since:row.stall_since,stall_alerted_at:row.stall_alerted_at,alert_armed_at:row.alert_armed_at},{stall_state:'clear',stall_since:0,stall_alerted_at:0,alert_armed_at:0});
  delete row.stall_state;delete row.stall_since;delete row.stall_alerted_at;delete row.alert_armed_at;
 }
 assert.deepEqual(afterRegistrationMigration,retained,'registration and alerting migrations preserve retained values');
 for(const file of files)await apply(fresh,file);
 const finalSchema=(await schema()).filter(r=>!r.name.startsWith('_cf_'));
 assert.deepEqual((await fresh.prepare('SELECT name,sql FROM sqlite_schema ORDER BY name').all()).results.filter(r=>!r.name.startsWith('_cf_')),finalSchema);
 assert.deepEqual((await fresh.prepare('PRAGMA foreign_key_check').all()).results,[]);
 console.log('PASS populated 0024→0025→0026 and fresh D1: readiness rollback, old/new insert overlap, exact catalog/source and all-row parity, composite-key rebuild, cascade-child/history/root preservation, FK integrity');
}finally{await mf.dispose();}
