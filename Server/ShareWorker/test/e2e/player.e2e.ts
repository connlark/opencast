// Player behaviour, driven the way a phone drives it: taps on touch projects,
// a real drag on the scrubber, and the audio element's own state read back
// through page.evaluate.
import type { Page } from "@playwright/test";
import { expect, test, type AudioState } from "./fixtures.ts";

const speedOption = (page: Page, rate: number) => page.getByRole("group", { name: "Playback speed" }).getByRole("button", { name: `${rate}×`, exact: true });

const controls = (page: Page) => ({
  play: page.getByRole("button", { name: /^(Play|Pause|Replay)$/ }),
  back: page.getByRole("button", { name: "Back 15 seconds" }),
  forward: page.getByRole("button", { name: "Forward 30 seconds" }),
  speed: page.getByRole("button", { name: /^Playback speed/ }),
  seek: page.getByRole("slider", { name: "Seek" }),
});

async function metadataLoaded(audio: () => Promise<AudioState>) {
  await expect.poll(async () => (await audio()).readyState, { message: "audio metadata never loaded" }).toBeGreaterThanOrEqual(1);
}

async function playing(audio: () => Promise<AudioState>, past = 0.3) {
  const start = (await audio()).currentTime;
  await expect
    .poll(async () => {
      const state = await audio();
      return !state.paused && state.currentTime > start + past;
    }, { message: "audio never advanced", timeout: 15_000 })
    .toBe(true);
}

test.describe("playback", () => {
  test("plays and pauses", async ({ page, share, press, audio }) => {
    await page.goto(share.url("happy"));
    const { play } = controls(page);
    await expect(play).toHaveAccessibleName("Play");
    await press(play);
    await playing(audio);
    await expect(play).toHaveAccessibleName("Pause");

    await press(play);
    await expect.poll(async () => (await audio()).paused).toBe(true);
    await expect(play).toHaveAccessibleName("Play");
    const stopped = (await audio()).currentTime;
    await page.waitForTimeout(600);
    expect((await audio()).currentTime).toBeCloseTo(stopped, 1);
  });

  test("skips forward 30 and back 15, clamped to the ends", async ({ page, share, press, audio }) => {
    await page.goto(share.url("happy"));
    await metadataLoaded(audio);
    const { back, forward, seek } = controls(page);

    await press(back);
    expect((await audio()).currentTime).toBe(0);
    await press(forward);
    await expect.poll(async () => (await audio()).currentTime).toBeCloseTo(30, 0);
    await expect(seek).toHaveAttribute("aria-valuetext", "0:30 of 1:00");
    await press(back);
    await expect.poll(async () => (await audio()).currentTime).toBeCloseTo(15, 0);
    await press(forward);
    await press(forward);
    // The synthesized file runs a few milliseconds past the token's 60 s.
    await expect.poll(async () => (await audio()).currentTime).toBeGreaterThan(55);
    const end = await audio();
    expect(end.currentTime).toBeLessThanOrEqual(end.duration);
  });

  test("seeks with the keyboard", async ({ page, share, audio }) => {
    await page.goto(share.url("happy"));
    await metadataLoaded(audio);
    const { seek } = controls(page);
    await seek.focus();
    for (let i = 0; i < 5; i += 1) await page.keyboard.press("ArrowRight");
    await expect.poll(async () => (await audio()).currentTime).toBeCloseTo(5, 0);
    await expect(seek).toHaveAttribute("aria-valuetext", "0:05 of 1:00");
    await page.keyboard.press("End");
    await expect.poll(async () => (await audio()).currentTime).toBeGreaterThan(55);
    await page.keyboard.press("Home");
    await expect.poll(async () => (await audio()).currentTime).toBe(0);
  });

  test("seeks by dragging the scrubber", async ({ page, share, audio, browserName, hasTouch }) => {
    await page.goto(share.url("happy"));
    await metadataLoaded(audio);
    const { seek } = controls(page);
    await seek.scrollIntoViewIfNeeded();
    const box = (await seek.boundingBox())!;
    const y = box.y + box.height / 2;
    const from = box.x + 4;
    const to = box.x + box.width / 2;
    if (browserName === "chromium" && hasTouch) {
      // Trusted touch events; Playwright's touchscreen only taps.
      const cdp = await page.context().newCDPSession(page);
      const touch = (type: "touchStart" | "touchMove" | "touchEnd", x: number) =>
        cdp.send("Input.dispatchTouchEvent", { type, touchPoints: type === "touchEnd" ? [] : [{ x, y }] });
      await touch("touchStart", from);
      for (let i = 1; i <= 10; i += 1) await touch("touchMove", from + ((to - from) * i) / 10);
      await touch("touchEnd", to);
    } else {
      // WebKit on macOS has no touch drag; a pointer drag is the closest trusted input.
      await page.mouse.move(from, y);
      await page.mouse.down();
      await page.mouse.move(to, y, { steps: 10 });
      await page.mouse.up();
    }
    await expect.poll(async () => (await audio()).currentTime).toBeGreaterThan(25);
    expect((await audio()).currentTime).toBeLessThan(35);
  });

  test("chooses a playback speed from the artwork panel", async ({ page, share, press, audio }) => {
    await page.goto(share.url("happy"));
    const { speed, play } = controls(page);
    await press(play);
    await playing(audio);
    await press(speed);
    await expect(speed).toHaveAttribute("aria-expanded", "true");
    for (const rate of [1.5, 2, 0.75, 1]) {
      const option = speedOption(page, rate);
      await press(option);
      await expect(option).toHaveAttribute("aria-pressed", "true");
      await expect.poll(async () => (await audio()).playbackRate).toBe(rate);
      await expect(speed).toHaveAttribute("aria-label", `Playback speed, ${rate}×`);
      // The header button shows the speed, or ⋯ at normal speed.
      await expect(speed).toHaveText(rate === 1 ? "" : `${rate}×`);
    }
    expect((await audio()).paused).toBe(false);
  });

  test("ends, then replays from the start", async ({ page, share, press, audio }) => {
    await page.goto(share.url("happy", "t=57"));
    const { play } = controls(page);
    await metadataLoaded(audio);
    await press(play);
    await expect.poll(async () => (await audio()).ended, { timeout: 15_000 }).toBe(true);
    await expect(play).not.toHaveAccessibleName("Pause");
    await press(play);
    await playing(audio, 0.2);
    expect((await audio()).currentTime).toBeLessThan(5);
  });
});

