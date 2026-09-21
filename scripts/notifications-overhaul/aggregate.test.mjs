import test from 'node:test';
import assert from 'node:assert/strict';
import { project,resourceIDs } from './aggregate.mjs';
test('M01 queue-only price never masquerades as total infrastructure cost',()=>{
 const result=project({window_seconds:86400,resources:{queue_operations:288000*3},rates:{queue_operations:{usd_per_unit:0.4/1e6,remaining_included:1e6}}});
 assert.equal(result.total_usd,null);assert.equal(result.complete,false);assert.ok(Math.abs(result.known_subtotal_usd-9.968)<1e-8);assert.equal(result.review,'insufficient_data');
});
test('M02 all categories, shared allowance and review threshold',()=>{
 const resources=Object.fromEntries(resourceIDs.map(id=>[id,1000])),rates=Object.fromEntries(resourceIDs.map(id=>[id,{usd_per_unit:0.001,remaining_included:0}]));const result=project({window_seconds:86400,resources,rates});assert.equal(result.complete,true);assert.equal(result.review,'required');assert.equal(result.monthly_resources.r2_gb_month,1000);assert.equal(result.monthly_resources.worker_requests,30000);
 assert.throws(()=>project({window_seconds:0,resources,rates}));
});
