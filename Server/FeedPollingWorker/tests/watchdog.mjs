// Exercise the actual Notifications scheduled handler and its read-only monitor.
// The hung health read: the wire proxy holds the read unforwarded and the read
// operation's own deadline, min(4 s, handler end - now) (WorkerDatabaseCore),
// fails it: the could-not-read alert, poll_watchdog's reason
// storage_A14_Deadline_NotApplicable, elapsed in [4 s, 10 s), and the wire
// witness: never forwarded, closed at least 4 s after its connection's
// ReadyForQuery was relayed (which precedes the operation's timer) and at most
// 4.5 s + EPSILON_MS after the hold fired (the deadline plus the bounded
// finish).
// Scope: the watchdog's own 10 s health-read deadline
// (NotificationsWorker/src/polling/watchdog.rs:39-44) is untested. Under the
// operation caps the whole health read is connect <= 3 s + the read <= 4 s +
// finish <= 0.5 s = 7.5 s < 10 s, so one connect stall plus one read stall does
// not reach it; the alert send has its own 10 s outside the health-read scope
// (watchdog.rs:73-77). That is not a claim that the deadline is unreachable: a
// reachability test must identify more work inside the health-read scope, or
// another explicitly justified mechanism, and keep the alert send separate.
import assert from 'node:assert/strict';
import { performance } from 'node:perf_hooks';
import { setTimeout as sleep } from 'node:timers/promises';

const fixtureDateNow = Date.now;
import { harness, ALERT_WEBHOOK_URL } from './harness.mjs';

