import type { ReactElement } from "react";
import { renderToString } from "preact-render-to-string";

// The JSON state script is type="application/json", so script-src does not
// apply to it; 'unsafe-inline' styles cover the server-rendered style="…"
// attributes (the scrubber track, the artwork glow).
export const CONTENT_SECURITY_POLICY = [
  "default-src 'none'",
  "script-src 'self'",
  "style-src 'self' 'unsafe-inline'",
  "img-src https: http:",
  "media-src https: http:",
  "connect-src 'self'",
  "font-src 'self'",
  "base-uri 'none'",
  "form-action 'none'",
  "frame-ancestors 'none'",
  "upgrade-insecure-requests",
].join("; ");

export interface RenderOptions {
  status: number;
  head: boolean;
  /** vite dev serves HMR over a WebSocket the policy would block. */
  contentSecurityPolicy: boolean;
}

/**
 * A full HTML document with the page headers. Worker responses are not
 * edge-cached; max-age governs browsers and link-preview crawlers. HEAD gets
 * the same headers, including the length, and no body.
 */
export function renderHTML(document: ReactElement, options: RenderOptions): Response {
  // The app authors against React's types; the alias makes this a preact vnode.
  const html = `<!doctype html>${renderToString(document as unknown as Parameters<typeof renderToString>[0])}`;
  const body = new TextEncoder().encode(html);
  const headers = new Headers({
    "content-type": "text/html; charset=utf-8",
    "content-length": String(body.byteLength),
    "cache-control": "public, max-age=300",
    "x-robots-tag": "noindex",
    "x-content-type-options": "nosniff",
    // Hosts get our origin for their stats, never the token path.
    "referrer-policy": "strict-origin-when-cross-origin",
  });
  if (options.contentSecurityPolicy) {
    headers.set("content-security-policy", CONTENT_SECURITY_POLICY);
  }
  return new Response(options.head ? null : body, { status: options.status, headers });
}
