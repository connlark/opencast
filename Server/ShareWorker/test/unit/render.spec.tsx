import { describe, expect, it } from "vitest";
import vectorFixture from "../../../../Packages/OpenCastCore/Tests/OpenCastCoreTests/Fixtures/EpisodeShareTokenVectors.json";
import { NotFoundPage } from "../../src/app/NotFoundPage.tsx";
import { Page } from "../../src/app/Page.tsx";
import type { SharePayload } from "../../src/shared/payload.ts";
import { renderHTML } from "../../src/worker/render.ts";

const ASSETS = { js: "/e/_/entry.js?v=test", css: "/e/_/entry.css?v=test" };
const ALMANAC = vectorFixture.vectors.find((vector) => vector.name === "almanac-fixture")!;

describe("renderHTML", () => {
  it("sends no referrer from the share page or the 404 page", () => {
    // Hotlink-protected hosts (This American Life) refuse artwork to any
    // cross-site referrer; the origin is not worth a blank tile.
    const page = renderHTML(
      <Page payload={ALMANAC.payload as SharePayload} token={ALMANAC.token} start={0} canonical={`https://share.example.com/e/${ALMANAC.token}`} assets={ASSETS} />,
      { status: 200, head: false, contentSecurityPolicy: true },
    );
    const notFound = renderHTML(<NotFoundPage assets={ASSETS} />, { status: 404, head: false, contentSecurityPolicy: true });
    expect(page.status).toBe(200);
    expect(page.headers.get("referrer-policy")).toBe("no-referrer");
    expect(notFound.status).toBe(404);
    expect(notFound.headers.get("referrer-policy")).toBe("no-referrer");
  });

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
