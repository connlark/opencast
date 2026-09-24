// Renders the server document through the same react → preact/compat alias
// as the build and checks the Open Graph set verified live in Messages.
import { renderToString } from "preact-render-to-string";
import { describe, expect, it } from "vitest";
import vectorFixture from "../../../../Packages/OpenCastCore/Tests/OpenCastCoreTests/Fixtures/EpisodeShareTokenVectors.json";
import { NotFoundPage } from "../../src/app/NotFoundPage.tsx";
import { Page, shareDescription } from "../../src/app/Page.tsx";
import type { SharePayload } from "../../src/shared/payload.ts";
import { canonicalURL } from "../../src/shared/urls.ts";

const ORIGIN = "https://share.example.com";
const ASSETS = { js: "/e/_/entry.js?v=abc1234", css: "/e/_/entry.css?v=abc1234" };

function vector(name: string) {
  const found = vectorFixture.vectors.find((candidate) => candidate.name === name);
  if (!found) {
    throw new Error(`missing vector ${name}`);
  }
  return found;
}

function render(payload: SharePayload, token: string, start = 0): string {
  const html = renderToString(
    (<Page payload={payload} token={token} start={start} canonical={canonicalURL(ORIGIN, token, start)} assets={ASSETS} />) as never,
  );
  return `<!doctype html>${html}`;
}

function meta(html: string, key: string): string[] {
  const pattern = new RegExp(`<meta (?:property|name)="${key.replace(/[.:]/g, "\\$&")}" content="([^"]*)"`, "g");
  return Array.from(html.matchAll(pattern), (match) => match[1]!);
}

function decodeEntities(value: string): string {
  return value
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&amp;/g, "&");
}

describe("Page head", () => {
  const almanac = vector("almanac-fixture");
  const html = render(almanac.payload, almanac.token, 754);
  const canonical = `${ORIGIN}/e/${almanac.token}?t=754`;

  it("emits exactly the verified Open Graph and Twitter set", () => {
    expect(html).toContain("<title>Rubber Duck, Final Witness — The Example Almanac</title>");
    expect(meta(html, "description")).toEqual(["The Example Almanac · starts at 12:34 of 40:00"]);
    expect(meta(html, "robots")).toEqual(["noindex"]);
    expect(html).toContain(`<link rel="canonical" href="${canonical}"/>`);
    expect(meta(html, "og:type")).toEqual(["music.song"]);
    expect(meta(html, "og:site_name")).toEqual(["opencast"]);
    expect(meta(html, "og:title")).toEqual(["Rubber Duck, Final Witness"]);
    expect(meta(html, "og:description")).toEqual(["The Example Almanac · starts at 12:34 of 40:00"]);
    expect(meta(html, "og:url")).toEqual([canonical]);
    expect(meta(html, "og:image")).toEqual([almanac.payload.artworkURL]);
    expect(meta(html, "og:image:alt")).toEqual(["The Example Almanac artwork"]);
    expect(meta(html, "og:audio")).toEqual([almanac.payload.audioURL]);
    expect(meta(html, "og:audio:secure_url")).toEqual([almanac.payload.audioURL]);
    expect(meta(html, "og:audio:type")).toEqual(["audio/mpeg"]);
    expect(meta(html, "music:duration")).toEqual(["2400"]);
    expect(meta(html, "twitter:card")).toEqual(["summary"]);
    expect(meta(html, "twitter:title")).toEqual(["Rubber Duck, Final Witness"]);
    expect(meta(html, "twitter:description")).toEqual(["The Example Almanac · starts at 12:34 of 40:00"]);
    expect(meta(html, "twitter:image")).toEqual([almanac.payload.artworkURL]);
    expect(html).toContain('<meta name="theme-color" media="(prefers-color-scheme: light)" content="#fbf7f2"/>');
    expect(html).toContain('<meta name="theme-color" media="(prefers-color-scheme: dark)" content="#0a0e18"/>');
    expect(html).not.toMatch(/twitter:player|og:video/);
  });

  it("links the feed as an RSS alternate", () => {
    expect(html).toContain(`<link rel="alternate" type="application/rss+xml" title="The Example Almanac" href="${almanac.payload.feedURL}"/>`);
  });

  it("versions both asset URLs and loads nothing third-party", () => {
    expect(html).toContain('<link rel="stylesheet" href="/e/_/entry.css?v=abc1234"/>');
    expect(html).toContain('<script type="module" src="/e/_/entry.js?v=abc1234"></script>');
    const scripts = Array.from(html.matchAll(/<script[^>]*\ssrc="([^"]*)"/g), (match) => match[1]);
    expect(scripts).toEqual(["/e/_/entry.js?v=abc1234"]);
    const links = Array.from(html.matchAll(/<link rel="([^"]*)"[^>]*href="([^"]*)"/g), (match) => [match[1]!, match[2]!] as const);
    for (const [rel, href] of links) {
      if (rel === "stylesheet") {
        expect(href.startsWith("/")).toBe(true);
      } else if (rel === "icon" || rel === "apple-touch-icon") {
        expect(href.startsWith("https://opencast.mobile/brand/")).toBe(true);
      } else {
        expect(["canonical", "alternate"]).toContain(rel);
      }
    }
    expect(html).not.toMatch(/fonts\.(googleapis|gstatic)|<link[^>]*rel="preload"/);
  });

  it("hydrates only the body root, with the state script before it", () => {
    const state = html.indexOf('<script id="__share" type="application/json">');
    const root = html.indexOf('<main id="app"');
    expect(state).toBeGreaterThan(html.indexOf("<body"));
    expect(root).toBeGreaterThan(state);
    const json = html.slice(html.indexOf(">", state) + 1, html.indexOf("</script>", state));
    expect(JSON.parse(json)).toEqual({ payload: almanac.payload, token: almanac.token, start: 754, canonical });
  });

  it("renders the player's accessible controls on the server", () => {
    expect(html).toContain('aria-label="Seek"');
    expect(html).toContain('aria-valuetext="12:34 of 40:00"');
    expect(html).toContain('aria-label="Playback speed, 1×"');
    expect(html).toContain(`href="/e/${almanac.token}/download"`);
    expect(html).toMatch(/<h1[^>]*>Rubber Duck, Final Witness<\/h1>/);
    expect(html).toMatch(/<header[\s>]/);
    expect(html).toMatch(/<footer[\s>]/);
    expect(html).toContain(">Share<");
    expect(html).not.toContain("Copy link");
  });

  it("quotes the artwork in the CSS url()", () => {
    expect(html).toContain(`background-image:url(&quot;${almanac.payload.artworkURL}&quot;)`);
  });
});

