// Mutable RSS fixture for the two-device episode-identity exercise.
//
// Serves "The Grafted Podcast" at /feed.xml with a GUID set chosen by the
// KV-backed state: "v1" emits urn:castgraft:legacy:* GUIDs, "v2" emits
// urn:castgraft:modern:*. Titles, enclosures, and dates never change, so a
// v1→v2 flip is exactly the guid-rotation legacy state the app's identity
// reconciliation and "Merge Duplicate Episodes" sweep repair: episode IDs
// change while the audio-URL and title tiers still match.
//
// Enclosures reuse the seed podcast's public MP3s so playback works without
// hosting new media. The admin flip is token-gated; the feed itself is public
// like every other fixture feed.

const EPISODES = [
  {
    title: "Graft One",
    slug: "001",
    media: "001-seed.mp3",
    length: 20298,
    duration: "00:00:05",
    pubDate: "Tue, 12 May 2026 12:00:00 -0500",
  },
  {
    title: "Whip Two",
    slug: "002",
    media: "002-sprout.mp3",
    length: 28202,
    duration: "00:00:07",
    pubDate: "Mon, 11 May 2026 12:00:00 -0500",
  },
  {
    title: "Bridge Three",
    slug: "003",
    media: "003-root.mp3",
    length: 36210,
    duration: "00:00:09",
    pubDate: "Sun, 10 May 2026 12:00:00 -0500",
  },
];

const FEED_URL = "https://graft.example.com/feed.xml";
const MEDIA_BASE = "https://seed.example.com/media";
const ARTWORK_URL = "https://seed.example.com/artwork/cover.svg";
const STATE_KEY = "guid-state";
const VALID_STATES = new Set(["v1", "v2"]);

function guidFor(state, slug) {
  const generation = state === "v2" ? "modern" : "legacy";
  return `urn:castgraft:${generation}:${slug}`;
}

function feedXML(state) {
  const items = EPISODES.map(
    (episode) => `    <item>
      <title>${episode.title}</title>
      <link>${FEED_URL}#graft-${episode.slug}</link>
      <description>Grafted podcast exercise episode.</description>
      <pubDate>${episode.pubDate}</pubDate>
      <guid isPermaLink="false">${guidFor(state, episode.slug)}</guid>
      <enclosure url="${MEDIA_BASE}/${episode.media}" length="${episode.length}" type="audio/mpeg"></enclosure>
      <itunes:duration>${episode.duration}</itunes:duration>
      <itunes:explicit>false</itunes:explicit>
    </item>`
  ).join("\n");

  return `<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd" xmlns:atom="http://www.w3.org/2005/Atom">
  <channel>
    <title>The Grafted Podcast</title>
    <link>https://graft.example.com</link>
    <description>Mutable exercise feed for episode-identity device tests.</description>
    <language>en-us</language>
    <atom:link href="${FEED_URL}" rel="self" type="application/rss+xml"></atom:link>
    <image>
      <url>${ARTWORK_URL}</url>
      <title>The Grafted Podcast</title>
      <link>https://graft.example.com</link>
    </image>
    <itunes:author>Example Studios</itunes:author>
    <itunes:explicit>false</itunes:explicit>
    <itunes:category text="Technology"></itunes:category>
    <itunes:image href="${ARTWORK_URL}"></itunes:image>
${items}
  </channel>
</rss>
`;
}

async function currentState(env) {
  const stored = await env.STATE.get(STATE_KEY);
  return VALID_STATES.has(stored) ? stored : "v1";
}

// Digest-first, then constant-time compare: the SHA-256 round gives both
// sides a fixed length (timingSafeEqual requires it) and removes any
// length or prefix timing signal from the raw string comparison this
// replaced. Exported for the worker's tests.
export async function adminTokenMatches(providedAuthorization, adminToken) {
  const encoder = new TextEncoder();
  const [providedDigest, expectedDigest] = await Promise.all([
    crypto.subtle.digest("SHA-256", encoder.encode(providedAuthorization ?? "")),
    crypto.subtle.digest("SHA-256", encoder.encode(`Bearer ${adminToken}`)),
  ]);
  return crypto.subtle.timingSafeEqual(providedDigest, expectedDigest);
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (url.pathname === "/feed.xml" && (request.method === "GET" || request.method === "HEAD")) {
      const state = await currentState(env);
      const etag = `"graft-${state}"`;
      const headers = {
        "Content-Type": "application/rss+xml; charset=utf-8",
        "Cache-Control": "no-store",
        ETag: etag,
      };
      if (request.headers.get("If-None-Match") === etag) {
        return new Response(null, { status: 304, headers: { ETag: etag } });
      }
      // HEAD gets the headers with no body, so `curl -I` during debugging
      // reads as a live route instead of a 404.
      const body = request.method === "HEAD" ? null : feedXML(state);
      return new Response(body, { headers });
    }

    if (url.pathname === "/state" && request.method === "GET") {
      return new Response(await currentState(env), {
        headers: { "Content-Type": "text/plain", "Cache-Control": "no-store" },
      });
    }

    // Derive the flip target from VALID_STATES rather than a second copy of
    // the state set, so a future generation only has to be added in one place.
    const flipTarget = url.pathname.startsWith("/state/")
      ? url.pathname.slice("/state/".length)
      : null;
    if (flipTarget !== null && VALID_STATES.has(flipTarget) && request.method === "POST") {
      const token = request.headers.get("Authorization");
      if (!env.ADMIN_TOKEN || !(await adminTokenMatches(token, env.ADMIN_TOKEN))) {
        return new Response("forbidden", { status: 403 });
      }
      await env.STATE.put(STATE_KEY, flipTarget);
      return new Response(flipTarget, {
        headers: { "Content-Type": "text/plain" },
      });
    }

    return new Response("not found", { status: 404 });
  },
};
