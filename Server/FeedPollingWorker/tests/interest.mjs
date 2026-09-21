import assert from 'node:assert/strict';
import { harness,item,rss } from './harness.mjs';
let version=1;
const h=await harness(()=>new Response(rss([item('base',h.now-100),...(version>1?Array.from({length:130},(_,i)=>item(`new-${i}`,h.now-10)):[])]),{headers:{etag:`"v${version}"`}}));
try {
  const feed=await h.add('https://interest.example.com/feed');
  await h.invoke('test/dispatch');await h.drain();
  version=2;await h.run('UPDATE n_feed SET due_at=?',h.now);
  await h.invoke('test/dispatch');
  let old;
  for(let i=0;i<50;i++){
    const wakes=await h.polls();old=wakes[0]??old;
    if((await h.first("SELECT COUNT(*) AS n FROM n_observation WHERE state='published' AND drain_complete=0")).n)break;
    for(const wake of wakes)await h.consume(wake);
  }
  assert.equal((await h.first("SELECT candidate_count FROM n_observation WHERE state='published' ORDER BY generation DESC LIMIT 1")).candidate_count,130);
  assert.ok(old);
  // A new subscriber revision changes eligibility, not a published complete
  // observation. Simulate the exact revision the interest triggers use, then
  // lose the in-flight continuation so only the reservation can recover it.
  await h.run('UPDATE n_feed SET eligibility_generation=eligibility_generation+1,due_at=? WHERE feed_id=?',h.now,feed);
  await h.invoke('clock','301');await h.invoke('test/dispatch');
  assert.equal((await h.consume(old)).outcome,'obsolete','the superseded generation is fenced');
  const before=h.fetches.length;
  const wakes=await h.polls();assert.ok(wakes.length);
  await h.consume(wakes[0]);
  assert.equal(h.fetches.length,before,'finish published drain before another network scan');
  await h.drain();await h.deliver(true);
  assert.equal((await h.first('SELECT COUNT(*) AS n FROM n_event')).n,130);
  assert.equal((await h.first('SELECT COUNT(*) AS n FROM n_feed WHERE dispatch_until>0')).n,0);
  assert.equal(h.sends.length,1);assert.equal(h.sends[0].opencast.episode_count,130);
  console.log('PASS interest revision and a lost continuation resume the published drain, preserve complete burst membership, and cannot strand a new poll');
}finally {await h.instance.dispose();}
