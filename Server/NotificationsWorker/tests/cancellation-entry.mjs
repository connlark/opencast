// Local workerd test entrypoint only. The production entrypoint and Wasm are
// imported unchanged. This barrier delays a read result after scanning, so an
// abandoned Rust continuation must not reach notification claims/checkpoints.
import worker, {FeedObservations} from '../adapter/index.js';

let incomingAborts = 0;
const cancellations = new Map();
const pause = () => new Promise(resolve => setTimeout(resolve, 5));

// The post-scan hold is the wire proxy's hold-response (tests/postgres/proxy.mjs),
// armed for the request that carries x-test-postscan through TEST_STORAGE,
// storage.mjs's Node function for this Worker's proxy alias.
async function storage(env, op) {
  const response = await env.TEST_STORAGE.fetch('https://test-storage.invalid/', { method: 'POST', body: JSON.stringify(op) });
  const body = await response.json();
  if (!response.ok) throw Error(`TEST_STORAGE ${op.op}: ${body.error}`);
  return body;
}

export default {
  async fetch(request, env, ctx) {
    const path = new URL(request.url).pathname;
    if (path === '/__cancellation-state') {
      // A fired, unreleased storage hold answers; otherwise none is held.
      let reads = 0;
      if (env.TEST_STORAGE) {
        const held = await storage(env, { op: 'state', which: 'postscan-reads' });
        if (held.value !== null) reads = held.value;
      }
      return Response.json({ incomingAborts, postscanReads: reads, pendingSignals: [...cancellations.keys()] });
    }
    if (path === '/__release-postscan') {
      if (env.TEST_STORAGE) await storage(env, { op: 'release', kind: 'release-postscan' });
      return new Response('released');
    }
    if (path === '/__cancel') {
      const id = new URL(request.url).searchParams.get('id');
      const found = cancellations.has(id);
      const pending = cancellations.get(id);
      if (pending) pending.requested = true;
      cancellations.delete(id);
      return Response.json({ id, found });
    }
    const cancellationID = request.headers.get('x-test-cancel');
    let cancellation;
    let watching;
    if (cancellationID) {
      // Miniflare's HTTP proxy does not reliably propagate socket disconnects.
      // A native, controllable signal tests the real Rust entrypoint locally;
      // platform disconnect propagation is distinct from this cancellation proof.
      const controller = new AbortController();
      cancellation = { requested: false, finished: false };
      cancellations.set(cancellationID, cancellation);
      request = new Request(request, { signal: controller.signal });
      watching = (async () => {
        while (!cancellation.requested && !cancellation.finished) await pause();
        // Native I/O must be canceled in its originating request context.
        if (cancellation.requested) controller.abort();
      })();
    }
    if (cancellationID) {
      request.signal.addEventListener('abort', () => incomingAborts++, { once: true });
    }
    let postscan;
    if (request.headers.get('x-test-postscan') === '1' && env.TEST_STORAGE) {
      postscan = await storage(env, { op: 'arm', kind: 'postscan' });
    }
    try {
      return await new FeedObservations(ctx, env).fetch(new Request(request.url.replace('/observation',''),request));
    } finally {
      if (cancellation) cancellation.finished = true;
      cancellations.delete(cancellationID);
      await watching;
      // The header's arming ends with its request.
      if (postscan) await storage(env, { op: 'arm', kind: 'postscan-done', arming: postscan.arming });
    }
  },
  scheduled: (event, env, ctx) => new worker(ctx, env).scheduled(event),
};
