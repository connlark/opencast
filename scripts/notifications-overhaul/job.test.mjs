import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { H,canonicalJSON,payloadDigest } from './encoding.mjs';
import { Clock,T,FakeAPNs,Faults } from './fixtures.mjs';
import { JobModel,clientOwner,localSummary,foreground,deliveryStep } from './job-model.mjs';
const setup=(producer='ad_analysis')=>{const clock=new Clock(),m=new JobModel(clock);const ticket={producer,operation:'op',environment:'development',requester:'authorized-subject',expires:T+1800};const request={install:'install',operation:'op',producer,ticket};const i=m.issue(request);const binding={producer,environment:'development',requester:ticket.requester,run:'run-1'};return {clock,m,i,binding,request};};
test('W01 JSON-array identifiers and canonical UTF-8 envelope match pinned cross-language vectors',()=>{
 const wire=JSON.parse(readFileSync(new URL('./fixtures/wire.json',import.meta.url),'utf8'));
 for(const [name,vector] of Object.entries(wire.identifiers)) {
  assert.equal(JSON.stringify(vector.parts),vector.utf8,name);assert.equal(H(vector.parts),vector.sha256,name);
 }
 const vector=wire.payload_digest;
 assert.equal(canonicalJSON(vector.envelope),vector.canonical_utf8);
 assert.equal(payloadDigest(vector.envelope),vector.sha256);
 const reordered=Object.fromEntries(Object.entries(vector.envelope).reverse());
 reordered.data=Object.fromEntries(Object.entries(reordered.data).reverse());
 assert.equal(payloadDigest(reordered),vector.sha256);
 assert.equal(Object.hasOwn(vector.envelope.data,vector.omitted_optional_field),false);
 assert.notEqual(H(['a|b','c']),H(['a','b|c']));
 assert.notEqual(H(['é']),H(['e\u0301']));
 for(const value of [1.5,Number.MAX_SAFE_INTEGER+1,NaN,undefined,'\ud800']) assert.throws(()=>canonicalJSON(value));
});
test('J01 issuance retry, producer authorization ticket and stolen-grant binding',()=>{
 const {m,i,binding,request}=setup();assert.equal(m.issue(request),i);
 assert.throws(()=>m.issue({...request,install:'victim'},'attacker'),/unauthorized_install/);
 assert.throws(()=>m.accept(i,{...binding,requester:'other-account'}),/unauthorized_producer/);
 assert.throws(()=>m.issue({...request,ticket:null}),/ticket_invalid/);
 assert.throws(()=>m.issue({...request,producer:'chapters'}),/unsupported_producer/);
});
test('J02 wrong producer/environment, untrusted acceptance timestamp, grant replay',()=>{
 const {m,i,binding}=setup();for(const patch of [{producer:'remote_transcription'},{environment:'production'}]) assert.throws(()=>m.accept(i,{...binding,...patch}),/unauthorized/);
 assert.throws(()=>m.accept(i,binding,false),/unauthorized/);m.accept(i,binding);assert.equal(m.accept(i,binding),i);assert.throws(()=>m.accept(i,{...binding,run:'another-run'}),/grant_replay/);
});
test('J03 lost 202/attachment response and six-day registration outage',()=>{
 const {m,i,binding,clock}=setup();const acceptedAt=clock.now;clock.advance(6*86400);m.accept(i,{...binding,acceptedAt});assert.equal(m.accept(i,{...binding,acceptedAt}).run,'run-1');
});
test('J04 grant 30-minute and registration seven-day exclusive deadlines',()=>{
 const a=setup();a.clock.advance(1799);a.m.accept(a.i,a.binding);
 const b=setup();b.clock.advance(1800);assert.throws(()=>b.m.accept(b.i,b.binding),/expired/);
 const c=setup();c.clock.advance(604800);assert.throws(()=>c.m.accept(c.i,{...c.binding,acceptedAt:T}),/expired/);
});
test('J05 terminal before attach synthesizes same event and receipt; conflict rejected',()=>{
 const {m,i,binding}=setup();m.complete({run:'run-1'});assert.equal(m.event(i),null);m.accept(i,binding);const e=m.event(i);assert.equal(m.ingest(e),m.ingest(e));assert.throws(()=>m.ingest({...e,data:{...e.data,title:'different'}}),/event_conflict/);
});
test('J06 coalesced computation has independent authorized requesters and interests',()=>{
 const {m,i,binding,request}=setup();m.accept(i,binding);const j=m.issue({...request,install:'second',ticket:{...request.ticket,requester:'other-authorized'}});m.accept(j,{...binding,requester:'other-authorized'});m.complete({run:'run-1'});assert.notEqual(m.event(i).event_id,m.event(j).event_id);m.revoke(i);assert.equal(m.event(i),null);assert.ok(m.event(j));
});
test('J07 reused content fingerprint gets distinct immutable execution identity',()=>{
 const {m,i,binding,request}=setup();m.accept(i,binding);m.complete({run:'run-1'});const first=m.event(i);const j=m.issue({...request,operation:'op2',ticket:{...request.ticket,operation:'op2'}});m.accept(j,{...binding,run:'run-2'});m.complete({run:'run-2'});assert.notEqual(m.event(j).event_id,first.event_id);
});
test('J08 revoke/delete/seen before terminal and late registration never resurrect interest',()=>{
 for(const action of ['revoke','delete','seen']) {const {m,i,binding}=setup();if(action==='delete')m.delete(i.install);else m[action](i);if(action==='seen')m.accept(i,binding);else assert.throws(()=>m.accept(i,binding),/revoked/);m.complete({run:'run-1'});assert.equal(m.event(i),null);}
 const {m,i}=setup();assert.throws(()=>m.seen(i,'another'),/unauthorized/);assert.throws(()=>m.revoke(i,'another'),/unauthorized/);
});
test('J09 cancellation/supersession silent, one actionable failure, chain completion only',()=>{
 for(const outcome of ['cancelled','superseded']) {const {m,i,binding}=setup();m.accept(i,binding);m.complete({run:'run-1',outcome});assert.equal(m.event(i),null);}
 const {m,i,binding}=setup('remote_transcription');m.accept(i,binding);assert.equal(m.complete({run:'run-1',chainPending:true}),null);assert.equal(m.event(i),null);m.complete({run:'run-1',producer:'remote_transcription',outcome:'failed'});assert.equal(m.event(i).routing.operation_id,'op');assert.equal(m.ingest(m.event(i)),m.ingest(m.event(i)));
});
test('J10 six-hour delivery, 24-hour success, failure retry and grandfathered expiry',()=>{
 const {m,i,binding,clock}=setup();m.accept(i,binding);const run=m.complete({run:'run-1',billingPending:true});clock.advance(21600);assert.equal(m.event(i),null);assert.equal(m.tap(run),'fetch_authorized');clock.advance(64800);m.purge(run);assert.equal(m.tap(run),'unavailable_explicit_retry');assert.equal(run.billingPending,true);
 const failure=m.complete({run:'failed',outcome:'failed'});assert.equal(failure.resultExpires,clock.now+1800);
 const old=m.complete({run:'legacy',oldExpiry:clock.now+400});assert.equal(old.resultExpires,clock.now+400);
});
test('J11 remote seven-day retention; cached result before ack; billing/outbox survive',()=>{
 const {m,clock}=setup('remote_transcription');const run=m.complete({run:'run-1',producer:'remote_transcription',billingPending:true});assert.throws(()=>m.ack(run),/durably_imported/);run.localCached=true;m.ack(run);assert.equal(m.tap(run),'local');assert.equal(run.outbox,true);assert.equal(run.billingPending,true);
 const other=m.complete({run:'run-2',producer:'remote_transcription'});clock.advance(604799);assert.equal(m.tap(other),'fetch_authorized');clock.advance(1);m.purge(other);assert.equal(m.tap(other),'unavailable_explicit_retry');
});
test('J12 local/remote ownership persisted before submit; lost response keeps remote; old clients',()=>{
 assert.equal(clientOwner({optIn:true,setup:'uncertain'}),'remote');assert.equal(clientOwner({optIn:true,setup:'definite_failure'}),'local');assert.equal(clientOwner({optIn:true,capability:false}),'local');assert.equal(clientOwner({optIn:false}),'local');assert.equal(clientOwner({optIn:false,persistedOwner:'remote'}),'remote');assert.deepEqual(localSummary([{id:'a',owner:'remote'},{id:'b',owner:'local'},{id:'c',owner:'local',cancelled:true}]),['b']);
});
test('J13 foreground reconciliation, cold relaunch tap, denied setup and zero-feed install',()=>{
 assert.deepEqual(foreground({visibleOperation:'op',eventOperation:'op'}),{ingest:true,banner:false});assert.equal(foreground({visibleOperation:'other',eventOperation:'op'}).banner,true);
 const {m,i,binding}=setup();m.accept(i,binding);const run=m.complete({run:'run-1'});assert.ok(m.event(i));assert.equal(m.tap(JSON.parse(JSON.stringify(run))),'fetch_authorized');assert.equal(clientOwner({optIn:true,setup:'definite_failure'}),'local');
});
test('J14 acceptance crash/replay and post-expiry replay cannot renew event',()=>{
 const {m,i,binding,clock}=setup();m.accept(i,binding);m.complete({run:'run-1'});const event=m.event(i),fault=new Faults('after_accept');let receipt;assert.throws(()=>{receipt=m.ingest(event);fault.hit('after_accept');},/fault/);assert.equal(m.ingest(event),receipt);clock.advance(21600);assert.throws(()=>m.ingest(event),/expired/);
});
for(const [id,outcome,state] of [['A01',{status:200},'accepted'],['A02',{status:410},'permanent_failure'],['A03',{status:429},'pending'],['A04',{status:503},'pending'],['A05',{timeout:true},'uncertain'],['A06',{lostResponse:true},'uncertain'],['A07',{status:403},'pending'],['A08',{status:400},'permanent_failure']]) test(`${id} APNs ${JSON.stringify(outcome)}`,()=>{
 const d={id:'d',collapse:'stable',expires:T+21600,state:'pending'},endpoint={enabled:true,generation:1,registeredAt:T-10},apns=new FakeAPNs(outcome),clock=new Clock();assert.equal(deliveryStep(d,endpoint,apns,clock),state);if(outcome.status===403)assert.equal(d.pauseLane,true);if(outcome.lostResponse){assert.equal(apns.accepted.length,1);deliveryStep(d,endpoint,apns,clock);assert.equal(apns.requests[0].collapse,apns.requests[1].collapse);assert.equal(apns.requests[0].expiration,apns.requests[1].expiration);}
});
test('A09 token rotation during send and an older 410 cannot invalidate replacement',()=>{
 const clock=new Clock(),d={id:'d',collapse:'same',expires:T+100,state:'pending'},endpoint={enabled:true,generation:1,registeredAt:T};const apns={send(){endpoint.generation=2;return {status:410,timestamp:T-1};}};deliveryStep(d,endpoint,apns,clock);assert.equal(endpoint.enabled,true);assert.equal(d.state,'pending');
});
test('A10 kill switch, opt-out, expiry and durable acceptance prevent new sends',()=>{
 const clock=new Clock(),endpoint={enabled:true,generation:1},apns=new FakeAPNs(),d={id:'d',collapse:'same',expires:T+100,state:'pending'};deliveryStep(d,endpoint,apns,clock,{enabled:false});assert.equal(apns.requests.length,0);deliveryStep(d,endpoint,apns,clock);deliveryStep(d,endpoint,apns,clock);assert.equal(apns.requests.length,1);
 const e={...d,state:'pending'};clock.advance(100);assert.equal(deliveryStep(e,endpoint,apns,clock),'expired');assert.equal(apns.requests.length,1);assert.equal(deliveryStep({...d,state:'pending',expires:T+200},endpoint,apns,clock,{eligible:false}),'suppressed');
});

test('J15 explicit attachment rejection seals remote work; uncertain/mismatched responses cannot enable local',()=>{
 const {m,i,binding}=setup();
 const owner=attachment=>clientOwner({optIn:true,persistedOwner:'remote',attachment,operation:i.operation,interestId:i.id,generation:i.generation});
 assert.throws(()=>m.decline(i,{...binding,requester:'attacker'}),/unauthorized/);
 assert.equal(owner(m.decline(i,binding,{mayHaveRegistered:true})),'remote');
 const rejected=m.decline(i,binding);assert.equal(owner(rejected),'local');assert.equal(i.reason,'attachment_rejected');
 assert.equal(owner({...rejected,interest_generation:2}),'remote');assert.equal(owner(undefined),'remote');
 assert.throws(()=>m.accept(i,binding),/revoked/);m.complete({run:binding.run});assert.equal(m.event(i),null);
 const b=setup();b.m.accept(b.i,b.binding);assert.equal(b.m.decline(b.i,b.binding).state,'pending');
 assert.equal(b.m.decline(b.i,b.binding,{safeSuppressionReceipt:true}).state,'rejected');b.m.complete({run:b.binding.run});assert.equal(b.m.event(b.i),null);
});
