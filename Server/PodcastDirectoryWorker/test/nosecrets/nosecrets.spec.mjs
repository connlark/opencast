// Requires `build/index.js` (see `yarn build:worker`). Runs with the
// public flag on but no Podcast Index credentials bound.
import { SELF } from "cloudflare:test";
import { afterEach, beforeEach, expect, it } from "vitest";

const BASE = "https://opencast-podcast-directory.example";

const realFetch = globalThis.fetch;
let upstreamCallCount;

beforeEach(() => {
  upstreamCallCount = 0;
  globalThis.fetch = async () => {
    upstreamCallCount += 1;
    throw new Error("unprovisioned worker must not reach upstream");
  };
});

afterEach(() => {
  globalThis.fetch = realFetch;
});

it("fails search closed with 503 when credentials are unprovisioned", async () => {
  const response = await SELF.fetch(`${BASE}/v1/search`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ query: "serial" }),
  });
  expect(response.status).toBe(503);
  const body = await response.json();
  expect(body.error).toBe("worker_secret_missing");
  expect(body.detail).toBe("PODCAST_INDEX_API_KEY");
  expect(upstreamCallCount).toBe(0);
});

it("keeps health up without credentials", async () => {
  const response = await SELF.fetch(`${BASE}/v1/health`);
  expect(response.status).toBe(200);
  expect(await response.json()).toEqual({ message: "ok", enabled: true });
});
