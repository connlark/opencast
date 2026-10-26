// The Notifications scheduled maintenance through the delivery entry's
// /scheduled (the actual scheduled handler): reconciliation's and retention's
// storage budgets, the retire warn's storage token, and reconciliation's
// `maintenance` storage_phases line. Each case runs on its own PostgreSQL
// clone through the wire proxy, whose statement holds and closes act on the
// delivery Worker's alias.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { setTimeout as sleep } from 'node:timers/promises';
import { ALERT_WEBHOOK_URL, harness } from './harness.mjs';

let passed = 0, failed = 0;
const report = [];
const only = process.env.MAINTENANCE_CASES?.split(',');
async function test(name, run) {
  if (only && !only.some(id => name.startsWith(id))) return;
  try { await run(); passed++; console.log(`PASS ${name}`); }
  catch (error) { failed++; console.log(`FAIL ${name}: ${error?.stack ?? error}`); }
}
const PARSER = fileURLToPath(new URL('../storage_phases/', import.meta.url));
const secrets = { ALERT_WEBHOOK_URL, ALERT_CREDENTIAL: 'fixture-credential', ALERT_RECIPIENT: 'fixture-recipient' };
const DAY = 86400;
async function open() {
  const h = await harness(request => {
    if (request.url === ALERT_WEBHOOK_URL) return Response.json({ aggregate_status: 'accepted' });
    return new Response('not a feed', { status: 404 });
  }, { logs: true, deliveryBindings: { ...secrets, NOTIFICATION_CLEANUP: 'true' } });
  const worker = await h.instance.getWorker('delivery-runtime');
  const ts = h.storage.testStorage('delivery-runtime');
  // One scheduled invocation at `ms`; the messages it logged.
  const scheduled = async ms => {
    const from = h.raw.length, logs = h.logs.length;
    const r = await worker.fetch('https://fixture.invalid/scheduled', { method: 'POST', headers: { 'x-test-scheduled-time': String(ms) } });
    assert.equal(r.status, 200, await r.clone().text());
    await sleep(50);
    return { raw: h.raw.slice(from).map(m => m.message), logs: h.logs.slice(logs) };
  };
  const traces = async () => (await worker.fetch('https://fixture.invalid/traces')).json();
  return { h, worker, ts, scheduled, traces };
}
const first = op => op.sql ?? op.statements?.[0] ?? '';
// A hold the Worker gave up on (its race ended first) is discarded: expected.
async function settle(ts, fires) {
  for (const fire of fires) {
    for (let i = 0; i < 300 && !ts({ op: 'witness' }).operations.find(o => o.id === fire.op)?.close; i++) await sleep(10);
    if (ts({ op: 'witness' }).fires.find(f => f.id === fire.id)?.discarded != null) ts({ op: 'expect', fire: fire.id, outcome: 'discarded' });
  }
}
const CONTROL = 'SELECT enabled FROM n_control';
// A whole minute that is not a five-minute boundary: the watchdog reads nothing.
const offBoundary = () => { const m = Math.floor(Date.now() / 60_000); return (m % 5 === 0 ? m - 1 : m) * 60_000; };
const retention = raw => raw.find(m => m.startsWith('scheduled retention:'));

await test('retention-budget: reconciliation\'s storage spent past its 12 s budget by sequential sub-cap holds; the cleanup control read and the prunes run under a budget of their own: the seeded expired row is pruned and the retention line is logged', async () => {
  const { h, ts, scheduled } = await open();
  try {
    // A warm-up run names reconciliation's statements on this tree, in order.
    const at = ts({ op: 'witness' }).operations.length;
    await scheduled(offBoundary());
    const ops = ts({ op: 'witness' }).operations.slice(at).map(first);
    const reconcile = [...new Set(ops.filter(x => !x.startsWith(CONTROL)))].slice(0, 4).map(x => x.slice(0, 48));
    assert.equal(reconcile.length, 4, JSON.stringify(ops));
    await h.run("INSERT INTO secure_hello_attempts(attempt_id,accepted,created_at) VALUES('maintenance-retention',0,0)");
    // Each hold releases after 3.5 s, under the 4 s statement cap: 14 s in all.
    const armings = reconcile.map(match => ts({ op: 'arm', kind: 'statement', action: 'hold-request', match, release_after_ms: 3500 }));
    const started = Date.now();
    const run = await scheduled(offBoundary());
    const wall = Date.now() - started;
    const fires = ts({ op: 'witness' }).fires.filter(f => armings.some(a => a.arming === f.arming));
    assert.equal(fires.length, 4, 'every hold fired');
    await settle(ts, fires);
    assert.ok(wall >= 12_000, `the first budget is spent: ${wall} ms`);
    assert.equal(await h.first("SELECT attempt_id FROM secure_hello_attempts WHERE attempt_id='maintenance-retention'"), null, 'the expired row is pruned');
    const line = retention(run.raw);
    assert.ok(line && /secure_attempts=[1-9]/.test(line), `the retention line: ${line} (${run.raw.filter(m => !m.startsWith('{')).join(' | ')})`);
    report.push(`retention-budget: holds on ${reconcile.length} reconciliation statements, wall ${wall} ms; ${line}`);
  } finally { await h.close(); }
});

