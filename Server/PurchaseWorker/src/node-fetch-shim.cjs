// Transport-only node-fetch replacement for workerd bundles.
// The Apple library compiles `import fetch, { Headers } from "node-fetch"`
// without esModuleInterop, so it reads `.default`/`.Headers` off the CJS
// export directly. It also calls node-fetch's `response.buffer()` and passes
// a non-standard `timeout` option. No crypto, parsing, or OCSP logic may
// ever live here — revocation logic stays 100% library code.
'use strict';
const { Buffer } = require('node:buffer');

async function fetchShim(url, init) {
  const { timeout, ...rest } = init || {};
  if (timeout && !rest.signal && typeof AbortSignal !== 'undefined' && AbortSignal.timeout) {
    rest.signal = AbortSignal.timeout(timeout);
  }
  const response = await globalThis.fetch(url, rest);
  response.buffer = async () => Buffer.from(await response.arrayBuffer());
  return response;
}

module.exports = {
  default: fetchShim,
  fetch: fetchShim,
  Headers: globalThis.Headers,
  Request: globalThis.Request,
  Response: globalThis.Response,
  FetchError: Error,
  AbortError: Error,
};
