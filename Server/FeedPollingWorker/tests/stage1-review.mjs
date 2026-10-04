// Packaged-runtime regressions for the independent Stage 1 review.
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { harness,item,rss } from './harness.mjs';

const h=await harness(request=>request.headers.has('if-none-match')
  ? new Response(null,{status:304})
  : new Response(rss([item('base',h.now-100)]),{headers:{etag:'"v1"'}}));
try {
  // Redelivery statistics do not own the pre-existing scan lease. Inject an
  // error and cancellation before work starts; neither may release that lease.
  const feed=await h.add('https://lease.example.com/feed');
  await h.invoke('test/dispatch');const [wake]=await h.polls();
  const lease=randomUUID();await h.run('UPDATE n_feed SET lease_id=?,lease_until=? WHERE feed_id=?',lease,h.now+180,feed);
  const held=await h.first('SELECT lease_id,lease_until,last_poll_at,last_poll_outcome FROM n_feed WHERE feed_id=?',feed);
  await h.run("CREATE TRIGGER reject_redelivery_stat BEFORE INSERT ON n_poll_stat WHEN NEW.redeliveries>0 BEGIN SELECT RAISE(ABORT,'fixture:redelivery_stat'); END");
  const requests=h.fetches.length;
  assert.equal((await h.consume(wake,{attempts:2})).status,500);
  assert.deepEqual(await h.first('SELECT lease_id,lease_until,last_poll_at,last_poll_outcome FROM n_feed WHERE feed_id=?',feed),held);
  assert.equal(h.fetches.length,requests);
  await h.run('DROP TRIGGER reject_redelivery_stat');
  await h.invoke('fault','hang_redelivery_stat');
  const execution=randomUUID();
  const pending=h.consume(wake,{attempts:2,headers:{'x-test-execution':execution}});
  for(let i=0;i<100&&(await h.invoke('fault-state'))!=='redelivery_stat_active';i++)await new Promise(resolve=>setTimeout(resolve,10));
  assert.equal(await h.invoke('fault-state'),'redelivery_stat_active');
  await h.invoke('abort',execution);
  assert.equal((await pending).status,503);
  assert.deepEqual(await h.first('SELECT lease_id,lease_until,last_poll_at,last_poll_outcome FROM n_feed WHERE feed_id=?',feed),held);
  await h.invoke('release-hang');
  console.log('PASS failed/cancelled redelivery bookkeeping preserves another invocation\'s live lease and feed outcome');

  // A non-bookkeeping error before acquiring a lease must also preserve the
  // competing lease. Force the step backstop, after its fence is installed.
  assert.equal((await h.consume({...wake,step:5000})).status,500);
  assert.deepEqual(await h.first('SELECT lease_id,lease_until FROM n_feed WHERE feed_id=?',feed),{lease_id:lease,lease_until:held.lease_until});
  console.log('PASS step failure releases only a lease attempted by its own invocation');

  // The delayed continuation arrives at its ready time: all its age is
  // intentional, so it cannot enter the initial-admission wait distribution.
  await h.invoke('freeze',String(h.now));
  assert.equal((await h.consume(wake)).outcome,'scan_held');
  await h.invoke('freeze',String(h.now+180));const [delayed]=await h.polls();
  assert.equal(delayed.step,1);
  assert.equal((await h.consume(delayed,{headers:{'x-poll-enqueued-ms':String(h.now*1000)}})).status,200);
  const delayedLog=(await h.invoke('metrics')).deliveries.at(-1);
  assert.equal(delayedLog.message_age_ms,180000);assert.equal(delayedLog.initial_queue_wait_ms,null);
  assert.equal(delayedLog.due_lag_seconds,180);
  assert.equal(Object.hasOwn(delayedLog,'queue_wait_ms'),false);

  // A known sampled unchanged success retains its per-poll schedule lag.
  const generation=64-(parseInt(feed.slice(0,8),16)%64);
  await h.run('UPDATE n_feed SET due_at=?,dispatch_until=?,schedule_generation=? WHERE feed_id=?',h.now,h.now+600,generation,feed);
  const sampleWake={...wake,generation,due_at:h.now};
  const before=(await h.invoke('metrics')).deliveries.length;
  assert.equal((await h.consume(sampleWake,{headers:{'x-poll-enqueued-ms':String((h.now+179)*1000)}})).outcome,'not_modified');
  const sample=(await h.invoke('metrics')).deliveries.at(-1);
  assert.equal((await h.invoke('metrics')).deliveries.length,before+1);
  assert.equal(sample.sample,64);assert.equal(sample.due_lag_seconds,180);assert.equal(sample.initial_queue_wait_ms,1000);
  console.log('PASS message age excludes planned delays from initial Queue wait; sampled unchanged success retains due lag');

  // Every exhausted run must still expire history/statistics. The clock fault
  // spends the object budget on a scratch delete without a 26-second sleep.
  await h.invoke('freeze','');
  const bucket=await h.instance.getR2Bucket('FEED_SNAPSHOTS','polling-runtime');
  for(let round=0;round<2;round++){
    const url=`https://retention-${round}.example.com/feed`,f=await h.add(url);
    await h.run('UPDATE n_feed SET due_at=?,dispatch_until=0 WHERE feed_id<>?',h.now+90*86400,f);
    await h.invoke('test/dispatch');await h.drain();
    assert.ok((await h.first('SELECT snapshot_key FROM n_feed WHERE feed_id=?',f)).snapshot_key);
    await h.run('UPDATE feed_subscriptions SET notifications_enabled=0 WHERE feed_url=?',url);
    await h.run('UPDATE n_feed SET no_interest_since=? WHERE feed_id=?',h.now-31*86400,f);
    const oldBucket=Math.floor(h.now/3600)-72-round;
    await h.run('INSERT INTO n_poll_stat(bucket,redeliveries) VALUES(?,1)',oldBucket);
    await bucket.put(`scratch/${f}/${randomUUID()}`,'crashed fixture');
    await h.invoke('clock',String(3700+round*120));await h.invoke('fault','cleanup_budget');
    await h.invoke('test/cleanup');
    assert.equal((await h.invoke('metrics')).cleanup.at(-1).budget_exhausted,true);
    assert.equal((await h.first('SELECT COUNT(*) AS n FROM n_poll_stat WHERE bucket=?',oldBucket)).n,0);
    assert.equal((await h.first('SELECT snapshot_key FROM n_feed WHERE feed_id=?',f)).snapshot_key,null);
    await h.invoke('clock','0');
  }
  console.log('PASS repeated scratch budget exhaustion does not starve bounded history or statistic retention');
} finally {await h.instance.dispose();}

