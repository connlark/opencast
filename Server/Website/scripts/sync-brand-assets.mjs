#!/usr/bin/env node
// Regenerates every brand image the website ships from the single source of
// truth: OpenCast/Resources/AppIcon.icon (the Icon Composer document that also
// produces the shipping iOS app icon).
//
// Requires macOS with Xcode 26+ installed, because the renderer is Icon
// Composer's embedded `ictool`. `xcrun ictool` is a different shim that only
// compiles asset catalogs — it cannot export images. Nothing else in the
// website build depends on Xcode; the generated PNG/JPEG outputs are committed
// so `yarn build` and `yarn deploy` work on any machine.
//
// Outputs (never hand-edit them — rerun this script instead):
//   public/brand/icon-light-{32,192}.png   Default rendition, for light UI
//   public/brand/icon-dark-{32,192}.png    Dark rendition, for dark UI
//   public/brand/apple-touch-icon-180.png  Default rendition, opaque
//   public/opengraph-image.jpg             1200x630 social card
import { execFileSync } from "node:child_process";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import sharp from "sharp";

const websiteDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const repoDir = path.resolve(websiteDir, "..", "..");
const iconDocument = path.join(repoDir, "OpenCast", "Resources", "AppIcon.icon");
const brandDir = path.join(websiteDir, "public", "brand");
const screenshotDir = path.join(websiteDir, "public", "screenshots");
const socialImagePath = path.join(websiteDir, "public", "opengraph-image.jpg");

const ictool =
  "/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool";

// Rendered once per rendition at 1024 and downscaled with Lanczos. Rendering
// natively at 32px loses the thin inner arc of the mark; downscaling a 1024
// master keeps it legible.
const MASTER_SIZE = 1024;

// The Default rendition's own background gradient, sampled from the render.
// Used to flatten the Apple touch icon (iOS composites transparent corners
// against white) and to key the social card.
const BRAND_NAVY_TOP = "#121f3c";
const BRAND_NAVY_BOTTOM = "#0d111c";
const BRAND_ORANGE = "#f9730e";
const BRAND_GOLD = "#fec44c";

const SOCIAL_TAGLINE = "Native podcasting. RSS-first.";
const SOCIAL_SCREENSHOT_ID = "app_store_01_now_playing_framed";

// Bounding box of the device inside a 464x1008 framed screenshot, measured from
// the committed render. The fastlane frame template is fixed, so these hold as
// long as the screenshot pipeline keeps producing 464px-wide framed shots.
const DEVICE_CROP = { left: 26, top: 247, width: 414, height: 761 };

// 32px drives the browser tab, 192px is both the site header mark (42 CSS px at
// up to 4x) and the multiple-of-48 size search engines and Android ask for.
const iconSizes = [
  { rendition: "Default", size: 32, name: "icon-light-32.png" },
  { rendition: "Default", size: 192, name: "icon-light-192.png" },
  { rendition: "Dark", size: 32, name: "icon-dark-32.png" },
  { rendition: "Dark", size: 192, name: "icon-dark-192.png" },
];

function fail(message) {
  console.error(`sync-brand-assets: ${message}`);
  process.exit(1);
}

if (process.platform !== "darwin") {
  fail(
    "this script renders OpenCast/Resources/AppIcon.icon with Icon Composer and " +
      "only runs on macOS. The generated assets are committed, so builds and " +
      "deploys do not need it."
  );
}
if (!existsSync(ictool)) {
  fail(
    `Icon Composer's ictool was not found at ${ictool}.\n` +
      "Install Xcode 26+ (the full app, not just Command Line Tools). Note that " +
      "`xcrun ictool` is a different tool and cannot export images."
  );
}
if (!existsSync(iconDocument)) {
  fail(`icon source ${iconDocument} does not exist.`);
}

function renderMaster(workDir, rendition) {
  const output = path.join(workDir, `master-${rendition}.png`);
  execFileSync(
    ictool,
    [
      iconDocument,
      "--export-image",
      "--output-file",
      output,
      "--platform",
      "iOS",
      "--rendition",
      rendition,
      "--width",
      String(MASTER_SIZE),
      "--height",
      String(MASTER_SIZE),
      "--scale",
      "1",
    ],
    { stdio: ["ignore", "ignore", "inherit"] }
  );
  if (!existsSync(output)) {
    fail(`ictool did not produce a ${rendition} rendition.`);
  }
  return output;
}