test.describe("start offset", () => {
  for (const [query, expected] of [
    ["t=30", 30],
    ["t=0", 0],
    ["t=1m", 0], // 60 s is past duration − 2: out of range
    ["t=999", 0],
    ["t=abc", 0],
    ["t=0h0m20s", 20],
  ] as const) {
    test(`?${query} starts at ${expected}`, async ({ page, share, press, audio }) => {
      await page.goto(share.url("happy", query));
      await metadataLoaded(audio);
      await expect.poll(async () => (await audio()).currentTime).toBeCloseTo(expected, 0);
      await expect(controls(page).seek).toHaveAttribute("aria-valuetext", `0:${String(expected).padStart(2, "0")} of 1:00`);
      await press(controls(page).play);
      await playing(audio);
      expect((await audio()).currentTime).toBeLessThan(expected + 5);
    });
  }

  test("a start past the real end of an episode with no duration does not start at the end", async ({ page, share, press, audio }) => {
    // The server accepts up to a day when the token has no duration; only the
    // audio itself knows the episode is 60 s long.
    await page.goto(share.url("no-duration", "t=120"));
    await metadataLoaded(audio);
    await press(controls(page).play);
    await playing(audio);
  });

  test("a skip before metadata wins over ?t=", async ({ page, share, press, audio }) => {
    // Headers arrive after 4 s; the skip lands relative to the linked 0:10.
    await page.goto(share.url("audio-slow", "t=10"));
    await press(controls(page).forward);
    await expect(controls(page).seek).toHaveAttribute("aria-valuetext", "0:40 of 1:00");
    await metadataLoaded(audio);
    await page.waitForTimeout(300);
    await expect.poll(async () => (await audio()).currentTime).toBeCloseTo(40, 0);
  });
});

