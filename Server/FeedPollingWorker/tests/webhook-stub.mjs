// The operator-alert webhook as a test outbound stub: the alert URL is
// answered as the provider answers it (200, aggregate_status accepted), and
// an idempotency ledger keeps every request's idempotency-key: a key seen
// before is answered 409 idempotency_conflict, the provider's idempotent
// result. With bodyDelayMs the reply carries x-test-body-delay-ms, so the
// FeedPolling test entry hands the Worker its status and headers at once and
// its body that much later, inside the isolate (a delay here, before the
// reply leaves Node, would hold the whole reply: Miniflare buffers it).
// handle() returns null for any other URL.
import { ALERT_WEBHOOK_URL } from './harness.mjs';
const now = () => performance.timeOrigin + performance.now();
export function webhookStub({ url = ALERT_WEBHOOK_URL, bodyDelayMs = 0 } = {}) {
  const ledger = [], seen = new Set();
  return {
    ledger,
    get bodyDelayMs() { return bodyDelayMs; },
    set bodyDelayMs(ms) { bodyDelayMs = ms; },
    async handle(request) {
      if (request.url !== url) return null;
      const key = request.headers.get('idempotency-key'), replay = key !== null && seen.has(key);
      if (key !== null) seen.add(key);
      const entry = { key, replay, status: replay ? 409 : 200, delay_ms: bodyDelayMs, received: now(), payload: await request.clone().json().catch(() => null) };
      ledger.push(entry);
      const body = replay ? { error: { code: 'idempotency_conflict' } } : { aggregate_status: 'accepted' };
      return new Response(JSON.stringify(body), { status: entry.status, headers: { 'content-type': 'application/json', ...(bodyDelayMs > 0 ? { 'x-test-body-delay-ms': String(bodyDelayMs) } : {}) } });
    },
  };
}
