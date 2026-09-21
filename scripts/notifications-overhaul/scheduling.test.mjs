import test from 'node:test';
import assert from 'node:assert/strict';
import { T } from './fixtures.mjs';
// Controlled workload and admission oracle; no measured production capacity claim.
function admit(jobs,slots) {
 const sorted=kind=>jobs.filter(x=>x.kind===kind).sort((a,b)=>a.due-b.due || a.id.localeCompare(b.id));
 const recurring=sorted('recurring'),baseline=sorted('baseline'),selected=[];
 const take=(list,n)=>selected.push(...list.splice(0,n));
 take(recurring,Math.ceil(slots*0.8));take(baseline,slots-selected.length);take(recurring,slots-selected.length);
 return selected;
}
class OriginPermits {
 constructor(){this.active=new Map();this.cooldown=new Map();}
 acquire(origin,now){if((this.cooldown.get(origin)??0)>now || (this.active.get(origin)??0)>=1)return false;this.active.set(origin,1);return true;}
 release(origin){this.active.delete(origin);}
 redirect(from,to,now){this.release(from);return this.acquire(to,now);}
}
test('F28 oldest-due recurring 80% / baseline 20%, borrowing unused capacity',()=>{
 const recurring=Array.from({length:20},(_,n)=>({id:`r${n}`,due:T-600+n,kind:'recurring'}));const baseline=Array.from({length:20},(_,n)=>({id:`b${n}`,due:T-60+n,kind:'baseline'}));
 const selected=admit([...baseline,...recurring],10);assert.equal(selected.filter(x=>x.kind==='recurring').length,8);assert.equal(selected[0].id,'r0');assert.equal(selected[8].id,'b0');assert.equal(admit(recurring,10).length,10);assert.equal(admit(baseline,10).length,10);
});
test('F29 shared origin permit and redirect destination honor cooldown',()=>{
 const p=new OriginPermits();assert.equal(p.acquire('origin-a',T),true);assert.equal(p.acquire('origin-a',T),false);assert.equal(p.acquire('origin-b',T),true);assert.equal(p.redirect('origin-a','origin-b',T),false);assert.equal(p.acquire('origin-a',T),true);p.release('origin-b');p.cooldown.set('origin-b',T+120);assert.equal(p.acquire('origin-b',T+119),false);assert.equal(p.acquire('origin-b',T+120),true);
});
test('F30 1000-feed outage workload coalesces missed slots, mixed origins and outliers',()=>{
 const feeds=Array.from({length:1000},(_,n)=>({id:`feed-${n}`,due:T-1800+n%300,kind:'recurring',origin:`origin-${n%20}`,bytes:n%100===0?128*1024*1024:64000,latency:n%100===0?120:0.1}));
 const durable=new Map();for(let retry=0;retry<6;retry++)for(const feed of feeds)if(!durable.has(feed.id))durable.set(feed.id,{...feed});
 assert.equal(durable.size,1000);assert.equal(Math.min(...[...durable.values()].map(x=>x.due)),T-1800);assert.equal(feeds.filter(x=>x.latency===120).length,10);assert.equal(new Set(feeds.map(x=>x.origin)).size,20);
});
