import { afterEach, describe, expect, it, vi } from "vitest";
import type { SharePayload } from "../../src/shared/payload.ts";
import { audioMediaType, handleDownload, rateLimitKey } from "../../src/worker/download.ts";
import type { Env } from "../../src/worker/env.ts";

const payload: SharePayload = {
  audioURL: "https://media.example.com/a.mp3",
  title: "Title",
  podcastTitle: "Show",
  artworkURL: "",
  feedURL: "",
  guid: "",
  durationSeconds: 60,
  publishedUnix: 0,
};

function env(allowed = true): Env {
  return {
    ASSETS: { fetch: async () => new Response(null, { status: 404 }) },
    DOWNLOAD_RATE_LIMITER: { limit: async () => ({ success: allowed }) },
  };
}

function head(): Request {
  return new Request("https://share.example/e/1token/download", { method: "HEAD" });
}

afterEach(() => {
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
});

// Through SELF the runtime drops HEAD bodies itself, so only a direct call can
// show that the handler never attaches one.
describe("handleDownload HEAD", () => {
  it("returns headers only when the host answers HEAD", async () => {
    vi.spyOn(console, "log").mockImplementation(() => undefined);
    vi.stubGlobal("fetch", async () => new Response(null, { headers: { "content-type": "audio/mpeg", "content-length": "1234" } }));
    const response = await handleDownload(head(), env(), payload);
    expect(response.status).toBe(200);
    expect(response.body).toBeNull();
    expect(response.headers.get("content-length")).toBe("1234");
  });

  it("returns headers only after retrying a refused HEAD as GET", async () => {
    vi.spyOn(console, "log").mockImplementation(() => undefined);
    vi.stubGlobal("fetch", async (_: string, init: RequestInit) =>
      init.method === "HEAD"
        ? new Response(null, { status: 405 })
        : new Response("audio-bytes", { headers: { "content-type": "audio/mpeg", "content-length": "11" } }),
    );
    const response = await handleDownload(head(), env(), payload);
    expect(response.status).toBe(200);
    expect(response.body).toBeNull();
  });

  it("returns headers only for errors and the rate limit", async () => {
    vi.spyOn(console, "log").mockImplementation(() => undefined);
    vi.stubGlobal("fetch", async () => new Response("<html>", { headers: { "content-type": "text/html" } }));
    const refused = await handleDownload(head(), env(), payload);
    expect(refused.status).toBe(502);
    expect(refused.body).toBeNull();
    const limited = await handleDownload(head(), env(false), payload);
    expect(limited.status).toBe(429);
    expect(limited.body).toBeNull();
  });

  it("omits the length of an encoded response, which describes the compressed bytes", async () => {
    vi.spyOn(console, "log").mockImplementation(() => undefined);
    vi.stubGlobal("fetch", async () =>
      new Response(null, { headers: { "content-type": "audio/mpeg", "content-encoding": "gzip", "content-length": "99", "accept-ranges": "bytes" } }),
    );
    const response = await handleDownload(head(), env(), payload);
    expect(response.status).toBe(200);
    expect(response.headers.has("content-length")).toBe(false);
    expect(response.headers.has("accept-ranges")).toBe(false);
  });
});

describe("rateLimitKey", () => {
  it.each([
    [null, "unknown"],
    ["", "unknown"],
    ["203.0.113.7", "203.0.113.7"],
    ["::ffff:203.0.113.7", "203.0.113.7"],
    ["2001:db8:1:2:3:4:5:6", "2001:db8:1:2::/64"],
    ["2001:db8:1:2::9", "2001:db8:1:2::/64"],
    ["2001:0db8:0001:0002:ffff::", "2001:db8:1:2::/64"],
    ["2001:db8::1", "2001:db8:0:0::/64"],
    ["::1", "0:0:0:0::/64"],
    ["fe80::1%en0", "fe80:0:0:0::/64"],
  ])("%s → %s", (address, key) => {
    expect(rateLimitKey(address)).toBe(key);
  });
});

describe("audioMediaType", () => {
  it.each([
    ["audio/mpeg", "audio/mpeg"],
    ["AUDIO/MP4; codecs=mp4a.40.2", "audio/mp4"],
    [" audio/x-m4a ", "audio/x-m4a"],
    ["application/octet-stream", "application/octet-stream"],
    ["binary/octet-stream", "binary/octet-stream"],
    [null, null],
    ["", null],
    ["text/html", null],
    ["video/mp4", null],
    ["audio/mpeg, text/javascript", null],
    ["audio/mpeg,text/css", null],
    ["audio/", null],
    ["audio/mpeg text/javascript", null],
    ["audio/mp\u0000eg", null],
  ])("%j → %j", (contentType, essence) => {
    expect(audioMediaType(contentType)).toBe(essence);
  });
});
