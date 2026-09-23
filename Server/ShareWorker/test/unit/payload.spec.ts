// The Swift encoder in OpenCastCore is the reference: its fixture tokens must
// decode here. Node ships Chromium's zlib fork, so this side only checks that
// its own output decodes and stays under each vector's length cap, never that
// it matches the Swift bytes.
import { createHash, randomBytes } from "node:crypto";
import { deflateRawSync, inflateRawSync } from "node:zlib";
import { describe, expect, it } from "vitest";
import vectorFixture from "../../../../Packages/OpenCastCore/Tests/OpenCastCoreTests/Fixtures/EpisodeShareTokenVectors.json";
import hostile from "../fixtures/hostile-tokens.json";
import { DICTIONARY_V1, DICTIONARY_V1_BYTES, DICTIONARY_V1_SHA256 } from "../../src/shared/dictionary.ts";
import { decodeToken, MAX_TOKEN_LENGTH, MAX_TUPLE_BYTES, PAYLOAD_FIELDS, SHARE_PATH, type SharePayload } from "../../src/shared/payload.ts";

function tokenFromBytes(bytes: Uint8Array, dictionary: Uint8Array | null = DICTIONARY_V1_BYTES): string {
  const options = dictionary ? { level: 9, memLevel: 9, dictionary } : { level: 9, memLevel: 9 };
  return `1${deflateRawSync(bytes, options).toString("base64url")}`;
}

function tokenFromFields(fields: string[]): string {
  return tokenFromBytes(Buffer.from(fields.join("\n"), "utf8"));
}

function fieldsOf(payload: SharePayload): string[] {
  return PAYLOAD_FIELDS.map((key) => String(payload[key]));
}

const valid = ["https://media.example.com/a.mp3", "Title", "Show", "https://media.example.com/a.jpg", "https://media.example.com/feed.xml", "guid", "60", "1758500000"];

describe("dictionary v1", () => {
  it("matches the pinned hash, byte count, and the Swift fixture", () => {
    const digest = createHash("sha256").update(DICTIONARY_V1_BYTES).digest("hex");
    expect(DICTIONARY_V1.length).toBe(961);
    expect(DICTIONARY_V1_BYTES.byteLength).toBe(965);
    expect(digest).toBe(DICTIONARY_V1_SHA256);
    expect(vectorFixture.dictionary).toEqual({ utf8Bytes: 965, sha256: digest });
  });
});

describe("Swift-minted vectors", () => {
  it("covers the fixture set", () => {
    expect(vectorFixture.format).toBe("opencast-episode-share-token");
    expect(vectorFixture.version).toBe("1");
    expect(vectorFixture.vectors.length).toBeGreaterThanOrEqual(7);
  });

  for (const vector of vectorFixture.vectors) {
    it(`${vector.name}: decodes to its payload`, () => {
      expect(decodeToken(vector.token)).toEqual(vector.payload);
    });

    it(`${vector.name}: builds its URL`, () => {
      const start = vector.startTime >= 1 ? `?t=${vector.startTime}` : "";
      expect(`https://opencast.mobile/e/${vector.token}${start}`).toBe(vector.url);
    });

    it(`${vector.name}: Node's zlib round-trips within maxTokenLength`, () => {
      const token = tokenFromFields(fieldsOf(vector.payload));
      expect(decodeToken(token)).toEqual(vector.payload);
      expect(token.length).toBeLessThanOrEqual(vector.maxTokenLength);
    });
  }

  it("the dictionary vector's cap fails an encoder that skips the dictionary", () => {
    const vector = vectorFixture.vectors.find((candidate) => candidate.name === "dictionary-sensitivity");
    expect(vector).toBeDefined();
    const withoutDictionary = tokenFromBytes(Buffer.from(fieldsOf(vector!.payload).join("\n")), null);
    expect(withoutDictionary.length).toBeGreaterThan(vector!.maxTokenLength);
  });
});

