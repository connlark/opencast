// Workerd integration tests for the built worker (dist/dev/<worker>/).
//
// The main worker runs in the same isolate as the tests, so replacing the
// global `fetch` intercepts the download proxy's upstream request. Binding
// traffic (SELF, the assets binding, the rate limiter) does not use it.
import { env, SELF } from "cloudflare:test";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import vectorFixture from "../../../../Packages/OpenCastCore/Tests/OpenCastCoreTests/Fixtures/EpisodeShareTokenVectors.json";
import hostile from "../fixtures/hostile-tokens.json";

const BASE = "https://share.example";
const CSP =
  "default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src https: http:; media-src https: http:; connect-src 'self'; font-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'; upgrade-insecure-requests";

const realFetch = globalThis.fetch;
let upstream;
let clientAddress = 0;

beforeEach(() => {
  upstream = [];
});

afterEach(() => {
  globalThis.fetch = realFetch;
});

function stubUpstream(handler) {
  globalThis.fetch = async (input, init = {}) => {
    const request = new Request(input, init);
    upstream.push({ request, init });
    return handler(request, init);
  };
}

function vector(name) {
  const found = vectorFixture.vectors.find((candidate) => candidate.name === name);
  if (!found) {
    throw new Error(`missing vector ${name}`);
  }
  return found;
}

// Each download gets its own client address so the rate limiter only bites
// in the test that exercises it.
function download(token, init = {}, address = `198.51.100.${++clientAddress % 250}`) {
  return SELF.fetch(`${BASE}/e/${token}/download`, {
    ...init,
    headers: { "cf-connecting-ip": address, ...init.headers },
  });
}

function audio(body, headers = {}, status = 200) {
  return new Response(body, {
    status,
    headers: {
      "content-type": "audio/mpeg",
      "content-length": String(new TextEncoder().encode(body).byteLength),
      "accept-ranges": "bytes",
      etag: '"episode-etag"',
      "last-modified": "Wed, 01 Jul 2026 00:00:00 GMT",
      "set-cookie": "tracker=1",
      ...headers,
    },
  });
}

// The limiter counts per wall-clock window; start a burst early in a window so
// its 21 requests cannot straddle two.
async function freshRateLimitWindow() {
  const left = 60_000 - (Date.now() % 60_000);
  if (left < 10_000) {
    await new Promise((resolve) => setTimeout(resolve, left + 50));
  }
}

function meta(html, key) {
  return Array.from(html.matchAll(new RegExp(`<meta (?:property|name)="${key}" content="([^"]*)"`, "g")), (match) => match[1]);
}

const almanac = vector("almanac-fixture");

