// What a changed poll publishes, pinned byte-for-byte. `fixtures/prose-golden.json`
// was recorded from the single-pass scan (OPENCAST_RECORD_GOLDEN=1); any later
// scan shape must reproduce every candidate page, release row, outbox payload
// and APNs send it lists for the same first complete responses. The publisher
// sends no validators, so every poll reads and parses its body.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFile, writeFile } from 'node:fs/promises';
import { harness } from './harness.mjs';

const FIXTURE = new URL('fixtures/prose-golden.json', import.meta.url);
const RECORD = process.env.OPENCAST_RECORD_GOLDEN === '1';
// A fixed wall clock, so dates in page bytes and rows repeat across runs.
const T0 = 1791460800, DAY = 86400;
// The only values masked before comparison: each carries a random id (recorded
// twice and diffed to confirm). A page or object `key` embeds the observation's
// id; `observation_id` is one; an outbox `payload_digest` hashes a payload that
// carries it. `event_id` is derived and stays. Masking is textual inside stored
// JSON strings, so every other byte of a row or payload is compared as recorded.
const RANDOM = ['observation_id', 'key', 'payload_digest'];
const MASK = new RegExp(`"(${RANDOM.join('|')})":"[^"]*"`, 'g');
const sha = bytes => createHash('sha256').update(bytes).digest('hex');
const strip = value => Array.isArray(value) ? value.map(strip)
  : value && typeof value === 'object' ? Object.fromEntries(Object.entries(value).map(([k, v]) => [k, RANDOM.includes(k) ? '<random>' : strip(v)]))
  : typeof value === 'string' ? value.replace(MASK, '"$1":"<random>"') : value;

const documents = new Map();
const h = await harness(request => {
  const body = documents.get(request.url);
  return body == null ? new Response('missing', { status: 404 }) : new Response(body);
});
const bucket = await h.instance.getR2Bucket('FEED_SNAPSHOTS', 'polling-runtime');
const delivery = await h.instance.getWorker('delivery-runtime');
let step = 0;
// Polling is frozen at T0 + step; the delivery worker only has an offset.
async function at(seconds) {
  step = seconds; await h.invoke('clock', String(seconds));
  await (await delivery.fetch('https://delivery.invalid/clock', { method: 'POST', body: String(T0 + seconds - Math.floor(Date.now() / 1000)) })).text();
}
const entry = ({ guid, at: date, title = `Episode ${guid}`, description, notes, audio = guid }) => `<item><guid>${guid}</guid><title>${title}</title>${description == null ? '' : `<description>${description}</description>`}${notes == null ? '' : `<content:encoded>${notes}</content:encoded>`}${date == null ? '' : `<pubDate>${new Date(date * 1000).toUTCString()}</pubDate>`}<enclosure url="https://audio.example.com/${audio}.mp3"/></item>`;
const document = items => `<rss xmlns:content="http://purl.org/rss/1.0/modules/content/"><channel><title>Prose golden</title>${items.map(entry).join('')}</channel></rss>`;
async function add(url) {
  const feed = await h.add(url);
  // The harness stamps its rows with the real clock; move them onto T0.
  await h.run('UPDATE feed_subscriptions SET created_at=?,updated_at=?', T0 - 100000, T0 - 100000);
  await h.run('UPDATE devices SET created_at=?,last_seen_at=?', T0 - 100000, T0);
  await h.run('UPDATE n_feed_catalog SET created_at=?,updated_at=?', T0, T0);
  return feed;
}
// One scheduled poll of `feed` alone, then every continuation and delivery.
async function poll(feed) {
  await at(step + 120);
  await h.run('UPDATE n_feed SET due_at=? WHERE feed_id<>?', T0 + 100 * DAY, feed);
  await h.run('UPDATE n_feed SET due_at=0,retry_at=0,poll_failures=0,dispatch_until=0 WHERE feed_id=?', feed);
  await h.run('DELETE FROM n_poll_origin');
  await h.invoke('test/dispatch'); await h.drain();
  const state = await h.first('SELECT last_poll_outcome,observation_generation,snapshot_key FROM n_feed WHERE feed_id=?', feed);
  // Candidate pages exactly as published: order, boundaries and bytes.
  const manifest = await (await bucket.get(state.snapshot_key)).json();
  const pages = [];
  for (const [ordinal, page] of manifest.candidate_pages.entries()) {
    const bytes = new Uint8Array(await (await bucket.get(page.key)).arrayBuffer());
    assert.equal(sha(bytes), page.sha256, 'the page object matches its manifest entry');
    pages.push({ ordinal, ...strip(page), object_bytes: bytes.length });
  }
  await h.deliver(true);
  return { outcome: state.last_poll_outcome, generation: state.observation_generation, candidate_count: manifest.candidate_count, candidate_pages: pages };
}
const rows = async (feed, full = Infinity) => {
  const releases = (await h.rows('SELECT episode_id,fingerprint,first_observed_at,eligible_at,expires_at,reason,state,disposition,published_at,generation,metadata_json FROM n_episode_release WHERE feed_id=? ORDER BY episode_id', feed)).map(strip);
  const outbox = (await h.rows('SELECT x.event_id,x.payload_digest,x.occurred_at,x.expires_at,x.state,x.payload_json FROM n_outbox x JOIN n_episode_release r ON r.event_id=x.event_id WHERE r.feed_id=? ORDER BY x.event_id', feed)).map(strip);
  // A large history is pinned by one digest over every row, with the first
  // and last rows kept readable.
  const keep = list => list.length <= full ? list : { count: list.length, sha256: sha(JSON.stringify(list)), first: list.slice(0, 3), last: list.slice(-3) };
  return { releases: keep(releases), outbox: keep(outbox) };
};
const sends = from => h.sends.slice(from).map(strip).map(s => JSON.stringify(s)).sort().map(s => JSON.parse(s));

