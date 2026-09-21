// A changed 200 must create the same exact event set and release deadlines as
// the previous complete-observation path. `fixtures/equivalence-pass04.json` is
// that path's recorded output for `equivalence-fixture.mjs`; it is an inert
// contract oracle, not authorization to restart the retired executor.
import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';
const run = promisify(execFile), here = new URL('./', import.meta.url);
const fixture = 'Server/FeedPollingWorker/tests/equivalence-fixture.mjs';
async function record(root, out) {
  await run(process.execPath, [fixture, out], { cwd: root, maxBuffer: 1 << 28 });
  return JSON.parse(await readFile(out, 'utf8'));
}
const current = await record(fileURLToPath(new URL('../../../', here)), '/private/tmp/opencast-pass045-equivalence.json');
const expected = JSON.parse(await readFile(new URL('fixtures/equivalence-pass04.json', here), 'utf8'));
// Every candidate and event, not just the latest episode.
for (const key of ['releases', 'events', 'deliveries', 'sends']) assert.deepEqual(current[key], expected[key], key);
const reasons = new Set(current.releases.map(r => r.reason)), feeds = new Set(current.releases.map(r => r.feed));
assert.deepEqual([...reasons].sort(), ['future', 'recent', 'undated']);
assert.ok(current.releases.some(r => r.state === 'withdrawn') && current.releases.some(r => r.group.length === 6));
// Reordering, a pin, edited metadata, identity churn and an old backfill are
// never releases: only the genuinely new members of each history alert.
assert.deepEqual([...feeds].sort(), ['burst', 'edited-bonus', 'future-withdrawn', 'limited-catch-up', 'no-validators-undated', 'reordered-pinned']);
console.log(`PASS identical to the complete-observation path: ${current.releases.length} releases, ${current.events.length} events, ${current.deliveries.length} deliveries, ${current.sends.length} sends across reordered/pinned, edited, bonus, limited catch-up, no-validator undated, future/withdrawn, burst, churn and stale histories`);
