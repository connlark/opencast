// Opt-in proof against the unmodified deployed prod-staging Worker. Provision
// the temporary fixture and enable authenticated admin tests using the normal
// staging lane first; restore staging and delete the fixture afterward.
import assert from 'node:assert/strict';
import { readFile, writeFile } from 'node:fs/promises';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { setTimeout } from 'node:timers/promises';
import { fileURLToPath } from 'node:url';

const run = promisify(execFile);
const repo = fileURLToPath(new URL('../../../', import.meta.url));
const origin = process.env.OPENCAST_CANCELLATION_ORIGIN;
const fixture = process.env.OPENCAST_CANCELLATION_FIXTURE;
const tokenFile = process.env.OPENCAST_CANCELLATION_TOKEN_FILE;
assert.equal(new URL(origin).protocol, 'https:', 'The admin token requires HTTPS');
assert.equal(new URL(origin).hostname, 'notifications-prod-staging.example.com', 'Only prod-staging is permitted');
assert.equal(new URL(fixture).protocol, 'https:');
const token = (await readFile(tokenFile, 'utf8')).trim();
const prefix = crypto.randomUUID();
const urls = new Map(['probe', 'fetch-a', 'fetch-b', 'read-a', 'read-b', 'parse-a', 'parse-b']
  .map(name => [name, new URL(`/${prefix}/${name}`, fixture).href]));
const quote = value => "'" + value.replaceAll("'", "''") + "'";
const events = [];
const requests = new Set();
const sqlURLs = [...urls.values()].map(quote).join(',');
async function sql(command) {
  const { stdout } = await run('yarn', ['workspace', '@opencast/notifications-worker', 'exec',
    'wrangler', 'd1', 'execute', 'APP_ATTEST_DB', '--env', 'prod-staging', '--remote', '--command', command, '--json'],
  { cwd: repo, maxBuffer: 4 * 1024 * 1024 });
  const result = JSON.parse(stdout.slice(stdout.indexOf('[')));
  assert.ok(result.every(x => x.success), stdout);
  return result.map(x => x.results);
}
async function poll(name, controller) {
  const response = await fetch(new URL('/v1/admin/test/poll-feed', origin), {
    method: 'POST', headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
    body: JSON.stringify({ feed_url: urls.get(name) }), signal: controller?.signal,
  });
  assert.equal(response.status, 200, response.status === 200 ? '' : await response.text());
  return response.json();
}
async function snapshot() {
  return (await sql(`SELECT feed_url,latest_episode_id,etag,last_error,last_polled_at FROM feeds WHERE feed_url IN (${sqlURLs}) ORDER BY feed_url`))[0];
}
try {
  const now = Math.floor(Date.now() / 1000);
  await sql([...urls.values()].map(url => `INSERT INTO feeds(feed_url,source_url,poll_interval_seconds,consecutive_failures,created_at,updated_at,next_poll_at) VALUES (${quote(url)},${quote(url)},3600,0,${now},${now},${now + 3600})`).join(';'));
  await sql([...urls.values()].map(url => `INSERT INTO feed_subscriptions(install_id,feed_url,notifications_enabled,created_at,updated_at) VALUES (${quote(prefix)},${quote(url)},1,${now},${now})`).join(';'));
  const baseline = await poll('probe');
  assert.equal(baseline.first_error ?? null, null, 'Fixture must be reachable before cancellation proof');
  for (const phase of ['fetch', 'read', 'parse']) {
    for (let iteration = 0; iteration < 4; iteration++) {
      const controllers = [new AbortController(), new AbortController()];
      controllers.forEach(x => requests.add(x));
      const pending = controllers.map((controller, index) => poll(`${phase}-${index ? 'b' : 'a'}`, controller)
        .then(value => ({ unexpectedCompletion: value }), error => ({ error: error.name })));
      await setTimeout(750);
      const busy = await poll('probe');
      assert.equal(busy.scan_active, 2, JSON.stringify(busy));
      assert.equal(busy.feeds_polled, 0);
      assert.equal(busy.isolate_id, baseline.isolate_id, 'A different isolate cannot prove warm-instance recovery');
      assert.equal(busy.wasm_instance_id, baseline.wasm_instance_id);
      controllers.forEach(x => x.abort());
      const canceled = await Promise.all(pending);
      assert.ok(canceled.every(x => x.error === 'AbortError'), JSON.stringify(canceled));
      controllers.forEach(x => requests.delete(x));
      await setTimeout(150);
      const recovered = await poll('probe');
      assert.equal(recovered.feeds_polled, 1, JSON.stringify(recovered));
      assert.equal(recovered.scan_active, 0);
      assert.equal(recovered.isolate_id, baseline.isolate_id);
      assert.equal(recovered.wasm_instance_id, baseline.wasm_instance_id);
      events.push({ phase, iteration, isolate: recovered.isolate_id,
        wasmInstance: recovered.wasm_instance_id, wasmBytes: recovered.wasm_memory_bytes });
      console.log(JSON.stringify(events.at(-1)));
    }
  }
  const rows = await snapshot();
  for (const row of rows.filter(x => x.feed_url !== urls.get('probe'))) {
    assert.equal(row.latest_episode_id, null);
    assert.equal(row.etag, null);
    assert.equal(row.last_error, null);
    assert.equal(row.last_polled_at, null);
  }
  const retained = events.map(x => x.wasmBytes);
  assert.ok(Math.max(...retained) - Math.min(...retained) < 2 * 1024 * 1024);
  const report = process.env.OPENCAST_CANCELLATION_REMOTE_REPORT ?? '/private/tmp/opencast-feed-cancellation-remote.json';
  await writeFile(report, JSON.stringify({ passed: true, nativeDisconnects: events.length * 2, events, rows }, null, 2));
  console.log('Remote disconnect proof passed:', report);
} finally {
  requests.forEach(x => x.abort());
  // Exact fixture keys only; never touch another staging subscriber or ledger.
  await sql(`DELETE FROM feed_poll_attempts WHERE feed_url IN (${sqlURLs}); DELETE FROM feed_subscriptions WHERE install_id=${quote(prefix)}; DELETE FROM feeds WHERE feed_url IN (${sqlURLs})`);
}
