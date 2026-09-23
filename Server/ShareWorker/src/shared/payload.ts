import { inflateRawSync } from "node:zlib";
import { DICTIONARY_V1_BYTES } from "./dictionary.ts";
import { isWebURL } from "./urls.ts";

/** Everything the web player needs. Nothing about the sharer. */
export interface SharePayload {
  audioURL: string;
  title: string;
  podcastTitle: string;
  artworkURL: string;
  feedURL: string;
  guid: string;
  durationSeconds: number;
  publishedUnix: number;
}

export const PAYLOAD_FIELDS = [
  "audioURL", "title", "podcastTitle", "artworkURL", "feedURL", "guid", "durationSeconds", "publishedUnix",
] as const satisfies readonly (keyof SharePayload)[];

export const MAX_TOKEN_LENGTH = 4096;
export const MAX_TUPLE_BYTES = 16 * 1024;

/** `/e/<token>` and `/e/<token>/download`, matched before any decoding. */
export const SHARE_PATH = /^\/e\/(1[A-Za-z0-9_-]{15,4095})(\/download)?$/;

// Decode caps are looser than the app's (300 / 300 / 512 characters) so no
// token the app mints is ever cut; they only bound hand-made tokens.
const TITLE_LIMIT = 500;
const PODCAST_TITLE_LIMIT = 300;
const GUID_LIMIT = 1000;

const CONTROL_CHARACTERS = /\p{Cc}/gu;
// The app trims Swift's whitespace set, which is \p{Z} plus controls.
const EDGE_SPACE = /^\p{Z}+|\p{Z}+$/gu;
const graphemes = new Intl.Segmenter(undefined, { granularity: "grapheme" });

/**
 * Version "1": the eight-field tuple joined with "\n", raw DEFLATE primed with
 * DICTIONARY_V1, base64url without padding, behind the version character.
 * Returns null for anything the page must 404 on.
 */
export function decodeToken(token: string): SharePayload | null {
  if (token.length < 16 || token.length > MAX_TOKEN_LENGTH || token[0] !== "1" || !/^1[A-Za-z0-9_-]+$/.test(token)) {
    return null;
  }

  let tuple: string;
  try {
    const inflated = inflateRawSync(base64URLDecode(token.slice(1)), {
      dictionary: DICTIONARY_V1_BYTES,
      maxOutputLength: MAX_TUPLE_BYTES,
    });
    tuple = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true }).decode(inflated);
  } catch {
    return null;
  }

  const parts = tuple.split("\n");
  if (parts.length !== PAYLOAD_FIELDS.length) {
    return null;
  }
  const [audioURL, title, podcastTitle, artworkURL, feedURL, guid, duration, published] = parts as [
    string, string, string, string, string, string, string, string,
  ];

  const cleanTitle = cleanText(title, TITLE_LIMIT);
  if (!isWebURL(audioURL) || cleanTitle === "") {
    return null;
  }

  return {
    audioURL,
    title: cleanTitle,
    podcastTitle: cleanText(podcastTitle, PODCAST_TITLE_LIMIT),
    artworkURL: isWebURL(artworkURL) ? artworkURL : "",
    feedURL: isWebURL(feedURL) ? feedURL : "",
    guid: cleanText(guid, GUID_LIMIT),
    // Digits only: Number() would accept "1e3", "0x10" and "-5".
    durationSeconds: /^\d{1,7}$/.test(duration) ? Number(duration) : 0,
    publishedUnix: /^\d{1,10}$/.test(published) ? Number(published) : 0,
  };
}

function base64URLDecode(value: string): Uint8Array {
  const binary = atob(value.replace(/-/g, "+").replace(/_/g, "/"));
  const bytes = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index++) {
    bytes[index] = binary.charCodeAt(index);
  }
  return bytes;
}

function cleanText(value: string, limit: number): string {
  const cleaned = value.replace(CONTROL_CHARACTERS, "").replace(EDGE_SPACE, "");
  if (cleaned.length <= limit) {
    return cleaned;
  }
  const clusters = Array.from(graphemes.segment(cleaned), (segment) => segment.segment);
  return clusters.length <= limit ? cleaned : clusters.slice(0, limit).join("").replace(EDGE_SPACE, "");
}
