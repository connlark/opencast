// The public catalog contract: registration, full sync, admission, quota,
// unsubscribe and erasure responses, asserted literally. Fixtures use real App
// Attest assertions, isolated storage and a deterministic mock publisher. The
// storage is the current PostgreSQL schema, so the orphan's retained admission
// is seeded in its moved state (the n_feed_catalog row and its
// admission_health_json). The schema's foreign keys are enforced at statement
// time.
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {fileURLToPath} from 'node:url';
import {Miniflare,convertV4MiniflareOptions} from 'miniflare';
import {identity} from './delivery-auth.mjs';
import {openStorage} from './storage.mjs';
import {compatibilityDate,compatibilityFlags} from './runtime-compatibility.mjs';
const root=fileURLToPath(new URL('../',import.meta.url));
const H=parts=>createHash('sha256').update(JSON.stringify(parts)).digest('hex');
// The orphan's retained admission, moved out of the retired feeds table: no
// n_feed carries its URL, so its first-sync health snapshot is the four
// polling fields as compact JSON; website_url was never set.
const ORPHAN={feed_url:'https://orphan.example/feed',source_url:'http://orphan.example/feed',title:'Retained admission',website_url:null,created_at:30,updated_at:40,
 admission_health_json:'{"consecutive_failures":3,"last_http_status":503,"last_error":"http_error","last_polled_at":42}'};