try {
  await h.run("UPDATE n_control SET enabled=0 WHERE name='cleanup'");
  await h.invoke('freeze', String(T0)); await at(0);
  const result = { schema_version: 1, frozen_at: T0, scenarios: {} };

  // prose: every path the notification prose takes from feed text.
  const PROSE = 'https://prose.example.com/feed';
  const prose = await add(PROSE);
  const base = [1, 2, 3].map(i => ({ guid: `base-${i}`, at: T0 - i * DAY, description: `Baseline notes ${i}.` }));
  let items = base;
  documents.set(PROSE, document(items));
  const polls = [];
  const sent = () => h.sends.length;
  let from = sent();
  polls.push({ name: 'baseline', ...(await poll(prose)), sends: sends(from) });
  const near = offset => T0 + step + 120 - offset;
  const fresh = [
    { guid: 'html', title: 'Inline &amp; block markup', description: '<![CDATA[<p>Intro with <em>inline</em> and <strong>bold</strong> words &amp; an entity&#8217;s turn.</p><ul><li>First point</li><li>Second point</li></ul><div>A block <a href="https://example.com/x">link</a>, then more.</div>]]>' },
    { guid: 'show-notes', title: 'Show notes fallback', description: '', notes: '<![CDATA[<p>Only the show notes carry <b>prose</b> for this one.</p><p>Second paragraph.</p>]]>' },
    { guid: 'title-echo', title: 'Same words as the title', description: 'Same words as the title' },
    { guid: 'nbsp-crlf', title: 'Whitespace', description: 'First line&#160;with nbsp\r\nsecond line\r\n\r\n\tthird line' },
    { guid: 'long-prose', title: 'Longer than the budget', description: Array.from({ length: 24 }, (_, i) => `Sentence ${i + 1} of the long description carries ordinary words.`).join(' ') },
    { guid: 'sixteen-k', title: 'Sixteen KiB', description: `<![CDATA[${Array.from({ length: 180 }, (_, i) => `<p>Paragraph ${i + 1} of a very long show description with <a href="https://example.com/p/${i}">a link</a>.</p>`).join('')}]]>` },
    { guid: 'cut-href', title: 'Cut inside a link', description: `<![CDATA[<p>${'Lead sentence words. '.repeat(22)}<a href="https://example.com/${'segment/'.repeat(40)}">the link text</a> and the prose after the link.</p>]]>` },
    { guid: 'url-only', title: 'Only a URL', description: 'https://example.com/episodes/url-only?utm_source=feed' },
  ].map((item, i) => ({ ...item, at: near(600 - i * 10) }));
  assert.ok(fresh.find(i => i.guid === 'sixteen-k').description.length > 16 * 1024);
  items = [...fresh, ...base]; documents.set(PROSE, document(items));
  from = sent(); polls.push({ name: 'eight prose paths', ...(await poll(prose)), sends: sends(from) });
  from = sent(); polls.push({ name: 'unchanged repoll', ...(await poll(prose)), sends: sends(from) });
  items = items.map(i => i.guid === 'base-1' ? { ...i, description: 'Edited baseline notes 1.' } : i); documents.set(PROSE, document(items));
  from = sent(); polls.push({ name: 'metadata-only edit', ...(await poll(prose)), sends: sends(from) });
  // Same title, audio and summary under a new GUID.
  items = items.map(i => i.guid === 'base-2' ? { ...i, guid: 'base-2-alias', title: 'Episode base-2', audio: 'base-2' } : i); documents.set(PROSE, document(items));
  from = sent(); polls.push({ name: 'alias', ...(await poll(prose)), sends: sends(from) });
  items = [{ guid: 'one-more', title: 'One more &amp; final', description: '<![CDATA[<p>A single release: its own alert with <i>this</i> summary.</p>]]>', at: near(60) }, ...items]; documents.set(PROSE, document(items));
  from = sent(); polls.push({ name: 'one more release', ...(await poll(prose)), sends: sends(from) });
  assert.deepEqual(polls.map(p => p.outcome), ['published', 'published', 'unchanged', 'published', 'published', 'published']);
  result.scenarios.prose = { polls, ...(await rows(prose)) };

  // large: a body over the 5 MiB buffer and a spool over 16 candidate pages.
  const LARGE = 'https://large.example.com/feed';
  const large = await add(LARGE);
  const head = [1, 2, 3].map(i => ({ guid: `large-base-${i}`, at: T0 - i * DAY, description: `Large baseline ${i}.` }));
  documents.set(LARGE, document(head));
  const lpolls = [];
  from = sent(); lpolls.push({ name: 'baseline', ...(await poll(large)), sends: sends(from) });
  const prose3k = i => `<![CDATA[${`<p>Item ${i} paragraph with <a href="https://example.com/${i}">a link</a> &amp; words.</p>`.repeat(48).slice(0, 3072 - 12)}]]>`;
  const novel = Array.from({ length: 2000 }, (_, i) => ({ guid: `large-${i}`, title: `Large release ${i}`, description: prose3k(i), at: near(3000 - i) }));
  documents.set(LARGE, document([...novel, ...head]));
  const bodyBytes = Buffer.byteLength(documents.get(LARGE));
  assert.ok(bodyBytes > 5 * 1024 * 1024, `the large body is ${bodyBytes} bytes`);
  from = sent(); lpolls.push({ name: '2000 novel items', ...(await poll(large)), sends: sends(from) });
  assert.ok(lpolls[1].candidate_pages.length > 16, `${lpolls[1].candidate_pages.length} candidate pages`);
  from = sent(); lpolls.push({ name: 'unchanged repoll', ...(await poll(large)), sends: sends(from) });
  assert.deepEqual(lpolls.map(p => p.outcome), ['published', 'published', 'unchanged']);
  result.scenarios.large = { body_bytes: bodyBytes, polls: lpolls, ...(await rows(large, 0)) };

  const text = JSON.stringify(result, null, 1) + '\n';
  if (RECORD) {
    await writeFile(process.env.OPENCAST_GOLDEN_OUT ?? FIXTURE, text);
    console.log(`RECORDED ${result.scenarios.prose.releases.length} prose releases, ${lpolls[1].candidate_count} large candidates on ${lpolls[1].candidate_pages.length} pages`);
  } else {
    const expected = await readFile(FIXTURE, 'utf8');
    if (text !== expected) {
      const golden = JSON.parse(expected);
      for (const name of Object.keys(golden.scenarios)) for (const key of Object.keys(golden.scenarios[name])) assert.deepEqual(result.scenarios[name][key], golden.scenarios[name][key], `${name}.${key}`);
      assert.equal(text, expected, 'byte-identical recording');
    }
    console.log(`PASS prose and large scenarios reproduce the golden byte-for-byte: ${result.scenarios.prose.releases.length} prose releases, ${lpolls[1].candidate_count} large candidates on ${lpolls[1].candidate_pages.length} pages, ${h.sends.length} sends`);
  }
} finally { await h.instance.dispose(); }
