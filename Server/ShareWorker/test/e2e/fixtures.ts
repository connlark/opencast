// Shared test fixtures. Every test that opens a page is guarded: a CSP
// violation, an uncaught error, a console error or warning, a failed request
// or a ≥400 response fails it, unless the test (or its token fixture) names
// the URL as an expected failure.
import { readFileSync } from "node:fs";
import path from "node:path";
import { test as base, expect, type Locator } from "@playwright/test";
import { SITE_ORIGIN } from "../../src/shared/urls.ts";
import { judge, measure, type Finding, type Measurements } from "./battery.ts";
import { MANIFEST_PATH, SCREENSHOT_DIR } from "./env.ts";
import type { Manifest } from "./global-setup.ts";
import { TINY_PNG } from "./media-server.ts";
import { mint, type Fields } from "./tokens.ts";

export { expect };

export interface AudioState {
  currentTime: number;
  duration: number;
  paused: boolean;
  ended: boolean;
  readyState: number;
  networkState: number;
  playbackRate: number;
  error: number | null;
  src: string;
}

interface Problem {
  kind: string;
  text: string;
  url: string;
}

export interface Guards {
  problems: Problem[];
  allowed: string[];
  /** Tolerate failures whose URL or text contains this substring. */
  allow(substring: string): void;
}

interface Fixtures {
  guards: Guards;
  share: {
    /** URL of a named fixture token, optionally with a query string (`t=30`). */
    url(name: string, query?: string): string;
    /** Mints a bespoke token against the media host. */
    mint(fields: Fields): string;
    media: Manifest["media"];
    fields(name: string): Fields;
  };
  /** Taps on touch projects, clicks elsewhere. */
  press(locator: Locator): Promise<void>;
  audio(): Promise<AudioState>;
  battery(): Promise<{ findings: Finding[]; measurements: Measurements }>;
  snapshot(name: string): Promise<void>;
}

export const test = base.extend<Fixtures, { manifest: Manifest }>({
  manifest: [
    async ({}, use) => use(JSON.parse(readFileSync(process.env.SHARE_E2E_MANIFEST ?? MANIFEST_PATH, "utf8"))),
    { scope: "worker" },
  ],

  guards: async ({}, use) => {
    const allowed: string[] = [];
    await use({ problems: [], allowed, allow: (substring) => allowed.push(substring) });
  },

  // Guarded here rather than in an auto fixture so request-only tests never
  // launch a browser.
  page: async ({ page, guards }, use, testInfo) => {
    // The brand icons come from the marketing site; keep the run hermetic.
    await page.route(`${SITE_ORIGIN}/**`, (route) =>
      route.request().resourceType() === "image"
        ? route.fulfill({ status: 200, contentType: "image/png", body: TINY_PNG })
        : route.abort(),
    );

    const { problems } = guards;
    let cancelled = 0;
    // CSP reports reach the test through a binding, which survives reloads.
    await page.exposeBinding("__reportCSP", (_source, v: { directive: string; blocked: string; sample: string }) => {
      problems.push({ kind: "csp-violation", text: `${v.directive} refused ${v.blocked} ${v.sample}`.trim(), url: v.blocked });
    });
    await page.addInitScript(() => {
      document.addEventListener("securitypolicyviolation", (event) => {
        (window as unknown as { __reportCSP(v: unknown): void }).__reportCSP({
          directive: event.effectiveDirective,
          blocked: event.blockedURI,
          sample: event.sample,
        });
      });
    });
    page.on("pageerror", (error) => problems.push({ kind: "page-error", text: String(error.stack ?? error), url: page.url() }));
    page.on("console", (message) => {
      if (message.type() === "error" || message.type() === "warning") {
        problems.push({ kind: `console-${message.type()}`, text: message.text(), url: message.location().url });
      }
    });
    page.on("requestfailed", async (request) => {
      const failure = request.failure()?.errorText ?? "";
      // Media elements cancel their own range requests once they have the
      // metadata, and as they seek; that is the element working. WebKit does
      // not label these "media", so the Range header identifies them.
      const headers: Record<string, string> = await request.allHeaders().catch(() => ({}));
      const media = request.resourceType() === "media" || headers.range !== undefined;
      if (media && /cancel|abort/i.test(failure)) {
        cancelled += 1;
        return;
      }
      problems.push({ kind: "request-failed", text: `${request.resourceType()}: ${failure}`, url: request.url() });
    });
    page.on("response", (response) => {
      if (response.status() >= 400) {
        problems.push({ kind: "bad-response", text: String(response.status()), url: response.url() });
      }
    });

    await use(page);

    const unexpected = problems.filter(
      (problem) => !guards.allowed.some((substring) => problem.url.includes(substring) || problem.text.includes(substring)),
    );
    await testInfo.attach("guards.json", {
      body: JSON.stringify({ unexpected, allowed: guards.allowed, all: problems, cancelledMediaRequests: cancelled }, null, 2),
      contentType: "application/json",
    });
    expect(unexpected, "CSP violations, page errors, console errors/warnings, failed requests").toEqual([]);
  },

  share: async ({ manifest }, use) => {
    const named = (name: string) => {
      const entry = manifest.tokens[name];
      if (!entry) throw new Error(`no fixture token named ${name}`);
      return entry;
    };
    await use({
      url: (name, query) => `/e/${named(name).token}${query ? `?${query}` : ""}`,
      mint,
      media: manifest.media,
      fields: (name) => named(name).fields,
    });
  },

  press: async ({ hasTouch }, use) => {
    await use((locator) => (hasTouch ? locator.tap() : locator.click()));
  },

  audio: async ({ page }, use) => {
    await use(() =>
      page.locator("audio").evaluate((a: HTMLAudioElement) => ({
        currentTime: a.currentTime,
        duration: a.duration,
        paused: a.paused,
        ended: a.ended,
        readyState: a.readyState,
        networkState: a.networkState,
        playbackRate: a.playbackRate,
        error: a.error?.code ?? null,
        src: a.currentSrc || a.src,
      })),
    );
  },

  battery: async ({ page }, use, testInfo) => {
    await use(async () => {
      const measurements = await page.evaluate(measure);
      const findings = judge(measurements);
      await testInfo.attach("battery.json", {
        body: JSON.stringify({ findings, measurements }, null, 2),
        contentType: "application/json",
      });
      return { findings, measurements };
    });
  },

  snapshot: async ({ page }, use, testInfo) => {
    await use(async (name) => {
      const file = path.join(SCREENSHOT_DIR, `${testInfo.project.name}--${name}.png`);
      // Playwright sizes a full-page capture by body's scroll width too, which
      // includes what body clips; crop to what the reader can actually see.
      const size = await page.evaluate(() => ({
        width: document.documentElement.clientWidth,
        height: document.documentElement.scrollHeight,
      }));
      await page.screenshot({ path: file, fullPage: true, clip: { x: 0, y: 0, ...size }, animations: "disabled" });
    });
  },
});