function pngPipeline(image) {
  // The mark sits on a smooth gradient, so palette quantization bands visibly.
  // Keep full colour and lean on zlib + adaptive filtering instead.
  return image.png({ compressionLevel: 9, effort: 10, palette: false });
}

function brandGradientSVG(width, height) {
  return Buffer.from(
    `<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${height}">` +
      `<defs><linearGradient id="g" x1="0" y1="0" x2="0" y2="1">` +
      `<stop offset="0" stop-color="${BRAND_NAVY_TOP}"/>` +
      `<stop offset="1" stop-color="${BRAND_NAVY_BOTTOM}"/>` +
      `</linearGradient></defs>` +
      `<rect width="${width}" height="${height}" fill="url(#g)"/></svg>`
  );
}

async function writeIconSizes(masters) {
  mkdirSync(brandDir, { recursive: true });
  const written = [];
  for (const { rendition, size, name } of iconSizes) {
    const buffer = await pngPipeline(
      sharp(masters[rendition]).resize(size, size, { kernel: sharp.kernel.lanczos3 })
    ).toBuffer();
    writeFileSync(path.join(brandDir, name), buffer);
    written.push({ name, bytes: buffer.length });
  }

  // Apple touch icons are composited against white when they carry alpha, which
  // would ring the squircle in white on a Home Screen. Flatten onto the icon's
  // own gradient so the corners disappear and iOS applies its own mask.
  const appleSize = 180;
  const appleName = "apple-touch-icon-180.png";
  const appleBuffer = await pngPipeline(
    sharp(brandGradientSVG(appleSize, appleSize)).composite([
      {
        input: await sharp(masters.Default)
          .resize(appleSize, appleSize, { kernel: sharp.kernel.lanczos3 })
          .png()
          .toBuffer(),
      },
    ])
  ).toBuffer();
  writeFileSync(path.join(brandDir, appleName), appleBuffer);
  written.push({ name: appleName, bytes: appleBuffer.length });

  const expected = new Set(written.map((entry) => entry.name));
  const stale = readdirSync(brandDir).filter((name) => !expected.has(name));
  for (const name of stale) {
    rmSync(path.join(brandDir, name), { recursive: true });
  }
  return { written, stale };
}

function resolveScreenshot() {
  if (!existsSync(screenshotDir)) {
    fail(
      `${screenshotDir} does not exist. Run \`yarn sync-screenshots\` before rebuilding brand assets.`
    );
  }
  const matches = readdirSync(screenshotDir).filter(
    (name) => name.startsWith(`${SOCIAL_SCREENSHOT_ID}.`) && name.endsWith(".w464.png")
  );
  if (matches.length !== 1) {
    fail(
      `expected exactly one committed ${SOCIAL_SCREENSHOT_ID}.*.w464.png in ` +
        `${screenshotDir}, found ${matches.length}. Run \`yarn sync-screenshots\`.`
    );
  }
  return path.join(screenshotDir, matches[0]);
}