test.describe("resume", () => {
  test("resumes where the listener paused, across a reload", async ({ page, share, press, audio }) => {
    await page.goto(share.url("happy"));
    await metadataLoaded(audio);
    const { play, forward } = controls(page);
    await press(forward);
    await press(play);
    await playing(audio, 2.5);
    await press(play);
    await expect.poll(async () => (await audio()).paused).toBe(true);
    const left = (await audio()).currentTime;
    expect(left).toBeGreaterThan(32.5);

    await page.reload();
    await metadataLoaded(audio);
    // Saved in whole seconds: never later than the pause, never a second earlier.
    await expect.poll(async () => (await audio()).currentTime).toBeGreaterThan(left - 1);
    expect((await audio()).currentTime).toBeLessThanOrEqual(left);
    expect(await page.evaluate(() => Object.keys(localStorage).length)).toBe(1);
  });

  test("the saved position is written when the page is hidden", async ({ page, context, share, press, audio }) => {
    await page.goto(share.url("happy"));
    await metadataLoaded(audio);
    await press(controls(page).forward);
    await press(controls(page).play);
    await playing(audio, 1);
    // Backgrounding: the tab is hidden but not unloaded, and may never come back.
    await page.evaluate(() => {
      Object.defineProperty(document, "visibilityState", { value: "hidden", configurable: true });
      Object.defineProperty(document, "hidden", { value: true, configurable: true });
      document.dispatchEvent(new Event("visibilitychange"));
    });
    const hiddenAt = (await audio()).currentTime;

    const second = await context.newPage();
    await second.goto(share.url("happy"));
    const resumed = await second.locator("audio").evaluate(async (a: HTMLAudioElement) => {
      if (a.readyState < 1) await new Promise((resolve) => a.addEventListener("loadedmetadata", resolve, { once: true }));
      await new Promise((resolve) => setTimeout(resolve, 300));
      return a.currentTime;
    });
    expect(resumed).toBeGreaterThan(hiddenAt - 1);
    expect(resumed).toBeLessThanOrEqual(hiddenAt + 0.5);
  });

  test("?t= and the saved position: the link's time wins on a fresh visit", async ({ page, share, press, audio }) => {
    await page.goto(share.url("happy"));
    await metadataLoaded(audio);
    await press(controls(page).forward);
    await press(controls(page).play);
    await playing(audio);
    await press(controls(page).play);

    await page.goto(share.url("happy", "t=10"));
    await metadataLoaded(audio);
    await expect.poll(async () => (await audio()).currentTime).toBeCloseTo(10, 0);
  });
});

