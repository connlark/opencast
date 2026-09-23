#!/usr/bin/env node
// Development tool: mint a share link by hand, or regenerate the hostile-token
// fixture the tests use. The app is the real encoder (OpenCastCore); tokens
// from this script decode identically but are not byte-compared with it.
//
//   node scripts/mint-link.mjs --audio <url> --title <title> [--podcast <title>]
//        [--artwork <url>] [--feed <url>] [--guid <guid>] [--duration <seconds>]
//        [--published <unix seconds>] [--t <seconds>] [--origin https://opencast.mobile]
//   node scripts/mint-link.mjs --hostile   rewrites test/fixtures/hostile-tokens.json
import { writeFileSync } from "node:fs";
import { parseArgs } from "node:util";
import { deflateRawSync } from "node:zlib";
import { DICTIONARY_V1_BYTES } from "../src/shared/dictionary.ts";
import { decodeToken } from "../src/shared/payload.ts";

export function tokenFromBytes(bytes) {
  return `1${deflateRawSync(bytes, { level: 9, memLevel: 9, dictionary: DICTIONARY_V1_BYTES }).toString("base64url")}`;
}

export function tokenFromFields(fields) {
  return tokenFromBytes(Buffer.from(fields.join("\n"), "utf8"));
}

function hostileTokens() {
  const valid = ["https://media.example.com/a.mp3", "Title", "Show", "", "", "", "60", "0"];
  return {
    // Well-formed tuples that only the decoder's 16 KiB inflate cap can refuse:
    // a 200 KB guid deflates to a few hundred characters.
    bomb: tokenFromFields([...valid.slice(0, 5), "g".repeat(200 * 1024), ...valid.slice(6)]),
    overInflateCap: tokenFromFields([...valid.slice(0, 5), "g".repeat(16 * 1024), ...valid.slice(6)]),
    sevenFields: tokenFromFields(valid.slice(0, 7)),
    nineFields: tokenFromFields([...valid, "extra"]),
    fileAudio: tokenFromFields(["file:///private/var/a.mp3", ...valid.slice(1)]),
    javascriptAudio: tokenFromFields(["javascript:alert(1)", ...valid.slice(1)]),
    emptyTitle: tokenFromFields([valid[0], " \t\u0007 ", ...valid.slice(2)]),
    invalidUTF8: tokenFromBytes(Buffer.concat([Buffer.from(`${valid[0]}\nTi`), Buffer.from([0xc3, 0x28]), Buffer.from("tle\nShow\n\n\n\n60\n0")])),
    oversizedURL: tokenFromFields([`https://media.example.com/${"a".repeat(2100)}.mp3`, ...valid.slice(1)]),
    // Wrong-dictionary data is caught only by the tuple checks: raw deflate carries no dictionary id.
    zlibWrapped: `1${Buffer.from([0x78, 0xda, 0x01, 0x00, 0x00, 0xff, 0xff]).toString("base64url")}${"A".repeat(16)}`,
  };
}

function mintLink(values) {
  const fields = [
    values.audio ?? "",
    values.title ?? "",
    values.podcast ?? "",
    values.artwork ?? "",
    values.feed ?? "",
    values.guid ?? "",
    values.duration ?? "0",
    values.published ?? "0",
  ];
  const token = tokenFromFields(fields);
  const decoded = decodeToken(token);
  if (decoded === null) {
    throw new Error("the worker would reject this payload (check the audio URL and title)");
  }
  const origin = values.origin ?? "https://opencast.mobile";
  const start = values.t && Number(values.t) >= 1 ? `?t=${Number(values.t)}` : "";
  return `${origin}/e/${token}${start}`;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const { values } = parseArgs({
    options: Object.fromEntries(
      ["audio", "title", "podcast", "artwork", "feed", "guid", "duration", "published", "t", "origin"].map((name) => [
        name,
        { type: "string" },
      ]).concat([["hostile", { type: "boolean" }]]),
    ),
  });
  if (values.hostile) {
    const path = new URL("../test/fixtures/hostile-tokens.json", import.meta.url);
    writeFileSync(path, `${JSON.stringify(hostileTokens(), null, 2)}\n`);
    console.log(`wrote ${path.pathname}`);
  } else {
    console.log(mintLink(values));
  }
}