await test('retire-warn: a RetireEvent whose COMMIT acknowledgement is dropped is swallowed and the warn names its storage token and source; separately an escaping reconciliation failure\'s warn carries its error', async () => {
  const { h, ts, scheduled } = await open();
  try {
    const t = Math.floor(Date.now() / 1000), terminal = t - 31 * DAY;
    await h.run("INSERT INTO n_event(source,event_id,schema_version,kind,payload_digest,occurred_at,eligible_at,expires_at,receipt_id,fanout_complete,terminal_at) VALUES('feed_polling','maintenance-retire',1,'episode','digest',?,?,?,'receipt-maintenance-retire',1,?)", terminal - DAY, terminal - DAY, terminal, terminal);
    // (a) the retire transaction's COMMIT acknowledgement dropped.
    const arm = ts({ op: 'arm', kind: 'statement', action: 'drop-commit-ack', match: 'WITH gone AS (DELETE FROM n_delivery_member WHERE source=$1' });
    const a = await scheduled(offBoundary());
    assert.ok(ts({ op: 'witness' }).fires.some(f => f.arming === arm.arming), 'the retirement was attempted');
    const warn = a.raw.find(m => m.startsWith('notification retire failed'));
    assert.ok(warn && /count=1 last_error=storage_B05_[A-Za-z]+_[A-Za-z]+ source=feed_polling$/.test(warn), `the retire warn: ${warn}`);
    // (b) a reconciliation statement closed before it is sent: the failure escapes.
    const at = ts({ op: 'witness' }).operations.length;
    await scheduled(offBoundary());
    const firstStatement = ts({ op: 'witness' }).operations.slice(at).map(first).find(x => !x.startsWith(CONTROL));
    ts({ op: 'arm', kind: 'statement', action: 'close-before', match: firstStatement.slice(0, 48) });
    const b = await scheduled(offBoundary());
    const failed = b.raw.find(m => m.startsWith('notification reconciliation failed; continuing maintenance'));
    assert.ok(failed && /: \S+/.test(failed), `the reconciliation warn carries its error: ${failed}`);
    report.push(`retire-warn: "${warn}"; "${failed}"`);
  } finally { await h.close(); }
});

await test('maintenance-line: reconciliation writes one storage_phases line (handler maintenance, schema 2, at most 8,192 bytes, parsed) with the cron\'s lag in milliseconds; the watchdog\'s read is witnessed outside it and absent inside it; a failed reconciliation reads failed', async () => {
  const { h, ts, scheduled, traces } = await open();
  try {
    // A five-minute boundary: the watchdog reads.
    const boundary = Math.floor(Date.now() / 300_000) * 300_000;
    const before = Date.now(), tracesAt = (await traces()).length, at = ts({ op: 'witness' }).operations.length;
    const run = await scheduled(boundary);
    const after = Date.now();
    const lines = run.logs.filter(e => e.event === 'storage_phases' && e.handler === 'maintenance');
    assert.equal(lines.length, 1, 'one maintenance line');
    const [line] = lines;
    assert.deepEqual([line.schema, line.outcome, line.budget.handler_main_ms, line.budget.scope, line.budget.source], [2, 'ok', 12000, 'main', 'HANDLER_MS']);
    assert.ok(line.scheduled_lag_ms >= before - boundary - 50 && line.scheduled_lag_ms <= after - boundary + 50, `lag ${line.scheduled_lag_ms} for ${before - boundary}..${after - boundary}`);
    const watchdogReads = (await traces()).slice(tracesAt).reduce((n, t) => n + (t.watchdog_reads ?? 0), 0);
    assert.ok(watchdogReads >= 1, 'the watchdog read, witnessed by the proxy');
    const watchdogOps = ts({ op: 'witness' }).operations.slice(at).filter(o => first(o).includes('AS late_900')).length;
    assert.ok(watchdogOps >= 1);
    // Inside the line: reconciliation's operations alone, no watchdog read (A14)
    // anywhere in its detail, and fewer operations than the invocation ran.
    const named = [...line.op.map(o => o.op), ...line.slowest.map(o => o.op), line.primary?.op].filter(Boolean);
    assert.ok(!named.includes('A14'), JSON.stringify(named));
    assert.ok(line.ops.total > 0 && line.ops.total < ts({ op: 'witness' }).operations.slice(at).length - watchdogOps, `${line.ops.total} of ${ts({ op: 'witness' }).operations.slice(at).length} operations`);
    const text = JSON.stringify(line);
    assert.ok(Buffer.byteLength(text) <= 8192, `${Buffer.byteLength(text)} bytes`);
    const parsed = JSON.parse(execFileSync('python3', ['-B', '-c', 'import json,sys\nimport storage_phases_parse as p\nprint(json.dumps(p.parse(sys.stdin.read())[0]))'], { cwd: PARSER, input: text }).toString());
    assert.equal(parsed, 'row');
    // A failed reconciliation: its first statement closed before it is sent.
    const at2 = ts({ op: 'witness' }).operations.length;
    await scheduled(boundary - 60_000);
    const firstStatement = ts({ op: 'witness' }).operations.slice(at2).map(first).find(x => !x.startsWith(CONTROL));
    ts({ op: 'arm', kind: 'statement', action: 'close-before', match: firstStatement.slice(0, 48) });
    const bad = await scheduled(boundary - 60_000);
    const failedLine = bad.logs.find(e => e.event === 'storage_phases' && e.handler === 'maintenance');
    assert.equal(failedLine?.outcome, 'failed', JSON.stringify(failedLine?.primary));
    report.push(`maintenance-line: lag ${line.scheduled_lag_ms} ms, ${line.ops.total} reconciliation ops, ${Buffer.byteLength(text)} bytes, watchdog reads ${watchdogReads} outside; the failed run reads ${failedLine.outcome}`);
  } finally { await h.close(); }
});
process.on('exit', () => { for (const line of report) console.log(`REPORT ${line}`); console.log(`${passed} passed, ${failed} failed`); });
if (failed) process.exitCode = 1;
