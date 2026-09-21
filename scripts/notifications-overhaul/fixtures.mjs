// Owned synthetic inputs. Never fetch these reserved domains on the network.
import { createHash } from 'node:crypto';
import { Readable } from 'node:stream';
import { createGzip } from 'node:zlib';
export const T = 1_800_000_000;
export const feedURL = 'https://fixtures.example.invalid/private/feed.xml?token=SYNTHETIC_ONLY';
export const hash = value => createHash('sha256').update(value).digest('hex');
export const episode = (id, date = T, extra = {}) => ({ id, title: `Episode ${id}`, date, fingerprint: `visible-${id}`, ...extra });
const old = episode('old', T - 86400);
export const feedCases = [
  { id: 'F01', name: 'quiet baseline', baseline: [], items: [old], initial: true, events: [], reason: 'baseline' },
  { id: 'F02', name: 'pinned top', baseline: [old], items: [old, episode('new')], events: ['new'] },
  { id: 'F03', name: 'reorder', baseline: [old, episode('other')], items: [episode('other'), old], events: [] },
  { id: 'F04', name: 'missing anchor', baseline: [old], items: [episode('new')], events: ['new'] },
  { id: 'F05', name: 'five releases', baseline: [old], items: ['a','b','c','d','e'].map(x => episode(x)), events: ['a','b','c','d','e'], group: true },
  { id: 'F06', name: 'bonus and regular', baseline: [old], items: [episode('bonus',T-20), episode('regular')], events: ['bonus','regular'] },
  { id: 'F07', name: 'stale backfill', baseline: [old], items: [episode('archive',T-259201)], events: [], reason: 'stale' },
  { id: 'F08', name: '72-hour boundary', baseline: [old], items: [episode('boundary',T-259200)], events: ['boundary'] },
  { id: 'F09', name: 'undated', baseline: [old], items: [episode('undated',null)], events: ['undated'] },
  { id: 'F10', name: 'invalid date', baseline: [old], items: [episode('invalid','not-a-date')], events: ['invalid'] },
  { id: 'F11', name: 'clock skew inclusive ten minutes', baseline: [old], items: [episode('skew',T+600)], events: ['skew'] },
  { id: 'F12', name: 'defer future', baseline: [old], items: [episode('future',T+601)], events: [], pending: ['future'] },
  { id: 'F13', name: 'seven-day future inclusive', baseline: [old], items: [episode('future',T+604800)], events: [], pending: ['future'] },
  { id: 'F14', name: 'anomalous future', baseline: [old], items: [episode('anomaly',T+604801)], events: ['anomaly'], reason: 'anomalous_date' },
  { id: 'F15', name: 'GUID churn', baseline: [old], items: [episode('new-guid',T,{fingerprint:old.fingerprint})], events: [], reason: 'identity_churn' },
  { id: 'F16', name: 'metadata correction', baseline: [old], items: [{...old,title:'Edited title'}], events: [] },
  { id: 'F17', name: 'invalid XML tail', baseline: [old], items: [episode('new')], fault:'invalid_tail', events: [] },
  { id: 'F18', name: 'cancelled stream', baseline: [old], items: [episode('new')], fault:'cancel', events: [] },
  { id: 'F19', name: 'inactivity timeout', baseline: [old], items: [episode('new')], fault:'timeout', events: [] },
  { id: 'F20', name: 'conditional not modified', baseline: [old], items: [], status:304, events: [] },
];
const escapeXML = value => String(value).replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('"','&quot;');
export function* rssChunks(items, { invalidTail = false, padding = 0 } = {}) {
  yield '<rss version="2.0"><channel><title>Owned fixture 🎧</title>';
  for (const item of items) {
    const date = item.date == null ? '' : `<pubDate>${typeof item.date === 'number' ? new Date(item.date*1000).toUTCString() : escapeXML(item.date)}</pubDate>`;
    yield `<item><guid>${escapeXML(item.id)}</guid><title>${escapeXML(item.title)}</title>${date}<enclosure url="https://audio.example.invalid/${escapeXML(item.id)}.mp3"/><description>${'x'.repeat(padding)}</description></item>`;
  }
  yield invalidTail ? '<item><title>truncated' : '</channel></rss>';
}
export function* catalog(count) { for (let n=0;n<count;n++) yield episode(`catalog-${n}`,T-n*60); }
export function rssStream(items, options = {}) {
  const source = Readable.from(rssChunks(items,options));
  return options.gzip ? source.pipe(createGzip()) : source;
}
export class Clock {
  constructor(now=T) { this.now=now; }
  advance(seconds) { if(seconds<0) throw Error('clock reversal'); this.now+=seconds; }
}
export class Faults {
  constructor(...points) { this.points=new Set(points); }
  hit(point) { if(this.points.delete(point)) throw Error(`fault:${point}`); }
}
export class FakeAPNs {
  constructor(...outcomes) { this.outcomes=outcomes; this.requests=[]; this.accepted=[]; }
  send(request) {
    this.requests.push(structuredClone(request));
    const outcome=this.outcomes.shift() ?? {status:200};
    if(outcome.status===200 || outcome.lostResponse) this.accepted.push(request.id);
    if(outcome.lostResponse || outcome.timeout) throw Error('uncertain');
    return outcome;
  }
}
