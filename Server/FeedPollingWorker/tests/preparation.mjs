import assert from 'node:assert/strict';
import { harness,item,rss } from './harness.mjs';
let version=1;
const h=await harness(()=>new Response(rss([...Array.from({length:100},(_,i)=>item(`episode-${i}`,h.now-100-i)),...(version>1?[item('backfill',h.now-4*86400)]:[])]),{headers:{etag:`"v${version}"`}}));
try {
  const feed=await h.add('https://preparation.example.com/feed');
  await h.invoke('test/dispatch');await h.drain();
  version=2;await h.run('UPDATE n_feed SET due_at=?',h.now);await h.invoke('test/dispatch');
  for(const wake of await h.polls())assert.equal((await h.consume(wake)).outcome,'staged');
  assert.equal((await h.first("SELECT COUNT(*) AS n FROM n_observation WHERE state='staging' AND valid_eof=1")).n,1);
  const requests=h.fetches.length;
  await h.run("UPDATE n_observation SET processing_failures=9 WHERE state='staging' AND valid_eof=1");
  await h.invoke('fault','before_put');await h.drain();
  assert.equal((await h.first("SELECT COUNT(*) AS n FROM n_observation WHERE state='abandoned' AND processing_failures=10")).n,1);
  assert.equal((await h.first('SELECT lease_id FROM n_feed WHERE feed_id=?',feed)).lease_id,null);
  // The Queue redelivers the failed step. Its poisoned preparation is gone,
  // so the same generation rescans once rather than waiting for an operator.
  assert.equal(h.fetches.length,requests+1);
  assert.equal((await h.first('SELECT observation_generation FROM n_feed WHERE feed_id=?',feed)).observation_generation,2);
  assert.equal((await h.first('SELECT COUNT(*) AS n FROM n_event')).n,0);
  console.log('PASS a poisoned valid-EOF preparation retains recovery evidence, releases its lease and permits a fresh quiet scan');
}finally {await h.instance.dispose();}
