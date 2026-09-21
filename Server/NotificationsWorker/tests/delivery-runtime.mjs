import assert from 'node:assert/strict';
import { fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';
import { Miniflare, convertV4MiniflareOptions } from 'miniflare';
import { migrate } from './migrations.mjs';
import { identity } from './delivery-auth.mjs';
import { compatibilityDate, compatibilityFlags } from './runtime-compatibility.mjs';

const T=1800000000,root=new URL('../',import.meta.url);
const H=parts=>createHash('sha256').update(JSON.stringify(parts)).digest('hex');
const url='https://fixtures.example.invalid/notifications.xml',feed=H(['feed-v1',url]);
const observation='00000000-0000-4000-8000-000000000001';
const sends=[];let outcome={status:200};let duringSend;
const bindings={APPLE_TEAM_ID:'EXAMPLETEAM',APPLE_BUNDLE_ID:'com.example.opencast',APP_ATTEST_ENVIRONMENT:'development',APNS_ENVIRONMENT:'development',NOTIFICATION_ENVIRONMENT:'development',PUBLIC_NOTIFICATIONS_ENABLED:'true',DEBUG_ENDPOINTS_ENABLED:'false'};
const options={cf:false,workers:[{
  name:'notifications',modulesRoot:fileURLToPath(root),modules:[...['tests/delivery-entry.mjs','adapter/index.js','build/index.js'].map(f=>({type:'ESModule',path:fileURLToPath(new URL(f,root))})),{type:'CompiledWasm',path:fileURLToPath(new URL('build/index_bg.wasm',root))}],compatibilityDate,compatibilityFlags,bindings,
  d1Databases:{APP_ATTEST_DB:'isolated-delivery'},
  queueProducers:{EVENT_QUEUE:'opencast-notification-event-development',EPISODE_DELIVERY_QUEUE:'opencast-notification-episode-development',JOB_DELIVERY_QUEUE:'opencast-notification-job-development'},
  serviceBindings:{APNS_CERT:async request=>{
    sends.push({headers:Object.fromEntries(request.headers),url:request.url,body:await request.json()});
    if(duringSend){const callback=duringSend;duringSend=undefined;await callback();}
    if(outcome.lost)return new Response(null,{status:200,headers:{'x-fixture-lost':'1'}});
    if(outcome.timeout)await new Promise(resolve=>setTimeout(resolve,16000));
    return new Response(outcome.status===200?null:JSON.stringify(outcome.body??{}),{status:outcome.status,headers:outcome.headers});
  }},outboundService:()=>{throw Error('External networking forbidden');},
},...['FeedEvents','AdAnalysisEvents','RemoteTranscriptionEvents'].map(entrypoint=>({name:entrypoint,modules:true,script:`export default { fetch(r,e) { return e.INGRESS.fetch(r); } }`,compatibilityDate,compatibilityFlags,serviceBindings:{INGRESS:{name:'notifications',entrypoint}}}))]};
const mf=new Miniflare(convertV4MiniflareOptions(options));
let passed=0; const check=async(name,fn)=>{await fn();passed++;console.log(`PASS ${name}`);};
try {
 let db=await mf.getD1Database('APP_ATTEST_DB','notifications');await migrate(db,new URL('migrations/',root));
 const worker=await mf.getWorker('notifications');const producer=await mf.getWorker('FeedEvents');
 const sql=(query,...args)=>db.prepare(query).bind(...args);
 const post=(w,path,value)=>w.fetch(`https://fixture.invalid${path}`,{method:'POST',body:JSON.stringify(value)});
 const clock=t=>worker.fetch('https://fixture.invalid/test/clock',{method:'POST',body:String(t)});
 const fault=name=>worker.fetch('https://fixture.invalid/test/fault',{method:'POST',body:name});
 const control=(name,enabled)=>sql('UPDATE n_control SET enabled=?,revision=revision+1 WHERE name=?',enabled,name).run();
 const drive=(source,id,generation=1,kind='event')=>post(worker,'/test/queue',{queue:`opencast-notification-${kind}-development`,message:{schema_version:1,environment:'development',source,id,generation}});
 const episode=(name='episode-1',patch={})=>({schema_version:1,environment:'development',source:'feed_polling',event_id:H(['episode-v1','development',feed,name]),kind:'episode',occurred_at:T,eligible_at:T,expires_at:T+86400,routing:{feed_id:feed,observation_id:observation,observation_generation:1,owner_epoch:1,episode_id:name},data:{feed_url:url,podcast_title:'Owned fixture',episode_title:name,first_observed_at:T,published_at:T,decision_reason:'recent'},...patch});
 await sql("INSERT INTO n_feed(feed_id,canonical_url,epoch,due_at,observation_generation) VALUES(?,?,1,?,1)",feed,url,T).run();
 await sql("INSERT INTO n_snapshot(object_key,feed_id,owner_epoch,lease_id,sha256,bytes,state,created_at,gc_after) VALUES('snapshot',?,1,'lease','digest',1,'referenced',?,?)",feed,T,T+86400).run();
 await sql("INSERT INTO n_observation(observation_id,feed_id,generation,owner_epoch,lease_id,expected_generation,snapshot_key,scan_started_at,completed_at,candidate_count,valid_eof,state) VALUES(?,?,1,1,'lease',0,'snapshot',?,?,0,1,'published')",observation,feed,T,T).run();
 const addInstall=async(install,created=T-100)=>{
  await sql("INSERT INTO devices(install_id,key_id,device_token,device_token_hash,apns_environment,bundle_id,notifications_enabled,created_at,last_seen_at,job_capable) VALUES(?,? ,?,?,'development','com.example.opencast',1,?,?,1)",install,install,'a'.repeat(64),H([install]),created,created).run();
  await sql('INSERT INTO feed_subscriptions VALUES(?,?,1,?,?,NULL)',install,url,created,created).run();
 };
 for(let i=0;i<205;i++) await addInstall(`install-${String(i).padStart(3,'0')}`);
 await check('new controls default off and public paths cannot invoke private ingress',async()=>{
   assert.equal((await post(producer,'/v1/events',episode())).status,503);
   for(const path of ['/v1/events','/internal/v1/events'])assert.equal((await post(worker,path,episode())).status,404);
   assert.equal(sends.length,0);
 });
 await control('episode_activation',1);
 const e=episode();let receipt;
 await check('private receipt is durable, idempotent and detects conflicts',async()=>{
   let r=await post(producer,'/v1/events',e);assert.equal(r.status,200,await r.clone().text());receipt=await r.json();
   r=await post(producer,'/v1/events',e);assert.equal((await r.json()).receipt_id,receipt.receipt_id);
   assert.equal((await post(producer,'/v1/events',{...e,data:{...e.data,episode_title:'changed'}})).status,409);
   assert.equal((await post(await mf.getWorker('AdAnalysisEvents'),'/v1/events',e)).status,403);
   assert.equal((await producer.fetch('https://fixture.invalid/v1/events',{method:'POST',body:JSON.stringify(e).replace('"schema_version":1','"schema_version":1,"schema_version":1')})).status,400);
 });
 await check('fanout paginates 205 recipients exactly once under page replays',async()=>{
   for(let i=0;i<5;i++){const r=await drive('feed_polling',e.event_id);assert.equal(r.status,200,await r.text());}
   assert.equal((await sql('SELECT COUNT(*) AS n FROM n_delivery').first()).n,205);
   assert.equal((await sql('SELECT COUNT(*) AS n FROM n_delivery_member').first()).n,205);
   assert.equal((await sql('SELECT fanout_complete FROM n_event').first()).fanout_complete,1);
 });
 const d=await sql("SELECT * FROM n_delivery WHERE install_id='install-000'").first();
 await check('send off survives queue wakeup; accepted replay never sends twice',async()=>{
   await drive('feed_polling',d.delivery_id,1,'episode');assert.equal(sends.length,0);
   await control('episode_send',1);let r=await drive('feed_polling',d.delivery_id,1,'episode');assert.equal(r.status,200,await r.text());
   assert.equal(sends.length,1);assert.equal(sends[0].headers['apns-id'],d.apns_id);assert.equal(sends[0].headers['apns-collapse-id'],d.delivery_id);assert.equal(sends[0].headers['apns-expiration'],String(T+86400));
   await drive('feed_polling',d.delivery_id,1,'episode');assert.equal(sends.length,1);
 });
 await check('late subscribers and re-enabled generations cannot inherit an event',async()=>{
   await addInstall('late',T+1);
   await sql("UPDATE feed_subscriptions SET notifications_enabled=0 WHERE install_id='install-001'").run();
   await sql("UPDATE feed_subscriptions SET notifications_enabled=1,created_at=? WHERE install_id='install-001'",T+1).run();
   const old=await sql("SELECT * FROM n_delivery WHERE install_id='install-001'").first();assert.equal(old.state,'suppressed');
   await drive('feed_polling',old.delivery_id,1,'episode');assert.equal(sends.length,1);
 });
 await check('stale owner and zero-row fanout claim cannot insert delivery',async()=>{
   const other=episode('stale');assert.equal((await post(producer,'/v1/events',other)).status,200);
   await sql("UPDATE n_feed SET epoch=2 WHERE feed_id=?",feed).run();
   assert.equal((await post(producer,'/v1/events',episode('rejected-stale'))).status,409);
   await drive('feed_polling',other.event_id);assert.equal((await sql('SELECT COUNT(*) AS n FROM n_delivery WHERE event_id=?',other.event_id).first()).n,0);
   await sql("UPDATE n_feed SET epoch=1 WHERE feed_id=?",feed).run();
 });
 await check('lost response retries stable APNs IDs',async()=>{
   const target=await sql("SELECT * FROM n_delivery WHERE install_id='install-002'").first();
   outcome={lost:true};await drive('feed_polling',target.delivery_id,1,'episode');
   assert.equal((await sql('SELECT state FROM n_delivery WHERE delivery_id=?',target.delivery_id).first()).state,'uncertain');
   await clock(T+5);outcome={status:200};await drive('feed_polling',target.delivery_id,1,'episode');
   assert.equal(sends.at(-1).headers['apns-id'],sends.at(-2).headers['apns-id']);assert.equal(sends.at(-1).headers['apns-collapse-id'],sends.at(-2).headers['apns-collapse-id']);
 });
 await check('410 response cannot disable a rotated token',async()=>{
   const target=await sql("SELECT * FROM n_delivery WHERE install_id='install-003'").first();
   outcome={status:410,body:{reason:'Unregistered',timestamp:T*1000}};
   const rotate=await identity(db,'install-003','EXAMPLETEAM.com.example.opencast',T);
   duringSend=async()=>{const r=await rotate(worker,'/v1/devices/register',{device_token:'b'.repeat(64),apns_environment:'development'});assert.equal(r.status,200,await r.text());};
   await drive('feed_polling',target.delivery_id,1,'episode');
   assert.equal((await sql("SELECT enabled FROM n_install WHERE install_id='install-003'").first()).enabled,1);
   await clock(T+10);outcome={status:200};await drive('feed_polling',target.delivery_id,1,'episode');assert.ok(sends.at(-1).url.endsWith('b'.repeat(64)));await clock(T+6);
 });
 await check('credential failure opens circuit without invalidating recipients',async()=>{
   const a=await sql("SELECT * FROM n_delivery WHERE install_id='install-004'").first();const b=await sql("SELECT * FROM n_delivery WHERE install_id='install-005'").first();
   outcome={status:403,body:{reason:'BadCertificate'}};await drive('feed_polling',a.delivery_id,1,'episode');const before=sends.length;
   await drive('feed_polling',b.delivery_id,1,'episode');assert.equal(sends.length,before);assert.equal((await sql('SELECT COUNT(*) AS n FROM n_install WHERE enabled=0').first()).n,0);
   await sql("UPDATE n_circuit SET paused=0 WHERE lane='apns'").run();outcome={status:200};
 });
 await check('15-second APNs deadline records uncertainty',async()=>{
   const target=await sql("SELECT * FROM n_delivery WHERE install_id='install-007'").first();outcome={status:200,timeout:true};
   const start=performance.now();await drive('feed_polling',target.delivery_id,1,'episode');assert.ok(performance.now()-start<15900);
   assert.equal((await sql('SELECT state FROM n_delivery WHERE delivery_id=?',target.delivery_id).first()).state,'uncertain');outcome={status:200};
 });
 await check('429 and 5xx persist retry deadlines and preserve expiry',async()=>{
   const target=await sql("SELECT * FROM n_delivery WHERE install_id='install-008'").first();outcome={status:429,headers:{'Retry-After':'90'}};
   await drive('feed_polling',target.delivery_id,1,'episode');let row=await sql('SELECT * FROM n_delivery WHERE delivery_id=?',target.delivery_id).first();assert.equal(row.next_attempt_at,T+96);assert.equal(row.expires_at,T+86400);
   const before=sends.length;await drive('feed_polling',target.delivery_id,1,'episode');assert.equal(sends.length,before);
   await clock(T+96);outcome={status:503};await drive('feed_polling',target.delivery_id,1,'episode');row=await sql('SELECT * FROM n_delivery WHERE delivery_id=?',target.delivery_id).first();assert.equal(row.next_attempt_at,T+111);assert.equal(row.state,'pending');outcome={status:200};
 });
 await check('live 410 erases raw token; an older invalidation cannot erase re-registration',async()=>{
   let target=await sql("SELECT * FROM n_delivery WHERE install_id='install-009'").first();outcome={status:410,body:{reason:'Unregistered',timestamp:(T+90)*1000}};
   await drive('feed_polling',target.delivery_id,1,'episode');assert.equal((await sql("SELECT device_token FROM devices WHERE install_id='install-009'").first()).device_token,'');
   target=await sql("SELECT * FROM n_delivery WHERE install_id='install-010'").first();await sql("UPDATE devices SET last_seen_at=? WHERE install_id='install-010'",T+95).run();
   await drive('feed_polling',target.delivery_id,1,'episode');assert.equal((await sql("SELECT enabled FROM n_install WHERE install_id='install-010'").first()).enabled,1);outcome={status:200};
 });
 await check('repeated stale 410 under one registration backs off then suppresses only the delivery',async()=>{
   const target=await sql("SELECT * FROM n_delivery WHERE install_id='install-010'").first();assert.equal(target.next_attempt_at,T+101);
   outcome={status:410,body:{reason:'Unregistered',timestamp:(T+90)*1000}};const before=sends.length;
   await drive('feed_polling',target.delivery_id,1,'episode');assert.equal(sends.length,before);
   await clock(T+101);await drive('feed_polling',target.delivery_id,1,'episode');const row=await sql('SELECT * FROM n_delivery WHERE delivery_id=?',target.delivery_id).first();assert.equal(row.state,'suppressed');assert.equal(row.last_reason,'stale_token');assert.equal((await sql("SELECT enabled FROM n_install WHERE install_id='install-010'").first()).enabled,1);
   await drive('feed_polling',target.delivery_id,1,'episode');assert.equal(sends.length,before+1);outcome={status:200};await clock(T+96);
 });
 await check('same-token confirmation during an APNs attempt preserves the claim and rejects an older 410',async()=>{
   const signed=await identity(db,'install-013','EXAMPLETEAM.com.example.opencast',T);
   const register=async()=>{const r=await signed(worker,'/v1/devices/register',{device_token:'a'.repeat(64),apns_environment:'development'});assert.equal(r.status,200,await r.text());};
   await register();
   const before=await sql("SELECT token_generation FROM n_install WHERE install_id='install-013'").first();
   const target=await sql("SELECT * FROM n_delivery WHERE install_id='install-013' LIMIT 1").first();
   outcome={status:410,body:{reason:'Unregistered',timestamp:(T+96)*1000}};
   duringSend=register;
   await drive('feed_polling',target.delivery_id,1,'episode');
   const after=await sql("SELECT token_generation,registered_at,enabled FROM n_install WHERE install_id='install-013'").first();
   assert.equal(after.token_generation,before.token_generation);assert.equal(after.registered_at,T+96);assert.equal(after.enabled,1);
   assert.equal((await sql('SELECT state FROM n_delivery WHERE delivery_id=?',target.delivery_id).first()).state,'pending');
   await clock(T+102);outcome={status:200};await drive('feed_polling',target.delivery_id,1,'episode');
   assert.equal((await sql('SELECT state FROM n_delivery WHERE delivery_id=?',target.delivery_id).first()).state,'accepted');
   await clock(T+96);
 });
 await check('zero-row page fence blocks every following insert and cursor update',async()=>{
   const other=episode('page-fenced');await post(producer,'/v1/events',other);await fault('reclaim_fanout');
   await drive('feed_polling',other.event_id);assert.equal((await sql('SELECT COUNT(*) AS n FROM n_delivery WHERE event_id=?',other.event_id).first()).n,0);
   assert.equal((await sql('SELECT fanout_cursor FROM n_event WHERE event_id=?',other.event_id).first()).fanout_cursor,null);
   await sql('UPDATE n_event SET lease_id=NULL,lease_until=NULL WHERE event_id=?',other.event_id).run();await drive('feed_polling',other.event_id);
   assert.equal((await sql('SELECT COUNT(*) AS n FROM n_delivery WHERE event_id=?',other.event_id).first()).n,100);
 });
 await check('failed fanout transaction rolls back delivery and cursor together',async()=>{
   const other=episode('rollback');await post(producer,'/v1/events',other);await fault('fail_batch');assert.equal((await drive('feed_polling',other.event_id)).status,500);
   assert.equal((await sql('SELECT COUNT(*) AS n FROM n_delivery WHERE event_id=?',other.event_id).first()).n,0);assert.equal((await sql('SELECT fanout_cursor FROM n_event WHERE event_id=?',other.event_id).first()).fanout_cursor,null);
 });
 await check('send control changed after lease admission blocks the final APNs call',async()=>{
   const target=await sql("SELECT * FROM n_delivery WHERE install_id='install-014' LIMIT 1").first();const before=sends.length;
   await fault('final_send_off');await drive('feed_polling',target.delivery_id,1,'episode');assert.equal(sends.length,before);
   assert.equal((await sql('SELECT last_reason FROM n_delivery WHERE delivery_id=?',target.delivery_id).first()).last_reason,'authority_changed');await control('episode_send',1);
 });
 await check('repeated handler errors poison fanout without advancing its cursor',async()=>{
   const other=episode('poison');await post(producer,'/v1/events',other);
   for(let i=0;i<10;i++){await clock(T+96+i*301);await fault('fail_batch');assert.equal((await drive('feed_polling',other.event_id)).status,500);}
   const row=await sql('SELECT failures,fanout_cursor FROM n_event WHERE event_id=?',other.event_id).first();assert.equal(row.failures,10);assert.equal(row.fanout_cursor,null);
   await drive('feed_polling',other.event_id);assert.equal((await sql('SELECT COUNT(*) AS n FROM n_delivery WHERE event_id=?',other.event_id).first()).n,0);await clock(T+96);
 });
 await check('wrong queue, environment and generation messages have no effect',async()=>{
   const before=sends.length;assert.equal((await drive('feed_polling',d.delivery_id,1,'job')).status,400);await drive('feed_polling',d.delivery_id,99,'episode');assert.equal(sends.length,before);
   assert.equal((await post(worker,'/test/queue',{queue:'opencast-notification-event-development',message:{schema_version:1,environment:'production',source:'feed_polling',id:e.event_id,generation:1}})).status,400);
 });
 await check('legacy public registration payload and signed opt-out erase token and suppress pending work',async()=>{
   const signed=await identity(db,'install-011','EXAMPLETEAM.com.example.opencast',T);
   let r=await signed(worker,'/v1/devices/register',{device_token:'c'.repeat(64),apns_environment:'development'});assert.equal(r.status,200,await r.text());
   assert.equal((await sql("SELECT job_capable FROM n_install WHERE install_id='install-011'").first()).job_capable,0);
   r=await signed(worker,'/v1/devices/unregister',{device_token:'c'.repeat(64)});assert.equal(r.status,200,await r.text());
   assert.equal((await sql("SELECT device_token FROM devices WHERE install_id='install-011'").first()).device_token,'');
   assert.equal((await sql("SELECT COUNT(*) AS n FROM n_delivery WHERE install_id='install-011' AND state='pending'").first()).n,0);
 });
 await check('signed legacy subscription sync atomically advances eligibility on unsubscribe/resubscribe',async()=>{
   const signed=await identity(db,'install-015','EXAMPLETEAM.com.example.opencast',T);
   let r=await signed(worker,'/v1/subscriptions/sync',{subscriptions:[]});assert.equal(r.status,200,await r.text());
   const revoked=await sql("SELECT * FROM n_interest WHERE install_id='install-015'").first();assert.equal(revoked.enabled,0);assert.equal(revoked.generation,2);assert.equal(revoked.changed_at,T+96);
   await sql('INSERT INTO n_feed_catalog(feed_url,source_url,created_at,updated_at) VALUES(?,?,?,?)',url,url,T,T).run();
   r=await signed(worker,'/v1/subscriptions/sync',{subscriptions:[{feed_url:url,notifications_enabled:true}]});assert.equal(r.status,200,await r.text());
   const renewed=await sql("SELECT * FROM n_interest WHERE install_id='install-015'").first();assert.equal(renewed.enabled,1);assert.equal(renewed.generation,3);assert.equal(renewed.activated_at,T+96);
   assert.equal((await sql("SELECT COUNT(*) AS n FROM n_delivery WHERE install_id='install-015' AND state='pending'").first()).n,0);
 });
 await check('signed install deletion erases all owned state with controls off and queue replay cannot resurrect it',async()=>{
   const signed=await identity(db,'install-012','EXAMPLETEAM.com.example.opencast',T);const target=await sql("SELECT * FROM n_delivery WHERE install_id='install-012' LIMIT 1").first();
   await control('episode_send',0);await control('cleanup',0);let r=await signed(worker,'/v1/install/delete',{});assert.equal(r.status,200,await r.text());
   for(const table of ['n_install','n_interest','n_delivery','devices','feed_subscriptions','app_attest_keys'])assert.equal((await sql(`SELECT COUNT(*) AS n FROM ${table} WHERE install_id='install-012'`).first()).n,0,table);
   assert.equal((await sql('SELECT COUNT(*) AS n FROM n_deleted_install').first()).n,1);
   await drive('feed_polling',target.delivery_id,1,'episode');assert.equal((await sql("SELECT COUNT(*) AS n FROM n_install WHERE install_id='install-012'").first()).n,0);
   r=await signed(worker,'/v1/devices/register',{device_token:'d'.repeat(64),apns_environment:'development'});assert.equal(r.status,401);
   await control('episode_send',1);
 });
 await check('fresh key for a deleted install recovers registration while old queued work stays erased',async()=>{
   // Models successful fresh App Attest enrollment, as the shipped client does
   // after unknown_key. The SQL challenge guard is separately host-tested.
   const fresh=await identity(db,'install-012','EXAMPLETEAM.com.example.opencast',T+96);
   let r=await fresh(worker,'/v1/devices/register',{device_token:'d'.repeat(64),apns_environment:'development'});assert.equal(r.status,200,await r.text());
   assert.equal((await sql("SELECT enabled FROM n_install WHERE install_id='install-012'").first()).enabled,1);
   assert.equal((await sql("SELECT COUNT(*) AS n FROM n_delivery WHERE install_id='install-012'").first()).n,0);assert.equal((await sql('SELECT COUNT(*) AS n FROM n_deleted_install').first()).n,1);
   r=await fresh(worker,'/v1/subscriptions/sync',{subscriptions:[{feed_url:url,notifications_enabled:true}]});assert.equal(r.status,200,await r.text());
   await drive('feed_polling',e.event_id);assert.equal((await sql("SELECT COUNT(*) AS n FROM n_delivery WHERE install_id='install-012'").first()).n,0);
 });
 await check('pre-deletion authenticated writes cannot overwrite a fresh enrollment',async()=>{
   for(const [install,path,payload] of [
     ['install-016','/v1/devices/register',{device_token:'f'.repeat(64),apns_environment:'development'}],
     ['install-017','/v1/subscriptions/sync',{subscriptions:[]}],
   ]){
     const old=await identity(db,install,'EXAMPLETEAM.com.example.opencast',T);
     await worker.fetch('https://fixture.invalid/test/hold-auth-write',{method:'POST',body:path});const pending=old(worker,path,payload);
     for(let n=0;!(await (await worker.fetch('https://fixture.invalid/test/auth-write-held')).json());n++){assert.ok(n<200);await new Promise(resolve=>setTimeout(resolve,5));}
     let r=await old(worker,'/v1/install/delete',{});assert.equal(r.status,200);
     const fresh=await identity(db,install,'EXAMPLETEAM.com.example.opencast',T+96);
     r=await fresh(worker,'/v1/devices/register',{device_token:'d'.repeat(64),apns_environment:'development'});assert.equal(r.status,200);
     r=await fresh(worker,'/v1/subscriptions/sync',{subscriptions:[{feed_url:url,notifications_enabled:true}]});assert.equal(r.status,200);
     await worker.fetch('https://fixture.invalid/test/release-auth-write',{method:'POST'});r=await pending;assert.equal(r.status,200);
     assert.equal((await sql('SELECT device_token FROM devices WHERE install_id=?',install).first()).device_token,'d'.repeat(64));
     assert.equal((await sql('SELECT enabled FROM n_interest WHERE install_id=?',install).first()).enabled,1);
   }
 });
 const ad=await mf.getWorker('AdAnalysisEvents');
 const seedInterest=async(number,install)=>{
   const operation=`00000000-0000-4000-8000-${String(number).padStart(12,'0')}`,run='00000000-0000-4000-8000-000000009999';
   const interest=H(['interest-v1','development',install,'1',operation,'1']),grant=H(['grant',operation]);
   await sql("INSERT INTO n_job_interest(install_id,install_epoch,operation_id,producer,requester_ref,generation,grant_digest,grant_nonce,grant_key_version,issued_at,accept_before,register_before,state,interest_id) VALUES(?,1,?,'ad_analysis','requester',1,?,'nonce',1,?,?,?,'issued',?)",install,operation,grant,T,T+1800,T+604800,interest).run();
   const registration={schema_version:1,environment:'development',producer:'ad_analysis',grant_digest:grant,operation_id:operation,interest_id:interest,interest_generation:1,requester_ref:'requester',run_id:run,job_handle:'job-handle',accepted_at:T};
   const event={schema_version:1,environment:'development',source:'ad_analysis',event_id:H(['job-v1','development','ad_analysis',run,operation,interest,'ad_analysis.completed']),kind:'ad_analysis.completed',occurred_at:T,eligible_at:T,expires_at:T+21600,routing:{interest_id:interest,interest_generation:1,operation_id:operation,run_id:run},data:{job_handle:'job-handle',result_expires_at:T+86400,title:'Ad analysis ready',body:'The server result is ready.'}};
   return {registration,event};
 };
 await check('job registration binds run/requester and completion queue sends only opted-in capable recipients',async()=>{
   const {registration,event}=await seedInterest(100,'install-020');let r=await post(ad,'/v1/interests/register',registration);assert.equal(r.status,200,await r.clone().text());const receipt=await r.json();
   assert.equal((await (await post(ad,'/v1/interests/register',registration)).json()).receipt_id,receipt.receipt_id);
   assert.equal((await post(ad,'/v1/interests/register',{...registration,requester_ref:'stranger'})).status,409);
   assert.equal((await post(ad,'/v1/events',event)).status,200);await drive('ad_analysis',event.event_id);const target=await sql('SELECT * FROM n_delivery WHERE event_id=?',event.event_id).first();assert.ok(target);
   let before=sends.length;await drive('ad_analysis',target.delivery_id,1,'job');assert.equal(sends.length,before);
   await control('job_send',1);await drive('ad_analysis',target.delivery_id,1,'job');assert.equal(sends.length,before+1);assert.equal(sends.at(-1).body.aps.category,'OPENCAST_JOB_COMPLETION');assert.equal(sends.at(-1).body.opencast.operation_id,registration.operation_id);
   const c={schema_version:1,environment:'development',producer:'ad_analysis',interest_id:registration.interest_id,interest_generation:1,run_id:registration.run_id,reason:'rejected',grant_digest:registration.grant_digest,operation_id:registration.operation_id,requester_ref:'requester'};
   r=await post(ad,'/v1/interests/cancel',c);assert.equal(r.status,200,await r.clone().text());assert.equal((await r.json()).local_fallback_safe,false);
 });
 await check('pre-registration rejection is monotonic and terminal replay is suppressed',async()=>{
   const {registration,event}=await seedInterest(101,'install-021');
   let r=await post(ad,'/v1/interests/cancel',{schema_version:1,environment:'development',producer:'ad_analysis',interest_id:registration.interest_id,interest_generation:1,reason:'rejected',grant_digest:registration.grant_digest,operation_id:registration.operation_id,requester_ref:'requester'});assert.equal(r.status,200,await r.clone().text());assert.equal((await r.json()).local_fallback_safe,true);
   assert.equal((await post(ad,'/v1/interests/register',registration)).status,410);
   r=await post(ad,'/v1/events',event);assert.equal(r.status,200,await r.clone().text());assert.equal((await r.json()).disposition,'suppressed');assert.equal((await sql('SELECT COUNT(*) AS n FROM n_delivery WHERE interest_key=?',registration.interest_id).first()).n,0);
 });
 await check('revoked interests return 410; lost capability returns a durable suppressed event receipt',async()=>{
   const revoked=await seedInterest(103,'install-022');await sql("UPDATE n_job_interest SET state='revoked' WHERE interest_id=?",revoked.registration.interest_id).run();
   let r=await post(ad,'/v1/interests/register',revoked.registration);assert.equal(r.status,410);assert.equal((await r.json()).error,'interest_revoked');
   const disabled=await seedInterest(104,'install-023');r=await post(ad,'/v1/interests/register',disabled.registration);assert.equal(r.status,200);
   const signed=await identity(db,'install-023','EXAMPLETEAM.com.example.opencast',T);r=await signed(worker,'/v1/devices/register',{device_token:'e'.repeat(64),apns_environment:'development'});assert.equal(r.status,200);
   r=await post(ad,'/v1/events',disabled.event);assert.equal(r.status,200);const receipt=await r.json();assert.equal(receipt.disposition,'suppressed');
   r=await post(ad,'/v1/events',disabled.event);assert.equal((await r.json()).receipt_id,receipt.receipt_id);assert.equal((await sql('SELECT COUNT(*) AS n FROM n_delivery WHERE event_id=?',disabled.event.event_id).first()).n,0);
 });
 await check('fixed expiry stops sends and rejects replay after tombstone deletion',async()=>{
   await clock(T+86400);const before=sends.length;
   const target=await sql("SELECT * FROM n_delivery WHERE install_id='install-006'").first();await drive('feed_polling',target.delivery_id,1,'episode');assert.equal(sends.length,before);
   assert.equal((await post(producer,'/v1/events',e)).status,410);
 });
 await check('expiry compacts receipts; cleanup respects controls and fixed retention',async()=>{
   let r=await worker.fetch('https://fixture.invalid/test/reconcile',{method:'POST'});assert.equal(r.status,200,await r.text());
   const compact=await sql('SELECT * FROM n_event WHERE event_id=?',episode('poison').event_id).first();assert.equal(compact.envelope_json,'{}');assert.equal(compact.terminal_at,T+86400);
   await sql("INSERT INTO n_feed(feed_id,canonical_url,epoch,due_at) VALUES('unused','https://unused.example/feed.xml',1,?)",T).run();
   await clock(T+32*86400);await worker.fetch('https://fixture.invalid/test/reconcile',{method:'POST'});
   assert.equal((await sql("SELECT COUNT(*) AS n FROM n_feed WHERE feed_id='unused'").first()).n,1);assert.equal((await sql('SELECT COUNT(*) AS n FROM n_deleted_install').first()).n,0);
   await control('cleanup',1);for(let i=0;i<6;i++){r=await worker.fetch('https://fixture.invalid/test/reconcile',{method:'POST'});assert.equal(r.status,200,await r.text());}
   assert.equal((await sql("SELECT COUNT(*) AS n FROM n_feed WHERE feed_id='unused'").first()).n,0);assert.equal((await sql('SELECT COUNT(*) AS n FROM n_event WHERE event_id=?',episode('poison').event_id).first()).n,0);
   await control('cleanup',0);
 });
 await check('send-paused deliveries do not starve the recovery queue',async()=>{
   await clock(T);
   const pausedFeed=H(['feed-v1','https://paused.example/feed.xml']);
   const activeFeed=H(['feed-v1','https://active.example/feed.xml']);
   await sql("INSERT INTO n_feed(feed_id,canonical_url,epoch,due_at,send_paused) VALUES(?,?,1,?,1),(?,?,1,?,0)",pausedFeed,'https://paused.example/feed.xml',T,activeFeed,'https://active.example/feed.xml',T).run();
   const pausedIds=[];
   for(let i=0;i<120;i++) { const id=H(['paused-delivery',i]); pausedIds.push(id); await sql("INSERT INTO n_delivery(delivery_id,presentation_id,install_id,install_epoch,interest_key,interest_generation,state,expires_at,next_attempt_at,apns_id,collapse_id,source,event_id,owner_epoch) VALUES(?,?,?,1,?,1,'pending',?,?,?,?,'feed_polling',?,1)").bind(id,'paused-presentation-'+i,`install-${String(i).padStart(3,'0')}`,pausedFeed,T+3600,T,'apns-'+id,'collapse-'+id,'event-'+id).run(); }
   const activeId=H(['active-delivery']);
   await sql("INSERT INTO n_delivery(delivery_id,presentation_id,install_id,install_epoch,interest_key,interest_generation,state,expires_at,next_attempt_at,apns_id,collapse_id,source,event_id,owner_epoch) VALUES(?,?,?,1,?,1,'pending',?,?,?,?,'feed_polling',?,1)").bind(activeId,'active-presentation','install-204',activeFeed,T+3600,T,'apns-'+activeId,'collapse-'+activeId,'event-'+activeId).run();
   const before=(await (await worker.fetch('https://fixture.invalid/test/enqueued')).json()).length;
   await worker.fetch('https://fixture.invalid/test/reconcile',{method:'POST'});
   const queued=(await (await worker.fetch('https://fixture.invalid/test/enqueued')).json()).slice(before).map(x=>x.message?.id);
   assert.ok(queued.includes(activeId));
   assert.equal(queued.some(id=>pausedIds.includes(id)),false);
   await sql("DELETE FROM n_delivery WHERE interest_key IN(?,?)",pausedFeed,activeFeed).run();
   await sql("DELETE FROM n_feed WHERE feed_id IN(?,?)",pausedFeed,activeFeed).run();
 });
 await check('real Queue consumers repair a lost enqueue and expired lease from D1',async()=>{
   await sql("UPDATE n_delivery SET state='expired',lease_id=NULL,lease_until=NULL,terminal_at=? WHERE state IN('pending','uncertain','leased')",T+86400).run();
   await sql('UPDATE n_event SET fanout_complete=1,lease_id=NULL,lease_until=NULL').run();
   await control('episode_send',0);await control('job_send',0);
   await mf.setOptions(convertV4MiniflareOptions({...options,workers:options.workers.map((w,i)=>i===0?{...w,bindings:{...w.bindings,DEBUG_ENDPOINTS_ENABLED:'true'},queueConsumers:Object.fromEntries(['event','episode','job'].map(kind=>[`opencast-notification-${kind}-development`,{maxBatchSize:10,maxBatchTimeout:0}]))}:w)}));
   db=await mf.getD1Database('APP_ATTEST_DB','notifications');
   const actual=await mf.getWorker('notifications'),actualAd=await mf.getWorker('AdAnalysisEvents');
   const waitFor=async predicate=>{for(let i=0;i<150;i++){const result=await predicate();if(result)return result;await new Promise(resolve=>setTimeout(resolve,50));}assert.fail('durable queue progress timed out');};
   const {registration,event}=await seedInterest(102,'install-030');
   let r=await post(actualAd,'/v1/interests/register',registration);assert.equal(r.status,200,await r.text());
   r=await post(actualAd,'/v1/events',event);assert.equal(r.status,200,await r.text());
   const target=await waitFor(()=>sql('SELECT * FROM n_delivery WHERE event_id=?',event.event_id).first());
   // The first queue message was acknowledged while sends were off. Simulate
   // a prior worker disappearing after lease admission, with no Queue copy.
   await sql("UPDATE n_delivery SET state='leased',lease_id='abandoned',lease_until=?,attempt=1,attempt_started_at=? WHERE delivery_id=?",T-1,T-61,target.delivery_id).run();
   await control('job_send',1);r=await actual.fetch('https://fixture.invalid/test/reconcile',{method:'POST'});assert.equal(r.status,200,await r.text());
   await waitFor(async()=>(await sql('SELECT state FROM n_delivery WHERE delivery_id=?',target.delivery_id).first())?.state==='accepted');
   const trace=await actual.fetch('https://fixture.invalid/test/queue-trace').then(r=>r.json());assert.ok(trace.some(b=>b.first?.id===event.event_id));assert.ok(trace.some(b=>b.first?.id===target.delivery_id));
   const delivered=sends.filter(s=>s.body.opencast?.operation_id===registration.operation_id);assert.equal(delivered.length,1);assert.equal(delivered[0].headers['apns-id'],target.apns_id);
   await actual.fetch('https://fixture.invalid/test/reconcile',{method:'POST'});await new Promise(resolve=>setTimeout(resolve,200));assert.equal(sends.filter(s=>s.body.opencast?.operation_id===registration.operation_id).length,1);
   const signed=await identity(db,'install-040','EXAMPLETEAM.com.example.opencast',T);const before=sends.length;
   await control('diagnostic_send',0);let diagnostic=await signed(actual,'/v1/debug/send-test-push',{});assert.equal(diagnostic.status,200,await diagnostic.text());assert.equal(sends.length,before);
   await control('diagnostic_send',1);await sql("UPDATE n_circuit SET paused=1 WHERE lane='apns'").run();diagnostic=await signed(actual,'/v1/debug/send-test-push',{});assert.equal(diagnostic.status,200);assert.equal(sends.length,before);
   await sql("UPDATE n_circuit SET paused=0 WHERE lane='apns'").run();outcome={status:410,body:{reason:'Unregistered',timestamp:T*1000}};
   duringSend=()=>sql("UPDATE devices SET last_seen_at=? WHERE install_id='install-040'",T+1).run();diagnostic=await signed(actual,'/v1/debug/send-test-push',{});assert.equal(diagnostic.status,200);assert.equal((await diagnostic.json()).apns_status,410);assert.equal((await sql("SELECT enabled FROM n_install WHERE install_id='install-040'").first()).enabled,1);outcome={status:200};

 });
 console.log(`${passed} delivery runtime checks passed`);
} finally {await mf.dispose();}
