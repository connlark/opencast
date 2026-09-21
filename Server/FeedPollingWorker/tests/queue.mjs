import assert from 'node:assert/strict';
import { setTimeout } from 'node:timers/promises';
import { harness, item, rss } from './harness.mjs';
let version=1,fail=0;
const h=await harness(()=>new Response(rss([item('base',h.now-100),...(version===2?[item('released',h.now-1)]:[])]),{headers:{etag:`"v${version}"`}}),{realQueues:true});
async function settle(){for(let i=0;i<600;i++){if((await h.first('SELECT COUNT(*) AS n FROM n_feed WHERE dispatch_until>0')).n===0)return;await setTimeout(100);}throw Error('real queue did not finish');}
try{
  const feed=await h.add('https://queue.example.com/feed');
  await h.invoke('test/dispatch');await settle();
  assert.equal((await h.first('SELECT observation_generation FROM n_feed WHERE feed_id=?',feed)).observation_generation,1);
  version=2;await h.run('UPDATE n_feed SET due_at=? WHERE feed_id=?',h.now,feed);
  await h.invoke('test/dispatch');await settle();await h.deliver(true);
  // The first on-phase slot may fall inside the early-admission window.
  assert.equal(h.sends.length,1);assert.ok(h.fetches.length>=2&&h.fetches.length<=3);
  console.log('PASS native Queue sendBatch, actual consumer adapter, chained resumable steps and compatible APNs');

  // The real consumer retries a failed delivery and acknowledges only after
  // the fenced commit: one crash, one redelivery, one logical poll.
  await h.run('UPDATE n_feed SET due_at=? WHERE feed_id=?',h.now,feed);
  await h.invoke('fault','before_settle');await h.invoke('test/dispatch');await settle();
  assert.equal((await h.first('SELECT last_poll_outcome FROM n_feed WHERE feed_id=?',feed)).last_poll_outcome,'unchanged');
  assert.ok((await h.invoke('test/stats')).redelivery_total>=1,'the Queue redelivered the unacknowledged message');
  assert.equal(h.sends.length,1,'redelivery sends nothing again');
  assert.equal((await h.first('SELECT COUNT(*) AS n FROM n_event')).n,1);
  console.log('PASS unacknowledged delivery is redelivered by the Queue and finishes without a duplicate event or send');
  // Three retries, then the dead-letter consumer settles the generation into
  // a bounded backoff. The message is dropped; the feed row recovers later.
  await h.run('UPDATE n_feed SET due_at=? WHERE feed_id=?',h.now,feed);
  await h.invoke('fault','always:before_settle');await h.invoke('test/dispatch');
  for(let i=0;i<300&&(await h.first('SELECT handling_failures FROM n_feed WHERE feed_id=?',feed)).handling_failures===0;i++)await setTimeout(100);
  await h.invoke('fault','none');
  const parked=await h.first('SELECT handling_failures,poll_failures,retry_at,dispatch_until,last_poll_outcome FROM n_feed WHERE feed_id=?',feed);
  assert.deepEqual([parked.handling_failures,parked.poll_failures,parked.dispatch_until,parked.last_poll_outcome],[1,0,0,'dead_letter']);
  assert.ok(parked.retry_at>=h.now+295);
  const stats=await h.invoke('test/stats');
  assert.ok(stats.dead_letter_total>=1&&stats.handling_failure_total>=4&&stats.redelivery_total>=4,JSON.stringify(stats));
  await h.invoke('test/dispatch');await setTimeout(500);
  assert.equal((await h.first('SELECT dispatch_until FROM n_feed WHERE feed_id=?',feed)).dispatch_until,0,'no hot loop while backing off');
  assert.equal(h.sends.length,1);
  console.log('PASS real Queue exhausts three retries into the dead-letter consumer, which backs the feed off without a hot loop');
  assert.equal((await h.first("SELECT COUNT(*) AS n FROM sqlite_master WHERE name='n_poll'")).n+(await h.first("SELECT COUNT(*) AS n FROM sqlite_master WHERE name='n_origin_permit'")).n,0);
}finally{await h.instance.dispose();}
