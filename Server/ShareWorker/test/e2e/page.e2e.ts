// Render and layout: every fixture token × project × light/dark gets a clean
// battery, clean guards, and the right head. iPhone states also leave a
// full-page screenshot in the out dir for a person (or agent) to read.
import { decodeToken } from "../../src/shared/payload.ts";
import { FALLBACK_OG_IMAGE } from "../../src/shared/urls.ts";
import { expect, test } from "./fixtures.ts";
import { fixtureTokens } from "./tokens.ts";

// Names and expected failures are static; only the media origin (and so the
// tokens) differ per run, and those come from the manifest.
const FIXTURES = fixtureTokens("https://media.invalid");

for (const [name, { expectedFailures }] of Object.entries(FIXTURES)) {
  for (const colorScheme of ["light", "dark"] as const) {
    test.describe(`${name} (${colorScheme})`, () => {
      test.use({ colorScheme });

      test("lays out cleanly", async ({ page, share, battery, guards, snapshot }, testInfo) => {
        for (const failure of expectedFailures) guards.allow(failure);
        await page.goto(share.url(name));
        await page.waitForLoadState("networkidle");
        const { findings, measurements } = await battery();
        if (/^(iphone|desktop-webkit)/.test(testInfo.project.name)) await snapshot(`${name}-${colorScheme}`);
        expect(findings).toEqual([]);

        // The theme follows prefers-color-scheme.
        expect(measurements.colorScheme.prefersDark).toBe(colorScheme === "dark");
        const luminance = relativeLuminance(measurements.colorScheme.bodyBackgroundRGB);
        if (colorScheme === "dark") expect(luminance).toBeLessThan(0.1);
        else expect(luminance).toBeGreaterThan(0.8);
      });
    });
  }

  test(`${name}: head matches the token`, async ({ page, share, guards, baseURL }) => {
    for (const failure of expectedFailures) guards.allow(failure);
    const path = share.url(name);
    const token = path.slice("/e/".length);
    const payload = decodeToken(token)!;
    await page.goto(path);

    const meta = (selector: string) => page.locator(`head meta[${selector}]`).getAttribute("content");
    const canonical = `${baseURL}/e/${token}`;
    await expect(page).toHaveTitle(new RegExp(`^${escape(payload.title)}`));
    expect(await meta('property="og:title"')).toBe(payload.title);
    expect(await meta('name="twitter:title"')).toBe(payload.title);
    expect(await meta('property="og:description"')).toContain(payload.podcastTitle);
    expect(await meta('property="og:url"')).toBe(canonical);
    expect(await page.locator('head link[rel="canonical"]').getAttribute("href")).toBe(canonical);
    expect(await meta('property="og:audio"')).toBe(payload.audioURL);
    const image = payload.artworkURL || FALLBACK_OG_IMAGE;
    expect(await meta('property="og:image"')).toBe(image);
    expect(await meta('name="twitter:image"')).toBe(image);
    await expect(page.locator("h1")).toHaveText(payload.title);
  });
}

test("the page hydrates: a control responds after load", async ({ page, share, press }) => {
  await page.goto(share.url("happy"));
  const speed = page.getByRole("button", { name: /^Playback speed/ });
  await expect(speed).toHaveAttribute("aria-expanded", "false");
  await press(speed);
  await expect(speed).toHaveAttribute("aria-expanded", "true");
});