// Scheduling allowance between workerd's timers and the proxy's stamps, the
// same as tests/postgres/test-proxy.mjs's.
const EPSILON_MS = 250;
let status = 200, hangBody = false;
const secrets = { ALERT_WEBHOOK_URL, ALERT_CREDENTIAL: 'fixture-credential', ALERT_RECIPIENT: 'fixture-recipient' };
const h = await harness(request => {
  assert.equal(request.url, ALERT_WEBHOOK_URL);
  if (hangBody) return new Response(new ReadableStream({ start() {} }));
  return Response.json(status === 200 ? { aggregate_status: 'accepted' } : { error: { code: 'unavailable' } }, { status });
}, { deliveryBindings: { ...secrets, NOTIFICATION_CLEANUP: 'true' }, logs: true });
try {
  const worker = await h.instance.getWorker('delivery-runtime');
  const at = Math.floor(h.now / 1800) * 1800;
  const invoke = async (path, body, headers) => {
    const r = await worker.fetch(`https://fixture.invalid/${path}`, { method: 'POST', body, headers });
    assert.equal(r.status, 200, await r.clone().text());
    return r;
  };
  const tick = async seconds => {
    await h.run("INSERT INTO secure_hello_attempts(attempt_id,accepted,created_at) VALUES('watchdog-retention',0,0)");
    const r = await invoke('scheduled', undefined, { 'x-test-scheduled-time': String(seconds * 1000) });
    assert.equal(await h.first("SELECT * FROM secure_hello_attempts WHERE attempt_id='watchdog-retention'"), null, 'existing retention completes despite watchdog failure');
    return r;
  };
  // Actual wall clock and scheduled time deliberately differ.
  const before = await h.rows('SELECT * FROM n_poll_dispatch');
  const ids = [];
  for (let i = 0; i < 17; i++) ids.push(await h.add(`https://watchdog-${i}.example.com/feed`, h.now - 1000));
  await h.run("UPDATE n_feed SET snapshot_key='fixture-scanned'");
  await h.run('UPDATE n_feed SET snapshot_key=NULL WHERE feed_id=?', ids[0]);
  await h.run('UPDATE n_feed SET admission_paused=1 WHERE feed_id=?', ids[1]);
  await h.run('UPDATE n_interest SET enabled=0 WHERE feed_id=?', ids[2]);
  await h.run('UPDATE n_feed SET poll_failures=1 WHERE feed_id=?', ids[3]);
  await h.run('UPDATE n_feed SET handling_failures=1 WHERE feed_id=?', ids[4]);
  await h.run('UPDATE n_feed SET retry_at=? WHERE feed_id=?', h.now + 3600, ids[5]);
  await h.run("UPDATE n_feed SET origin_key='cooling' WHERE feed_id=?", ids[6]);
  await h.run("INSERT INTO n_poll_origin(origin_key,cooldown_until,failures,updated_at) VALUES('cooling',?,1,?)", h.now + 3600, h.now);
  await h.run('UPDATE n_feed SET due_at=? WHERE feed_id=?', h.now - 700, ids[7]);
  await tick(at + 60);
  assert.equal(h.alerts.length, 0, 'non-fifth minute does not read or page');
  let traces = await (await invoke('traces')).json();
  assert.equal(traces.at(-1).watchdog_reads, undefined);
  await tick(at);
  assert.equal(h.alerts.length, 0, 'nine late feeds, excluding baseline/backoff/ineligible/cooling, stay quiet');
  await h.run('UPDATE n_feed SET due_at=? WHERE feed_id=?', h.now - 1000, ids[7]);
  const feeds = await h.rows('SELECT * FROM n_feed ORDER BY feed_id');
  await tick(at);
  assert.equal(h.alerts.length, 1);
  assert.match(h.alerts[0].body.draft.body, /10 healthy scanned feeds/);
  assert.equal(h.alerts[0].headers.authorization, 'Bearer fixture-credential');
  await tick(at + 300);
  assert.equal(h.alerts[1].headers['idempotency-key'], h.alerts[0].headers['idempotency-key']);
  await h.run("UPDATE n_poll_dispatch SET stall_state='stalled'");
  await tick(at);
  assert.equal(h.alerts.length, 2, 'dispatcher-alerted lane stays quiet');
  await h.run("UPDATE n_poll_dispatch SET stall_state='clear'");
  await invoke('fault', 'watchdog_read');
  await tick(at);
  assert.equal(h.alerts.length, 3, 'failed read pages');
  assert.match(h.alerts[2].body.draft.body, /could not read/);
  assert.equal(h.alerts[2].headers['idempotency-key'], h.alerts[0].headers['idempotency-key'], 'both reasons share one bucket');
  await invoke('fault', 'watchdog_read_hang');
  // These checks measure actual timeout duration, independently of the
  // frozen fixture epoch used by the worker and scheduled timestamps.
  const elapsedOrigin = performance.now(), wallOrigin = Date.now();
  Date.now = () => wallOrigin + performance.now() - elapsedOrigin;
  const failedReads = () => h.logs.filter(e => e.event === 'poll_watchdog' && e.read === 'failed'), failedBefore = failedReads().length;
  let started = Date.now();
  await tick(at);
  const elapsed = Date.now() - started;
  assert.ok(elapsed >= 4000 && elapsed < 10000, `hung read ends at its operation deadline, inside the watchdog's ten seconds: ${elapsed} ms`);
  for (let i = 0; i < 200 && failedReads().length <= failedBefore; i++) await sleep(10);
  assert.deepEqual(failedReads().slice(failedBefore), [{ event: 'poll_watchdog', read: 'failed', reason: 'storage_A14_Deadline_NotApplicable' }]);
  const ts = h.storage.testStorage('delivery-runtime');
  const hold = () => { const w = ts({ op: 'witness' }), f = w.fires.find(x => x.hook === 'O-watchdog_read_hang'); return { f, o: w.operations.find(x => x.id === f?.op) }; };
  for (let i = 0; i < 200 && hold().o?.close == null; i++) await sleep(10);
  const { f, o } = hold();
  assert.ok(f && f.action === 'hold-forever' && f.forwarded === null && o.forwarded === null && f.discarded !== null, `the held health read ended otherwise: ${JSON.stringify(f)}`);
  const lower = o.close - o.Z_relay, span = o.close - o.fire;
  console.log(`hung health read: elapsed ${Math.round(elapsed)} ms, fire-Z_relay ${(o.fire - o.Z_relay).toFixed(1)} ms, close-Z_relay ${lower.toFixed(1)} ms, close-fire ${span.toFixed(1)} ms`);
  assert.ok(lower >= 4000, `close - Z_relay ${lower}`);
  assert.ok(span <= 4500 + EPSILON_MS, `close - fire ${span}`);
  ts({ op: 'expect', fire: f.id, outcome: 'discarded' });
  assert.equal(h.alerts.length, 4);
  assert.match(h.alerts[3].body.draft.body, /could not read/);
  status = 503;
  await tick(at);
  hangBody = true;
  started = Date.now();
  await tick(at);
  assert.ok(Date.now() - started < 15000, 'hung alert response body cannot hang scheduled work');
  hangBody = false;
  Date.now = fixtureDateNow;
  await invoke('clock', '1800');
  await tick(at + 1800);
  assert.notEqual(h.alerts.at(-1).headers['idempotency-key'], h.alerts[0].headers['idempotency-key'], 'new half-hour allows a reminder');
  traces = await (await invoke('traces')).json();
  for (const trace of traces.filter(t => t.path === '/scheduled')) {
    // The counts are the proxy's deltas over the invocation's window: this
    // lower bound holds only if no other invocation overlapped it.
    assert.equal(trace.storage_exclusive, true, 'a scheduled invocation shared its counter window');
    assert.ok(trace.d1 > (trace.watchdog_reads ?? 0), 'existing maintenance executes even when watchdog read/send fails');
    assert.ok((trace.watchdog_reads ?? 0) <= 1, 'one aggregate read');
  }
  assert.deepEqual(await h.rows('SELECT * FROM n_feed ORDER BY feed_id'), feeds, 'watchdog never writes feeds');
  assert.deepEqual(await h.rows('SELECT * FROM n_poll_dispatch'), before, 'watchdog never writes alert state');
  console.log('PASS watchdog scheduled cadence, shared health exclusions, onset, read failure/deadline, bucket deduplication, and maintenance isolation');
} finally { Date.now = fixtureDateNow; await h.instance.dispose(); }

const off = await harness(() => { throw Error('unexpected network'); });
try {
  const worker = await off.instance.getWorker('delivery-runtime');
  await worker.fetch('https://fixture.invalid/scheduled', { method: 'POST', headers: { 'x-test-scheduled-time': '1800000' } });
  const traces = await (await worker.fetch('https://fixture.invalid/traces')).json();
  assert.equal(traces[0].watchdog_reads, undefined, 'no secrets means no watchdog read');
  assert.equal(off.alerts.length, 0);
  console.log('PASS watchdog disabled without secrets');
} finally { await off.instance.dispose(); }
