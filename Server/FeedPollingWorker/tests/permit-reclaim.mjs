import assert from 'node:assert/strict';
import { harness, item, rss } from './harness.mjs';

let behavior;
const h = await harness(request => behavior(request));
behavior = () => new Response(rss([item('base', h.now - 100)]), { headers: { etag: '"v1"' } });

try {
  const firstFeed = await h.add('https://hang.example.com/feed');
  await h.invoke('test/dispatch');
  const [baselineWake] = await h.polls();
  assert.equal((await h.consume(baselineWake)).status, 200);
  await h.run('UPDATE n_feed SET due_at=0,dispatch_until=0 WHERE feed_id=?', firstFeed);
  behavior = () => new Response(rss([item('base', h.now - 100), item('new', h.now - 20)]), { headers: { etag: '"v2"' } });
  await h.invoke('test/dispatch');
  const [firstWake] = await h.polls();
  await h.invoke('fault', 'hang_get');
  const pending = h.consume(firstWake).catch(error => ({ status: 0, error }));
  for (let i = 0; i < 100; i++) {
    const stats = await h.invoke('test/stats');
    if (stats.active_permits === 2) break;
    await new Promise(resolve => setTimeout(resolve, 10));
  }
  assert.equal((await h.invoke('test/stats')).active_permits, 2, 'the hanging R2 read owns both permits');

  await h.invoke('clock', '100');
  const secondFeed = await h.add('https://waiting.example.com/feed');
  await h.invoke('test/dispatch');
  const [secondWake] = (await h.polls()).filter(wake => wake.feed_id === secondFeed);
  const refused = await h.consume(secondWake);
  assert.equal(refused.outcome, 'scan_busy');
  assert.equal((await h.invoke('metrics')).logged['scan_busy:'], 1, 'one refusal emits one scan_busy event');

  await h.invoke('clock', '241');
  let recovered;
  try { recovered = await h.consume(secondWake); } catch (error) { recovered = { status: 200, transportError: error }; }
  assert.equal(recovered.status, 200);
  assert.ok((await h.invoke('test/stats')).permit_reclaim_total >= 1, 'a new owner records the reclaim');

  await h.invoke('release-hang');
  await pending;
  console.log('PASS leaked permits refuse at 100s and reclaim at 241s');
} finally {
  await h.instance.dispose();
}
