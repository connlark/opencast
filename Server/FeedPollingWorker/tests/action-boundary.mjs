// A delivery ended at a chosen boundary of the consume's action loop, for the
// suites whose setup needs a state between two actions (a staged preparation,
// a published observation not yet drained). Both run a storage-fixture build
// of the polling Worker (its loop clock and gate: POLLING_FIXTURE) and the
// harness's TEST_STORAGE; neither changes what the delivery does before it.
//
//  stopAfter(h, wake, n)  holds the fresh claim that opens the boundary after
//    the n-th action (the proxy's hold-request on the claim statement), moves
//    the loop clock past the 140 s start guard and releases it, so the
//    delivery yields `guard` there with its one continuation. Deterministic;
//    the caller knows the n-th action continues (a terminal result would leave
//    the hold unfired, which the storage's dispose rejects).
//  oneAction(h, wake)  arms the loop gate instead and runs one delivery: if it
//    waits at its first completed boundary (its storage quiet for 500 ms), the
//    loop clock moves past the guard and the gate is released; a delivery
//    that ends after one action is simply over. For a first action that may
//    or may not continue, and on a build with no loop.
import assert from 'node:assert/strict';
import { setTimeout as sleep } from 'node:timers/promises';

export const POLLING_FIXTURE = process.env.OPENCAST_POLLING_FIXTURE_BUILD ?? '/tmp/opencast-polling-fixture-build';
export const CLAIM = 'SELECT f.origin_key,f.due_at';
const ts = h => h.storage.testStorage('polling-runtime');
async function fired(h, arming) {
  for (let i = 0; i < 2000; i++) { const f = ts(h)({ op: 'witness' }).fires.find(x => x.arming === arming); if (f) return f; await sleep(5); }
  throw Error(`arming ${arming} never fired`);
}
export async function stopAfter(h, wake, n = 1, options = {}) {
  await h.invoke('test/loop-clock', '0');
  const arm = ts(h)({ op: 'arm', kind: 'statement', action: 'hold-request', match: CLAIM, skip: n });
  const running = h.consume(wake, options);
  running.catch(() => {});
  const fire = await fired(h, arm.arming);
  await h.invoke('test/loop-clock', '141000');
  ts(h)({ op: 'release', fire: fire.id });
  const result = await running;
  await h.invoke('test/loop-clock', '0');
  return result;
}
export async function oneAction(h, wake, options = {}) {
  await h.invoke('test/loop-clock', '0');
  await h.invoke('test/loop-gate', 'arm');
  const at = ts(h)({ op: 'witness' }).operations.length;
  let done = null;
  const running = h.consume(wake, options).then(r => { done = r; return r; });
  running.catch(() => {});
  for (let quiet = 0, seen = -1; done === null;) {
    const n = ts(h)({ op: 'witness' }).operations.length - at;
    if (n > 0 && n === seen) { if ((quiet += 25) >= 500) break; } else quiet = 0;
    seen = n; await sleep(25);
  }
  if (done === null) {
    await h.invoke('test/loop-clock', '141000');
    assert.equal((await h.invoke('test/loop-gate', 'release')).released_waiter, true, 'the delivery waited at its boundary');
  }
  const result = await running;
  await h.invoke('test/loop-clock', '0');
  // Unconsumed when the delivery ended after one action: disarmed for the next.
  await h.invoke('test/loop-gate', 'release');
  return result;
}