async function buildSocialImage(defaultMaster) {
  const W = 1200;
  const H = 630;

  const screenshotPath = resolveScreenshot();
  const screenshotMeta = await sharp(screenshotPath).metadata();
  if (screenshotMeta.width !== 464) {
    fail(
      `social card expects a 464px-wide framed screenshot, got ${screenshotMeta.width}px. ` +
        "Update DEVICE_CROP in this script if the screenshot pipeline changed."
    );
  }
  if (DEVICE_CROP.top + DEVICE_CROP.height > screenshotMeta.height) {
    fail("DEVICE_CROP falls outside the framed screenshot; re-measure the device bounds.");
  }

  // The device is taller than the card on purpose: it bleeds off the bottom
  // edge, so it is trimmed to the visible band before compositing.
  // Sized so the visible band ends just below the scrubber and its ad-break
  // markers, above the transport row.
  const deviceWidth = 430;
  const deviceHeight = Math.round(
    (DEVICE_CROP.height / DEVICE_CROP.width) * deviceWidth
  );
  const deviceX = 718;
  const deviceY = 40;
  const deviceVisible = Math.min(deviceHeight, H - deviceY);
  // DEVICE_CROP is the device's bounding box, so its corners still hold the
  // framed screenshot's near-black backdrop. Knock them out with a rounded mask
  // matching the hardware corner before compositing onto the navy card.
  const deviceRadius = Math.round(deviceWidth * 0.163);
  const deviceMask = Buffer.from(
    `<svg xmlns="http://www.w3.org/2000/svg" width="${deviceWidth}" height="${deviceHeight}">` +
      `<rect width="${deviceWidth}" height="${deviceHeight}" rx="${deviceRadius}" fill="#ffffff"/></svg>`
  );

  const deviceFull = await sharp(screenshotPath)
    .extract(DEVICE_CROP)
    .resize(deviceWidth, deviceHeight, { kernel: sharp.kernel.lanczos3 })
    .composite([{ input: deviceMask, blend: "dest-in" }])
    .png()
    .toBuffer();
  const device = await sharp(deviceFull)
    .extract({ left: 0, top: 0, width: deviceWidth, height: deviceVisible })
    .png()
    .toBuffer();

  const iconSize = 148;
  const icon = await sharp(defaultMaster)
    .resize(iconSize, iconSize, { kernel: sharp.kernel.lanczos3 })
    .png()
    .toBuffer();

  const background = Buffer.from(`<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${H}">
  <defs>
    <linearGradient id="page" x1="0" y1="0" x2="0.55" y2="1">
      <stop offset="0" stop-color="#16264c"/>
      <stop offset="0.55" stop-color="${BRAND_NAVY_TOP}"/>
      <stop offset="1" stop-color="${BRAND_NAVY_BOTTOM}"/>
    </linearGradient>
    <radialGradient id="ember" cx="0.5" cy="0.5" r="0.5">
      <stop offset="0" stop-color="${BRAND_ORANGE}" stop-opacity="0.34"/>
      <stop offset="0.62" stop-color="${BRAND_ORANGE}" stop-opacity="0.09"/>
      <stop offset="1" stop-color="${BRAND_ORANGE}" stop-opacity="0"/>
    </radialGradient>
    <radialGradient id="glow" cx="0.5" cy="0.5" r="0.5">
      <stop offset="0" stop-color="#8fb6ff" stop-opacity="0.18"/>
      <stop offset="1" stop-color="#8fb6ff" stop-opacity="0"/>
    </radialGradient>
    <linearGradient id="vignette" x1="0" y1="0.55" x2="0" y2="1">
      <stop offset="0" stop-color="${BRAND_NAVY_BOTTOM}" stop-opacity="0"/>
      <stop offset="1" stop-color="${BRAND_NAVY_BOTTOM}" stop-opacity="0.55"/>
    </linearGradient>
    <pattern id="grid" width="72" height="72" patternUnits="userSpaceOnUse">
      <path d="M72 0H0V72" fill="none" stroke="#ffffff" stroke-opacity="0.05" stroke-width="1"/>
    </pattern>
    <linearGradient id="gridFade" x1="0" y1="0" x2="0.8" y2="1">
      <stop offset="0" stop-color="#ffffff" stop-opacity="0.9"/>
      <stop offset="1" stop-color="#ffffff" stop-opacity="0"/>
    </linearGradient>
    <mask id="gridMask">
      <rect width="${W}" height="${H}" fill="url(#gridFade)"/>
    </mask>
    <linearGradient id="rule" x1="0" y1="0" x2="1" y2="0">
      <stop offset="0" stop-color="${BRAND_ORANGE}"/>
      <stop offset="1" stop-color="${BRAND_GOLD}"/>
    </linearGradient>
  </defs>
  <rect width="${W}" height="${H}" fill="url(#page)"/>
  <rect width="${W}" height="${H}" fill="url(#grid)" mask="url(#gridMask)"/>
  <ellipse cx="1010" cy="560" rx="470" ry="360" fill="url(#ember)"/>
  <ellipse cx="180" cy="60" rx="440" ry="320" fill="url(#glow)"/>
  <rect width="${W}" height="${H}" fill="url(#vignette)"/>
</svg>`);

  const foreground = Buffer.from(`<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${H}">
  <defs>
    <linearGradient id="rule" x1="0" y1="0" x2="1" y2="0">
      <stop offset="0" stop-color="${BRAND_ORANGE}"/>
      <stop offset="1" stop-color="${BRAND_GOLD}"/>
    </linearGradient>
  </defs>
  <rect x="76" y="304" width="84" height="4" rx="2" fill="url(#rule)"/>
  <text x="76" y="418" font-family="System Font" font-size="104" font-weight="600"
        letter-spacing="-4.5" fill="#fdfaf5">opencast</text>
  <text x="76" y="476" font-family="System Font" font-size="34" font-weight="500"
        letter-spacing="-0.4" fill="${BRAND_GOLD}">${SOCIAL_TAGLINE}</text>
  <text x="76" y="548" font-family="System Font" font-size="23" font-weight="500"
        letter-spacing="1.7" fill="#ffffff" fill-opacity="0.46">OPENCAST.MOBILE</text>
</svg>`);

  // A soft drop shadow for the device, drawn as a blurred silhouette so we do
  // not depend on librsvg filter fidelity for the composite itself.
  const shadow = Buffer.from(`<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${H}">
  <defs><filter id="b" x="-40%" y="-40%" width="180%" height="180%">
    <feGaussianBlur stdDeviation="34"/>
  </filter></defs>
  <rect x="${deviceX + 10}" y="${deviceY + 28}" width="${deviceWidth - 20}"
        height="${deviceHeight}" rx="${deviceRadius}" fill="#000000" fill-opacity="0.6" filter="url(#b)"/>
</svg>`);

  const buffer = await sharp(background)
    .composite([
      { input: shadow, top: 0, left: 0 },
      { input: device, top: deviceY, left: deviceX },
      { input: icon, top: 106, left: 76 },
      { input: foreground, top: 0, left: 0 },
    ])
    .jpeg({ quality: 88, mozjpeg: true, chromaSubsampling: "4:4:4" })
    .toBuffer();

  writeFileSync(socialImagePath, buffer);
  return { bytes: buffer.length, screenshot: path.basename(screenshotPath) };
}