describe("share page", () => {
  it("renders the page with every response header and the Open Graph title", async () => {
    stubUpstream(() => {
      throw new Error("pages never contact the podcast host");
    });
    const response = await SELF.fetch(`${BASE}/e/${almanac.token}`);
    const body = await response.text();

    expect(response.status).toBe(200);
    expect(response.headers.get("content-type")).toBe("text/html; charset=utf-8");
    expect(response.headers.get("content-length")).toBe(String(new TextEncoder().encode(body).byteLength));
    expect(response.headers.get("cache-control")).toBe("public, max-age=300");
    expect(response.headers.get("x-robots-tag")).toBe("noindex");
    expect(response.headers.get("x-content-type-options")).toBe("nosniff");
    expect(response.headers.get("referrer-policy")).toBe("strict-origin-when-cross-origin");
    expect(response.headers.get("content-security-policy")).toBe(CSP);
    expect(response.headers.has("set-cookie")).toBe(false);
    expect(response.headers.has("server-timing")).toBe(false);
    expect(body.startsWith("<!doctype html><html lang=\"en\">")).toBe(true);
    expect(meta(body, "og:title")).toEqual(["Rubber Duck, Final Witness"]);
    expect(meta(body, "og:url")).toEqual([`${BASE}/e/${almanac.token}`]);
    expect(body).toMatch(/<script type="module" src="\/e\/_\/entry\.js\?v=[0-9a-z-]+"><\/script>/);
    expect(body).toMatch(/<link rel="stylesheet" href="\/e\/_\/entry\.css\?v=[0-9a-z-]+"\/>/);
    expect(upstream).toHaveLength(0);
  });

  it.each([
    ["754", "754"],
    ["12m34s", "754"],
  ])("reflects ?t=%s in og:url and the description", async (t, seconds) => {
    const body = await (await SELF.fetch(`${BASE}/e/${almanac.token}?t=${t}`)).text();
    expect(meta(body, "og:url")).toEqual([`${BASE}/e/${almanac.token}?t=${seconds}`]);
    expect(meta(body, "og:description")).toEqual(["The Example Almanac · starts at 12:34 of 40:00"]);
  });

  it("drops a start time past the episode", async () => {
    const body = await (await SELF.fetch(`${BASE}/e/${almanac.token}?t=2399`)).text();
    expect(meta(body, "og:url")).toEqual([`${BASE}/e/${almanac.token}`]);
  });

  // SELF drops HEAD bodies in the runtime; test/unit/render.spec.tsx checks
  // the handler itself returns none. This checks the headers match.
  it("answers HEAD with the same headers as GET", async () => {
    const get = await SELF.fetch(`${BASE}/e/${almanac.token}`);
    const head = await SELF.fetch(`${BASE}/e/${almanac.token}`, { method: "HEAD" });

    expect(head.status).toBe(200);
    expect(await head.text()).toBe("");
    expect(Object.fromEntries(head.headers)).toEqual(Object.fromEntries(get.headers));
  });

  it.each([
    ["garbage", "1garbage-garbage-garbage"],
    ["a truncated token", "1AAAA"],
    ["the wrong version", `2${almanac.token.slice(1)}`],
    ...Object.entries(hostile),
  ])("returns the branded 404 for %s without contacting a host", async (_, token) => {
    stubUpstream(() => {
      throw new Error("an invalid token must never reach upstream");
    });
    for (const path of [`/e/${token}`, `/e/${token}/download`]) {
      const response = await SELF.fetch(`${BASE}${path}`);
      expect(response.status).toBe(404);
      expect(response.headers.get("content-type")).toBe("text/html; charset=utf-8");
      expect(response.headers.get("x-robots-tag")).toBe("noindex");
      expect(await response.text()).toContain("This share link isn't valid");
    }
    expect(upstream).toHaveLength(0);
  });

  it("rejects a decompression bomb quickly", async () => {
    const started = Date.now();
    const response = await SELF.fetch(`${BASE}/e/${hostile.bomb}`);
    expect(response.status).toBe(404);
    expect(Date.now() - started).toBeLessThan(1000);
  });

  it("sends /e/ home and 404s everything else under the route", async () => {
    const home = await SELF.fetch(`${BASE}/e/`, { redirect: "manual" });
    expect(home.status).toBe(302);
    expect(home.headers.get("location")).toBe("https://opencast.mobile/");
    expect(home.headers.get("x-robots-tag")).toBe("noindex");

    for (const path of ["/", "/e", `/e/${almanac.token}/`, `/e/${almanac.token}/other`, "/e/_/missing.js"]) {
      const response = await SELF.fetch(`${BASE}${path}`);
      expect(response.status, path).toBe(404);
      expect(response.headers.get("x-robots-tag"), path).toBe("noindex");
    }
  });

  it("allows only GET and HEAD", async () => {
    const response = await SELF.fetch(`${BASE}/e/${almanac.token}`, { method: "POST", body: "x" });
    expect(response.status).toBe(405);
    expect(response.headers.get("allow")).toBe("GET, HEAD");
  });

  // The pool's SELF skips the asset router that runs ahead of the worker in
  // production, so the built client is checked through the binding itself.
  it("ships the client bundle through the assets binding", async () => {
    for (const [file, type] of [["entry.js", /javascript/], ["entry.css", /css/]]) {
      const response = await env.ASSETS.fetch(new Request(`${BASE}/e/_/${file}?v=anything`));
      expect(response.status, file).toBe(200);
      expect(response.headers.get("content-type"), file).toMatch(type);
      expect(response.headers.get("cache-control"), file).toBe("public, max-age=31536000, immutable");
      expect(response.headers.get("x-content-type-options"), file).toBe("nosniff");
      expect((await response.text()).length, file).toBeGreaterThan(1000);
    }
  });
});

