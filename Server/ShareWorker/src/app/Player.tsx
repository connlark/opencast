import { useCallback, useEffect, useRef, useState } from "react";
import type { SharePayload } from "../shared/payload.ts";
import { formatClock } from "../shared/start.ts";
import { cssURL, downloadPath, playableAudioURL } from "../shared/urls.ts";
import { ArtworkStage } from "./ArtworkStage.tsx";
import { BrandMark } from "./Brand.tsx";
import { Icon } from "./Icon.tsx";

/** Serialized into the page's #__share script and hydrated inside <main id="app">. */
export interface PlayerProps {
  payload: SharePayload;
  token: string;
  start: number;
  canonical: string;
}

const SPEED_PANEL_ID = "speed-panel";
const BACK_SECONDS = 15;
const FORWARD_SECONDS = 30;
const HAVE_METADATA = 1;

type AudioNotice = "failed" | "blocked" | null;
type ShareNotice = "copied" | "copy-failed" | null;

/**
 * The one isomorphic component: server-rendered by the worker, then hydrated
 * with the same props. Anything that differs between server and browser (the
 * Web Share fallback label, a resume position) changes only in an effect.
 */
export function Player({ payload, token, start, canonical }: PlayerProps) {
  const audioRef = useRef<HTMLAudioElement>(null);
  const seekRef = useRef<HTMLInputElement>(null);
  const artworkRef = useRef<HTMLImageElement>(null);
  const speedButtonRef = useRef<HTMLButtonElement>(null);
  const pendingSeek = useRef<number | null>(null);
  // Set by any seek the listener makes, so a later loadedmetadata (on iOS it
  // waits for the first play) does not jump back to ?t= or the saved spot.
  const listenerSeeked = useRef(false);
  const [playing, setPlaying] = useState(false);
  const [waiting, setWaiting] = useState(false);
  const [time, setTime] = useState(start);
  const [duration, setDuration] = useState(payload.durationSeconds);
  const [rate, setRate] = useState(1);
  const [speedOpen, setSpeedOpen] = useState(false);
  const [scrub, setScrub] = useState<number | null>(null);
  const [audioNotice, setAudioNotice] = useState<AudioNotice>(null);
  const [shareNotice, setShareNotice] = useState<ShareNotice>(null);
  const [shareLabel, setShareLabel] = useState("Share");
  const [artworkFailed, setArtworkFailed] = useState(false);

  const download = downloadPath(token);
  const insecureEnclosure = /^http:/i.test(payload.audioURL);
  const showArtwork = payload.artworkURL !== "" && !artworkFailed;

  useEffect(() => {
    if (typeof navigator.share !== "function") {
      setShareLabel("Copy link");
    }
  }, []);

  // Escape closes the speed panel, and hands focus back if it was inside.
  useEffect(() => {
    if (!speedOpen) {
      return;
    }
    const onKey = (event: KeyboardEvent) => {
      if (event.key !== "Escape") {
        return;
      }
      const hadFocus = document.getElementById(SPEED_PANEL_ID)?.contains(document.activeElement) ?? false;
      setSpeedOpen(false);
      if (hadFocus) {
        speedButtonRef.current?.focus();
      }
    };
    document.addEventListener("keydown", onKey);
    return () => document.removeEventListener("keydown", onKey);
  }, [speedOpen]);

  useEffect(() => {
    if (shareNotice !== "copied") {
      return;
    }
    const timer = setTimeout(() => setShareNotice(null), 2000);
    return () => clearTimeout(timer);
  }, [shareNotice]);

  useEffect(() => {
    const image = artworkRef.current;
    if (!image) {
      return;
    }
    const onError = () => setArtworkFailed(true);
    // The image may have failed before this script ran.
    if (image.complete && image.naturalWidth === 0) {
      onError();
    }
    image.addEventListener("error", onError);
    return () => image.removeEventListener("error", onError);
  }, []);

  useEffect(() => {
    const audio = audioRef.current;
    if (!audio) {
      return;
    }
    const storageKey = `opencast.share.position.${payload.guid || payload.audioURL}`;
    let savedSecond = -1;

    const syncPositionState = () => {
      if (!("mediaSession" in navigator) || !Number.isFinite(audio.duration) || audio.duration <= 0) {
        return;
      }
      try {
        navigator.mediaSession.setPositionState({
          duration: audio.duration,
          playbackRate: audio.playbackRate,
          position: Math.min(audio.currentTime, audio.duration),
        });
      } catch {
        // Some browsers reject a position past a still-changing duration.
      }
    };
    const onMetadata = () => {
      const total = Number.isFinite(audio.duration) ? audio.duration : 0;
      if (total > 0) {
        setDuration(total);
      }
      if (!listenerSeeked.current) {
        const resume = start > 0 ? start : readPosition(storageKey);
        if (resume > 0 && (total === 0 || resume < total - 2)) {
          audio.currentTime = resume;
        }
        setTime(audio.currentTime);
      }
      syncPositionState();
    };
    const onTime = () => {
      setTime(audio.currentTime);
      const second = Math.floor(audio.currentTime);
      if (second !== savedSecond) {
        savedSecond = second;
        writePosition(storageKey, second);
      }
      syncPositionState();
    };
    const onPlay = () => {
      setPlaying(true);
      setAudioNotice((notice) => (notice === "blocked" ? null : notice));
    };
    const onPause = () => setPlaying(false);
    const onWaiting = () => setWaiting(true);
    const onPlaying = () => setWaiting(false);
    const onRate = () => {
      setRate(audio.playbackRate);
      syncPositionState();
    };
    const onEnded = () => removePosition(storageKey);
    const onError = () => {
      setAudioNotice("failed");
      setPlaying(false);
      setWaiting(false);
    };

    const listeners: [string, () => void][] = [
      ["loadedmetadata", onMetadata],
      ["timeupdate", onTime],
      ["play", onPlay],
      ["pause", onPause],
      ["waiting", onWaiting],
      ["playing", onPlaying],
      ["ratechange", onRate],
      ["ended", onEnded],
      ["error", onError],
    ];
    for (const [type, listener] of listeners) {
      audio.addEventListener(type, listener);
    }
    // With preload="metadata" the element may have loaded (or failed) before hydration.
    if (audio.error) {
      onError();
    } else if (audio.readyState >= HAVE_METADATA) {
      onMetadata();
    }

    const seekTo = (seconds: number) => {
      const upper = Number.isFinite(audio.duration) && audio.duration > 0 ? audio.duration : Number.MAX_SAFE_INTEGER;
      listenerSeeked.current = true;
      audio.currentTime = Math.min(Math.max(0, seconds), upper);
    };
    const actions: [MediaSessionAction, MediaSessionActionHandler][] = [
      ["play", () => void audio.play().catch(() => undefined)],
      ["pause", () => audio.pause()],
      ["seekbackward", (details) => seekTo(audio.currentTime - (details.seekOffset ?? BACK_SECONDS))],
      ["seekforward", (details) => seekTo(audio.currentTime + (details.seekOffset ?? FORWARD_SECONDS))],
      ["seekto", (details) => details.seekTime !== undefined && seekTo(details.seekTime)],
    ];
    if ("mediaSession" in navigator) {
      navigator.mediaSession.metadata = new MediaMetadata({
        title: payload.title,
        artist: payload.podcastTitle,
        album: payload.podcastTitle,
        artwork: payload.artworkURL ? [{ src: payload.artworkURL, sizes: "512x512" }] : [],
      });
      for (const [action, handler] of actions) {
        try {
          navigator.mediaSession.setActionHandler(action, handler);
        } catch {
          // Unsupported action in this browser.
        }
      }
    }

    return () => {
      for (const [type, listener] of listeners) {
        audio.removeEventListener(type, listener);
      }
      if ("mediaSession" in navigator) {
        for (const [action] of actions) {
          try {
            navigator.mediaSession.setActionHandler(action, null);
          } catch {
            // Unsupported action in this browser.
          }
        }
      }
    };
  }, [payload, start]);

  const commitSeek = useCallback(() => {
    const audio = audioRef.current;
    const value = pendingSeek.current;
    if (!audio || value === null) {
      return;
    }
    pendingSeek.current = null;
    listenerSeeked.current = true;
    audio.currentTime = value;
    setTime(value);
    setScrub(null);
  }, []);

  useEffect(() => {
    // The native change event: preact/compat maps onChange on inputs to input.
    const input = seekRef.current;
    input?.addEventListener("change", commitSeek);
    return () => input?.removeEventListener("change", commitSeek);
  }, [commitSeek]);

  // The browser took the touch away mid-drag (a scroll, a system gesture): no
  // pointerup or change follows, so drop the preview or the thumb stays frozen.
  const cancelSeek = () => {
    pendingSeek.current = null;
    setScrub(null);
  };

  const previewSeek = (event: { currentTarget: HTMLInputElement }) => {
    const value = Number(event.currentTarget.value);
    pendingSeek.current = value;
    setScrub(value);
  };

  const togglePlayback = () => {
    const audio = audioRef.current;
    if (!audio) {
      return;
    }
    if (!audio.paused) {
      audio.pause();
      return;
    }
    audio.play().catch((error: unknown) => {
      const name = error instanceof Error ? error.name : "";
      if (name === "NotAllowedError") {
        setAudioNotice("blocked");
      } else if (name !== "AbortError") {
        setAudioNotice("failed");
      }
    });
  };

  const skip = (seconds: number) => {
    const audio = audioRef.current;
    if (!audio) {
      return;
    }
    // Before metadata the element still reports 0; skip from what the page shows.
    const from = audio.readyState >= HAVE_METADATA ? audio.currentTime : time;
    const upper = Number.isFinite(audio.duration) && audio.duration > 0 ? audio.duration : Number.MAX_SAFE_INTEGER;
    const next = Math.min(Math.max(0, from + seconds), upper);
    listenerSeeked.current = true;
    audio.currentTime = next;
    setTime(next);
  };

  const chooseRate = (next: number) => {
    if (audioRef.current) {
      audioRef.current.playbackRate = next;
    }
    setRate(next);
  };

  const share = async () => {
    if (typeof navigator.share === "function") {
      try {
        await navigator.share({ title: payload.title, url: canonical });
      } catch {
        // Dismissed.
      }
      return;
    }
    try {
      await navigator.clipboard.writeText(canonical);
      setShareNotice("copied");
    } catch {
      setShareNotice("copy-failed");
    }
  };

  const shown = scrub ?? time;
  const progress = duration > 0 ? Math.min(100, (shown / duration) * 100) : 0;
  const valueText = duration > 0 ? `${formatClock(shown)} of ${formatClock(duration)}` : formatClock(shown);
  const transportButton = "flex min-h-11 min-w-11 flex-col items-center justify-center rounded-full ring-1 ring-border";
  const actionButton =
    "inline-flex min-h-11 min-w-11 items-center gap-2 rounded-full px-4 text-sm font-medium ring-1 ring-border bg-surface/70";

  return (
    <div className="relative isolate flex flex-col items-center gap-6 pb-6 pt-4 md:flex-row md:items-center md:gap-10 md:pt-10">
      {/* Sits in the header row (bottom-full of this box, which starts where
          the header ends, on the same gutter) but belongs to the hydrated
          player. Shows ⋯ at normal speed, the speed otherwise. */}
      <button
        ref={speedButtonRef}
        type="button"
        data-needs-script
        aria-label={`Playback speed, ${rate}×`}
        aria-expanded={speedOpen}
        aria-controls={SPEED_PANEL_ID}
        onClick={() => setSpeedOpen((open) => !open)}
        className="absolute bottom-full right-0 flex min-h-11 min-w-11 items-center justify-center rounded-full px-2 text-sm font-semibold tabular-nums ring-1 ring-border"
      >
        {rate === 1 ? <Icon name="more" size={22} /> : `${rate}×`}
      </button>
      {showArtwork && (
        <div
          aria-hidden="true"
          className="artwork-glow pointer-events-none absolute left-1/2 -top-40 -z-10 h-[80vh] w-[150vw] max-w-[1600px] -translate-x-1/2 bg-cover bg-center opacity-50 blur-3xl saturate-150 motion-reduce:transition-none"
          style={{ backgroundImage: cssURL(payload.artworkURL) }}
        />
      )}
      <div className="flex shrink-0 justify-center">
        <ArtworkStage open={speedOpen} onOpenChange={setSpeedOpen} rate={rate} onRate={chooseRate} panelID={SPEED_PANEL_ID}>
          {showArtwork ? (
            <img
              ref={artworkRef}
              src={payload.artworkURL}
              alt=""
              width={320}
              height={320}
              decoding="async"
              draggable={false}
              className="object-cover"
            />
          ) : (
            <div className="flex items-center justify-center bg-surface-secondary">
              <BrandMark size={96} className="opacity-80" />
            </div>
          )}
        </ArtworkStage>
      </div>

      <div className="flex w-full min-w-0 flex-1 flex-col text-center md:text-left">
        {/* Titles can be one unbroken run (a URL, a slug): break it rather than run off the screen. */}
        <h1 className="text-balance wrap-break-word text-xl font-semibold leading-snug md:text-2xl">{payload.title}</h1>
        {payload.podcastTitle !== "" && <p className="mt-1 wrap-break-word text-sm text-muted">{payload.podcastTitle}</p>}

        <audio ref={audioRef} src={playableAudioURL(payload.audioURL)} preload="metadata" playsInline />
        {/* Without script the controls below are inert (Page hides them); the
            browser's own player takes their place. Raw HTML, so hydration
            leaves the noscript alone instead of building an audio inside it. */}
        <noscript dangerouslySetInnerHTML={{ __html: noScriptPlayer(payload.audioURL) }} />

        <div data-needs-script className="mt-6">
          <input
            ref={seekRef}
            type="range"
            min={0}
            max={Math.max(1, Math.floor(duration), Math.floor(shown))}
            step={1}
            value={Math.floor(shown)}
            aria-label="Seek"
            aria-valuetext={valueText}
            className="w-full cursor-pointer"
            style={{ "--track": `linear-gradient(to right, var(--accent) ${progress}%, var(--border) ${progress}%)` } as Record<string, string>}
            onInput={previewSeek}
            onPointerUp={commitSeek}
            onPointerCancel={cancelSeek}
            onKeyUp={commitSeek}
          />
          <div aria-hidden="true" className="-mt-2 flex justify-between text-xs tabular-nums text-muted">
            <span>{formatClock(shown)}</span>
            <span>{duration > 0 ? `-${formatClock(duration - shown)}` : ""}</span>
          </div>
        </div>

        {/* One two-column grid for both rows, so the controls line up: each
            skip button centres over the pill below it and Play (lifted out of
            the flow, not the tab order) sits over the seam between them. */}
        <div data-actions className="relative mx-auto mt-4 grid w-fit grid-cols-2 items-center gap-x-3 gap-y-5 md:mx-0">
          <div data-needs-script className="flex h-16 items-center justify-center">
            <button type="button" onClick={() => skip(-BACK_SECONDS)} className={transportButton}>
              <Icon name="back" size={20} />
              <span aria-hidden="true" className="text-[0.625rem] font-semibold leading-none">{BACK_SECONDS}</span>
              <span className="sr-only">Back {BACK_SECONDS} seconds</span>
            </button>
          </div>
          <button
            type="button"
            data-needs-script
            onClick={togglePlayback}
            className="absolute left-1/2 top-0 flex h-16 w-16 -translate-x-1/2 items-center justify-center rounded-full bg-cta text-cta-ink shadow-lg"
          >
            {waiting && playing ? (
              <span className="h-6 w-6 animate-spin rounded-full border-2 border-current border-t-transparent motion-reduce:animate-none" />
            ) : (
              <Icon name={playing ? "pause" : "play"} size={30} />
            )}
            <span className="sr-only">{playing ? "Pause" : "Play"}</span>
          </button>
          <div data-needs-script className="flex h-16 items-center justify-center">
            <button type="button" onClick={() => skip(FORWARD_SECONDS)} className={transportButton}>
              <Icon name="forward" size={20} />
              <span aria-hidden="true" className="text-[0.625rem] font-semibold leading-none">{FORWARD_SECONDS}</span>
              <span className="sr-only">Forward {FORWARD_SECONDS} seconds</span>
            </button>
          </div>
          <a href={download} download className={`${actionButton} justify-center`}>
            <Icon name="download" size={18} />
            Download
          </a>
          <button type="button" data-needs-script onClick={share} className={`${actionButton} justify-center`}>
            <Icon name="share" size={18} />
            {shareLabel}
          </button>
        </div>

        <div aria-live="polite" className="mt-4 empty:mt-0">
          {audioNotice === "failed" && (
            <div className="rounded-xl bg-skip/10 px-4 py-3 text-sm">
              <p>
                This audio could not be loaded.
                {insecureEnclosure
                  ? " The podcast serves it without HTTPS, which this page cannot play, but the download still works."
                  : " The download may still work."}
              </p>
              <p className="mt-3 flex flex-wrap items-center justify-center gap-3 md:justify-start">
                <a href={download} download className="inline-flex min-h-11 items-center rounded-full bg-cta px-5 font-semibold text-cta-ink">
                  Download the episode
                </a>
                {payload.feedURL !== "" && (
                  <a href={payload.feedURL} className="inline-flex min-h-11 items-center underline decoration-dotted">
                    RSS feed
                  </a>
                )}
              </p>
            </div>
          )}
          {audioNotice === "blocked" && <p className="text-sm text-muted">The browser blocked playback. Tap Play again.</p>}
        </div>
        <p aria-live="polite" className="mt-2 text-sm text-muted empty:mt-0">
          {shareNotice === "copied" && "Link copied."}
          {shareNotice === "copy-failed" && "Copy the link from the address bar."}
        </p>
      </div>
    </div>
  );
}

function noScriptPlayer(audioURL: string): string {
  // href never holds a quote or angle bracket (the URL parser encodes them);
  // & still needs escaping so a query like &lt= is not read as an entity.
  const src = playableAudioURL(audioURL).replace(/&/g, "&amp;").replace(/"/g, "&quot;").replace(/</g, "&lt;");
  return `<audio controls preload="none" src="${src}" class="mt-6 w-full"></audio>`;
}

function readPosition(key: string): number {
  try {
    return Number(localStorage.getItem(key)) || 0;
  } catch {
    return 0;
  }
}

function writePosition(key: string, seconds: number): void {
  try {
    localStorage.setItem(key, String(seconds));
  } catch {
    // Private mode or storage disabled.
  }
}

function removePosition(key: string): void {
  try {
    localStorage.removeItem(key);
  } catch {
    // Private mode or storage disabled.
  }
}
