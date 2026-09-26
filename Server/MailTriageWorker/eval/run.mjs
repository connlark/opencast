// Posts each .eml case to a local `wrangler dev` (/__triage, development lane
// only) and checks which side of the ping/quiet line it lands on. The AI
// binding always runs remotely, so this exercises the real classifier.
//
//   yarn workspace opencast-mail-triage-worker eval [--dir DIR] [--url URL]
//
// DIR defaults to eval/cases. An expected.json beside the cases maps file name
// to {"side": "ping"|"quiet", "label"?: category}; without one, results are
// printed unchecked. A label mismatch is reported but only the side fails.
import { existsSync, readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const args = process.argv.slice(2);
const option = (name, fallback) => {
  const at = args.indexOf(name);
  return at >= 0 && args[at + 1] ? args[at + 1] : fallback;
};
const defaultDir = fileURLToPath(new URL("./cases", import.meta.url));
const dir = option("--dir", defaultDir);
const url = option("--url", "http://localhost:8787/__triage");
const expectedPath = existsSync(join(dir, "expected.json"))
  ? join(dir, "expected.json")
  : dir === defaultDir
    ? fileURLToPath(new URL("./expected.json", import.meta.url))
    : null;
const expected = expectedPath ? JSON.parse(readFileSync(expectedPath, "utf8")) : {};

const files = readdirSync(dir).filter((f) => f.endsWith(".eml")).sort();
let passed = 0;
let failed = 0;
let labelMismatches = 0;
for (const file of files) {
  const response = await fetch(url, { method: "POST", body: readFileSync(join(dir, file)) });
  if (!response.ok) {
    console.log(`${file}: HTTP ${response.status}`);
    failed++;
    continue;
  }
  const verdict = await response.json();
  const side = verdict.decision === "quiet" ? "quiet" : "ping";
  const want = expected[file];
  const junk = verdict.junkP === null ? "  n/a" : verdict.junkP.toFixed(3);
  let mark = "      ";
  if (want) {
    const ok = want.side === side;
    ok ? passed++ : failed++;
    mark = ok ? "ok    " : "FAIL  ";
    if (want.label && want.label !== verdict.label) {
      labelMismatches++;
      mark = ok ? "label " : mark;
    }
  }
  const source = verdict.source === "jev" ? "" : `  (fallback: ${verdict.reason})`;
  console.log(`${mark}${file.padEnd(34)} ${side.padEnd(5)} ${String(verdict.label).padEnd(12)} junk=${junk}${source}`);
}
console.log(`\npassed=${passed} failed=${failed} label_mismatches=${labelMismatches} unchecked=${files.length - passed - failed}`);
process.exitCode = failed > 0 ? 1 : 0;
