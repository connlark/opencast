import type { SharePayload } from "../shared/payload.ts";
import { formatClock } from "../shared/start.ts";
import { APPLE_TOUCH_ICON, audioMimeType, BRAND_ICON_DARK, BRAND_ICON_LIGHT, FALLBACK_OG_IMAGE, SITE_ORIGIN } from "../shared/urls.ts";
import { BrandMark, THEME_COLOR_DARK, THEME_COLOR_LIGHT } from "./Brand.tsx";
import { Player, type PlayerProps } from "./Player.tsx";

export interface PageAssets {
  js: string;
  /** Null under vite dev, where the entry module injects its own CSS. */
  css: string | null;
}

export interface PageProps extends PlayerProps {
  assets: PageAssets;
}

/**
 * Server-only document shell. Only <main id="app"> is hydrated: on the zone,
 * Email Address Obfuscation, Rocket Loader, and extensions can rewrite <head>
 * or append to <body>, which positional whole-document hydration cannot absorb.
 */
export function Page({ payload, token, start, canonical, assets }: PageProps) {
  const description = shareDescription(payload, start);
  const image = payload.artworkURL || FALLBACK_OG_IMAGE;
  const state: PlayerProps = { payload, token, start, canonical };
  // type="application/json" never executes; escaping < keeps </script> inert.
  const serializedState = JSON.stringify(state).replace(/</g, "\\u003c");

  return (
    <html lang="en">
      <head>
        <meta charSet="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover" />
        <title>{payload.podcastTitle ? `${payload.title} — ${payload.podcastTitle}` : payload.title}</title>
        <meta name="description" content={description} />
        <meta name="robots" content="noindex" />
        <link rel="canonical" href={canonical} />
        {payload.feedURL !== "" && (
          <link rel="alternate" type="application/rss+xml" title={payload.podcastTitle || "RSS feed"} href={payload.feedURL} />
        )}
        <meta property="og:type" content="music.song" />
        <meta property="og:site_name" content="opencast" />
        <meta property="og:title" content={payload.title} />
        <meta property="og:description" content={description} />
        <meta property="og:url" content={canonical} />
        <meta property="og:image" content={image} />
        <meta property="og:image:alt" content={`${payload.podcastTitle || payload.title} artwork`} />
        <meta property="og:audio" content={payload.audioURL} />
        {/^https:/i.test(payload.audioURL) && <meta property="og:audio:secure_url" content={payload.audioURL} />}
        <meta property="og:audio:type" content={audioMimeType(payload.audioURL)} />
        {payload.durationSeconds > 0 && <meta property="music:duration" content={String(payload.durationSeconds)} />}
        <meta name="twitter:card" content="summary" />
        <meta name="twitter:title" content={payload.title} />
        <meta name="twitter:description" content={description} />
        <meta name="twitter:image" content={image} />
        <meta name="theme-color" media="(prefers-color-scheme: light)" content={THEME_COLOR_LIGHT} />
        <meta name="theme-color" media="(prefers-color-scheme: dark)" content={THEME_COLOR_DARK} />
        <BrandIcons />
        {/* The player's controls need script; without it they are hidden and
            the player's noscript fallback shows the browser's own audio controls.
            Download is then alone in the controls grid, so it becomes a row. */}
        <noscript>
          <style dangerouslySetInnerHTML={{ __html: "[data-needs-script]{display:none!important}[data-actions]{display:flex!important}" }} />
        </noscript>
        {assets.css !== null && <link rel="stylesheet" href={assets.css} />}
        <script type="module" src={assets.js} />
      </head>
      <body className="flex min-h-dvh flex-col bg-background font-sans text-foreground antialiased">
        <PageHeader />
        <script id="__share" type="application/json" dangerouslySetInnerHTML={{ __html: serializedState }} />
        <main id="app" className="mx-auto w-full max-w-md flex-1 px-5 md:max-w-2xl">
          <Player payload={payload} token={token} start={start} canonical={canonical} />
        </main>
        <footer className="mx-auto w-full max-w-md px-5 pb-[max(1.5rem,env(safe-area-inset-bottom))] pt-8 text-center text-xs text-muted md:max-w-2xl">
          {payload.feedURL !== "" && (
            <p>
              <a className="inline-flex min-h-11 items-center underline decoration-dotted" href={payload.feedURL}>
                RSS feed
              </a>
            </p>
          )}
          <p>
            Shared with{" "}
            <a className="font-medium underline decoration-dotted" href={SITE_ORIGIN}>
              opencast
            </a>
            , the open source podcast app.
          </p>
        </footer>
      </body>
    </html>
  );
}

export function BrandIcons() {
  return (
    <>
      <link rel="icon" type="image/png" sizes="192x192" media="(prefers-color-scheme: light)" href={BRAND_ICON_LIGHT} />
      <link rel="icon" type="image/png" sizes="192x192" media="(prefers-color-scheme: dark)" href={BRAND_ICON_DARK} />
      <link rel="apple-touch-icon" href={APPLE_TOUCH_ICON} />
    </>
  );
}

export function PageHeader() {
  return (
    <header className="mx-auto flex w-full max-w-md items-center px-5 pt-[max(0.75rem,env(safe-area-inset-top))] md:max-w-2xl">
      <a href={SITE_ORIGIN} className="flex min-h-11 items-center gap-2 font-semibold tracking-tight">
        <BrandMark size={28} />
        opencast
      </a>
    </header>
  );
}

/** "Podcast · starts at 12:34 of 1:00:00", or "Podcast · 1:00:00" without a start time. */
export function shareDescription(payload: SharePayload, start: number): string {
  const total = payload.durationSeconds > 0 ? formatClock(payload.durationSeconds) : "";
  const timing = start > 0 ? `starts at ${formatClock(start)}${total ? ` of ${total}` : ""}` : total;
  if (payload.podcastTitle === "") {
    return timing === "" ? payload.title : timing.charAt(0).toUpperCase() + timing.slice(1);
  }
  return timing === "" ? payload.podcastTitle : `${payload.podcastTitle} · ${timing}`;
}
