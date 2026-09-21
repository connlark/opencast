import assert from 'node:assert/strict';
import { harness, item, rss } from './harness.mjs';
let version=1;
const h=await harness(()=>new Response(rss([item('base',h.now-100),...(version>1?[item('future',h.now+3600)]:[])]),{headers:{etag:`"v${version}"`}}));
try{
  const feed=await h.add('https://future.example.com/feed');
  await h.invoke('test/dispatch');await h.drain();
  version=2;await h.run('UPDATE n_feed SET due_at=?',h.now);await h.invoke('test/dispatch');await h.drain();
  assert.equal((await h.first("SELECT COUNT(*) AS n FROM n_episode_release WHERE state='pending_future'")).n,1);
  // The publisher is backing off and not due. Maintenance is admitted from
  // durable work alone, so neither can hold a matured future release hostage.
  await h.run('UPDATE n_feed SET due_at=?,retry_at=?,poll_failures=4',h.now+7200,h.now+7200);
  const requests=h.fetches.length;
  await h.invoke('clock','3601');
  const delivery=await h.instance.getWorker('delivery-runtime');await(await delivery.fetch('https://delivery.invalid/clock',{method:'POST',body:'3601'})).text();
  await h.invoke('test/dispatch');await h.drain();await h.deliver(true);
  assert.equal(h.fetches.length,requests);
  assert.equal(h.sends.length,1);
  const event=await h.first('SELECT eligible_at,expires_at FROM n_event');
  assert.equal(event.eligible_at,h.now+3600);assert.equal(event.expires_at,h.now+3600+86400);
  assert.deepEqual(await h.first('SELECT due_at,retry_at,poll_failures,dispatch_until FROM n_feed WHERE feed_id=?',feed),{due_at:h.now+7200,retry_at:h.now+7200,poll_failures:4,dispatch_until:0});
  // Repeat maintenance for a dead-lettered feed with a pending source receipt.
  await h.run('UPDATE n_feed SET handling_failures=3 WHERE feed_id=?',feed);
  await h.run("UPDATE n_outbox SET state='pending',next_attempt_at=0");
  await h.invoke('test/dispatch');await h.drain();
  assert.equal((await h.first("SELECT COUNT(*) AS n FROM n_outbox WHERE state='pending'")).n,0);
  assert.equal(h.fetches.length,requests);
  assert.deepEqual(await h.first('SELECT retry_at,poll_failures,handling_failures,dispatch_until FROM n_feed WHERE feed_id=?',feed),{retry_at:h.now+7200,poll_failures:4,handling_failures:3,dispatch_until:0});
  console.log('PASS future/outbox maintenance bypasses publisher retry and dead-letter backoff, preserves their state and the fixed expiry, and never fetches RSS');

  // Exercise the actual dispatch share without depending on the fixture's
  // arbitrary network or preparation timing. These messages are not consumed.
  for(let i=0;i<1000;i++){
    const id=await h.add(`https://fair-${i%20}.example.com/${i}`,h.now+3601);
    if(i<500)await h.run("UPDATE n_feed SET snapshot_key='fixture-recurring',baseline_at=? WHERE feed_id=?",h.now-100,id);
  }
  await h.invoke('test/dispatch');
  const wakes=await h.polls();
  const classes=await h.rows("SELECT (f.snapshot_key IS NULL) AS baseline,COUNT(*) AS n FROM n_feed f WHERE f.feed_id IN(SELECT json_extract(value,'$.feed_id') FROM json_each(?)) GROUP BY baseline ORDER BY baseline",JSON.stringify(wakes));
  assert.deepEqual(classes,[{baseline:0,n:320},{baseline:1,n:80}]);
  assert.equal(new Set(wakes.map(w=>w.feed_id)).size,400,'one live generation per feed');
  assert.equal((await h.first('SELECT COUNT(*) AS n FROM n_feed WHERE dispatch_until>?',h.now+3601)).n,400);
  await h.invoke('test/dispatch');assert.equal(new Set([...(await h.polls()).map(w=>w.feed_id),...wakes.map(w=>w.feed_id)]).size,800,'a reserved feed is not admitted again');
  console.log('PASS recurring/baseline 80/20 admission with one reservation per feed and no job rows');
  assert.equal((await h.first("SELECT COUNT(*) AS n FROM sqlite_master WHERE name='n_poll'")).n,0);
}finally{await h.instance.dispose();}