describe("Page edge cases", () => {
  it("omits secure_url, duration, artwork and the feed link when the payload lacks them", () => {
    const bare = vector("empty-optionals");
    const html = render(bare.payload, bare.token);
    expect(meta(html, "og:audio")).toEqual(["http://plain.example.com/episodes/42.mp3"]);
    expect(meta(html, "og:audio:secure_url")).toEqual([]);
    expect(meta(html, "music:duration")).toEqual([]);
    expect(meta(html, "og:image")).toEqual(["https://opencast.mobile/opengraph-image.jpg"]);
    expect(meta(html, "og:description")).toEqual(["Bare Feed"]);
    expect(html).not.toContain('rel="alternate"');
    expect(html).not.toContain("background-image");
    expect(html).toContain(`src="https://plain.example.com/episodes/42.mp3"`);
  });

  it("describes m4a audio as audio/mp4", () => {
    const unicode = vector("unicode-title");
    const html = render(unicode.payload, unicode.token, 61);
    expect(meta(html, "og:audio:type")).toEqual(["audio/mp4"]);
    expect(meta(html, "og:title").map(decodeEntities)).toEqual([unicode.payload.title]);
  });

  it("escapes markup in titles and keeps </script> out of the state script", () => {
    const payload: SharePayload = {
      audioURL: "https://media.example.com/a.mp3",
      title: '</script><script>alert("x")</script>',
      podcastTitle: "A <b>bold</b> show",
      artworkURL: "https://media.example.com/art.jpg?x=\\\")",
      feedURL: "",
      guid: "",
      durationSeconds: 0,
      publishedUnix: 0,
    };
    const html = render(payload, "1AAAAAAAAAAAAAAAA");
    expect(html.match(/<script/g)).toHaveLength(2);
    expect(html).toContain("\\u003c/script>\\u003cscript>");
    expect(html).not.toContain("<b>bold</b>");
    expect(html).toContain("url(&quot;https://media.example.com/art.jpg?x=\\\\%22)&quot;)");
  });

  it("offers the browser's own player when script is off, with its src escaped", () => {
    const payload: SharePayload = {
      ...vector("almanac-fixture").payload,
      audioURL: "http://media.example.com/a.mp3?x=1&lt=2&quot=3",
    };
    const html = render(payload, "1AAAAAAAAAAAAAAAA");
    expect(html).toContain("<noscript><style>[data-needs-script]{display:none!important}[data-actions]{display:flex!important}</style></noscript>");
    expect(html).toContain(
      '<noscript><audio controls preload="none" src="https://media.example.com/a.mp3?x=1&amp;lt=2&amp;quot=3" class="mt-6 w-full"></audio></noscript>',
    );
    // The style, then what it hides: speed, the seek bar, both skips, Play, Share.
    expect(html.match(/data-needs-script/g)).toHaveLength(7);
  });

  it("writes descriptions for every combination", () => {
    const base = vector("almanac-fixture").payload;
    expect(shareDescription(base, 0)).toBe("The Example Almanac · 40:00");
    expect(shareDescription({ ...base, durationSeconds: 0 }, 754)).toBe("The Example Almanac · starts at 12:34");
    expect(shareDescription({ ...base, podcastTitle: "" }, 754)).toBe("Starts at 12:34 of 40:00");
    expect(shareDescription({ ...base, podcastTitle: "", durationSeconds: 0 }, 0)).toBe(base.title);
  });
});

describe("NotFoundPage", () => {
  it("is branded, noindex, and ships no script", () => {
    const html = renderToString((<NotFoundPage assets={ASSETS} />) as never);
    expect(html).toContain("This share link isn't valid");
    expect(html).toContain('<meta name="robots" content="noindex"/>');
    expect(html).toContain('href="https://opencast.mobile"');
    expect(html).not.toContain("<script");
  });
});
