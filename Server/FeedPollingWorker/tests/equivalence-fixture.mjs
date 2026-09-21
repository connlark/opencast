// One publishing history, driven through whichever executor this checkout
// builds. `equivalence.mjs` runs it against the previous complete-observation
// path and the cost-reset path and compares every release, event and send.
// It uses only the harness surface both versions share.
import { createHash } from 'node:crypto';
import { writeFile } from 'node:fs/promises';
import { harness } from './harness.mjs';
const out = process.argv[2];
if (!out) throw Error('usage: equivalence-fixture.mjs <output.json>');
let round = 1;
const entry = ({ guid, at, title, audio, summary }) => `<item><guid>${guid}</guid><title>${title ?? `Episode ${guid}`}</title>${at == null ? '' : `<pubDate>${new Date(at * 1000).toUTCString()}</pubDate>`}${summary ? `<description>${summary}</description>` : ''}<enclosure url="https://audio.example.com/${audio ?? guid}.mp3"/></item>`;
const day = 86400;
// Each history returns the complete document for a round.
const histories = now => ({
  // Reordering and a pinned top item are not releases; a release below the
  // pin and out of date order still is.
  'reordered-pinned': r => {
    const pin = { guid: 'pin', at: now - 30 * day }, a = [1, 2, 3].map(i => ({ guid: `a${i}`, at: now - (6 - i) * day }));
    if (r === 1) return [pin, ...a];
    if (r === 2) return [a[2], a[0], pin, a[1]];
    return [pin, a[1], a[2], a[0], { guid: 'a4', at: now - 60 }];
  },
  // Edited metadata changes a fingerprint, never an identity. Then a regular
  // and a bonus release arrive together.
  'edited-bonus': r => {
    const b = [{ guid: 'b1', at: now - 10 * day }, { guid: 'b2', at: now - 9 * day }];
    if (r === 1) return b;
    if (r === 2) return [{ ...b[0], title: 'Episode b1 (remastered)', summary: 'New notes' }, b[1]];
    return [{ guid: 'b3-bonus', at: now - 50 }, { guid: 'b3', at: now - 100 }, { ...b[0], title: 'Episode b1 (remastered)', summary: 'New notes' }, b[1]];
  },
  // A publisher that only lists its newest five items.
  'limited-catch-up': r => {
    const all = Array.from({ length: 8 }, (_, i) => ({ guid: `c${i + 1}`, at: i < 5 ? now - (20 - i) * day : now - (40 - i * 4) }));
    return all.slice(r === 1 ? 0 : r === 2 ? 1 : 3, r === 1 ? 5 : r === 2 ? 6 : 8).reverse();
  },
  // No validators and no dates: only complete prior absence dates a release.
  'no-validators-undated': r => [...(r === 3 ? [{ guid: 'd3' }] : []), { guid: 'd1' }, { guid: 'd2' }],
  // Futures are stored, one is withdrawn, the other matures at its own time.
  'future-withdrawn': r => [{ guid: 'e1', at: now - day }, ...(r >= 2 ? [{ guid: 'e2', at: now + 7200 }] : []), ...(r === 2 ? [{ guid: 'e3', at: now + 10800 }] : [])],
  // More than three releases are one immutable group.
  burst: r => [{ guid: 'f0', at: now - 3 * day }, ...(r >= 2 ? Array.from({ length: 6 }, (_, i) => ({ guid: `f${i + 1}`, at: now - 600 + i })) : [])],
  // A new GUID for a known episode, and a genuinely old backfill.
  'churn-stale': r => [{ guid: r >= 2 ? 'g1-reissued' : 'g1', audio: 'g1', title: 'Episode g1', at: now - 2 * day }, ...(r === 3 ? [{ guid: 'g-archive', at: now - 400 * day }] : [])],
});
let documents;
const h = await harness(request => {
  const name = new URL(request.url).hostname.split('.')[0];
  const body = `<rss><channel><title>${name}</title>${documents[name](round).map(entry).join('')}</channel></rss>`;
  if (name.startsWith('no-validators')) return new Response(body);
  const etag = `"${createHash('sha256').update(body).digest('hex').slice(0, 16)}"`;
  if (request.headers.get('if-none-match') === etag) return new Response(null, { status: 304 });
  return new Response(body, { headers: { etag } });
});
documents = histories(h.now);
const clock = async seconds => {
  await h.invoke('clock', String(seconds));
  const worker = await h.instance.getWorker('delivery-runtime');
  await (await worker.fetch('https://delivery.invalid/clock', { method: 'POST', body: String(seconds) })).text();
};
const poll = async () => {
  await h.run('UPDATE n_feed SET due_at=0,retry_at=0,dispatch_until=0');
  await h.invoke('test/dispatch'); await h.drain(); await h.deliver(true);
};
try {
  const names = Object.keys(documents), ids = {};
  for (const name of names) ids[await h.add(`https://${name}.example.com/feed`)] = name;
  for (round = 1; round <= 3; round++) { await clock((round - 1) * 120); await poll(); }
  // An unchanged extra poll, then the surviving future matures.
  round = 3; await clock(400); await poll();
  await clock(7300); await poll(); await clock(7400); await poll();
  const releases = await h.rows('SELECT r.*,o.scan_started_at FROM n_episode_release r JOIN n_observation o ON o.observation_id=r.observation_id ORDER BY r.feed_id,r.episode_id');
  const events = await h.rows('SELECT * FROM n_event ORDER BY event_id');
  const groups = {};
  for (const r of releases) (groups[r.presentation_key] ??= []).push(r.episode_id);
  const result = {
    releases: releases.map(r => ({
      feed: ids[r.feed_id], episode_id: r.episode_id, event_id: r.event_id, reason: r.reason, state: r.state, disposition: r.disposition,
      fingerprint: r.fingerprint, published_vs_base: r.published_at == null ? null : r.published_at - h.now,
      // Seconds of wall clock differ between two runs; every deadline is
      // compared relative to the scan that first observed the release.
      first_observed_vs_scan: r.first_observed_at - r.scan_started_at,
      eligible: r.reason === 'future' ? { vs_base: r.eligible_at - h.now } : { vs_scan: r.eligible_at - r.scan_started_at },
      delivery_window: r.expires_at - r.eligible_at, group: groups[r.presentation_key].toSorted(),
    })),
    events: events.map(e => ({ event_id: e.event_id, kind: e.kind, source: e.source, window: e.expires_at - e.eligible_at })),
    deliveries: await h.rows("SELECT interest_key,state,member_count FROM n_delivery ORDER BY interest_key,member_count,state").then(rows => rows.map(d => ({ feed: ids[d.interest_key], state: d.state, member_count: d.member_count }))),
    sends: h.sends.map(s => ({ category: s.aps.category, count: s.opencast.episode_count ?? 1, episode: s.opencast.episode_id })).toSorted((a, b) => JSON.stringify(a).localeCompare(JSON.stringify(b))),
    fetches: h.fetches.length,
  };
  await writeFile(out, JSON.stringify(result, null, 2));
  console.log(`WROTE ${result.releases.length} releases, ${result.events.length} events, ${result.sends.length} sends`);
} finally { await h.instance.dispose(); }
