// Compare the public contract against a previous-schema binary when supplied. Fixtures
// use real App Attest assertions, isolated D1 and a deterministic mock publisher.
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {readFile,readdir} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import {Miniflare,convertV4MiniflareOptions} from 'miniflare';
import {unstable_splitSqlQuery} from 'wrangler';
import {identity} from './delivery-auth.mjs';
import {compatibilityDate,compatibilityFlags} from './runtime-compatibility.mjs';
const currentRoot=fileURLToPath(new URL('../',import.meta.url));
const migrations=new URL('../migrations/',import.meta.url);
const H=parts=>createHash('sha256').update(JSON.stringify(parts)).digest('hex');
async function exercise(root,limit){
 const requests=[];
 const mf=new Miniflare(convertV4MiniflareOptions({cf:false,inspectorPort:0,workers:[{name:'catalog',modulesRoot:root,modules:[...['tests/observation-entry.mjs','adapter/index.js','build/index.js'].map(path=>({type:'ESModule',path:root+path})),{type:'CompiledWasm',path:root+'build/index_bg.wasm'}],compatibilityDate,compatibilityFlags,d1Databases:{APP_ATTEST_DB:'catalog'},r2Buckets:{FEED_SNAPSHOTS:'catalog'},queueProducers:{EVENT_QUEUE:'catalog-events',EPISODE_DELIVERY_QUEUE:'catalog-episodes',JOB_DELIVERY_QUEUE:'catalog-jobs'},bindings:{NOTIFICATION_ENVIRONMENT:'development',APPLE_TEAM_ID:'EXAMPLETEAM',APPLE_BUNDLE_ID:'com.example.opencast',APP_ATTEST_ENVIRONMENT:'development',APNS_ENVIRONMENT:'development',PUBLIC_NOTIFICATIONS_ENABLED:'true',NOTIFICATION_FEED_OBSERVATION:'true'},outboundService:request=>{requests.push(request.url);return new Response('<rss><channel><title>Publisher</title><item><guid>stable-guid</guid><title>Stable</title></item></channel></rss>',{headers:{'content-type':'application/rss+xml'}});}}]}));
 try{
  await mf.ready;const db=await mf.getD1Database('APP_ATTEST_DB');
  for(const f of (await readdir(migrations)).filter(f=>f.endsWith('.sql')&&Number(f.slice(0,4))<=limit).sort()){
   await db.batch(unstable_splitSqlQuery(await readFile(new URL(f,migrations),'utf8')).map(q=>db.prepare(q)));
   if(f.startsWith('0024'))await db.prepare("INSERT INTO feeds(feed_url,source_url,title,poll_interval_seconds,consecutive_failures,last_http_status,last_error,last_polled_at,created_at,updated_at) VALUES('https://orphan.example/feed','http://orphan.example/feed','Retained admission',900,3,503,'http_error',42,30,40)").run();
  }
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
  const catalog=root===currentRoot?'n_feed_catalog':'feeds';
  assert.deepEqual((await db.prepare(`SELECT feed_url,source_url FROM ${catalog} WHERE feed_url='${canonical}'`).all()).results,[{feed_url:canonical,source_url:source}]);
  await db.prepare(`UPDATE ${catalog} SET title='Preserved title',website_url='https://example.com/show'`).run();
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
  assert.deepEqual((await db.prepare('PRAGMA foreign_key_check').all()).results,[]);
  return {registration,orphan,enrolled,pending,accepted,quota,count,unsubscribe,deletion,requests,feed,membership};
 }finally{await mf.dispose();}
}
const current=await exercise(currentRoot,26);
assert.deepEqual(await exercise(currentRoot,25),current,'current binary must preserve the contract during expansion and after contraction');
if(process.env.OPENCAST_PREVIOUS_SCHEMA_WORKER_ROOT){
 const root=process.env.OPENCAST_PREVIOUS_SCHEMA_WORKER_ROOT.replace(/\/?$/,'/');
 assert.deepEqual(await exercise(root,24),current,'previous-schema public contract parity');
 assert.deepEqual(await exercise(root,25),current,'previous-schema binary remains compatible with expansion');
}
console.log('PASS catalog source/canonical identity and public registration/full-sync/admission/quota/unsubscribe/erasure responses; expansion/contraction and optional previous-schema binary parity');
