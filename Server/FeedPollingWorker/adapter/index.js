import { WorkerEntrypoint } from 'cloudflare:workers';
import RustWorker from '../build/index.js';

// The placed route's key, POLL_PLACED_KEY (a Worker secret), is usable only as
// a string of 32 characters or more. The one predicate for both ends of the hop.
function placedKey(env) {
  const key = env.POLL_PLACED_KEY;
  return typeof key === 'string' && key.length >= 32 ? key : null;
}
function invoke(ctx, env, request) {
  // Rust is never handed the key.
  const { POLL_PLACED_KEY: _key, ...bindings } = env;
  return new RustWorker(ctx, { ...bindings, POLLING_CAPABILITY: 'private' }).fetch(request);
}
// A poll delivery's route. The placed route forwards it to this script's own
// default fetch through POLL_PLACED, where placement runs it beside the
// database: when the binding exists, the key is usable, POLL_PLACED_SHARE is
// exactly a decimal integer from 1 to 256 (anything else is 0) and the wake's
// feed_id begins with two lowercase hex digits reading below the share. A feed
// keeps its route at a given share; dead letters and every other message stay
// in process.
export function placedRoute(env, body) {
  if (!env.POLL_PLACED || placedKey(env) === null) return false;
  const text = env.POLL_PLACED_SHARE;
  const share = typeof text === 'string' && /^[1-9][0-9]{0,2}$/.test(text) ? Number(text) : 0;
  if (share > 256) return false;
  const prefix = body?.kind === 'poll' && typeof body.feed_id === 'string' ? /^[0-9a-f]{2}/.exec(body.feed_id) : null;
  return prefix !== null && parseInt(prefix[0], 16) < share;
}
const hex = bytes => Array.from(bytes, b => b.toString(16).padStart(2, '0')).join('');
const digest16 = async id => hex(new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(id)))).slice(0, 16);
// The key compared in constant time; a different length is a mismatch.
function keyMatches(sent, key) {
  if (sent === null) return false;
  const a = new TextEncoder().encode(sent), b = new TextEncoder().encode(key);
  return a.byteLength === b.byteLength && crypto.subtle.timingSafeEqual(a, b);
}
// The placed route of one poll delivery. The engine is handed the body, the
// attempts and the enqueue time, never the message id: a placed engine can
// outlive this invocation, and a redelivery carrying the id would reclaim the
// live engine's scan permits. Acknowledged only on a fully read ok or 400
// response that carries the engine's header; anything else is retried, and a
// rejection (the 230 s bound included) throws out of queue() unacknowledged.
async function placedConsume(env, message) {
  const body = message.body, attempts = message.attempts ?? 1;
  const headers = { 'x-poll-attempts': String(attempts), 'x-poll-enqueued-ms': String(message.timestamp.getTime()), 'x-poll-placed-key': placedKey(env) };
  const chain = async () => ({ feed: body.feed_id, generation: body.generation, step: body.step, attempts, message: await digest16(message.id) });
  // A cohort feed (first hex digit below 4, the witness's rule) gets a token,
  // hop, that ties the callee's poll_placed line and witness row to its lines.
  let line = null;
  if (/^[0-3]/.test(body.feed_id)) {
    line = { hop: hex(crypto.getRandomValues(new Uint8Array(8))), ...await chain() };
    headers['x-poll-hop'] = line.hop;
    console.log(JSON.stringify({ event: 'poll_hop_start', ...line }));
  }
  const started = Date.now();
  const response = await env.POLL_PLACED.fetch('https://polling.invalid/consume', {
    method: 'POST', body: JSON.stringify(body), headers, signal: AbortSignal.timeout(230000),
  });
  await response.text();
  const engineMs = response.headers.get('x-poll-engine-ms'), engine = engineMs !== null;
  const acknowledged = engine && (response.ok || response.status === 400);
  if (line || !acknowledged) {
    const hop = { event: 'poll_hop', ...(line ?? await chain()), status: response.status, engine, hop_ms: Date.now() - started, engine_ms: engine ? Number(engineMs) : null, placement: response.headers.get('cf-placement') };
    (acknowledged ? console.log : console.warn)(JSON.stringify(hop));
  }
  if (acknowledged) message.ack();
  else message.retry({ delaySeconds: 60 });
}
// Only private service bindings expose operator inspection/repair. Public HTTP
// never receives this capability, even with forged headers or matching paths.
export class PollingControl extends WorkerEntrypoint {
  fetch(request) { return invoke(this.ctx, this.env, request); }
}
export default class extends WorkerEntrypoint {
  // The placed consume: POST /consume carrying this script's key, from its own
  // queue handler through POLL_PLACED. Everything else is 404 without entering
  // Rust. The engine gets a request built here (the body and the two delivery
  // headers), never the caller's request, its signal, the key or the token.
  async fetch(request) {
    const entered = Date.now(), key = placedKey(this.env);
    if (request.method !== 'POST' || new URL(request.url).pathname !== '/consume' || key === null || !keyMatches(request.headers.get('x-poll-placed-key'), key)) {
      return new Response('not_found', { status: 404 });
    }
    const hop = request.headers.get('x-poll-hop');
    if (hop !== null && /^[0-9a-f]{16}$/.test(hop)) console.log(JSON.stringify({ event: 'poll_placed', hop }));
    const headers = {};
    for (const name of ['x-poll-attempts', 'x-poll-enqueued-ms']) { const value = request.headers.get(name); if (value !== null) headers[name] = value; }
    const engine = await invoke(this.ctx, this.env, new Request('https://polling.invalid/consume', { method: 'POST', body: await request.text(), headers }));
    const response = new Response(engine.body, engine);
    response.headers.set('x-poll-engine-ms', String(Date.now() - entered));
    return response;
  }
  async scheduled(controller) {
    const path = controller.cron === '* * * * *' ? 'dispatch'
      : controller.cron === '*/2 * * * *' ? 'cleanup' : undefined;
    if (!path) throw new Error('unknown_poll_cron');
    // The scheduled time is a diagnostic for the storage timing witness only.
    const response = await invoke(this.ctx, this.env, new Request(`https://polling.invalid/${path}`, {
      method: 'POST', headers: { 'x-poll-scheduled-ms': String(controller.scheduledTime) },
    }));
    if (!response.ok) throw new Error(`poll_${path}_failed`);
    await response.text();
  }
  async queue(batch) {
    if (batch.queue.endsWith('-dlq')) {
      console.warn(JSON.stringify({ event: 'poll_dead_letters', count: batch.messages.length }));
      // The feed row is the recovery source, even after queue retention ends:
      // back the feed off and settle its generation, then drop the message.
      for (const message of batch.messages) {
        const response = await invoke(this.ctx, this.env, new Request('https://polling.invalid/dead-letter', {
          method: 'POST', body: JSON.stringify(message.body),
        }));
        await response.text();
        if (response.ok || response.status === 400) message.ack();
        else message.retry({ delaySeconds: 60 });
      }
      return;
    }
    // The message is the poll-attempt lease. Acknowledge only after the fenced
    // feed/checkpoint and event commit; any failure or crash redelivers it.
    for (const message of batch.messages) {
      if (placedRoute(this.env, message.body)) { await placedConsume(this.env, message); continue; }
      const response = await invoke(this.ctx, this.env, new Request('https://polling.invalid/consume', {
        method: 'POST', body: JSON.stringify(message.body), headers: { 'x-poll-attempts': String(message.attempts ?? 1), 'x-poll-enqueued-ms': String(message.timestamp.getTime()), 'x-poll-message-id': message.id },
      }));
      await response.text();
      if (response.ok || response.status === 400) message.ack();
      else message.retry({ delaySeconds: 60 });
    }
  }
}