describe("decodeToken rejects", () => {
  it.each([
    ["the wrong version", `2${tokenFromFields(valid).slice(1)}`],
    ["garbage shorter than 16 characters", "1AAAAAAAAAAAAAA"],
    ["characters outside base64url", `${tokenFromFields(valid)}=`],
    ["a base64 length that cannot decode", `1${"A".repeat(17)}`],
    ["garbage deflate data", `1${"AAAAAAAAAAAAAAAAAAAAAAAA"}`],
    ["seven fields", hostile.sevenFields],
    ["nine fields", hostile.nineFields],
    ["a decompression bomb", hostile.bomb],
    ["a file: audio URL", hostile.fileAudio],
    ["a javascript: audio URL", hostile.javascriptAudio],
    ["an audio URL over 2048 characters", hostile.oversizedURL],
    ["a title of only controls and spaces", hostile.emptyTitle],
    ["invalid UTF-8", hostile.invalidUTF8],
    ["a zlib-wrapped stream", hostile.zlibWrapped],
    ["an audio URL with a host WHATWG rejects", tokenFromFields(["https://example.123/a.mp3", ...valid.slice(1)])],
    ["an audio URL with edge whitespace", tokenFromFields([" https://media.example.com/a.mp3", ...valid.slice(1)])],
  ])("%s", (_, token) => {
    expect(decodeToken(token)).toBeNull();
  });

  it("stops a bomb at the 16 KiB inflate cap quickly", () => {
    const started = performance.now();
    expect(decodeToken(hostile.bomb)).toBeNull();
    expect(performance.now() - started).toBeLessThan(250);
  });

  it("refuses the bombs only because of the inflate cap: uncapped, they are well-formed tuples", () => {
    for (const token of [hostile.bomb, hostile.overInflateCap]) {
      const tuple = inflateRawSync(Buffer.from(token.slice(1), "base64url"), { dictionary: DICTIONARY_V1_BYTES });
      expect(tuple.byteLength).toBeGreaterThan(MAX_TUPLE_BYTES);
      expect(tuple.toString("utf8").split("\n")).toHaveLength(8);
      expect(decodeToken(token)).toBeNull();
    }
  });

  it("decodes a tuple of exactly 16 KiB and refuses one byte more", () => {
    const fields = (guidLength: number) => [valid[0]!, "Title", "Show", "", "", "g".repeat(guidLength), "0", "0"];
    const fixedBytes = Buffer.byteLength(fields(0).join("\n"));
    expect(decodeToken(tokenFromFields(fields(MAX_TUPLE_BYTES - fixedBytes)))).not.toBeNull();
    expect(decodeToken(tokenFromFields(fields(MAX_TUPLE_BYTES - fixedBytes + 1)))).toBeNull();
  });

  it("refuses a well-formed token longer than 4096 characters", () => {
    const token = tokenFromFields([valid[0]!, "Title", "Show", "", "", randomBytes(3200).toString("base64url"), "0", "0"]);
    expect(token.length).toBeGreaterThan(MAX_TOKEN_LENGTH);
    expect(decodeToken(token)).toBeNull();
    expect(decodeToken(tokenFromFields([valid[0]!, "Title", "Show", "", "", randomBytes(2000).toString("base64url"), "0", "0"]))).not.toBeNull();
  });
});

describe("decodeToken normalises", () => {
  it("drops non-http artwork and feed URLs instead of rejecting", () => {
    const payload = decodeToken(tokenFromFields([valid[0]!, "Title", "Show", "javascript:alert(1)", "ftp://example.com/feed", "", "0", "0"]));
    expect(payload?.artworkURL).toBe("");
    expect(payload?.feedURL).toBe("");
  });

  it("strips control characters and edge spaces from text", () => {
    const payload = decodeToken(tokenFromFields([valid[0]!, "\u0007 Ti\u0000tle ", "\u001bShow\u0085", "", "", "g\tu\u007fid ", "0", "0"]));
    expect(payload).toMatchObject({ title: "Title", podcastTitle: "Show", guid: "guid" });
  });

  it.each([
    ["1e3", 0],
    ["-5", 0],
    ["0x10", 0],
    [" 60", 0],
    ["12345678", 0],
    ["9999999", 9999999],
    ["3600", 3600],
  ])("reads duration %s as %i", (raw, seconds) => {
    expect(decodeToken(tokenFromFields([valid[0]!, "Title", "", "", "", "", raw, "0"]))?.durationSeconds).toBe(seconds);
  });

  it.each([
    ["1758500000", 1758500000],
    ["17585000000", 0],
    ["1.5", 0],
  ])("reads published %s as %i", (raw, seconds) => {
    expect(decodeToken(tokenFromFields([valid[0]!, "Title", "", "", "", "", "0", raw]))?.publishedUnix).toBe(seconds);
  });

  it("caps hand-made titles by grapheme without splitting one", () => {
    const payload = decodeToken(tokenFromFields([valid[0]!, "👨‍👩‍👧‍👦".repeat(600), "", "", "", "", "0", "0"]));
    expect(Array.from(new Intl.Segmenter().segment(payload!.title))).toHaveLength(500);
    expect(payload!.title).toBe("👨‍👩‍👧‍👦".repeat(500));
  });
});

describe("share path", () => {
  it.each([
    ["/e/1AAAAAAAAAAAAAAA", true],
    ["/e/1AAAAAAAAAAAAAAA/download", true],
    ["/e/1AAAAAAAAAAAAAA", false],
    ["/e/2AAAAAAAAAAAAAAA", false],
    ["/e/1AAAAAAAAAAAAAAA/", false],
    ["/e/1AAAAAAAAAAAAAAA/other", false],
    ["/e/_/entry.js", false],
    [`/e/1${"A".repeat(4095)}`, true],
    [`/e/1${"A".repeat(4096)}`, false],
  ])("%s → %s", (path, matches) => {
    expect(SHARE_PATH.test(path)).toBe(matches);
  });
});