describe("download proxy", () => {
  it("streams the enclosure as an attachment and forwards only the safe headers", async () => {
    stubUpstream(() => audio("episode-bytes"));
    const response = await download(almanac.token, { headers: { cookie: "session=1", referer: "https://example.com/", authorization: "Bearer x" } });

    expect(response.status).toBe(200);
    expect(await response.text()).toBe("episode-bytes");
    expect(response.headers.get("content-type")).toBe("audio/mpeg");
    expect(response.headers.get("content-length")).toBe("13");
    expect(response.headers.get("accept-ranges")).toBe("bytes");
    expect(response.headers.get("etag")).toBe('"episode-etag"');
    expect(response.headers.get("last-modified")).toBe("Wed, 01 Jul 2026 00:00:00 GMT");
    expect(response.headers.get("content-disposition")).toBe(
      "attachment; filename=\"The Example Almanac - Rubber Duck, Final Witness.mp3\"; filename*=UTF-8''The%20Example%20Almanac%20-%20Rubber%20Duck%2C%20Final%20Witness.mp3",
    );
    expect(response.headers.get("cache-control")).toBe("private, no-store");
    expect(response.headers.get("x-robots-tag")).toBe("noindex");
    expect(response.headers.get("x-content-type-options")).toBe("nosniff");
    expect(response.headers.has("set-cookie")).toBe(false);

    expect(upstream).toHaveLength(1);
    const [{ request, init }] = upstream;
    expect(request.url).toBe(almanac.payload.audioURL);
    expect(request.method).toBe("GET");
    expect(request.headers.get("user-agent")).toBe("opencast-share/1 (+https://opencast.mobile)");
    expect([...request.headers.keys()].sort()).toEqual(["accept-encoding", "user-agent"]);
    expect(request.headers.get("accept-encoding")).toBe("identity");
    expect(init.redirect).toBe("follow");
    expect(init.cf).toEqual({ cacheTtl: -1 });
  });

  it("passes Range and If-Range through and returns the partial response", async () => {
    stubUpstream(() => audio("0123", { "content-range": "bytes 0-3/2400" }, 206));
    const response = await download(almanac.token, { headers: { range: "bytes=0-3", "if-range": '"episode-etag"' } });

    expect(response.status).toBe(206);
    expect(response.headers.get("content-range")).toBe("bytes 0-3/2400");
    expect(await response.text()).toBe("0123");
    expect(upstream[0].request.headers.get("range")).toBe("bytes=0-3");
    expect(upstream[0].request.headers.get("if-range")).toBe('"episode-etag"');
  });

  it.each(["text/html; charset=utf-8", "video/mp4", "application/json", "", "audio/mpeg, text/javascript"])("refuses %j with 502", async (type) => {
    stubUpstream(() => audio("<html>", { "content-type": type }));
    const response = await download(almanac.token);
    expect(response.status).toBe(502);
    expect(response.headers.get("content-type")).toBe("text/plain; charset=utf-8");
  });

  it.each([
    ["application/octet-stream", "mp3"],
    ["binary/octet-stream", "mp3"],
    ["AUDIO/MP4; codecs=mp4a.40.2", "m4a"],
    ["audio/x-flac", "flac"],
  ])("accepts %s and names the file .%s", async (type, extension) => {
    stubUpstream(() => audio("x", { "content-type": type }));
    const response = await download(almanac.token);
    expect(response.status).toBe(200);
    expect(response.headers.get("content-disposition")).toContain(`Witness.${extension}"`);
    expect(response.headers.get("content-type")).toBe(type.split(";")[0].toLowerCase());
  });

  it("refuses two Content-Type headers, which read as a comma-joined list", async () => {
    stubUpstream(() => {
      const headers = new Headers({ "content-length": "1" });
      headers.append("content-type", "audio/mpeg");
      headers.append("content-type", "text/javascript");
      return new Response("x", { headers });
    });
    expect((await download(almanac.token)).status).toBe(502);
  });

  it("caps an encoded body while streaming: its declared length is the compressed size", async () => {
    stubUpstream(
      () =>
        new Response(new Uint8Array(5000), {
          headers: { "content-type": "audio/mpeg", "content-encoding": "gzip", "content-length": "100", "accept-ranges": "bytes" },
        }),
    );
    const response = await download(almanac.token);
    expect(response.status).toBe(200);
    expect(response.headers.has("content-length")).toBe(false);
    expect(response.headers.has("accept-ranges")).toBe(false);
    const received = await response.arrayBuffer().then(
      (buffer) => buffer.byteLength,
      () => "errored",
    );
    expect(received === "errored" || received <= 4096).toBe(true);
  });

  it("refuses a partial response of an encoded representation", async () => {
    stubUpstream(() => audio("0123", { "content-encoding": "br", "content-range": "bytes 0-3/2400" }, 206));
    expect((await download(almanac.token, { headers: { range: "bytes=0-3" } })).status).toBe(502);
  });

  it("refuses a declared length over the cap before streaming", async () => {
    let cancelled = false;
    stubUpstream(
      () =>
        new Response(new ReadableStream({ cancel: () => void (cancelled = true) }), {
          headers: { "content-type": "audio/mpeg", "content-length": "5000" },
        }),
    );
    const response = await download(almanac.token);
    expect(response.status).toBe(413);
    expect(cancelled).toBe(true);
  });

  it("streams an undeclared length and cuts it off past the cap", async () => {
    const chunk = new Uint8Array(1000).fill(97);
    stubUpstream(
      () =>
        new Response(
          new ReadableStream({
            start(controller) {
              for (let index = 0; index < 5; index++) {
                controller.enqueue(chunk);
              }
              controller.close();
            },
          }),
          { headers: { "content-type": "audio/mpeg" } },
        ),
    );
    const response = await download(almanac.token);
    expect(response.status).toBe(200);
    expect(response.headers.has("content-length")).toBe(false);
    const received = await response.arrayBuffer().then(
      (buffer) => buffer.byteLength,
      () => "errored",
    );
    expect(received === "errored" || received <= 4096).toBe(true);
  });

  it("streams an undeclared length under the cap in full", async () => {
    stubUpstream(() => new Response(new ReadableStream({ start: (c) => (c.enqueue(new Uint8Array(3000)), c.close()) }), { headers: { "content-type": "audio/mpeg" } }));
    const response = await download(almanac.token);
    expect((await response.arrayBuffer()).byteLength).toBe(3000);
  });

  it.each([
    ["an upstream 404", () => new Response("gone", { status: 404, headers: { "content-type": "audio/mpeg" } }), 502],
    ["an upstream 500", () => new Response("down", { status: 500, headers: { "content-type": "audio/mpeg" } }), 502],
    ["a network error", () => Promise.reject(new TypeError("connection refused")), 502],
  ])("answers %s with %i", async (_, handler, status) => {
    stubUpstream(handler);
    const response = await download(almanac.token);
    expect(response.status).toBe(status);
  });

  it("gives up on silent upstream headers with 504 after the timeout", async () => {
    stubUpstream(() => new Promise(() => {}));
    const started = Date.now();
    const response = await download(almanac.token);
    expect(response.status).toBe(504);
    expect(Date.now() - started).toBeGreaterThanOrEqual(450);
    expect(Date.now() - started).toBeLessThan(5000);
  });

  it("forwards HEAD as HEAD and returns headers only", async () => {
    stubUpstream(() => new Response(null, { headers: { "content-type": "audio/mpeg", "content-length": "1234" } }));
    const response = await download(almanac.token, { method: "HEAD" });
    expect(response.status).toBe(200);
    expect(upstream.map(({ request }) => request.method)).toEqual(["HEAD"]);
    expect(response.headers.get("content-length")).toBe("1234");
    expect(await response.text()).toBe("");
  });

  it("retries HEAD as GET when the host refuses HEAD, cancelling the body", async () => {
    let cancelled = false;
    stubUpstream((request) =>
      request.method === "HEAD"
        ? new Response(null, { status: 405 })
        : new Response(new ReadableStream({ cancel: () => void (cancelled = true) }), {
            headers: { "content-type": "audio/mpeg", "content-length": "1234" },
          }),
    );
    const response = await download(almanac.token, { method: "HEAD" });
    expect(response.status).toBe(200);
    expect(upstream.map(({ request }) => request.method)).toEqual(["HEAD", "GET"]);
    expect(cancelled).toBe(true);
    expect(await response.text()).toBe("");
  });

  it("rate-limits the 21st download from one address without contacting the host", async () => {
    await freshRateLimitWindow();
    stubUpstream(() => audio("x"));
    for (let index = 0; index < 20; index++) {
      expect((await download(almanac.token, {}, "203.0.113.77")).status).toBe(200);
    }
    const limited = await download(almanac.token, {}, "203.0.113.77");
    expect(limited.status).toBe(429);
    expect(limited.headers.get("retry-after")).toBe("60");
    expect(upstream).toHaveLength(20);
  });

  it("counts an IPv6 client by its /64", async () => {
    await freshRateLimitWindow();
    stubUpstream(() => audio("x"));
    for (let index = 0; index < 20; index++) {
      expect((await download(almanac.token, {}, `2001:db8:77:1::${index + 1}`)).status).toBe(200);
    }
    expect((await download(almanac.token, {}, "2001:db8:77:1:ffff:ffff:ffff:ffff")).status).toBe(429);
    expect((await download(almanac.token, {}, "2001:db8:77:2::1")).status).toBe(200);
  });

  it("writes Unicode names in both filename forms", async () => {
    const unicode = vector("unicode-title");
    stubUpstream(() => audio("x", { "content-type": "audio/mp4" }));
    const response = await download(unicode.token);
    expect(response.headers.get("content-disposition")).toBe(
      "attachment; filename=\"Radio _n_c_d_ _ - Caf_ Stories _ _The Last Word_ _ _____.m4a\"; " +
        "filename*=UTF-8''Radio%20%C3%9Cn%C3%AFc%C3%B6d%C3%A9%20%E2%9C%A8%20-%20Caf%C3%A9%20Stories%20%E2%80%94%20%E2%80%9CThe%20Last%20Word%E2%80%9D%20%F0%9F%8E%A7%20%E6%92%AD%E5%AE%A2%E7%9A%84%E6%9C%AA%E6%9D%A5.m4a",
    );
  });

  it("percent-encodes the characters RFC 5987 excludes and strips path separators", async () => {
    // node scripts/mint-link.mjs --audio https://media.example.com/episode \
    //   --title "Don't (Stop) *Now*! a/b" --podcast 'Show: "Live"'
    const token = "1g9GQiE2tSASFMnKa43LJz1MvUdAILskv0FTQ8ssv11JUSNRP4grOyC-3UlDyySxLVeICAgMuAwA";
    stubUpstream(() => audio("x", { "content-type": "application/octet-stream" }));
    const response = await download(token);
    expect(response.headers.get("content-disposition")).toBe(
      "attachment; filename=\"Show_ _Live_ - Don't (Stop) _Now_! a_b.mp3\"; " +
        "filename*=UTF-8''Show_%20_Live_%20-%20Don%27t%20%28Stop%29%20_Now_%21%20a_b.mp3",
    );
  });
});
