import assert from 'node:assert/strict';
import { harness, item, rss } from './harness.mjs';

// A cancelled Queue invocation is never polled again, so the scan permits it
// owns stay held; the hung R2 read stands in for it. That message's redelivery
// frees them on whichever route it takes, including an obsolete wake or an idle
// settle that never asks for a permit of its own.
let behavior;
const h = await harness(request => behavior(request));
const v1 = () => new Response(rss([item('base', h.now - 100)]), { headers: { etag: '"v1"' } });
const v2 = () => new Response(rss([item('base', h.now - 100), item('new', h.now - 20)]), { headers: { etag: '"v2"' } });
const wakeFor = async feed => (await h.polls()).filter(wake => wake.feed_id === feed);
let pending;

async function hung(url, id) {
  behavior = v1;
  const feed = await h.add(url);
  await h.invoke('test/dispatch');
  const [baseline] = await wakeFor(feed);
  assert.equal((await h.consume(baseline)).status, 200);
  await h.run('UPDATE n_feed SET due_at=0,dispatch_until=0 WHERE feed_id=?', feed);
  behavior = v2;
  await h.invoke('test/dispatch');
  const [wake] = await wakeFor(feed);
  const headers = { 'x-poll-message-id': id };
  await h.invoke('fault', 'hang_get');
  pending = h.consume(wake, { headers }).catch(error => ({ status: 0, error }));
  for (let i = 0; i < 500; i++) {
    if ((await h.invoke('test/stats')).active_permits === 2 && (await h.invoke('fault-state')) === 'hang_get_active') break;
    await new Promise(resolve => setTimeout(resolve, 10));
  }
  const before = await h.invoke('test/stats');
  assert.equal(before.active_permits, 2, 'the hung read owns both permits');
  return { feed, wake, headers, before };
}
async function release() {
  await h.invoke('release-hang');
  await pending;
  pending = undefined;
}

try {
  const obsolete = await hung('https://obsolete.example.com/feed', 'redelivery-obsolete');
  await h.run('UPDATE n_feed SET schedule_generation=schedule_generation+1 WHERE feed_id=?', obsolete.feed);
  const retried = await h.consume(obsolete.wake, { attempts: 2, headers: obsolete.headers });
  assert.equal(retried.outcome, 'obsolete');
  const afterObsolete = await h.invoke('test/stats');
  assert.equal(afterObsolete.active_permits, 0, 'the obsolete redelivery frees its earlier attempt\'s permits');
  assert.equal(afterObsolete.permit_reclaim_total, obsolete.before.permit_reclaim_total + 1);
  behavior = v1;
  const unrelated = await h.add('https://unrelated.example.com/feed');
  await h.invoke('test/dispatch');
  const [unrelatedWake] = await wakeFor(unrelated);
  const admitted = await h.consume(unrelatedWake);
  assert.equal(admitted.status, 200);
  assert.notEqual(admitted.outcome, 'scan_busy', 'an unrelated delivery is admitted at once');
  await release();

  const idle = await hung('https://idle.example.com/feed', 'redelivery-idle');
  await h.run('UPDATE n_feed SET due_at=? WHERE feed_id=?', h.now + 86400, idle.feed);
  const settled = await h.consume(idle.wake, { attempts: 2, headers: idle.headers });
  assert.equal(settled.outcome, 'settled');
  const afterIdle = await h.invoke('test/stats');
  assert.equal(afterIdle.active_permits, 0, 'the idle redelivery frees its earlier attempt\'s permits');
  assert.equal(afterIdle.permit_reclaim_total, idle.before.permit_reclaim_total + 1);
  await release();
  console.log('PASS obsolete and idle redeliveries reclaim their earlier attempt\'s permits');
} finally {
  if (pending) await release();
  await h.instance.dispose();
}
