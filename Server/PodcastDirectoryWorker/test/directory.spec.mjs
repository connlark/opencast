// Workerd integration tests for the compiled Wasm Worker.
// Requires `build/index.js` (see `yarn build:worker`).
//
// The main worker runs in the same isolate as the tests, so stubbing the
// global `fetch` intercepts the Worker's outbound Podcast Index call.
// Binding traffic (SELF, the rate limiters, the cache) does not go
// through the global.
import { SELF } from "cloudflare:test";
import { afterEach, beforeEach, describe, expect, it } from "vitest";

const TEST_API_KEY = "integration-test-api-key";
const TEST_API_SECRET = "integration-test-api-secret";
const BASE = "https://opencast-podcast-directory.example";

const realFetch = globalThis.fetch;
let upstreamRequests;

beforeEach(() => {
  upstreamRequests = [];
});

afterEach(() => {
  globalThis.fetch = realFetch;
});

function stubUpstream(handler) {
  globalThis.fetch = async (input, init) => {
    const request = new Request(input, init);
    upstreamRequests.push(request);
    return handler(request);
  };
}

function upstreamSearchBody(feeds) {
  return JSON.stringify({ status: "true", feeds, count: feeds.length });
}

const serialFeed = {
  id: 745392,
  podcastGuid: "2d7400e3-bacb-52fd-aabc-0da55e39f98b",
  title: "Serial",
  url: "https://feeds.example.com/full",
  author: "Serial Productions",
  link: "https://serial.example.com",
  artwork: "https://images.example.com/serial.jpg",
  itunesId: 917918570,
  episodeCount: 124,
  newestItemPubdate: 1750230000,
};

function jsonUpstream(body, cacheControl) {
  const headers = { "content-type": "application/json" };
  if (cacheControl) {
    headers["cache-control"] = cacheControl;
  }
  return () => new Response(body, { status: 200, headers });
}

async function search(query, init = {}) {
  return SELF.fetch(`${BASE}/v1/search`, {
    method: "POST",
    headers: { "content-type": "application/json", ...init.headers },
    body: JSON.stringify({ query }),
    ...init.overrides,
  });
}

async function sha1Hex(text) {
  const digest = await crypto.subtle.digest("SHA-1", new TextEncoder().encode(text));
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

describe("health", () => {
  it("answers without contacting Podcast Index", async () => {
    stubUpstream(() => {
      throw new Error("health must not reach upstream");
    });
    const response = await SELF.fetch(`${BASE}/v1/health`);
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ message: "ok", enabled: true });
    expect(upstreamRequests).toHaveLength(0);
  });
});