async function exercise(){
 const requests=[],storage=await openStorage();
 const mf=new Miniflare(convertV4MiniflareOptions({cf:false,inspectorPort:0,workers:[storage.bind({name:'catalog',modulesRoot:root,modules:[...['tests/observation-entry.mjs','adapter/index.js','build/index.js'].map(path=>({type:'ESModule',path:root+path})),{type:'CompiledWasm',path:root+'build/index_bg.wasm'}],compatibilityDate,compatibilityFlags,r2Buckets:{FEED_SNAPSHOTS:'catalog'},queueProducers:{EVENT_QUEUE:'catalog-events',EPISODE_DELIVERY_QUEUE:'catalog-episodes',JOB_DELIVERY_QUEUE:'catalog-jobs'},bindings:{NOTIFICATION_ENVIRONMENT:'development',APPLE_TEAM_ID:'EXAMPLETEAM',APPLE_BUNDLE_ID:'com.example.opencast',APP_ATTEST_ENVIRONMENT:'development',APNS_ENVIRONMENT:'development',PUBLIC_NOTIFICATIONS_ENABLED:'true',NOTIFICATION_FEED_OBSERVATION:'true'},outboundService:request=>{requests.push(request.url);return new Response('<rss><channel><title>Publisher</title><item><guid>stable-guid</guid><title>Stable</title></item></channel></rss>',{headers:{'content-type':'application/rss+xml'}});}})]}));
 try{
  await mf.ready;
  const db=await storage.database(mf);
  await db.prepare('INSERT INTO n_feed_catalog(feed_url,source_url,title,website_url,created_at,updated_at,admission_health_json) VALUES(?,?,?,?,?,?,?)')
   .bind(ORPHAN.feed_url,ORPHAN.source_url,ORPHAN.title,ORPHAN.website_url,ORPHAN.created_at,ORPHAN.updated_at,ORPHAN.admission_health_json).run();
  const now=Math.floor(Date.now()/1000),worker=await mf.getWorker('catalog');
  const auth=await identity(db,'contract','EXAMPLETEAM.com.example.opencast',now);
  const result=async response=>({status:response.status,body:await response.json()});
  const call=async(path,body)=>result(await auth(worker,path,body));
  const registration=await call('/v1/devices/register',{device_token:'b'.repeat(64),apns_environment:'development'});
  const orphan=await call('/v1/subscriptions/sync',{subscriptions:[{feed_url:'https://orphan.example/feed',notifications_enabled:true}]});
  assert.deepEqual(orphan.body.accepted,[{feed_url:'https://orphan.example/feed',title:'Retained admission',health:{consecutive_failures:3,last_http_status:503,last_error:'http_error',last_polled_at:42}}]);
  const enrolled=await call('/v1/subscriptions/sync',{subscriptions:[{feed_url:'https://orphan.example/feed',notifications_enabled:true}]});
  assert.deepEqual(enrolled.body.accepted,[{feed_url:'https://orphan.example/feed',title:'Retained admission',health:{consecutive_failures:0}}]);
  const source='HTTPS://Fixture.example.com/feed.xml/?b=2&a=1',canonical='https://fixture.example.com/feed.xml?a=1&b=2',feed=H(['feed-v1',canonical]);
  const subscriptions=[{feed_url:source,notifications_enabled:true}];
  const pending=await call('/v1/subscriptions/sync',{subscriptions});
  assert.equal(pending.status,200);assert.deepEqual(pending.body.pending,[{feed_url:canonical}]);
  assert.deepEqual((await db.prepare(`SELECT feed_url,source_url FROM n_feed_catalog WHERE feed_url='${canonical}'`).all()).results,[{feed_url:canonical,source_url:source}]);
  await db.prepare("UPDATE n_feed_catalog SET title='Preserved title',website_url='https://example.com/show'").run();
  await db.prepare('UPDATE n_feed SET epoch=7,poll_failures=3,last_success_at=1700000000 WHERE feed_id=?').bind(feed).run();
  const accepted=await call('/v1/subscriptions/sync',{subscriptions});
  assert.deepEqual(accepted.body.accepted,[{feed_url:canonical,title:'Preserved title',health:{consecutive_failures:3,last_error:'poll_failed',last_polled_at:1700000000}}]);
  assert.equal((await db.prepare('SELECT epoch FROM n_feed WHERE feed_id=?').bind(feed).first()).epoch,7);
  // Exhaust only this fixture's install cap. Known catalog rows stay free,
  // unknown admissions retain their exact rejection and source URL.
  await db.batch(Array.from({length:200},(_,i)=>db.prepare("INSERT INTO feed_admission_attempts VALUES(?, 'contract','key','other.example',1,NULL,?)").bind('cap'+i,now)));
  const quota=await call('/v1/subscriptions/sync',{subscriptions:[...subscriptions,{feed_url:'https://unknown.example/over.xml',notifications_enabled:true}]});
  assert.equal(quota.body.rejected[0].error,'new_feed_limit_exceeded');assert.equal(quota.body.accepted.length,1);
  const count=await call('/v1/subscriptions/sync',{subscriptions:Array.from({length:201},(_,i)=>({feed_url:`https://fixture.example.com/${i}`,notifications_enabled:true}))});
  assert.equal(count.status,400);
  await db.prepare("UPDATE n_control SET enabled=1 WHERE name='feed_observation'").run();
  const scan=await result(await worker.fetch('https://fixture.invalid/observation/scan',{method:'POST',body:JSON.stringify({feed_id:feed})}));
  assert.equal(scan.status,200);
  for(let i=0;i<20&&await db.prepare("SELECT 1 FROM n_observation WHERE state='staging' AND valid_eof=1").first();i++)assert.equal((await worker.fetch('https://fixture.invalid/observation/prepare',{method:'POST',body:JSON.stringify({feed_id:feed})})).status,200);
  assert.equal(requests.length,1);assert.equal(requests[0],'https://fixture.example.com/feed.xml/?b=2&a=1');
  const snapshot=(await db.prepare('SELECT snapshot_key FROM n_feed WHERE feed_id=?').bind(feed).first()).snapshot_key;
  assert.ok(snapshot);
  const bucket=await mf.getR2Bucket('FEED_SNAPSHOTS');
  const manifest=await(await bucket.get(snapshot)).json();
  const membership=[];
  for(const page of manifest.pages.filter(p=>p.index==='identity'))membership.push(Buffer.from(await(await bucket.get(page.key)).arrayBuffer()).toString('hex'));
  const episode=createHash('sha256').update(canonical+'|guid:stable-guid').digest('hex');
  assert.deepEqual(membership,[createHash('sha256').update(episode).digest('hex')]);
  assert.equal(manifest.feed_id,feed);assert.equal(manifest.pages.filter(p=>p.index==='identity').reduce((n,p)=>n+p.count,0),1);
  const unsubscribe=await call('/v1/subscriptions/sync',{subscriptions:[]});
  assert.equal((await db.prepare('SELECT enabled FROM n_interest WHERE feed_id=?').bind(feed).first()).enabled,0);
  const deletion=await call('/v1/install/delete',{});
  assert.equal((await db.prepare("SELECT COUNT(*) n FROM feed_admission_attempts WHERE install_id='contract'").first()).n,0);
  return {registration,orphan,enrolled,pending,accepted,quota,count,unsubscribe,deletion,requests,feed,membership};
 }finally{try{await mf.dispose();}finally{await storage.dispose();}}
}
await exercise();
console.log('PASS catalog source/canonical identity and public registration/full-sync/admission/quota/unsubscribe/erasure responses on the current PostgreSQL schema, the orphan admission seeded in its moved state');
