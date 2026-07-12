interface Env {
  ASSETS: Fetcher;
}

const APP_STORE_URL = "https://apps.apple.com/app/opencast/id6766770733";
const SUPPORT_HOST = "support.opencast.mobile";

// Parity with the previous hand-rolled workers, which served HTML with a
// short public cache so design changes propagate within minutes.
function withHTMLCache(res: Response, status?: number): Response {
  const contentType = res.headers.get("content-type") ?? "";
  if (!contentType.includes("text/html") && status === undefined) return res;
  const headers = new Headers(res.headers);
  headers.set("cache-control", "public, max-age=300");
  return new Response(res.body, { status: status ?? res.status, headers });
}

const worker = {
  async fetch(request: Request, env: Env): Promise<Response> {
    if (request.method !== "GET" && request.method !== "HEAD") {
      return new Response("Method Not Allowed", {
        status: 405,
        headers: { Allow: "GET, HEAD" },
      });
    }
    const url = new URL(request.url);

    if (url.hostname === SUPPORT_HOST) {
      if (url.pathname === "/health") {
        return new Response("ok", {
          headers: { "content-type": "text/plain; charset=utf-8" },
        });
      }
      if (url.pathname === "/") {
        url.pathname = "/support";
        return withHTMLCache(await env.ASSETS.fetch(new Request(url, request)));
      }
      if (url.pathname === "/support" || url.pathname === "/privacy") {
        return withHTMLCache(await env.ASSETS.fetch(request));
      }
      // Legacy behavior: unknown support paths serve the support page body
      // with a 404 status.
      url.pathname = "/support";
      const res = await env.ASSETS.fetch(new Request(url, request));
      return withHTMLCache(res, 404);
    }

    // opencast.mobile (plus workers.dev and local preview)
    if (url.pathname === "/app-store") {
      return Response.redirect(APP_STORE_URL, 302);
    }
    const res = await env.ASSETS.fetch(request);
    // Legacy behavior: unknown marketing paths redirect home.
    if (res.status === 404) {
      return Response.redirect(new URL("/", url).toString(), 302);
    }
    return withHTMLCache(res);
  },
};

export default worker;
