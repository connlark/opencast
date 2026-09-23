import { describe, expect, it } from "vitest";
import { NotFoundPage } from "../../src/app/NotFoundPage.tsx";
import { renderHTML } from "../../src/worker/render.ts";

const ASSETS = { js: "/e/_/entry.js?v=test", css: "/e/_/entry.css?v=test" };

describe("renderHTML", () => {
  it("gives HEAD the GET headers, including the length, and a null body", async () => {
    const get = renderHTML(<NotFoundPage assets={ASSETS} />, { status: 404, head: false, contentSecurityPolicy: true });
    const head = renderHTML(<NotFoundPage assets={ASSETS} />, { status: 404, head: true, contentSecurityPolicy: true });

    expect(head.body).toBeNull();
    expect(Object.fromEntries(head.headers)).toEqual(Object.fromEntries(get.headers));
    expect(Number(get.headers.get("content-length"))).toBe((await get.arrayBuffer()).byteLength);
  });

  it("drops the content security policy only when asked (vite dev)", () => {
    const dev = renderHTML(<NotFoundPage assets={ASSETS} />, { status: 200, head: false, contentSecurityPolicy: false });
    expect(dev.headers.has("content-security-policy")).toBe(false);
  });
});
