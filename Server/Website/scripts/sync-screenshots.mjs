#!/usr/bin/env node
// Pulls the latest framed App Store screenshots (iPhone set) from the
// fastlane output into public/screenshots/ so every deploy ships the
// current marketing set. Fails the deploy when the fastlane output is
// missing or site.ts references a file that did not sync; set
// SKIP_SCREENSHOT_SYNC=1 to deploy with the committed copies instead.
import { copyFileSync, existsSync, readFileSync, readdirSync, rmSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const websiteDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const repoDir = path.resolve(websiteDir, "..", "..");
const sourceDir = path.join(repoDir, "fastlane", "screenshots", "en-US");
const destinationDir = path.join(websiteDir, "public", "screenshots");
const devicePrefix = "iPhone 17 Pro Max-";
const framedPattern = /^app_store_.+_framed\.png$/;

if (process.env.SKIP_SCREENSHOT_SYNC === "1") {
  console.warn("sync-screenshots: SKIP_SCREENSHOT_SYNC=1 — deploying committed screenshot copies.");
  process.exit(0);
}

if (!existsSync(sourceDir)) {
  console.error(
    `sync-screenshots: ${sourceDir} does not exist.\n` +
      "Generate the set with `bundle exec fastlane ios app_store_screenshots`, " +
      "or set SKIP_SCREENSHOT_SYNC=1 to deploy the committed copies."
  );
  process.exit(1);
}

const framedSources = readdirSync(sourceDir)
  .filter((name) => name.startsWith(devicePrefix) && framedPattern.test(name.slice(devicePrefix.length)))
  .sort();

if (framedSources.length === 0) {
  console.error(
    `sync-screenshots: no "${devicePrefix}app_store_*_framed.png" files under ${sourceDir}.\n` +
      "Generate the set with `bundle exec fastlane ios app_store_screenshots`, " +
      "or set SKIP_SCREENSHOT_SYNC=1 to deploy the committed copies."
  );
  process.exit(1);
}

const synced = new Set();
for (const source of framedSources) {
  const basename = source.slice(devicePrefix.length);
  copyFileSync(path.join(sourceDir, source), path.join(destinationDir, basename));
  synced.add(basename);
}

const pruned = readdirSync(destinationDir).filter(
  (name) => framedPattern.test(name) && !synced.has(name)
);
for (const stale of pruned) {
  rmSync(path.join(destinationDir, stale));
}

const siteSource = readFileSync(path.join(websiteDir, "src", "lib", "site.ts"), "utf8");
const referenced = [...siteSource.matchAll(/\/screenshots\/([\w.-]+\.png)/g)].map((match) => match[1]);
const missing = referenced.filter((name) => !existsSync(path.join(destinationDir, name)));
if (missing.length > 0) {
  console.error(
    `sync-screenshots: site.ts references screenshots that did not sync: ${missing.join(", ")}.\n` +
      `Synced from ${sourceDir}: ${[...synced].join(", ")}`
  );
  process.exit(1);
}

console.log(
  `sync-screenshots: synced ${synced.size} framed screenshots` +
    (pruned.length > 0 ? `, pruned ${pruned.length} stale (${pruned.join(", ")})` : "") +
    `; site.ts references ${referenced.length} of them.`
);