test.describe("edge behaviour", () => {
  test("a finished episode does not resume at its end", async ({ page, share, press, audio }) => {
    await page.goto(share.url("happy", "t=57"));
    await metadataLoaded(audio);
    await press(controls(page).play);
    await expect.poll(async () => (await audio()).ended, { timeout: 15_000 }).toBe(true);
    await page.goto(share.url("happy"));
    await metadataLoaded(audio);
    await page.waitForTimeout(300);
    expect((await audio()).currentTime).toBeLessThan(55);
    await press(controls(page).play);
    await playing(audio);
  });

  test("dragging while playing holds the thumb under the finger, then commits", async ({ page, share, press, audio, browserName, hasTouch }) => {
    await page.goto(share.url("happy"));
    await press(controls(page).play);
    await playing(audio);
    const { seek } = controls(page);
    await seek.scrollIntoViewIfNeeded();
    const box = (await seek.boundingBox())!;
    const y = box.y + box.height / 2;
    const from = box.x + 6;
    const to = box.x + box.width / 2;
    const cdp = browserName === "chromium" && hasTouch ? await page.context().newCDPSession(page) : null;
    const touch = (type: "touchStart" | "touchMove" | "touchEnd", x: number) =>
      cdp!.send("Input.dispatchTouchEvent", { type, touchPoints: type === "touchEnd" ? [] : [{ x, y }] });
    if (cdp) {
      await touch("touchStart", from);
      for (let i = 1; i <= 10; i += 1) await touch("touchMove", from + ((to - from) * i) / 10);
    } else {
      await page.mouse.move(from, y);
      await page.mouse.down();
      await page.mouse.move(to, y, { steps: 10 });
    }
    // Several timeupdates arrive while the finger rests mid-track.
    const held: number[] = [];
    for (let i = 0; i < 5; i += 1) {
      await page.waitForTimeout(250);
      held.push(Number(await seek.inputValue()));
    }
    if (cdp) await touch("touchEnd", to);
    else await page.mouse.up();
    expect(Math.min(...held), `thumb snapped back while held: ${held.join(", ")}`).toBeGreaterThan(25);
    await expect.poll(async () => (await audio()).currentTime).toBeGreaterThan(25);
    expect((await audio()).paused).toBe(false);
  });

  test("a drag the browser cancels does not freeze the scrubber", async ({ page, share, press, audio, browserName, hasTouch }) => {
    await page.goto(share.url("happy"));
    await press(controls(page).play);
    await playing(audio);
    const { seek } = controls(page);
    await seek.scrollIntoViewIfNeeded();
    const box = (await seek.boundingBox())!;
    const y = box.y + box.height / 2;
    const at = (i: number) => box.x + 6 + i * 20;
    // A scroll or system gesture takes the touch away mid-drag: pointercancel,
    // then no pointerup and no change.
    if (browserName === "chromium" && hasTouch) {
      const cdp = await page.context().newCDPSession(page);
      await cdp.send("Input.dispatchTouchEvent", { type: "touchStart", touchPoints: [{ x: at(0), y }] });
      for (let i = 1; i <= 5; i += 1) await cdp.send("Input.dispatchTouchEvent", { type: "touchMove", touchPoints: [{ x: at(i), y }] });
      await cdp.send("Input.dispatchTouchEvent", { type: "touchCancel", touchPoints: [] });
    } else {
      // No trusted touch here: a real pointer drag, then the cancel the
      // browser would send, dispatched by hand. The button stays down.
      await page.mouse.move(at(0), y);
      await page.mouse.down();
      await page.mouse.move(at(5), y, { steps: 5 });
      await seek.dispatchEvent("pointercancel", { pointerId: 1, pointerType: "touch", isPrimary: true });
    }
    await page.waitForTimeout(2_500);
    const now = (await audio()).currentTime;
    expect(Math.abs(Number(await seek.inputValue()) - now), "the thumb stopped following playback").toBeLessThan(2);
  });

  test("a speed chosen before the audio loads sticks", async ({ page, share, press, audio }) => {
    await page.goto(share.url("audio-slow"));
    const { speed, play } = controls(page);
    await press(speed);
    await press(speedOption(page, 1.25));
    await press(play);
    await playing(audio);
    expect((await audio()).playbackRate).toBe(1.25);
    await expect(speed).toHaveAttribute("aria-label", "Playback speed, 1.25×");
  });

  test("play then pause before the audio starts leaves no error and a paused player", async ({ page, share, press, audio }) => {
    await page.goto(share.url("audio-slow"));
    const { play } = controls(page);
    await press(play);
    await press(play);
    await page.waitForTimeout(5_000);
    expect((await audio()).paused).toBe(true);
    await expect(play).toHaveAccessibleName("Play");
  });

  test("after leaving and coming back, the controls match the audio", async ({ page, share, press, audio }) => {
    await page.goto(share.url("happy"));
    await press(controls(page).play);
    await playing(audio);
    await page.goto(share.url("scripts"));
    await page.goBack();
    await page.waitForTimeout(500);
    const state = await audio();
    await expect(controls(page).play).toHaveAccessibleName(state.paused ? "Play" : "Pause");
    await press(controls(page).play);
    await expect.poll(async () => (await audio()).paused).toBe(!state.paused);
  });

  for (const name of ["huge-duration", "no-duration"]) {
    test(`${name}: the scrubber follows the real length once the audio knows it`, async ({ page, share, audio }) => {
      await page.goto(share.url(name));
      await metadataLoaded(audio);
      const { seek } = controls(page);
      await expect(seek).toHaveAttribute("aria-valuetext", "0:00 of 1:00");
      expect(Number(await seek.getAttribute("max"))).toBeCloseTo((await audio()).duration, 0);
      await expect(page.getByText("-1:00", { exact: true })).toBeVisible();
    });
  }

  test("seeks deep into a three-hour episode and keeps playing", async ({ page, share, press, audio }) => {
    await page.goto(share.url("long-audio", "t=7200"));
    await metadataLoaded(audio);
    await expect.poll(async () => (await audio()).currentTime).toBeCloseTo(7200, 0);
    await expect(controls(page).seek).toHaveAttribute("aria-valuetext", "2:00:00 of 3:00:00");
    await press(controls(page).play);
    await playing(audio);
  });

  test("an http enclosure plays over https", async ({ page, share, press, audio }) => {
    const token = share.mint({ ...share.fields("happy"), audioURL: `${share.media.http}/audio/60.mp3` });
    await page.goto(`/e/${token}`);
    await press(controls(page).play);
    await playing(audio);
    expect((await audio()).src).toMatch(/^https:/);
  });

  test("Media Session actions drive the player", async ({ page, share, press, audio }) => {
    await page.addInitScript(() => {
      const w = window as unknown as { __handlers: Record<string, MediaSessionActionHandler> };
      w.__handlers = {};
      if (!("mediaSession" in navigator)) return;
      const setActionHandler = navigator.mediaSession.setActionHandler.bind(navigator.mediaSession);
      navigator.mediaSession.setActionHandler = (action, handler) => {
        if (handler) w.__handlers[action] = handler;
        else delete w.__handlers[action];
        try {
          setActionHandler(action, handler);
        } catch {}
      };
    });
    await page.goto(share.url("happy"));
    test.skip(!(await page.evaluate(() => "mediaSession" in navigator)), "no Media Session in this engine");
    await press(controls(page).play);
    await playing(audio);
    const act = (action: MediaSessionAction, details: Partial<MediaSessionActionDetails> = {}) =>
      page.evaluate(
        ([action, details]) =>
          (window as unknown as { __handlers: Record<string, MediaSessionActionHandler> }).__handlers[action]!({ action, ...details }),
        [action, details] as const,
      );

    await act("pause");
    await expect.poll(async () => (await audio()).paused).toBe(true);
    await expect(controls(page).play).toHaveAccessibleName("Play");
    await act("seekto", { seekTime: 20 });
    await expect.poll(async () => (await audio()).currentTime).toBeCloseTo(20, 0);
    await expect(controls(page).seek).toHaveAttribute("aria-valuetext", "0:20 of 1:00");
    await act("seekforward");
    await expect.poll(async () => (await audio()).currentTime).toBeCloseTo(50, 0);
    await act("seekbackward");
    await expect.poll(async () => (await audio()).currentTime).toBeCloseTo(35, 0);
    await act("play");
    await playing(audio);
    await expect(controls(page).play).toHaveAccessibleName("Pause");
  });
});