function escape(text: string) {
  return text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function relativeLuminance(rgb: number[]) {
  const [r, g, b] = rgb.map((c) => {
    const v = c / 255;
    return v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4;
  });
  return 0.2126 * r! + 0.7152 * g! + 0.0722 * b!;
}

for (const colorScheme of ["light", "dark"] as const) {
  test.describe(`404 page (${colorScheme})`, () => {
    test.use({ colorScheme });
    test("lays out cleanly", async ({ page, battery, guards, snapshot }, testInfo) => {
      guards.allow("/e/1AAAAAAAAAAAAAAAAAAAA");
      const response = await page.goto("/e/1AAAAAAAAAAAAAAAAAAAA");
      expect(response?.status()).toBe(404);
      await page.waitForLoadState("networkidle");
      const { findings } = await battery();
      if (testInfo.project.name.startsWith("iphone")) await snapshot(`not-found-${colorScheme}`);
      expect(findings).toEqual([]);
      await expect(page.locator("h1")).toBeVisible();
    });
  });
}

for (const colorScheme of ["light", "dark"] as const) {
  test.describe(`speed panel open (${colorScheme})`, () => {
    test.use({ colorScheme });
    test("lays out cleanly", async ({ page, share, press, battery, snapshot }, testInfo) => {
      await page.goto(share.url("happy", "t=25"));
      await page.waitForLoadState("networkidle");
      await press(page.getByRole("button", { name: /^Playback speed/ }));
      await expect(page.getByRole("group", { name: "Playback speed" })).toBeVisible();
      await page.waitForTimeout(450);
      const { findings } = await battery();
      if (/^(iphone|desktop-webkit)/.test(testInfo.project.name)) await snapshot(`speed-panel-${colorScheme}`);
      expect(findings).toEqual([]);
    });
  });
}

// Regressions found by the battery; each fails without its fix.
test.describe("regressions", () => {
  test("the artwork glow never lets the page pan sideways", async ({ page, share, battery, browserName, hasTouch }) => {
    await page.goto(share.url("happy"));
    await page.waitForLoadState("networkidle");
    const { measurements } = await battery();
    expect(measurements.overflow.documentScrollWidth).toBeLessThanOrEqual(measurements.viewport.width);
    if (browserName === "chromium" && hasTouch) {
      // body's clip hid the overflow from the layout viewport only; a mobile
      // browser still panned the visual viewport across it.
      const cdp = await page.context().newCDPSession(page);
      await cdp.send("Input.synthesizeScrollGesture", { x: 200, y: 300, xDistance: -300, yDistance: 0, gestureSourceType: "touch" });
      expect(await page.evaluate(() => visualViewport!.pageLeft)).toBe(0);
    }
  });

  test("quick taps on the controls are taps, not a double-tap zoom", async ({ page, share }) => {
    await page.goto(share.url("happy"));
    // No engine here emulates iOS's double-tap zoom; touch-action is what
    // Safari consults, on the control or any box above it.
    const unguarded = await page.evaluate(() =>
      [...document.querySelectorAll("main button, main a, main input, header a")]
        .filter((el) => {
          for (let a: Element | null = el; a; a = a.parentElement) {
            if (getComputedStyle(a).touchAction !== "auto") return false;
          }
          return true;
        })
        .map((el) => el.getAttribute("aria-label") ?? el.textContent?.trim()),
    );
    expect(unguarded).toEqual([]);
    expect(await page.evaluate(() => getComputedStyle(document.documentElement).touchAction)).toBe("manipulation");
  });

  test("the Play button sits on the column's centre line", async ({ page, share }) => {
    await page.goto(share.url("happy"));
    const offset = await page.evaluate(() => {
      // md: puts the controls in a left-aligned second column, by design.
      if (matchMedia("(min-width: 48rem)").matches) return null;
      const play = [...document.querySelectorAll("main button")].find((b) => /^(Play|Pause)$/.test(b.textContent?.trim() ?? ""))!;
      const column = document.querySelector("main h1")!.parentElement!.getBoundingClientRect();
      const r = play.getBoundingClientRect();
      return Math.round((r.left + r.width / 2 - (column.left + column.width / 2)) * 100) / 100;
    });
    test.skip(offset === null, "two-column layout");
    expect(Math.abs(offset!), `Play is ${offset}px off centre`).toBeLessThanOrEqual(1);
  });

  test("the transport sits on the Download and Share pills' grid", async ({ page, share }) => {
    await page.goto(share.url("happy"));
    const offsets = await page.evaluate(() => {
      // md: puts the controls in a left-aligned second column, by design.
      if (matchMedia("(min-width: 48rem)").matches) return null;
      const centre = (el: Element) => {
        const r = el.getBoundingClientRect();
        return r.left + r.width / 2;
      };
      const button = (name: RegExp) => [...document.querySelectorAll("main button, main a")].find((el) => name.test(el.textContent?.trim() ?? ""))!;
      const download = button(/^Download$/).getBoundingClientRect();
      const shareButton = button(/^(Share|Copy link)$/).getBoundingClientRect();
      const seam = (download.right + shareButton.left) / 2;
      const round = (n: number) => Math.round(n * 100) / 100;
      return {
        playOverSeam: round(centre(button(/^(Play|Pause)$/)) - seam),
        backOverDownload: round(centre(button(/Back 15 seconds$/)) - (download.left + download.width / 2)),
        forwardOverShare: round(centre(button(/Forward 30 seconds$/)) - (shareButton.left + shareButton.width / 2)),
        pillWidths: round(download.width - shareButton.width),
      };
    });
    test.skip(offsets === null, "two-column layout");
    for (const [name, px] of Object.entries(offsets!)) expect(Math.abs(px), `${name} is off by ${px}px`).toBeLessThanOrEqual(1);
  });

  test("an unbreakable title wraps inside the column", async ({ page, share }) => {
    await page.goto(share.url("unbreakable"));
    for (const text of [page.locator("main h1"), page.locator("main h1 + p")]) {
      const fits = await text.evaluate((el) => {
        const range = document.createRange();
        range.selectNodeContents(el);
        const r = range.getBoundingClientRect();
        return r.left >= 0 && r.right <= document.documentElement.clientWidth && el.scrollWidth <= el.clientWidth;
      });
      expect(fits, `${await text.evaluate((el) => el.tagName)} runs past the viewport`).toBe(true);
    }
  });
});
