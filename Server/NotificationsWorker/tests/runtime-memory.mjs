import WebSocket from 'ws';

// CDP reports JS heap, embedder allocations and ArrayBuffer backing storage
// separately. workerd does not include Wasm linear memory in these counters;
// a Wasm caller must add its own measured linear memory (see observation stats).
export async function sampleRuntimeMemory(inspectorURL, targetName = 'notifications-feed-runtime', timeoutMs = 5000) {
  const listing = new URL('/json/list', inspectorURL);
  listing.protocol = 'http:';
  const targets = await (await fetch(listing)).json();
  const target = targets.find(x => x.title?.includes(targetName)) ?? targets[0];
  if (!target?.webSocketDebuggerUrl) throw new Error('Worker inspector target missing');
  const socket = new WebSocket(target.webSocketDebuggerUrl);
  await new Promise((resolve, reject) => { socket.once('open', resolve); socket.once('error', reject); });
  const pending = new Map();
  let identifier = 0;
  let peak = { totalBytes: 0 };
  let peakCombined = { totalBytes: 0 };
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
      }, timeoutMs);
      pending.set(id, { resolve, reject, timeout });
      socket.send(JSON.stringify({ id, method, params }));
    });
  }
  async function sample() {
    const value = await command('Runtime.getHeapUsage');
    const totalBytes = value.usedSize + (value.embedderHeapUsedSize ?? 0) + (value.backingStorageSize ?? 0);
    if (totalBytes > peak.totalBytes) peak = { totalBytes, ...value };
    const wasm = await command('Runtime.evaluate', {
      contextId: contexts[0].id, expression: 'globalThis.__feedTransportAudit.wasmBytes ?? 0', returnByValue: true,
    });
    const wasmBytes = wasm.result.value;
    if (totalBytes + wasmBytes > peakCombined.totalBytes) peakCombined = {
      totalBytes: totalBytes + wasmBytes, wasmBytes, ...value,
    };
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
  const stop = () => {
    stopping ??= (async () => {
      stopped = true;
      try {
        await sampling;
        await sample();
        if (failed) throw failed;
        const audit = await command('Runtime.evaluate', {
          contextId: contexts[0].id, expression: 'globalThis.__feedTransportAudit', returnByValue: true,
        });
        return { ...peak, peakCombined, inspectorTarget: {title:target.title,url:target.url}, transportAudit: audit.result.value };
      } finally { socket.close(); }
    })();
    return stopping;
  };
  stop.snapshot = async () => { await sample(); return { ...peak, peakCombined }; };
  stop.transportAudit = async () => {
    const audit = await command('Runtime.evaluate', {
      contextId: contexts[0].id, expression: 'globalThis.__feedTransportAudit', returnByValue: true,
    });
    return audit.result.value;
  };
  // workerd accepts one debugger connection per isolate. Share this session
  // when collecting CPU and memory together instead of replacing its socket.
  stop.profileCPU = async () => {
    await command('Profiler.enable');
    await command('Profiler.setSamplingInterval', { interval: 1000 });
    await command('Profiler.start');
    return async () => ({ ...(await command('Profiler.stop')), target: target.title });
  };
  return stop;
}

function installTransportAudit() {
  const audit = globalThis.__feedTransportAudit = {
    aborted: [], readersCancelled: [], readerBytes: {},
    activeByOrigin: {}, peakByOrigin: {}, completedTransports: 0, abortedTransports: 0,
  };
  // Workerd omits Wasm linear memory from Runtime.getHeapUsage. Observe the
  // real buffer at allocation/growth so each sample adds its contemporaneous
  // size, rather than adding unrelated peaks from different invocations.
  const memoryBuffer = Object.getOwnPropertyDescriptor(WebAssembly.Memory.prototype, 'buffer');
  Object.defineProperty(WebAssembly.Memory.prototype, 'buffer', {...memoryBuffer, get() {
    const buffer = memoryBuffer.get.call(this);
    audit.wasmBytes = Math.max(audit.wasmBytes ?? 0, buffer.byteLength);
    return buffer;
  }});
  const bodies = new WeakMap();
  const readers = new WeakMap();
  const nativeFetch = globalThis.fetch;
  globalThis.fetch = async function(input, init) {
    const url = new URL(typeof input === 'string' ? input : input.url);
    const name = url.pathname;
    const tracked = name.startsWith('/stalled-') || name.startsWith('/cancel-');
    const origin = url.origin;
    audit.activeByOrigin[origin] = (audit.activeByOrigin[origin] ?? 0) + 1;
    audit.peakByOrigin[origin] = Math.max(audit.peakByOrigin[origin] ?? 0, audit.activeByOrigin[origin]);
    let finished = false;
    const finish = () => {
      if (finished) return;
      finished = true;
      audit.activeByOrigin[origin]--;
      audit.completedTransports++;
    };
    const signal = init?.signal ?? input?.signal;
    const abort = () => {
      if (tracked) audit.aborted.push(name);
      if (!finished) audit.abortedTransports++;
      finish();
    };
    signal?.addEventListener('abort', abort, { once: true });
    if (signal?.aborted) abort();
    try {
      const response = await nativeFetch.call(this, input, init);
      if (response.body) bodies.set(response.body, { name, tracked, finish });
      else finish();
      return response;
    } catch (error) { finish(); throw error; }
  };
  const nativeReader = ReadableStream.prototype.getReader;
  ReadableStream.prototype.getReader = function(options) {
    const reader = nativeReader.call(this, options);
    if (bodies.has(this)) readers.set(reader, bodies.get(this));
    return reader;
  };
  const nativeCancel = ReadableStreamBYOBReader.prototype.cancel;
  const nativeRead = ReadableStreamBYOBReader.prototype.read;
  ReadableStreamBYOBReader.prototype.read = async function(...args) {
    const transport = readers.get(this);
    try {
      const result = await nativeRead.apply(this, args);
      if (transport?.tracked) audit.readerBytes[transport.name] = (audit.readerBytes[transport.name] ?? 0) + (result.value?.byteLength ?? 0);
      if (result.done) transport?.finish();
      return result;
    } catch (error) { transport?.finish(); throw error; }
  };
  ReadableStreamBYOBReader.prototype.cancel = function(reason) {
    const transport = readers.get(this);
    if (transport?.tracked) audit.readersCancelled.push(transport.name);
    transport?.finish();
    return nativeCancel.call(this, reason);
  };
}
