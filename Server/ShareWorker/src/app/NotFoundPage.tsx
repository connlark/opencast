import { SITE_ORIGIN } from "../shared/urls.ts";
import { THEME_COLOR_DARK, THEME_COLOR_LIGHT } from "./Brand.tsx";
import { BrandIcons, PageHeader, type PageAssets } from "./Page.tsx";

/** Server-only; no script. Every unknown path and undecodable token lands here. */
export function NotFoundPage({ assets }: { assets: PageAssets }) {
  return (
    <html lang="en">
      <head>
        <meta charSet="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover" />
        <title>Share link not found — opencast</title>
        <meta name="robots" content="noindex" />
        <meta name="theme-color" media="(prefers-color-scheme: light)" content={THEME_COLOR_LIGHT} />
        <meta name="theme-color" media="(prefers-color-scheme: dark)" content={THEME_COLOR_DARK} />
        <BrandIcons />
        {assets.css !== null && <link rel="stylesheet" href={assets.css} />}
      </head>
      <body className="flex min-h-dvh flex-col bg-background font-sans text-foreground antialiased">
        <PageHeader />
        <main className="mx-auto flex w-full max-w-md flex-1 flex-col justify-center px-5 pb-16 text-center">
          <h1 className="text-balance text-2xl font-semibold">This share link isn't valid</h1>
          <p className="mt-3 text-muted">
            Part of it may have been cut off when it was copied. Ask for the link again, or find the episode in the
            opencast app.
          </p>
          <p className="mt-8">
            <a href={SITE_ORIGIN} className="inline-flex min-h-11 items-center rounded-full bg-cta px-5 font-semibold text-cta-ink">
              Go to opencast.mobile
            </a>
          </p>
        </main>
      </body>
    </html>
  );
}
