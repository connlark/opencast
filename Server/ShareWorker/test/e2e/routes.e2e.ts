// Routes through Playwright's request context (no browser), against the same
// `wrangler dev` server the page tests use. Runs in the "routes" project only.
import { readFileSync } from "node:fs";
import { expect, test } from "./fixtures.ts";
import { swiftVectors } from "./tokens.ts";

const hostile: Record<string, string> = JSON.parse(readFileSync(new URL("../fixtures/hostile-tokens.json", import.meta.url), "utf8"));

const CSP =
  "default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src https: http:; media-src https: http:; connect-src 'self'; font-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'; upgrade-insecure-requests";

const entities: Record<string, string> = { amp: "&", lt: "<", gt: ">", quot: '"', "#39": "'", "#x27": "'" };
const unescapeHTML = (text: string) => text.replace(/&(amp|lt|gt|quot|#39|#x27);/g, (_, name: string) => entities[name]!);

test("/e/ redirects to the site", async ({ request }) => {
  const response = await request.get("/e/", { maxRedirects: 0 });
  expect(response.status()).toBe(302);
  expect(response.headers().location).toMatch(/^https:\/\/[^/]+\/$/);
  expect(response.headers()["x-robots-tag"]).toBe("noindex");
});

for (const [name, token] of Object.entries(hostile)) {
  test(`hostile token ${name} gets the 404 page`, async ({ request }) => {
    const response = await request.get(`/e/${token}`);
    expect(response.status()).toBe(404);
    expect(response.headers()["content-type"]).toBe("text/html; charset=utf-8");
    expect(response.headers()["content-security-policy"]).toBe(CSP);
    expect(await response.text()).not.toContain('id="__share"');
  });
}

for (const path of ["/", "/e", "/e/x", "/e/1AAAA", "/favicon.ico", "/e/_/missing.js", "/E/1abcdefghijklmnopq"]) {
  test(`${path} is a 404`, async ({ request }) => {
    const response = await request.get(path, { maxRedirects: 0 });
    expect(response.status()).toBe(404);
    expect(response.headers()["x-robots-tag"]).toBe("noindex");
  });
}

test("a valid token with a trailing segment is a 404", async ({ request, share }) => {
  const response = await request.get(`${share.url("happy")}/extra`);
  expect(response.status()).toBe(404);
});

test("only GET and HEAD are allowed", async ({ request, share }) => {
  for (const method of ["POST", "PUT", "DELETE", "PATCH"]) {
    const response = await request.fetch(share.url("happy"), { method });
    expect(response.status(), method).toBe(405);
    expect(response.headers().allow).toBe("GET, HEAD");
  }
});

test("HEAD carries the page headers and no body", async ({ request, share }) => {
  const get = await request.get(share.url("happy"));
  const head = await request.head(share.url("happy"));
  expect(head.status()).toBe(200);
  expect((await head.body()).length).toBe(0);
  for (const header of ["content-type", "cache-control", "content-security-policy", "referrer-policy", "x-robots-tag"]) {
    expect(head.headers()[header], header).toBe(get.headers()[header]);
  }
});

test("client assets are immutable and versioned by the page", async ({ request, share }) => {
  const html = await (await request.get(share.url("happy"))).text();
  const assets = [...html.matchAll(/(?:src|href)="(\/e\/_\/[^"]+)"/g)].map((match) => unescapeHTML(match[1]!));
  expect(assets.map((asset) => asset.replace(/\?v=.*/, "")).sort()).toEqual(["/e/_/entry.css", "/e/_/entry.js"]);
  for (const asset of assets) {
    expect(asset).toMatch(/\?v=[\w-]+$/);
    const response = await request.get(asset);
    expect(response.status(), asset).toBe(200);
    expect(response.headers()["cache-control"]).toBe("public, max-age=31536000, immutable");
    expect(response.headers()["x-content-type-options"]).toBe("nosniff");
  }
});

// The app's own tokens, byte for byte: a token-format change on either side
// breaks this.
for (const vector of swiftVectors()) {
  test(`Swift vector ${vector.name} renders its payload`, async ({ request, baseURL }) => {
    const query = vector.startTime > 0 ? `?t=${vector.startTime}` : "";
    const response = await request.get(`/e/${vector.token}${query}`);
    expect(response.status()).toBe(200);
    const html = await response.text();
    const meta = (property: string) =>
      unescapeHTML(new RegExp(`<meta property="${property}" content="([^"]*)"`).exec(html)?.[1] ?? "<missing>");
    expect(meta("og:title")).toBe(vector.payload.title);
    expect(meta("og:audio")).toBe(vector.payload.audioURL);
    expect(meta("og:url")).toBe(`${baseURL}/e/${vector.token}${query}`);
    const state = JSON.parse(/<script id="__share" type="application\/json">(.*?)<\/script>/s.exec(html)![1]!);
    expect(state.payload).toEqual(vector.payload);
    expect(state.start).toBe(vector.startTime);
  });
}

test.describe("download", () => {
  // workerd will not trust the media host's self-signed certificate, so the
  // proxied tokens use its plain-http face (same port).
  test("streams the enclosure as an attachment named after the episode", async ({ request, share }) => {
    const probe = `dl-${Date.now()}`;
    const token = share.mint({
      audioURL: `${share.media.http}/audio/10.mp3?probe=${probe}`,
      title: "Café: “Quotes” & Emoji 🎧",
      podcastTitle: "Show",
      durationSeconds: 10,
    });
    const response = await request.get(`/e/${token}/download`);
    expect(response.status()).toBe(200);
    const headers = response.headers();
    expect(headers["content-type"]).toBe("audio/mpeg");
    expect(headers["content-disposition"]).toMatch(/^attachment; filename="[\x20-\x7e]+\.mp3"; filename\*=UTF-8''.+\.mp3$/);
    expect(decodeURIComponent(/filename\*=UTF-8''(.+)$/.exec(headers["content-disposition"]!)![1]!)).toContain("Café");
    expect((await response.body()).length).toBe(Math.round(10 / 0.036) * 144);

    const seen = await (await request.get(`${share.media.https}/__log?probe=${probe}`)).json();
    expect(seen).toHaveLength(1);
    expect(seen[0].userAgent).toBe("opencast-share/1");
    expect(seen[0].referer).toBeNull();
  });

  test("passes a Range request through as 206", async ({ request, share }) => {
    const token = share.mint({ audioURL: `${share.media.http}/audio/10.mp3`, title: "Ranged" });
    const response = await request.get(`/e/${token}/download`, { headers: { range: "bytes=100-199" } });
    expect(response.status()).toBe(206);
    expect(response.headers()["content-range"]).toBe(`bytes 100-199/${Math.round(10 / 0.036) * 144}`);
    expect((await response.body()).length).toBe(100);
  });

  test("refuses a host that does not return audio", async ({ request, share }) => {
    const token = share.mint({ audioURL: `${share.media.http}/audio/page.html`, title: "Not audio" });
    expect((await request.get(`/e/${token}/download`)).status()).toBe(502);
  });

  test("a missing enclosure is a 502, not the host's 404 page", async ({ request, share }) => {
    const token = share.mint({ audioURL: `${share.media.http}/audio/missing.mp3`, title: "Missing" });
    expect((await request.get(`/e/${token}/download`)).status()).toBe(502);
  });
});