test.describe("speed panel", () => {
  const panel = (page: Page) => page.getByRole("group", { name: "Playback speed" });
  const stage = (page: Page) => page.locator(".art-stage");
  const isOpen = async (page: Page) =>
    page.evaluate(() => {
      const group = document.getElementById("speed-panel")!;
      return !group.inert && Number(getComputedStyle(group).opacity) > 0.99;
    });

  async function swipe(page: Page, from: number, to: number, y: number, touch: boolean) {
    if (touch) {
      const cdp = await page.context().newCDPSession(page);
      await cdp.send("Input.dispatchTouchEvent", { type: "touchStart", touchPoints: [{ x: from, y }] });
      for (let i = 1; i <= 8; i += 1) {
        await cdp.send("Input.dispatchTouchEvent", { type: "touchMove", touchPoints: [{ x: from + ((to - from) * i) / 8, y }] });
      }
      await cdp.send("Input.dispatchTouchEvent", { type: "touchEnd", touchPoints: [] });
    } else {
      await page.mouse.move(from, y);
      await page.mouse.down();
      await page.mouse.move(to, y, { steps: 8 });
      await page.mouse.up();
    }
  }

  test("is closed and out of the tab order until asked for", async ({ page, share }) => {
    await page.goto(share.url("happy"));
    expect(await isOpen(page)).toBe(false);
    // inert: nothing inside can take focus (Playwright's role queries ignore inert).
    const focusable = await page.evaluate(() => {
      const option = document.querySelector<HTMLButtonElement>("#speed-panel button")!;
      option.focus();
      return document.activeElement === option;
    });
    expect(focusable).toBe(false);
    await expect(panel(page).getByRole("button")).toHaveCount(6);
  });

  test("tapping the artwork opens it; tapping the art's edge closes it", async ({ page, share, press, hasTouch }) => {
    await page.goto(share.url("happy"));
    await press(stage(page));
    await expect.poll(() => isOpen(page)).toBe(true);
    await expect(controls(page).speed).toHaveAttribute("aria-expanded", "true");
    // A tap on a speed keeps it open (as in the app); the rail closes it.
    await press(speedOption(page, 1.25));
    expect(await isOpen(page)).toBe(true);
    const box = (await stage(page).boundingBox())!;
    const [x, y] = [box.x + 16, box.y + box.height / 2];
    if (hasTouch) await page.touchscreen.tap(x, y);
    else await page.mouse.click(x, y);
    await expect.poll(() => isOpen(page)).toBe(false);
    await expect(controls(page).speed).toHaveAttribute("aria-expanded", "false");
  });

  test("a swipe left opens it and a swipe right closes it", async ({ page, share, browserName, hasTouch }) => {
    await page.goto(share.url("happy"));
    await stage(page).scrollIntoViewIfNeeded();
    const box = (await stage(page).boundingBox())!;
    const y = box.y + box.height / 2;
    const touch = browserName === "chromium" && hasTouch;
    await swipe(page, box.x + box.width * 0.85, box.x + box.width * 0.25, y, touch);
    await expect.poll(() => isOpen(page)).toBe(true);
    await swipe(page, box.x + box.width * 0.3, box.x + box.width * 0.95, y, touch);
    await expect.poll(() => isOpen(page)).toBe(false);
  });

  test("after a swipe opens it, the first tap on the art's edge closes it", async ({ page, share, browserName, hasTouch }) => {
    await page.goto(share.url("happy"));
    await stage(page).scrollIntoViewIfNeeded();
    const box = (await stage(page).boundingBox())!;
    const y = box.y + box.height / 2;
    await swipe(page, box.x + box.width * 0.85, box.x + box.width * 0.25, y, browserName === "chromium" && hasTouch);
    await expect.poll(() => isOpen(page)).toBe(true);
    if (hasTouch) await page.touchscreen.tap(box.x + 16, y);
    else await page.mouse.click(box.x + 16, y);
    await expect.poll(() => isOpen(page)).toBe(false);
  });

  test("a vertical drag on the artwork is left to the page", async ({ page, share, browserName, hasTouch }) => {
    test.skip(!(browserName === "chromium" && hasTouch), "needs trusted touch input (CDP)");
    await page.goto(share.url("happy"));
    const box = (await stage(page).boundingBox())!;
    const x = box.x + box.width / 2;
    const cdp = await page.context().newCDPSession(page);
    await cdp.send("Input.dispatchTouchEvent", { type: "touchStart", touchPoints: [{ x, y: box.y + box.height * 0.8 }] });
    for (let i = 1; i <= 8; i += 1) {
      await cdp.send("Input.dispatchTouchEvent", { type: "touchMove", touchPoints: [{ x: x - i * 3, y: box.y + box.height * (0.8 - i * 0.07) }] });
    }
    await cdp.send("Input.dispatchTouchEvent", { type: "touchEnd", touchPoints: [] });
    await page.waitForTimeout(400);
    expect(await isOpen(page)).toBe(false);
  });

  test("Escape closes it and hands focus back to the speed button", async ({ page, share, isMobile }, testInfo) => {
    test.skip(isMobile || testInfo.project.name.startsWith("iphone"), "keyboard is a desktop concern");
    await page.goto(share.url("happy"));
    const { speed } = controls(page);
    await speed.focus();
    await page.keyboard.press("Enter");
    await expect.poll(() => isOpen(page)).toBe(true);
    await speedOption(page, 0.75).focus();
    await page.keyboard.press("Enter");
    await expect(speed).toHaveAttribute("aria-label", "Playback speed, 0.75×");
    await page.keyboard.press("Escape");
    await expect.poll(() => isOpen(page)).toBe(false);
    await expect(speed).toBeFocused();
  });
});

