import test from 'node:test';
import assert from 'node:assert/strict';
import { createGunzip } from 'node:zlib';
import { Clock,T,episode,feedCases,rssChunks,rssStream,catalog } from './fixtures.mjs';
import { FeedModel,cadence,retryAfter,planCandidates } from './feed-model.mjs';
for(const scenario of feedCases) test(`${scenario.id} ${scenario.name}`,()=>{
 const model=new FeedModel(new Clock());
 if(!scenario.initial) model.scan(scenario.baseline,{initial:true});
 const before=model.generation;
 const decisions=model.scan(scenario.items,scenario);
 assert.deepEqual([...model.events.keys()].sort(),[...scenario.events].sort());
 assert.deepEqual([...model.pending.keys()],scenario.pending??[]);
 if(scenario.reason) assert.ok(decisions.some(x=>x.reason===scenario.reason));
 if(scenario.fault || scenario.status===304) assert.equal(model.generation,before);
 if(scenario.group) { const presentations=model.presentation(model.events.values()); assert.equal(presentations.length,1); assert.equal(presentations[0].members.length,5); }
 assert.ok([...rssChunks(scenario.items,{invalidTail:scenario.fault==='invalid_tail'})].join('').startsWith('<rss'));
});
test('F21 pending future release keeps original deadline; withdrawal before eligibility is silent',()=>{
 const c=new Clock(),m=new FeedModel(c); m.scan([episode('old')],{initial:true}); m.scan([episode('future',T+3600)]); c.advance(3600);m.releaseDue();assert.equal(m.events.get('future').expires,T+3600+86400);m.scan([]);assert.equal(m.events.size,1);
 const withdrawn=new FeedModel(new Clock());withdrawn.scan([],{initial:true});withdrawn.scan([episode('future',T+3600)]);withdrawn.scan([]);withdrawn.clock.advance(3600);withdrawn.releaseDue();assert.equal(withdrawn.events.size,0);
});
test('F22 removed and returned identities remain seen; overlapping old owner cannot publish',()=>{
 const m=new FeedModel(new Clock());m.scan([episode('old')],{initial:true});m.scan([]);m.scan([episode('old')]);assert.equal(m.events.size,0);m.epoch++;m.scan([episode('new')],{epoch:1});assert.equal(m.events.size,0);m.scan([episode('new')]);assert.equal(m.events.size,1);
});
test('F23 subscriber activation, undated absence, opt-out, resubscribe and deletion',()=>{
 const c=new Clock(),m=new FeedModel(c);m.scan([],{initial:true});c.advance(10);m.scan([episode('dated',T+5),episode('undated',null)]);
 const i={enabled:true,activated:T,absenceAt:T,generation:1,deliveryGeneration:1};
 for(const e of m.events.values()) assert.equal(m.recipient(e,i),true);
 assert.equal(m.recipient(m.events.get('dated'),{...i,activated:T+6}),false);
 assert.equal(m.recipient(m.events.get('undated'),{...i,absenceAt:null,activated:T+1}),false);
 for(const patch of [{enabled:false},{deleted:true},{generation:2},{activated:T+20}]) assert.equal(m.recipient(m.events.get('undated'),{...i,...patch}),false);
});
test('F24 partial retries preserve first observation and do not renew eligibility',()=>{
 const c=new Clock(),m=new FeedModel(c);m.scan([],{initial:true});m.scan([episode('new',null)],{fault:'cancel'});c.advance(600);m.scan([episode('new',null)]);assert.equal(m.events.get('new').first,T);assert.equal(m.events.get('new').expires,T+86400);
});
test('F25 active weekly/monthly, unknown probation, dormant tiers and reactivation',()=>{
 for(const days of [7,30,90]) assert.equal(cadence({now:T,created:T-700000,lastCredible:T-days*86400}),300);
 assert.equal(cadence({now:T,created:T-100,lastCredible:null}),300);
 assert.equal(cadence({now:T,created:T-700000,lastCredible:null}),1800);
 assert.equal(cadence({now:T,created:T-400*86400,lastCredible:T-400*86400}),3600);
 assert.equal(cadence({now:T,created:T-400*86400,lastCredible:T}),300);
 assert.equal(cadence({now:T,created:T-400*86400,lastCredible:T-120*86400,cadenceSeconds:70*86400,credibleGaps:3}),300);
});
test('F26 Retry-After seconds/date and malformed value have deterministic clock',()=>{
 assert.equal(retryAfter('120',T),T+120);assert.equal(retryAfter(new Date((T+300)*1000).toUTCString(),T),T+300);assert.equal(retryAfter('nonsense',T),T+60);
});
test('F27 generated 100000-item gzip fixture streams; model keeps more than 4096 identities',async()=>{
 let count=0,tail='',bytes=0;
 for await(const chunk of rssStream(catalog(100000),{gzip:true}).pipe(createGunzip())) {const text=tail+chunk.toString();const pieces=text.split('</item>');count+=pieces.length-1;tail=pieces.at(-1);bytes+=chunk.length;}
 assert.equal(count,100000);assert.ok(tail.endsWith('</channel></rss>'));assert.ok(bytes>10000000);
 const m=new FeedModel(new Clock());m.scan([...catalog(4097)],{initial:true});m.scan([episode('page-two')]);m.scan([episode('catalog-0')]);assert.equal(m.history.size,4098);assert.deepEqual([...m.events.keys()],['page-two']);
});
test('F31 catalog-scale churn/backfill creates aggregate counts and zero D1 candidates',()=>{
 const m=new FeedModel(new Clock()),items=[...catalog(100000)];
 assert.equal(planCandidates(m.scan(items,{initial:true})).d1Rows.length,0);
 const churn=planCandidates(m.scan(items.map(item=>({...item,id:`changed-${item.id}`}))));
 assert.equal(churn.counts.identity_churn,100000);assert.equal(churn.candidateCount,0);assert.equal(churn.d1Rows.length,0);
 const stale=planCandidates(m.scan(items.map(item=>episode(`archive-${item.id}`,T-259201))));
 assert.equal(stale.counts.stale,100000);assert.equal(stale.d1Rows.length,0);
});
test('F32 D1 candidate ceiling spills genuine bulk releases without losing group members or deadlines',()=>{
 for(const count of [1000,1001,5001]) {
  const m=new FeedModel(new Clock());m.scan([],{initial:true});
  const plan=planCandidates(m.scan(Array.from({length:count},(_,n)=>episode(`bulk-${n}`,null))));
  assert.equal(plan.storage,count>1000?'r2':'d1');assert.ok(plan.d1Rows.length<=1000);
  assert.equal(plan.d1Rows.length+plan.r2Records.length,count);
  const group=m.presentation(m.events.values());assert.equal(group.length,1);assert.equal(new Set(group[0].members).size,count);
  assert.ok([...m.events.values()].every(event=>event.expires===T+86400));
 }
});
test('F33 fenced validator-matched 304 establishes undated absence for already-active interests',()=>{
 const c=new Clock(),m=new FeedModel(c);m.scan([episode('old',null)],{initial:true});c.advance(10);
 const interest={enabled:true,activated:T+10,absenceAt:null,generation:1,deliveryGeneration:1};c.advance(10);
 const request={requestValidator:'"validated"',expectedGeneration:1,startedAt:T+20,interests:[interest]};
 for(const bad of [{requestValidator:null},{requestValidator:'"different"'},{expectedGeneration:0},{epoch:0}]) {assert.equal(m.notModified({...request,...bad}),false);assert.equal(interest.absenceAt,null);}
 const later={...interest,activated:T+21};assert.equal(m.notModified({...request,interests:[interest,later]}),true);
 assert.equal(interest.absenceAt,T+20);assert.equal(later.absenceAt,null);assert.equal(m.generation,1);
 c.advance(10);m.scan([episode('old',null),episode('new',null)]);assert.equal(m.recipient(m.events.get('new'),interest),true);assert.equal(m.events.has('old'),false);
 const cold=new FeedModel(c);assert.equal(cold.notModified({...request,expectedGeneration:0}),false);
});