describe("search", () => {
  it("normalizes upstream entries and signs the upstream request", async () => {
    stubUpstream(jsonUpstream(upstreamSearchBody([serialFeed]), "no-store"));

    const response = await search("serial season one");
    expect(response.status).toBe(200);
    const body = await response.json();
    expect(body.version).toBe(1);
    expect(body.results).toEqual([
      {
        podcastIndexId: 745392,
        podcastGuid: "2d7400e3-bacb-52fd-aabc-0da55e39f98b",
        appleId: 917918570,
        title: "Serial",
        author: "Serial Productions",
        feedUrl: "https://feeds.example.com/full",
        artworkUrl: "https://images.example.com/serial.jpg",
        websiteUrl: "https://serial.example.com",
        reportedEpisodeCount: 124,
        reportedUpdatedAt: 1750230000,
      },
    ]);

    expect(upstreamRequests).toHaveLength(1);
    const upstream = upstreamRequests[0];
    const url = new URL(upstream.url);
    expect(url.origin).toBe("https://api.podcastindex.org");
    expect(url.pathname).toBe("/api/1.0/search/byterm");
    expect(url.searchParams.get("q")).toBe("serial season one");
    expect(url.searchParams.get("max")).toBe("25");
    expect(upstream.headers.get("user-agent")).toBe(
      "OpenCast-Directory/1 (+https://opencast.mobile)",
    );
    expect(upstream.headers.get("x-auth-key")).toBe(TEST_API_KEY);
    const authDate = upstream.headers.get("x-auth-date");
    expect(authDate).toMatch(/^\d+$/);
    expect(upstream.headers.get("authorization")).toBe(
      await sha1Hex(`${TEST_API_KEY}${TEST_API_SECRET}${authDate}`),
    );
  });

  it("collapses and trims the query before contacting upstream", async () => {
    stubUpstream(jsonUpstream(upstreamSearchBody([]), "no-store"));
    const response = await search("  this \t american\nlife ");
    expect(response.status).toBe(200);
    const url = new URL(upstreamRequests[0].url);
    expect(url.searchParams.get("q")).toBe("this american life");
  });

  it("rejects non-JSON content types", async () => {
    const response = await SELF.fetch(`${BASE}/v1/search`, {
      method: "POST",
      headers: { "content-type": "text/plain" },
      body: JSON.stringify({ query: "serial" }),
    });
    expect(response.status).toBe(400);
    expect((await response.json()).error).toBe("invalid_content_type");
    expect(upstreamRequests).toHaveLength(0);
  });

  it("rejects malformed JSON bodies", async () => {
    const response = await SELF.fetch(`${BASE}/v1/search`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: "{not json",
    });
    expect(response.status).toBe(400);
    expect((await response.json()).error).toBe("invalid_json");
  });

  it("rejects blank and oversized queries", async () => {
    const blank = await search("   ");
    expect(blank.status).toBe(400);
    expect((await blank.json()).error).toBe("invalid_query");

    const oversized = await search("q".repeat(201));
    expect(oversized.status).toBe(400);
    expect((await oversized.json()).error).toBe("invalid_query");
    expect(upstreamRequests).toHaveLength(0);
  });

  it("rejects bodies past the 2 KiB cap with 413", async () => {
    const response = await SELF.fetch(`${BASE}/v1/search`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ query: "x", padding: "p".repeat(3000) }),
    });
    expect(response.status).toBe(413);
    expect((await response.json()).error).toBe("payload_too_large");
    expect(upstreamRequests).toHaveLength(0);
  });

  it("rejects non-POST methods with an allow header", async () => {
    const response = await SELF.fetch(`${BASE}/v1/search`);
    expect(response.status).toBe(405);
    expect(response.headers.get("allow")).toBe("POST");
    expect((await response.json()).error).toBe("method_not_allowed");
  });

  it("maps upstream failure statuses to 502", async () => {
    stubUpstream(() => new Response("upstream broke", { status: 500 }));
    const response = await search("failing query");
    expect(response.status).toBe(502);
    expect((await response.json()).error).toBe("upstream_status");
  });

  it("maps upstream transport failures to 502", async () => {
    stubUpstream(() => {
      throw new TypeError("network is down");
    });
    const response = await search("unreachable query");
    expect(response.status).toBe(502);
    expect((await response.json()).error).toBe("upstream_unreachable");
  });

  it("maps malformed upstream bodies to 502", async () => {
    stubUpstream(jsonUpstream("<html>not json</html>", "no-store"));
    const response = await search("malformed query");
    expect(response.status).toBe(502);
    expect((await response.json()).error).toBe("upstream_malformed");
  });

  it("abandons upstream bodies past the 512 KiB bound", async () => {
    stubUpstream(jsonUpstream(`{"feeds": ["${"x".repeat(600 * 1024)}"]}`, "no-store"));
    const response = await search("oversized upstream");
    expect(response.status).toBe(502);
    expect((await response.json()).error).toBe("upstream_too_large");
  });

  it("times out an unresponsive upstream after five seconds", async () => {
    stubUpstream(() => new Promise(() => {}));
    const startedAt = Date.now();
    const response = await search("hanging query");
    expect(response.status).toBe(502);
    expect((await response.json()).error).toBe("upstream_timeout");
    expect(Date.now() - startedAt).toBeGreaterThanOrEqual(4_900);
  });
});

describe("caching", () => {
  it("serves a repeated query from cache when upstream permits", async () => {
    stubUpstream(jsonUpstream(upstreamSearchBody([serialFeed]), "public, max-age=300"));

    const first = await search("cacheable serial query");
    expect(first.status).toBe(200);
    expect(first.headers.get("cache-control")).toBe("public, max-age=300");
    expect(upstreamRequests).toHaveLength(1);

    const second = await search("cacheable serial query");
    expect(second.status).toBe(200);
    expect((await second.json()).results).toHaveLength(1);
    expect(upstreamRequests).toHaveLength(1);

    const distinct = await search("a different cacheable query");
    expect(distinct.status).toBe(200);
    expect(upstreamRequests).toHaveLength(2);
  });

  it("does not cache when upstream forbids it", async () => {
    stubUpstream(jsonUpstream(upstreamSearchBody([serialFeed]), "no-store"));

    const first = await search("uncacheable query");
    expect(first.status).toBe(200);
    expect(first.headers.get("cache-control")).toBeNull();
    const second = await search("uncacheable query");
    expect(second.status).toBe(200);
    expect(upstreamRequests).toHaveLength(2);
  });

  it("caps the stored TTL at fifteen minutes for search", async () => {
    stubUpstream(jsonUpstream(upstreamSearchBody([serialFeed]), "public, max-age=86400"));
    const response = await search("long ttl query");
    expect(response.headers.get("cache-control")).toBe("public, max-age=900");
  });
});

