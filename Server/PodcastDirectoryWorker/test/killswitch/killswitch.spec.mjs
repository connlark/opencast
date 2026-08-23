// Requires `build/index.js` (see `yarn build:worker`). Runs with
// PUBLIC_PODCAST_DIRECTORY_ENABLED forced to "false" and no Podcast
// Index credentials bound.
import { SELF } from "cloudflare:test";
import { afterEach, beforeEach, expect, it } from "vitest";

const BASE = "https://opencast-podcast-directory.example";

const realFetch = globalThis.fetch;
let upstreamCallCount;

beforeEach(() => {
  upstreamCallCount = 0;
  globalThis.fetch = async () => {
    upstreamCallCount += 1;
    throw new Error("disabled worker must not reach upstream");
  };
});

afterEach(() => {
  globalThis.fetch = realFetch;
});

it("disables search with 503 before touching upstream", async () => {
  const response = await SELF.fetch(`${BASE}/v1/search`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ query: "serial" }),
  });
  expect(response.status).toBe(503);
  expect((await response.json()).error).toBe("podcast_directory_disabled");
  expect(upstreamCallCount).toBe(0);
});

it("disables lookup with 503 before touching upstream", async () => {
  const response = await SELF.fetch(`${BASE}/v1/podcasts/by-apple-id/917918570`);
  expect(response.status).toBe(503);
  expect((await response.json()).error).toBe("podcast_directory_disabled");
  expect(upstreamCallCount).toBe(0);
});

it("keeps health up and reports the disabled state", async () => {
  const response = await SELF.fetch(`${BASE}/v1/health`);
  expect(response.status).toBe(200);
  expect(await response.json()).toEqual({ message: "ok", enabled: false });
  expect(upstreamCallCount).toBe(0);
});