test.describe("more races and refusals", () => {
  test("Play before the audio loads starts at ?t=, not at 0:00", async ({ page, share, press, audio }) => {
    await page.addInitScript(() => {
      const w = window as unknown as { __times: number[] };
      w.__times = [];
      // Media events do not bubble; a capturing listener still sees them.
      document.addEventListener("timeupdate", (event) => w.__times.push((event.target as HTMLAudioElement).currentTime), true);
    });
    await page.goto(share.url("audio-slow", "t=20"));
    await press(controls(page).play);
    await expect.poll(async () => (await audio()).currentTime, { timeout: 15_000 }).toBeGreaterThan(20.5);
    const times = await page.evaluate(() => (window as unknown as { __times: number[] }).__times);
    expect(times.filter((t) => t > 0.25 && t < 19.5), "heard the start before jumping to ?t=").toEqual([]);
  });

  test("a skip before metadata wins over the saved position", async ({ page, share, press, audio }) => {
    await page.goto(share.url("audio-slow"));
    await press(controls(page).play);
    await playing(audio, 1);
    await press(controls(page).play);
    await page.goto("about:blank");
    await page.goto(share.url("audio-slow"));
    const saved = await page.evaluate(() => Object.values(localStorage)[0]);
    expect(saved, "a position was saved").toBeTruthy();
    await press(controls(page).forward);
    await metadataLoaded(audio);
    await page.waitForTimeout(300);
    await expect.poll(async () => (await audio()).currentTime).toBeGreaterThan(29);
  });

  test("the player works when storage is blocked", async ({ page, share, press, audio }) => {
    // Chrome with site data blocked throws on the localStorage getter itself.
    await page.addInitScript(() => {
      Object.defineProperty(window, "localStorage", {
        configurable: true,
        get() {
          throw new DOMException("The operation is insecure.", "SecurityError");
        },
      });
    });
    await page.goto(share.url("happy", "t=10"));
    await metadataLoaded(audio);
    await expect.poll(async () => (await audio()).currentTime).toBeCloseTo(10, 0);
    await press(controls(page).play);
    await playing(audio);
    await press(controls(page).forward);
    await press(controls(page).play);
    await expect.poll(async () => (await audio()).paused).toBe(true);
  });

  test("cancelling the share sheet is not an error and copies nothing", async ({ page, share, press }) => {
    await page.addInitScript(() => {
      const w = window as unknown as { __copied: string[] };
      w.__copied = [];
      Object.defineProperty(navigator, "share", {
        configurable: true,
        value: async () => {
          throw new DOMException("Share canceled", "AbortError");
        },
      });
      Object.defineProperty(navigator, "clipboard", {
        configurable: true,
        value: { writeText: async (text: string) => void w.__copied.push(text) },
      });
    });
    await page.goto(share.url("happy"));
    await press(page.getByRole("button", { name: "Share" }));
    await page.waitForTimeout(500);
    await expect(page.getByText("Copied")).toHaveCount(0);
    expect(await page.evaluate(() => (window as unknown as { __copied: string[] }).__copied)).toEqual([]);
  });

  test("Download saves the enclosure under the episode's name", async ({ page, share, press, browserName, isMobile }) => {
    test.skip(browserName === "chromium" && isMobile, "Android Chrome downloads are not emulated");
    const token = share.mint({ ...share.fields("happy"), audioURL: `${share.media.http}/audio/10.mp3`, durationSeconds: 10 });
    await page.goto(`/e/${token}`);
    const [download] = await Promise.all([page.waitForEvent("download"), press(page.getByRole("link", { name: "Download" }))]);
    expect(download.suggestedFilename()).toBe("The Example Almanac - Rubber Duck, Final Witness.mp3");
    expect(await download.failure()).toBeNull();
  });
});