describe("lookup", () => {
  it("returns the normalized entry for a hit", async () => {
    stubUpstream(
      jsonUpstream(JSON.stringify({ status: "true", feed: serialFeed }), "no-store"),
    );
    const response = await SELF.fetch(`${BASE}/v1/podcasts/by-apple-id/917918570`);
    expect(response.status).toBe(200);
    const body = await response.json();
    expect(body.version).toBe(1);
    expect(body.result.podcastIndexId).toBe(745392);
    expect(body.result.appleId).toBe(917918570);

    const url = new URL(upstreamRequests[0].url);
    expect(url.pathname).toBe("/api/1.0/podcasts/byitunesid");
    expect(url.searchParams.get("id")).toBe("917918570");
  });

  it("maps an upstream miss to 404", async () => {
    stubUpstream(jsonUpstream(JSON.stringify({ status: "false", feed: [] }), "no-store"));
    const response = await SELF.fetch(`${BASE}/v1/podcasts/by-apple-id/1`);
    expect(response.status).toBe(404);
    expect((await response.json()).error).toBe("not_found");
  });

  it("rejects malformed Apple IDs without contacting upstream", async () => {
    for (const segment of ["0", "-1", "abc", "1.5"]) {
      const response = await SELF.fetch(`${BASE}/v1/podcasts/by-apple-id/${segment}`);
      expect(response.status).toBe(400);
      expect((await response.json()).error).toBe("invalid_apple_id");
    }
    expect(upstreamRequests).toHaveLength(0);
  });

  it("caches lookup hits when upstream permits", async () => {
    stubUpstream(
      jsonUpstream(JSON.stringify({ status: "true", feed: serialFeed }), "public, max-age=7200"),
    );
    const first = await SELF.fetch(`${BASE}/v1/podcasts/by-apple-id/424242`);
    expect(first.status).toBe(200);
    expect(first.headers.get("cache-control")).toBe("public, max-age=3600");
    const second = await SELF.fetch(`${BASE}/v1/podcasts/by-apple-id/424242`);
    expect(second.status).toBe(200);
    expect(upstreamRequests).toHaveLength(1);
  });
});

describe("routing", () => {
  it("answers unknown paths with 404", async () => {
    const response = await SELF.fetch(`${BASE}/v1/other`);
    expect(response.status).toBe(404);
    expect((await response.json()).error).toBe("not_found");
  });
});

describe("rate limiting", () => {
  it("rejects a client past sixty requests per minute", async () => {
    stubUpstream(jsonUpstream(upstreamSearchBody([]), "no-store"));
    let sawRateLimit = false;
    for (let attempt = 0; attempt < 61 && !sawRateLimit; attempt += 1) {
      const response = await search(`rate limit probe ${attempt}`, {
        headers: { "cf-connecting-ip": "203.0.113.7" },
      });
      if (response.status === 429) {
        expect((await response.json()).error).toBe("rate_limited");
        sawRateLimit = true;
      } else {
        expect(response.status).toBe(200);
      }
    }
    expect(sawRateLimit).toBe(true);
  });
});

describe("credential non-disclosure", () => {
  it("never echoes credentials in bodies of any response class", async () => {
    stubUpstream(() => new Response("boom", { status: 500 }));
    const failure = await search("credential probe");
    const failureText = await failure.text();

    stubUpstream(jsonUpstream(upstreamSearchBody([serialFeed]), "no-store"));
    const success = await search("credential probe two");
    const successText = await success.text();

    const notFound = await SELF.fetch(`${BASE}/v1/nope`);
    const notFoundText = await notFound.text();

    for (const text of [failureText, successText, notFoundText]) {
      expect(text).not.toContain(TEST_API_KEY);
      expect(text).not.toContain(TEST_API_SECRET);
    }
  });
});
