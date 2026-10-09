// The strong-ETag shortcut: a 200 whose strong ETag (and Last-Modified, when one
// is stored) equals the validators stored for the same URL within the last 24 h
// settles as a fenced 304 without reading the body. The publisher here ignores
// If-None-Match and always answers 200 with a per-version strong tag.
import assert from 'node:assert/strict';
import { harness, item, rss } from './harness.mjs';

const DAY = 86400, LM1 = 'Wed, 07 Oct 2026 12:00:00 GMT', LM2 = 'Thu, 08 Oct 2026 12:00:00 GMT';
const FEED = 'https://etag.example.com/feed', HOP = 'https://hop.example.com/feed', CDN = 'https://cdn.example.net/c';
// One response per URL path; a redirect entry answers 302 to its target.
const serve = new Map(), requests = new Map();
const h = await harness(request => {
  requests.set(request.url, (requests.get(request.url) ?? 0) + 1);
  const r = serve.get(request.url);
  if (!r) return new Response('missing', { status: 404 });
  if (r.location) return new Response(null, { status: 302, headers: { location: r.location } });
  return new Response(rss(r.items), { headers: { etag: r.etag, ...(r.modified ? { 'last-modified': r.modified } : {}) } });
});
let offset = 0;
// The polling clock is frozen at h.now; each poll moves it forward explicitly so
// every settle has its own second. The delivery worker follows the same offset.
async function at(seconds) {
  offset = seconds; await h.invoke('clock', String(seconds));
  const delivery = await h.instance.getWorker('delivery-runtime');
  await (await delivery.fetch('https://delivery.invalid/clock', { method: 'POST', body: String(seconds) })).text();
}
// `*`: on a build without the validator columns the first red is the outcome.
const row = feed => h.first('SELECT * FROM n_feed WHERE feed_id=?', feed);
// One scheduled poll, `step` seconds after the previous one: dispatch, consume
// the poll message (its response JSON is kept), then drain any continuation.
async function poll(feed, url, step = 60) {
  await at(offset + step);
  await h.run('UPDATE n_feed SET due_at=0,retry_at=0,poll_failures=0,dispatch_until=0 WHERE feed_id=?', feed);
  await h.run('DELETE FROM n_poll_origin');
  const seen = requests.get(url) ?? 0, before = await h.invoke('metrics');
  await h.invoke('test/dispatch');
  const wake = (await h.polls()).find(w => w.feed_id === feed); assert.ok(wake, 'feed was not dispatched');
  const consumed = await h.consume(wake); assert.equal(consumed.status, 200, consumed.text);
  await h.drain();
  const after = await h.invoke('metrics');
  assert.equal(requests.get(url) ?? 0, seen + 1, `the publisher saw exactly one request to ${url}`);
  return { result: JSON.parse(consumed.text), r2: ['get', 'put', 'head', 'multipart'].map(k => after[k] - before[k]), state: await row(feed) };
}
const parsed = (p, outcome, label) => { assert.equal(p.state.last_poll_outcome, outcome, label); assert.equal(p.result.via ?? null, null, `${label}: a parsed poll carries no via`); };
const shortcut = (p, label) => {
  assert.equal(p.result.outcome, 'not_modified', label);
  assert.equal(p.state.last_poll_outcome, 'not_modified', label);
  assert.equal(p.result.via, 'strong_etag', label);
  assert.deepEqual(p.r2, [0, 0, 0, 0], `${label}: no R2 get/put/head/multipart`);
};
const v1 = [item('base', h.now - 3600)];
try {
  await h.invoke('freeze', String(h.now));
  await at(0);
  const feed = await h.add(FEED);
  serve.set(FEED, { items: v1, etag: '"v1"', modified: LM1 });

  // 1. The first parse binds the validators to the URL that answered and to now.
  let p = await poll(feed, FEED, 0);
  assert.equal(p.state.last_poll_outcome, 'published');
  assert.deepEqual([p.state.etag, p.state.last_modified], ['"v1"', LM1]);
  assert.match(p.state.semantic_digest, new RegExp(`^${p.state.snapshot_key}:[0-9a-f]{64}$`));
  const bound = p.state;
  console.log('PASS case 1: first parse publishes and stores etag/last_modified with a bound digest');

  // 2. Same body and tag: the request is made, the body is never read.
  p = await poll(feed, FEED);
  shortcut(p, 'step 2');
  assert.ok(p.state.last_success_at > bound.last_success_at, 'the settle advanced last_success_at');
  assert.deepEqual([p.state.etag, p.state.last_modified, p.state.validator_url, p.state.validator_at, p.state.observation_generation, p.state.semantic_digest],
    [bound.etag, bound.last_modified, bound.validator_url, bound.validator_at, bound.observation_generation, bound.semantic_digest], 'a shortcut settle writes no validator and no observation');
  // Step 1's binding, read after the outcome so a build without the shortcut
  // fails on the outcome: the first parse bound the validators to the URL that
  // answered and to the frozen now, and the shortcut left them as they were.
  assert.deepEqual([bound.validator_url, bound.validator_at], [FEED, h.now], 'step 1 bound the validators to the feed URL and its parse time');
  console.log('PASS case 2: equal strong ETag within 24 h settles as not_modified via strong_etag with zero R2; validators stay bound to step 1 (validator_url = feed URL, validator_at = frozen now)');

  // 3. The trust window is 24 h from the last parse: one second past it parses.
  await at(DAY + 1 - 60);
  p = await poll(feed, FEED);
  parsed(p, 'unchanged', 'step 3: expired window');
  assert.equal(p.state.validator_at, h.now + DAY + 1, 'the parse refreshed validator_at');
  shortcut(await poll(feed, FEED), 'step 3: refreshed window');
  console.log('PASS case 3: a match 24 h + 1 s after the last parse is parsed and refreshes validator_at; the next poll is the shortcut again');

  // 4. A weak tag is never trusted, and a strong tag never matches a stored weak one.
  serve.get(FEED).etag = 'W/"v1"';
  p = await poll(feed, FEED); parsed(p, 'unchanged', 'step 4: weak'); assert.equal(p.state.etag, 'W/"v1"');
  serve.get(FEED).etag = '"v1"';
  p = await poll(feed, FEED); parsed(p, 'unchanged', 'step 4: strong after weak'); assert.equal(p.state.etag, '"v1"');
  shortcut(await poll(feed, FEED), 'step 4: strong after strong');
  console.log('PASS case 4: weak ETag parses; strong after a stored weak tag parses once, then the shortcut');

  // 5. A stored Last-Modified must agree.
  serve.get(FEED).modified = LM2;
  p = await poll(feed, FEED); parsed(p, 'unchanged', 'step 5'); assert.equal(p.state.last_modified, LM2);
  console.log('PASS case 5: same ETag with a different Last-Modified parses');

  // 6. Only a digest bound to the current snapshot may skip the parse; a missing
  // or foreign-bound digest is parsed and repaired.
  for (const [label, sql] of [['missing', 'UPDATE n_feed SET semantic_digest=NULL WHERE feed_id=?'], ['foreign', "UPDATE n_feed SET semantic_digest='snapshots/foreign/key:'||substr(semantic_digest,length(snapshot_key)+2) WHERE feed_id=?"]]) {
    await h.run(sql, feed);
    p = await poll(feed, FEED);
    assert.notEqual(p.result.outcome, 'not_modified', `step 6 ${label}`); assert.notEqual(p.state.last_poll_outcome, 'not_modified', `step 6 ${label}`);
    assert.equal(p.result.via ?? null, null);
    assert.match(p.state.semantic_digest, new RegExp(`^${p.state.snapshot_key}:[0-9a-f]{64}$`), `step 6 ${label}: repaired`);
    shortcut(await poll(feed, FEED), `step 6 ${label}: after repair`);
  }
  console.log('PASS case 6: a missing or foreign-bound digest is parsed and repaired, never the shortcut');

  // 7. A real change with a new tag publishes, with the same notification text.
  const events = (await h.first('SELECT COUNT(*) AS n FROM n_event')).n;
  const seventh = item('seventh', h.now + offset + 60 - 10, 'Step seven', '<![CDATA[<p>Fresh <strong>news</strong> &amp; notes.</p><p>Second paragraph.</p>]]>');
  Object.assign(serve.get(FEED), { items: [...v1, seventh], etag: '"v2"' });
  p = await poll(feed, FEED);
  parsed(p, 'published', 'step 7');
  assert.equal((await h.first('SELECT COUNT(*) AS n FROM n_event')).n, events + 1);
  // The only release this feed has: the baseline is quiet. Expected prose by
  // hand: inline <strong> adds no space, </p><p> is one, &amp; decodes.
  const payload = await h.rows("SELECT json_extract(x.payload_json,'$.data.episode_title') AS title,json_extract(x.payload_json,'$.data.episode_summary') AS summary FROM n_outbox x JOIN n_episode_release r ON r.event_id=x.event_id WHERE r.feed_id=?", feed);
  assert.deepEqual(payload, [{ title: 'Step seven', summary: 'Fresh news & notes. Second paragraph.' }]);
  console.log('PASS case 7: changed body with a new ETag publishes one event with the expected title and cleaned summary');

  // 8. The accepted, time-bounded tradeoff: a non-compliant host that changes
  // the body but keeps the strong tag and Last-Modified is not re-read until the
  // 24 h trust window from the last parse has passed.
  const changedAt = offset;
  const eighth = item('eighth', h.now + changedAt + DAY + 1 - 10, 'Step eight');
  serve.get(FEED).items = [...v1, seventh, eighth];
  const releases = async () => (await h.first('SELECT COUNT(*) AS n FROM n_episode_release WHERE feed_id=?', feed)).n, known = await releases();
  shortcut(await poll(feed, FEED), 'step 8: inside the window');
  assert.equal(await releases(), known, 'nothing new inside the window');
  await at(changedAt + DAY + 1 - 60);
  p = await poll(feed, FEED);
  parsed(p, 'published', 'step 8: after the window');
  assert.equal(await releases(), known + 1);
  console.log('PASS case 8: changed body behind an equal strong ETag is the shortcut inside 24 h and publishes after it');

  // 9. Validators belong to the URL that answered. A redirect to a new target
  // with an equal tag is a different resource; a stable target keeps matching.
  const hop = await h.add(HOP), A = 'https://hop.example.com/a', B = 'https://hop.example.com/b';
  serve.set(A, { items: [item('hop-base', h.now - 3600)], etag: '"v1"' });
  serve.set(HOP, { location: A });
  p = await poll(hop, A); assert.equal(p.state.last_poll_outcome, 'published'); assert.equal(p.state.validator_url, A);
  serve.set(B, { items: [item('hop-base', h.now - 3600), item('hop-new', h.now + offset + 60 - 10)], etag: '"v1"' });
  serve.set(HOP, { location: B });
  p = await poll(hop, B); parsed(p, 'published', 'step 9: /a -> /b'); assert.equal(p.state.validator_url, B);
  serve.set(CDN, { items: serve.get(B).items, etag: '"v1"' });
  serve.set(HOP, { location: CDN });
  p = await poll(hop, CDN); parsed(p, 'unchanged', 'step 9: first cross-origin hop'); assert.equal(p.state.validator_url, CDN);
  shortcut(await poll(hop, CDN), 'step 9: stable cross-origin target');
  console.log('PASS case 9: a redirect target change with an equal tag parses and rebinds validator_url; a stable cross-origin target takes the shortcut');
} finally { await h.instance.dispose(); }
