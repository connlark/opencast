import { NotFoundPage } from "../app/NotFoundPage.tsx";
import { Page, type PageAssets } from "../app/Page.tsx";
import { decodeToken, SHARE_PATH } from "../shared/payload.ts";
import { parseStart } from "../shared/start.ts";
import { canonicalURL, SITE_ORIGIN } from "../shared/urls.ts";
import { handleDownload } from "./download.ts";
import type { Env } from "./env.ts";
import { logEvent } from "./log.ts";
import { renderHTML } from "./render.ts";

// /e/_/* is served by the assets binding before this code runs. Fixed names
// plus the build id stand in for hashed file names (the client builds after
// the worker, so there is no manifest to read).
const ASSETS: PageAssets = import.meta.env.DEV
  ? { js: "/src/client/entry.tsx", css: null }
  : { js: `/e/_/entry.js?v=${__BUILD_ID__}`, css: `/e/_/entry.css?v=${__BUILD_ID__}` };
const CONTENT_SECURITY_POLICY = !import.meta.env.DEV;

const worker = {
  async fetch(request: Request, env: Env): Promise<Response> {
    const head = request.method === "HEAD";
    if (request.method !== "GET" && !head) {
      return new Response("Method Not Allowed\n", {
        status: 405,
        headers: { allow: "GET, HEAD", "content-type": "text/plain; charset=utf-8", "x-robots-tag": "noindex" },
      });
    }

    try {
      const url = new URL(request.url);
      if (url.pathname === "/e/") {
        return new Response(null, {
          status: 302,
          headers: { location: `${SITE_ORIGIN}/`, "x-robots-tag": "noindex" },
        });
      }

      const match = SHARE_PATH.exec(url.pathname);
      const token = match?.[1];
      const payload = token === undefined ? null : decodeToken(token);
      if (match === null || token === undefined || payload === null) {
        logEvent("page", { status: 404 });
        return notFound(head);
      }
      if (match[2] !== undefined) {
        return await handleDownload(request, env, payload);
      }

      const start = parseStart(url.searchParams.get("t"), payload.durationSeconds);
      const canonical = canonicalURL(url.origin, token, start);
      logEvent("page", { status: 200 });
      return renderHTML(
        <Page payload={payload} token={token} start={start} canonical={canonical} assets={ASSETS} />,
        { status: 200, head, contentSecurityPolicy: CONTENT_SECURITY_POLICY },
      );
    } catch (error) {
      // The error name only: a message could quote the token.
      logEvent("error", { name: error instanceof Error ? error.name : "unknown" });
      return new Response("Something went wrong.\n", {
        status: 500,
        headers: { "content-type": "text/plain; charset=utf-8", "cache-control": "no-store", "x-robots-tag": "noindex" },
      });
    }
  },
};

function notFound(head: boolean): Response {
  return renderHTML(<NotFoundPage assets={ASSETS} />, { status: 404, head, contentSecurityPolicy: CONTENT_SECURITY_POLICY });
}

export default worker;