const workDir = mkdtempSync(path.join(tmpdir(), "opencast-brand-"));
try {
  const masters = {
    Default: renderMaster(workDir, "Default"),
    Dark: renderMaster(workDir, "Dark"),
  };
  for (const [rendition, file] of Object.entries(masters)) {
    const meta = await sharp(file).metadata();
    if (meta.width !== MASTER_SIZE || meta.height !== MASTER_SIZE) {
      fail(
        `${rendition} master rendered at ${meta.width}x${meta.height}, expected ` +
          `${MASTER_SIZE}x${MASTER_SIZE}.`
      );
    }
  }

  const { written, stale } = await writeIconSizes(masters);
  const social = await buildSocialImage(masters.Default);

  const totalBytes =
    written.reduce((sum, entry) => sum + entry.bytes, 0) + social.bytes;
  console.log(
    `sync-brand-assets: rendered Default + Dark iOS renditions of ` +
      `${path.relative(repoDir, iconDocument)} at ${MASTER_SIZE}px and wrote ` +
      `${written.length} icons to public/brand plus a 1200x630 social card from ` +
      `${social.screenshot} (${totalBytes.toLocaleString()} bytes total)` +
      (stale.length > 0 ? `, pruned ${stale.length} stale (${stale.join(", ")})` : "") +
      "."
  );
  for (const entry of written) {
    console.log(`  public/brand/${entry.name}  ${entry.bytes.toLocaleString()} bytes`);
  }
  console.log(
    `  public/opengraph-image.jpg  ${social.bytes.toLocaleString()} bytes`
  );
} finally {
  rmSync(workDir, { recursive: true, force: true });
}
