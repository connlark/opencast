// Local workerd test entrypoint only. The production entrypoint and Wasm are
// imported unchanged. This barrier delays a read result after scanning, so an
// abandoned Rust continuation must not reach notification claims/checkpoints.
import worker from '../build/index.js';

let incomingAborts = 0;
const postscanReads = new Set();
const cancellations = new Map();
const pause = () => new Promise(resolve => setTimeout(resolve, 5));

function delayedStatement(statement) {
  return new Proxy(statement, {
    get(target, property) {
      if (property === 'constructor') return target.constructor;
      if (property === 'bind') return (...values) => delayedStatement(target.bind(...values));
      if (property === 'all') return async (...args) => {
        const result = await target.all(...args);
        const pending = { released: false };
        postscanReads.add(pending);
        while (!pending.released) await pause();
        return result;
      };
      const value = Reflect.get(target, property);
      return typeof value === 'function' ? value.bind(target) : value;
    },
  });
}

export default {
  async fetch(request, env, ctx) {
    const path = new URL(request.url).pathname;
    if (path === '/__cancellation-state') {
      return Response.json({ incomingAborts, postscanReads: postscanReads.size, pendingSignals: [...cancellations.keys()] });
    }
    if (path === '/__release-postscan') {
      for (const pending of postscanReads) pending.released = true;
      postscanReads.clear();
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
      // the remote harness separately proves the platform's disconnect wiring.
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
    if (request.headers.get('x-test-postscan') === '1') {
      const database = env.APP_ATTEST_DB;
      env = { ...env, APP_ATTEST_DB: new Proxy(database, {
        get(target, property) {
          if (property === 'constructor') return target.constructor;
          if (property === 'prepare') return sql => {
            const statement = target.prepare(sql);
            return sql.startsWith('SELECT devices.install_id, devices.device_token,')
              ? delayedStatement(statement) : statement;
          };
          const value = Reflect.get(target, property);
          return typeof value === 'function' ? value.bind(target) : value;
        },
      }) };
    }
    try {
      return await new worker(ctx, env).fetch(request);
    } finally {
      if (cancellation) cancellation.finished = true;
      cancellations.delete(cancellationID);
      await watching;
    }
  },
  scheduled: (event, env, ctx) => new worker(ctx, env).scheduled(event),
};
