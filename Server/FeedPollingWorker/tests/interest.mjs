import assert from 'node:assert/strict';
import { harness,item,rss } from './harness.mjs';
import { POLLING_FIXTURE,stopAfter } from './action-boundary.mjs';
let version=1;
// One action per delivery (the loop stopped at its first boundary) up to the
// published, undrained observation whose continuation is then lost.
const h=await harness(()=>new Response(rss([item('base',h.now-100),...(version>1?Array.from({length:130},(_,i)=>item(`new-${i}`,h.now-10)):[])]),{headers:{etag:`"v${version}"`}}),{pollingBuild:POLLING_FIXTURE});
try {
  const feed=await h.add('https://interest.example.com/feed');
  await h.invoke('test/dispatch');await h.drain();
  version=2;await h.run('UPDATE n_feed SET due_at=?',h.now);
  await h.invoke('test/dispatch');
  let old;
  for(let i=0;i<50;i++){
    const wakes=await h.polls();old=wakes[0]??old;
    if((await h.first("SELECT COUNT(*) AS n FROM n_observation WHERE state='published' AND drain_complete=0")).n)break;
    for(const wake of wakes)await stopAfter(h,wake,1);
  }
  assert.equal((await h.first("SELECT candidate_count FROM n_observation WHERE state='published' ORDER BY generation DESC LIMIT 1")).candidate_count,130);
  assert.ok(old);
  // A new subscriber revision changes eligibility, not a published complete
  // observation. Simulate the exact revision the interest triggers use, then
  // lose the in-flight continuation so only the reservation can recover it.
  await h.run('UPDATE n_feed SET eligibility_generation=eligibility_generation+1,due_at=? WHERE feed_id=?',h.now,feed);
  await h.invoke('clock','301');await h.invoke('test/dispatch');
  const before=h.fetches.length;
  assert.notEqual((await stopAfter(h,old,1)).outcome,'obsolete','a retained continuation remains useful for the published drain');
  const wakes=await h.polls();assert.ok(wakes.length);
  assert.equal(wakes[0].generation,old.generation,'repair preserves the unsettled generation');
  await stopAfter(h,wakes[0],1);
  assert.equal(h.fetches.length,before,'finish published drain before another network scan');
  await h.drain();await h.deliver(true);
  assert.equal((await h.first('SELECT COUNT(*) AS n FROM n_event')).n,130);
  assert.equal((await h.first('SELECT COUNT(*) AS n FROM n_feed WHERE dispatch_until>0')).n,0);
  assert.equal(h.sends.length,1);assert.equal(h.sends[0].opencast.episode_count,130);
  console.log('PASS interest revision and a lost continuation resume the published drain, preserve complete burst membership, and cannot strand a new poll');
}finally {await h.instance.dispose();}

// An unsubscribe while the wakeup is queued leaves an ineligible feed holding
// a reservation nothing settles. /stats counts only
// the lapsed reservations of eligible feeds, so it is not read as stuck work.
const s=await harness(()=>new Response(rss([item('base',s.now-100)]),{headers:{etag:'"v1"'}}));
try {
  const retired=await s.add('https://retired.example.com/feed'),stuck=await s.add('https://stuck.example.com/feed');
  await s.invoke('test/dispatch');
  const wakes=await s.polls();assert.equal(wakes.length,2);
  await s.run("UPDATE feed_subscriptions SET notifications_enabled=0 WHERE feed_url='https://retired.example.com/feed'");
  assert.equal((await s.consume(wakes.find(wake=>wake.feed_id===retired))).status,200);
  // The other wakeup is lost. Both reservations lapse; neither is settled.
  await s.invoke('clock','301');
  assert.deepEqual((await s.rows('SELECT feed_id FROM n_feed WHERE dispatch_until>0 ORDER BY feed_id')).map(row=>row.feed_id),[retired,stuck].sort());
  assert.equal((await s.invoke('test/stats')).reservation_expired,1,'only the eligible feed whose wakeup was lost');
  await s.invoke('test/dispatch');
  assert.equal((await s.invoke('test/stats')).reservation_expired,0,'its repair leaves only the retired reservation, which is not counted');
  console.log('PASS a reservation lapsed by an unsubscribe while queued is not counted as an expired reservation');
}finally {await s.instance.dispose();}