test.describe("keyboard", () => {
  test("every control shows a focus ring", async ({ page, share, isMobile, browserName }, testInfo) => {
    test.skip(isMobile || testInfo.project.name.startsWith("iphone"), "keyboard focus is a desktop concern");
    await page.goto(share.url("happy"));
    const seen = new Map<string, { outline: string; width: number }>();
    for (let i = 0; i < 20; i += 1) {
      // Safari moves focus through every control only with Option-Tab.
      await page.keyboard.press(browserName === "webkit" ? "Alt+Tab" : "Tab");
      const focused = await page.evaluate(() => {
        const el = document.activeElement;
        if (!el || el === document.body) return null;
        const cs = getComputedStyle(el);
        return {
          name: `${el.tagName.toLowerCase()} ${el.getAttribute("aria-label") ?? (el.textContent ?? "").trim().slice(0, 30)}`,
          outline: cs.outlineStyle,
          width: parseFloat(cs.outlineWidth),
        };
      });
      if (!focused || seen.has(focused.name)) break;
      seen.set(focused.name, focused);
    }
    expect(seen.size).toBeGreaterThan(4);
    const invisible = [...seen].filter(([, f]) => f.outline === "none" || f.width === 0).map(([name]) => name);
    expect(invisible, "focused with no outline").toEqual([]);
  });
});

test.describe("failure states", () => {
  test("an audio 404 shows an error and the download fallback, not a dead control", async ({ page, share, press, guards }) => {
    guards.allow("/audio/missing.mp3");
    await page.goto(share.url("audio-404"));
    await press(controls(page).play);
    await expect(page.getByText("This audio could not be loaded")).toBeVisible();
    // The error adds a prominent Download next to the regular one.
    await expect(page.getByRole("link", { name: /Download/ })).toHaveCount(2);
    for (const link of await page.getByRole("link", { name: /Download/ }).all()) await expect(link).toBeVisible();
  });

  test("a slow host shows loading, then plays", async ({ page, share, press, audio }) => {
    await page.goto(share.url("audio-slow"));
    const { play } = controls(page);
    await press(play);
    // Something on the page has to say it is working on it.
    await expect(page.locator('[aria-busy="true"], .animate-spin').first()).toBeVisible({ timeout: 3_000 });
    await playing(audio);
    await expect(page.locator('[aria-busy="true"], .animate-spin')).toHaveCount(0);
  });
});

