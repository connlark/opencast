// Token fixtures for the browser tests, minted with the same encoder as
// scripts/mint-link.mjs. Layout depends on content, so most of these exist to
// be hostile: long and unbreakable text, mixed scripts, odd artwork, missing
// or absurd durations, and hosts that fail or stall.
import { readFileSync } from "node:fs";
import { tokenFromFields } from "../../scripts/mint-link.mjs";
import { decodeToken, type SharePayload } from "../../src/shared/payload.ts";

// Read rather than imported: Playwright loads specs as native ESM, where a JSON
// import needs an attribute this tsconfig's module target cannot express.
const VECTORS = new URL("../../../../Packages/OpenCastCore/Tests/OpenCastCoreTests/Fixtures/EpisodeShareTokenVectors.json", import.meta.url);

export interface SwiftVector {
  name: string;
  token: string;
  startTime: number;
  payload: SharePayload;
}

export function swiftVectors(): SwiftVector[] {
  return JSON.parse(readFileSync(VECTORS, "utf8")).vectors;
}

export type Fields = Partial<Record<keyof SharePayload, string | number>>;

/** A token the worker accepts; throws if the decoder would 404 it. */
export function mint(fields: Fields): string {
  const token = tokenFromFields([
    String(fields.audioURL ?? ""),
    String(fields.title ?? ""),
    String(fields.podcastTitle ?? ""),
    String(fields.artworkURL ?? ""),
    String(fields.feedURL ?? ""),
    String(fields.guid ?? ""),
    String(fields.durationSeconds ?? 0),
    String(fields.publishedUnix ?? 0),
  ]);
  if (decodeToken(token) === null) {
    throw new Error(`the worker would reject this fixture: ${JSON.stringify(fields).slice(0, 200)}`);
  }
  return token;
}

/** A plain, well-behaved episode: 60 s of audio at the stand-in host, square art. */
export function happyFields(media: string): Fields {
  return {
    audioURL: `${media}/audio/60.mp3`,
    title: "Rubber Duck, Final Witness",
    podcastTitle: "The Example Almanac",
    artworkURL: `${media}/art/square.png`,
    feedURL: "https://feeds.example.test/almanac.xml",
    guid: "tag:example.test,2026:almanac:010",
    durationSeconds: 60,
    publishedUnix: 1778590800,
  };
}

export interface FixtureToken {
  token: string;
  fields: Fields;
  /** Resources this fixture is expected to fail on, as URL substrings. */
  expectedFailures: string[];
}

export function fixtureTokens(media: string): Record<string, FixtureToken> {
  const happy = happyFields(media);
  const defs: Record<string, [Fields, string[]?]> = {
    happy: [happy],
    "long-text": [
      {
        ...happy,
        title:
          "An extraordinarily long episode title that keeps going well past any reasonable length, because some feeds paste the whole show notes intro into the title field and the page still has to hold together at three hundred and twenty points wide",
        podcastTitle:
          "The Podcast With A Name So Long That It Wraps Across Several Lines Even On The Widest Phone, Featuring Guests, Friends, Special Correspondents And Everyone Else",
      },
    ],
    unbreakable: [
      {
        ...happy,
        title: `Episode_${"Supercalifragilisticexpialidocious".repeat(6)}`,
        podcastTitle: `https://example.test/${"segment-that-never-breaks/".repeat(8)}`,
      },
    ],
    scripts: [
      {
        ...happy,
        title: "حلقة ١٢: 🧑🏽‍💻 הפרק ✨ 第十二回 — 日本語のタイトル 👩‍👩‍👧‍👦",
        podcastTitle: "بودكاست 🎧 播客 · 팟캐스트",
      },
    ],
    // Escaping: markup in the text, and CSS-significant characters in the
    // URL the artwork glow puts inside url("…").
    markup: [
      {
        ...happy,
        title: `</script><script>alert(1)</script> <b>bold</b> & "quotes" 'apostrophes' ${"`"}ticks${"`"}`,
        podcastTitle: "<img src=x onerror=alert(1)> Show &amp; Tell",
        artworkURL: `${media}/art/square.png?q=%22)%20red;x=('\\")`,
      },
    ],
    "no-artwork": [{ ...happy, artworkURL: "" }],
    "artwork-404": [{ ...happy, artworkURL: `${media}/art/missing.png` }, ["/art/missing.png"]],
    "artwork-wide": [{ ...happy, artworkURL: `${media}/art/wide.png` }],
    "artwork-tall": [{ ...happy, artworkURL: `${media}/art/tall.png` }],
    "artwork-svg": [{ ...happy, artworkURL: `${media}/art/cover.svg` }],
    "no-duration": [{ ...happy, durationSeconds: 0 }],
    "huge-duration": [{ ...happy, durationSeconds: 360000 }],
    "long-audio": [{ ...happy, audioURL: `${media}/audio/10800.mp3`, durationSeconds: 10800 }],
    "audio-404": [{ ...happy, audioURL: `${media}/audio/missing.mp3` }, ["/audio/missing.mp3"]],
    "audio-slow": [{ ...happy, audioURL: `${media}/audio/slow/4000/60.mp3` }],
  };

  // The app's own vectors, with their hosts swapped for the stand-in so the
  // content (Unicode, CRLF, tracker-prefixed URLs, empty optionals) is what the
  // page actually renders. The untouched tokens are exercised in routes.e2e.ts.
  for (const vector of swiftVectors()) {
    const payload = vector.payload;
    defs[`swift-${vector.name}`] = [
      {
        ...payload,
        audioURL: `${media}/audio/${payload.durationSeconds || 60}.mp3`,
        artworkURL: payload.artworkURL === "" ? "" : `${media}/art/square.png`,
      },
    ];
  }

  return Object.fromEntries(
    Object.entries(defs).map(([name, [fields, expectedFailures = []]]) => [
      name,
      { token: mint(fields), fields, expectedFailures },
    ]),
  );
}