// No persisted origin_key is necessary, including root/query/IPv6 URLs.
// New and already reserved URLs must share exactly the same authority grouping.
const origins=await harness(()=>new Response('unused'));
try {
  const now=origins.now;await origins.invoke('freeze',String(now));
  for(let i=0;i<230;i++){
    const url=i===0?'https://crowded.example.com':i%2?`https://crowded.example.com?item=${i}/x`:`https://crowded.example.com/path-${i}`;
    const f=await origins.add(url,now-60);
    // Both classes compete for the same origin occupancy in the combined
    // atomic reservation, despite having independent candidate selections.
    if(i<120)await origins.run("UPDATE n_feed SET snapshot_key='fixture-recurring',baseline_at=? WHERE feed_id=?",now-100,f);
  }
  const others=[];
  for(const url of ['https://fresh.example.com','https://fresh.example.com?path=/x','http://fresh.example.com','https://fresh.example.com:8443','https://[2001:db8::1]?x=/'])others.push(await origins.add(url,now));
  await Promise.all([origins.invoke('test/dispatch'),origins.invoke('test/dispatch')]);
  const first=await origins.polls();assert.equal(first.length,105);assert.equal(new Set(first.map(w=>w.feed_id)).size,105);
  for(const feed of others)assert.ok(first.some(w=>w.feed_id===feed));
  // A saturated origin has both known and unknown-origin rows, neither of
  // which may hide this later origin behind a truncated candidate list.
  const later=await origins.add('https://later.example.com/feed',now+90);
  await origins.invoke('freeze',String(now+60));await origins.invoke('test/dispatch');
  assert.deepEqual((await origins.polls()).map(w=>w.feed_id),[later]);
  assert.equal((await origins.first("SELECT COUNT(*) AS n FROM n_feed WHERE canonical_url LIKE 'https://crowded.example.com%' AND dispatch_until>?",now+60)).n,100);
  console.log('PASS unknown-origin burst, overlapping reservations and later-origin admission without cap borrowing');
} finally {await origins.instance.dispose();}
