import WebSocket from 'ws';

// CDP reports JS heap, embedder allocations and ArrayBuffer backing storage
// (including committed Wasm linear memory). Keep each component in the report.
export async function sampleRuntimeMemory(inspectorURL) {
  const listing = new URL('/json/list', inspectorURL);
  listing.protocol = 'http:';
  const targets = await (await fetch(listing)).json();
  const target = targets.find(x => x.title?.includes('notifications-feed-runtime')) ?? targets[0];
  if (!target?.webSocketDebuggerUrl) throw new Error('Worker inspector target missing');
  const socket = new WebSocket(target.webSocketDebuggerUrl);
  await new Promise((resolve, reject) => { socket.once('open', resolve); socket.once('error', reject); });
  const pending = new Map();
  let identifier = 0;
  let peak = { totalBytes: 0 };
  let stopped = false;
  let failed;
  const contexts = [];
  socket.on('message', bytes => {
    const message = JSON.parse(bytes);
    if (message.method === 'Runtime.executionContextCreated') contexts.push(message.params.context);
    const waiter = pending.get(message.id);
    if (waiter) {
      pending.delete(message.id);
      clearTimeout(waiter.timeout);
      if (message.error) waiter.reject(new Error(JSON.stringify(message.error)));
      else waiter.resolve(message.result);
    }
  });
  function command(method, params) {
    return new Promise((resolve, reject) => {
      const id = ++identifier;
      const timeout = setTimeout(() => {
        pending.delete(id);
        reject(new Error(`Inspector timed out: ${method}`));
      }, 5000);
      pending.set(id, { resolve, reject, timeout });
      socket.send(JSON.stringify({ id, method, params }));
    });
  }
  async function sample() {
    const value = await command('Runtime.getHeapUsage');
    const totalBytes = value.usedSize + (value.embedderHeapUsedSize ?? 0) + (value.backingStorageSize ?? 0);
    if (totalBytes > peak.totalBytes) peak = { totalBytes, ...value };
  }
  // Observe native cancellation inside workerd. Miniflare's Node service
  // bridge does not propagate cancellation back to its source stream.
  try {
    await command('Runtime.enable');
    if (!contexts.length) throw new Error(`Worker execution context missing: ${JSON.stringify(target)}`);
    const installed = await command('Runtime.evaluate', { contextId: contexts[0].id, expression: `(${installTransportAudit.toString()})()` });
    if (installed.exceptionDetails) throw new Error(JSON.stringify(installed.exceptionDetails));
  } catch (error) { socket.close(); throw error; }
  await sample();
  const sampling = (async () => {
    while (!stopped) {
      await new Promise(resolve => setTimeout(resolve, 25));
      if (!stopped) await sample();
    }
  })().catch(error => { failed = error; });
  let stopping;
  return () => {
    stopping ??= (async () => {
      stopped = true;
      try {
        await sampling;
        await sample();
        if (failed) throw failed;
        const audit = await command('Runtime.evaluate', {
          contextId: contexts[0].id, expression: 'globalThis.__feedTransportAudit', returnByValue: true,
        });
        return { ...peak, transportAudit: audit.result.value };
      } finally { socket.close(); }
    })();
    return stopping;
  };
}

function installTransportAudit() {
  const audit = globalThis.__feedTransportAudit = { aborted: [], readersCancelled: [] };
  const bodies = new WeakMap();
  const readers = new WeakMap();
  const nativeFetch = globalThis.fetch;
  globalThis.fetch = async function(input, init) {
    const name = new URL(typeof input === 'string' ? input : input.url).pathname;
    const tracked = name.startsWith('/stalled-');
    if (tracked) init?.signal?.addEventListener('abort', () => audit.aborted.push(name), { once: true });
    const response = await nativeFetch.call(this, input, init);
    if (tracked && response.body) bodies.set(response.body, name);
    return response;
  };
  const nativeReader = ReadableStream.prototype.getReader;
  ReadableStream.prototype.getReader = function(options) {
    const reader = nativeReader.call(this, options);
    if (bodies.has(this)) readers.set(reader, bodies.get(this));
    return reader;
  };
  const nativeCancel = ReadableStreamBYOBReader.prototype.cancel;
  ReadableStreamBYOBReader.prototype.cancel = function(reason) {
    if (readers.has(this)) audit.readersCancelled.push(readers.get(this));
    return nativeCancel.call(this, reason);
  };
}