test.describe("platform integration", () => {
  test("sets Media Session metadata and action handlers", async ({ page, share, press, audio }) => {
    await page.addInitScript(() => {
      const w = window as unknown as { __actions: string[]; __positions: unknown[] };
      w.__actions = [];
      w.__positions = [];
      if (!("mediaSession" in navigator)) return;
      const setActionHandler = navigator.mediaSession.setActionHandler.bind(navigator.mediaSession);
      navigator.mediaSession.setActionHandler = (action, handler) => {
        if (handler) w.__actions.push(action);
        try {
          setActionHandler(action, handler);
        } catch {}
      };
      const setPositionState = navigator.mediaSession.setPositionState?.bind(navigator.mediaSession);
      navigator.mediaSession.setPositionState = (state) => {
        w.__positions.push(state);
        setPositionState?.(state);
      };
    });
    await page.goto(share.url("happy"));
    const hasMediaSession = await page.evaluate(() => "mediaSession" in navigator);
    test.skip(!hasMediaSession, "no Media Session in this engine");
    await press(controls(page).play);
    await playing(audio);

    const session = await page.evaluate(() => {
      const metadata = navigator.mediaSession.metadata;
      const w = window as unknown as { __actions: string[]; __positions: { duration: number }[] };
      return {
        title: metadata?.title,
        artist: metadata?.artist,
        artwork: metadata?.artwork.map((a) => a.src) ?? [],
        playbackState: navigator.mediaSession.playbackState,
        actions: [...new Set(w.__actions)].sort(),
        lastPosition: w.__positions.at(-1),
      };
    });
    const fields = share.fields("happy");
    expect(session.title).toBe(fields.title);
    expect(session.artist).toBe(fields.podcastTitle);
    expect(session.artwork).toContain(fields.artworkURL);
    expect(session.actions).toEqual(expect.arrayContaining(["pause", "play", "seekbackward", "seekforward", "seekto"]));
    expect(session.lastPosition?.duration).toBeCloseTo(60, 1);
  });

  test("Share hands the link to the Web Share API", async ({ page, share, press, baseURL }) => {
    await page.addInitScript(() => {
      const w = window as unknown as { __shared: ShareData[] };
      w.__shared = [];
      Object.defineProperty(navigator, "share", {
        configurable: true,
        value: async (data: ShareData) => {
          w.__shared.push(data);
        },
      });
    });
    const path = share.url("happy");
    await page.goto(path);
    await press(page.getByRole("button", { name: "Share" }));
    const shared = await page.evaluate(() => (window as unknown as { __shared: ShareData[] }).__shared);
    expect(shared).toHaveLength(1);
    expect(shared[0]!.url?.startsWith(`${baseURL}${path}`)).toBe(true);
  });

  test("without Web Share, Share copies the link", async ({ page, share, press, baseURL }) => {
    await page.addInitScript(() => {
      const w = window as unknown as { __copied: string[] };
      w.__copied = [];
      Object.defineProperty(navigator, "share", { configurable: true, value: undefined });
      Object.defineProperty(navigator, "clipboard", {
        configurable: true,
        value: { writeText: async (text: string) => void w.__copied.push(text) },
      });
    });
    const path = share.url("happy");
    await page.goto(path);
    const button = page.getByRole("button", { name: "Copy link" });
    await press(button);
    await expect(page.getByText("Copied")).toBeVisible();
    const copied = await page.evaluate(() => (window as unknown as { __copied: string[] }).__copied);
    expect(copied).toHaveLength(1);
    expect(copied[0]!.startsWith(`${baseURL}${path}`)).toBe(true);
  });
});

test.describe("constrained clients", () => {
  test.describe("without JavaScript", () => {
    test.use({ javaScriptEnabled: false });
    test("still shows the episode, a way to listen, and the app link", async ({ page, share, snapshot }) => {
      await page.goto(share.url("happy"));
      await expect(page.locator("h1")).toHaveText(share.fields("happy").title as string);
      await expect(page.locator("main img")).toBeVisible();
      await expect(page.getByRole("link", { name: /Download/ })).toHaveAttribute("href", /\/download$/);
      await expect(page.getByRole("link", { name: "opencast" }).first()).toBeVisible();
      // A Play button that cannot play is worse than none: the controls that
      // need the client are gone, and the browser's own player stands in.
      for (const name of [/^Play$/, /^Playback speed/, /^Back 15/, /^Forward 30/, /^Share$/]) {
        await expect(page.getByRole("button", { name })).toHaveCount(0);
      }
      await expect(page.getByRole("slider", { name: "Seek" })).toHaveCount(0);
      const native = page.locator("audio[controls]");
      await expect(native).toBeVisible();
      await expect(native).toHaveAttribute("src", share.fields("happy").audioURL as string);
      await snapshot("no-script");
    });
  });

  test.describe("with reduced motion", () => {
    test.use({ reducedMotion: "reduce" });
    test("nothing animates indefinitely, and playback still works", async ({ page, share, press, audio }) => {
      await page.goto(share.url("audio-slow"));
      await press(controls(page).play);
      await page.waitForTimeout(500);
      const infinite = await page.evaluate(() =>
        document
          .getAnimations()
          .filter((animation) => animation.playState === "running" && animation.effect?.getTiming().iterations === Infinity)
          .map((animation) => (animation as CSSAnimation).animationName ?? "unknown"),
      );
      expect(infinite).toEqual([]);
      await playing(audio);
    });
  });
});
