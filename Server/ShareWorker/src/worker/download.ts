import type { SharePayload } from "../shared/payload.ts";
import { positiveInteger, type Env } from "./env.ts";
import { logEvent } from "./log.ts";

const DEFAULT_MAX_BYTES = 1024 ** 3;
const DEFAULT_HEADER_TIMEOUT_MS = 10_000;
const USER_AGENT = "opencast-share/1 (+https://opencast.mobile)";
const FORWARDED_REQUEST_HEADERS = ["range", "if-range"];
const PASSTHROUGH_IDENTITY_HEADERS = ["last-modified", "etag"];
const PASSTHROUGH_RANGE_HEADERS = ["content-range", "accept-ranges"];
const OCTET_STREAM_TYPES = new Set(["application/octet-stream", "binary/octet-stream"]);
// RFC 9110 media-type essence: token "/" token.
const MEDIA_TYPE = /^[a-z0-9!#$%&'*+.^_`|~-]+\/[a-z0-9!#$%&'*+.^_`|~-]+$/;
const EXTENSIONS_BY_TYPE: Record<string, string> = {
  "audio/mpeg": "mp3",
  "audio/mp3": "mp3",
  "audio/mpeg3": "mp3",
  "audio/mp4": "m4a",
  "audio/x-m4a": "m4a",
  "audio/m4a": "m4a",
  "audio/aac": "aac",
  "audio/aacp": "aac",
  "audio/ogg": "ogg",
  "audio/opus": "opus",
  "audio/wav": "wav",
  "audio/wave": "wav",
  "audio/x-wav": "wav",
  "audio/flac": "flac",
  "audio/x-flac": "flac",
};
const KNOWN_EXTENSIONS = new Set(["mp3", "m4a", "aac", "ogg", "opus", "wav", "flac"]);

class UpstreamTimeout extends Error {}

/**
 * GET|HEAD /e/<token>/download: streams the enclosure back with an attachment
 * disposition so browsers save it instead of playing it. Only the explicit
 * Download button uses this route; the page's <audio> and og:audio fetch from
 * the listener's own device. Nothing is cached or stored.
 */
export async function handleDownload(request: Request, env: Env, payload: SharePayload): Promise<Response> {
  const head = request.method === "HEAD";
  // Per-colo, eventually consistent counters: a nuisance cap, not accounting.
  const { success } = await env.DOWNLOAD_RATE_LIMITER.limit({ key: rateLimitKey(request.headers.get("cf-connecting-ip")) });
  if (!success) {
    logEvent("download", { status: 429 });
    return textResponse(429, "Too many downloads from this network. Try again in a minute.", head, { "retry-after": "60" });
  }

  const maxBytes = positiveInteger(env.DOWNLOAD_MAX_BYTES, DEFAULT_MAX_BYTES);
  const timeoutMs = positiveInteger(env.UPSTREAM_HEADER_TIMEOUT_MS, DEFAULT_HEADER_TIMEOUT_MS);
  const host = new URL(payload.audioURL).hostname;

  let upstream: Response;
  try {
    upstream = await fetchUpstream(payload.audioURL, request, head ? "HEAD" : "GET", timeoutMs);
    if (head && (upstream.status === 405 || upstream.status === 501)) {
      await upstream.body?.cancel();
      upstream = await fetchUpstream(payload.audioURL, request, "GET", timeoutMs);
      await upstream.body?.cancel();
    }
  } catch (error) {
    const status = error instanceof UpstreamTimeout ? 504 : 502;
    logEvent("download", { status, host });
    return textResponse(status, "The podcast host did not answer. Try again later.", head);
  }

  const mediaType = audioMediaType(upstream.headers.get("content-type"));
  const encoded = isContentEncoded(upstream.headers.get("content-encoding"));
  // A range of an encoded representation is a slice of the compressed stream,
  // which cannot be decoded on its own.
  if ((upstream.status !== 200 && upstream.status !== 206) || mediaType === null || (encoded && upstream.status === 206)) {
    await upstream.body?.cancel();
    logEvent("download", { status: 502, host, upstreamStatus: upstream.status });
    return textResponse(502, "The episode audio is not available for download right now.", head);
  }

  // The runtime decodes gzip and br bodies but keeps the compressed length, so
  // an encoded response has no usable length and no meaningful byte ranges.
  const lengthHeader = encoded ? null : upstream.headers.get("content-length");
  const length = lengthHeader !== null && /^\d+$/.test(lengthHeader) ? Number(lengthHeader) : null;
  if (length !== null && length > maxBytes) {
    await upstream.body?.cancel();
    logEvent("download", { status: 413, host });
    return textResponse(413, "This episode is too large to download through opencast.", head);
  }

  // Only the validated media type goes out: a raw header could carry a second,
  // comma-joined type that a browser would honour.
  const headers = new Headers({ "content-type": mediaType });
  for (const name of encoded ? PASSTHROUGH_IDENTITY_HEADERS : [...PASSTHROUGH_IDENTITY_HEADERS, ...PASSTHROUGH_RANGE_HEADERS]) {
    const value = upstream.headers.get(name);
    if (value !== null) {
      headers.set(name, value);
    }
  }
  if (length !== null) {
    headers.set("content-length", String(length));
  }
  headers.set("content-disposition", attachmentDisposition(payload, mediaType));
  headers.set("cache-control", "private, no-store");
  headers.set("x-robots-tag", "noindex");
  headers.set("x-content-type-options", "nosniff");

  // Without a usable length the cap is enforced while streaming. The status is
  // already sent by then, so an oversized body arrives truncated.
  let body: ReadableStream<Uint8Array> | null = head ? null : upstream.body;
  if (body !== null && length === null) {
    body = body.pipeThrough(byteCap(maxBytes));
  }
  logEvent("download", { status: upstream.status, host });
  return new Response(body, { status: upstream.status, headers });
}

async function fetchUpstream(url: string, request: Request, method: "GET" | "HEAD", timeoutMs: number): Promise<Response> {
  // Asking for identity is a courtesy; an encoded answer is still handled.
  const headers = new Headers({ "user-agent": USER_AGENT, "accept-encoding": "identity" });
  for (const name of FORWARDED_REQUEST_HEADERS) {
    const value = request.headers.get(name);
    if (value !== null) {
      headers.set(name, value);
    }
  }

  // The timer covers the response headers only. AbortSignal.timeout would stay
  // armed through the streamed body and cut off any long download.
  const controller = new AbortController();
  let timer: ReturnType<typeof setTimeout> | undefined;
  const timeout = new Promise<never>((_, reject) => {
    timer = setTimeout(() => {
      controller.abort();
      reject(new UpstreamTimeout());
    }, timeoutMs);
  });
  try {
    // Proxied downloads reach the podcast host from Cloudflare with our user
    // agent, so IAB-style counting collapses them into one listener. The page's
    // <audio> element and og:audio fetch from the listener's device and count
    // normally. cacheTtl -1 keeps .mp3 (a default-cacheable extension) out of
    // the zone's edge cache; cacheEverything false alone does not.
    const init = {
      method,
      headers,
      redirect: "follow",
      signal: controller.signal,
      cf: { cacheTtl: -1 },
    } as RequestInit;
    return await Promise.race([globalThis.fetch(url, init), timeout]);
  } finally {
    clearTimeout(timer);
  }
}

/**
 * The lowercased essence of an audio or octet-stream Content-Type, or null.
 * A comma means a list (two headers or a joined value); refuse it outright.
 */
export function audioMediaType(contentType: string | null): string | null {
  if (contentType === null || contentType.includes(",")) {
    return null;
  }
  const essence = contentType.split(";")[0]!.trim().toLowerCase();
  if (!MEDIA_TYPE.test(essence)) {
    return null;
  }
  return essence.startsWith("audio/") || OCTET_STREAM_TYPES.has(essence) ? essence : null;
}

function isContentEncoded(contentEncoding: string | null): boolean {
  const value = contentEncoding?.trim().toLowerCase() ?? "";
  return value !== "" && value !== "identity";
}

function byteCap(maxBytes: number): TransformStream<Uint8Array, Uint8Array> {
  let seen = 0;
  return new TransformStream({
    transform(chunk, controller) {
      seen += chunk.byteLength;
      if (seen > maxBytes) {
        controller.error(new Error("download exceeded the size cap"));
        return;
      }
      controller.enqueue(chunk);
    },
  });
}

/** `"{podcastTitle} - {title}"`, 120 characters, as an ASCII fallback plus RFC 5987 UTF-8. */
export function attachmentDisposition(payload: SharePayload, mediaType: string): string {
  const joined = [payload.podcastTitle, payload.title].filter((part) => part !== "").join(" - ");
  const name = Array.from(joined.replace(/[\\/:*?"<>|\r\n]/g, "_")).slice(0, 120).join("").trim() || "episode";
  const file = `${name}.${extensionFor(mediaType, payload.audioURL)}`;
  const ascii = file.replace(/[^\x20-\x7e]/gu, "_");
  // encodeURIComponent leaves !'()* alone; RFC 5987 attr-char excludes them.
  const encoded = encodeURIComponent(file).replace(
    /[!'()*]/g,
    (character) => `%${character.charCodeAt(0).toString(16).toUpperCase()}`,
  );
  return `attachment; filename="${ascii}"; filename*=UTF-8''${encoded}`;
}

function extensionFor(mediaType: string, audioURL: string): string {
  const byType = EXTENSIONS_BY_TYPE[mediaType];
  if (byType !== undefined) {
    return byType;
  }
  const byPath = /\.([a-z0-9]{2,4})$/i.exec(new URL(audioURL).pathname)?.[1]?.toLowerCase();
  return byPath !== undefined && KNOWN_EXTENSIONS.has(byPath) ? byPath : "mp3";
}

/** IPv4 as is; IPv6 collapsed to its /64 so one client cannot rotate through its prefix. */
export function rateLimitKey(address: string | null): string {
  if (!address) {
    return "unknown";
  }
  const mapped = /^::ffff:(\d{1,3}(?:\.\d{1,3}){3})$/i.exec(address);
  if (mapped) {
    return mapped[1]!;
  }
  if (!address.includes(":")) {
    return address;
  }
  const [left = "", right] = address.split("::", 2);
  const leftGroups = left === "" ? [] : left.split(":");
  const rightGroups = right === undefined || right === "" ? [] : right.split(":");
  const groups = [...leftGroups, ...Array<string>(Math.max(0, 8 - leftGroups.length - rightGroups.length)).fill("0"), ...rightGroups];
  return `${groups.slice(0, 4).map((group) => (Number.parseInt(group, 16) || 0).toString(16)).join(":")}::/64`;
}

function textResponse(status: number, message: string, head: boolean, extra: Record<string, string> = {}): Response {
  const body = new TextEncoder().encode(`${message}\n`);
  return new Response(head ? null : body, {
    status,
    headers: {
      "content-type": "text/plain; charset=utf-8",
      "content-length": String(body.byteLength),
      "cache-control": "no-store",
      "x-robots-tag": "noindex",
      "x-content-type-options": "nosniff",
      ...extra,
    },
  });
}
