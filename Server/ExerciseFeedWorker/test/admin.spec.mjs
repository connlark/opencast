// Focused first tests (Phase 10 G): the constant-time admin compare and
// the flip endpoint's 403 paths. The feed itself is a fixture exercised by
// the device flows; this suite stays minimal on purpose.
import { SELF } from "cloudflare:test";
import { describe, expect, it } from "vitest";

import { adminTokenMatches } from "../src/index.js";

// The worker routes purely by pathname, so the tests use a neutral origin.
const ORIGIN = "https://exercise-feed.test";
const TOKEN = "integration-test-admin-token";

describe("adminTokenMatches", () => {
  it("accepts exactly the bearer form of the admin token", async () => {
    expect(await adminTokenMatches(`Bearer ${TOKEN}`, TOKEN)).toBe(true);
  });

  it("rejects wrong tokens, malformed schemes, and missing headers", async () => {
    expect(await adminTokenMatches(`Bearer not-the-token`, TOKEN)).toBe(false);
    expect(await adminTokenMatches(TOKEN, TOKEN)).toBe(false);
    expect(await adminTokenMatches(`bearer ${TOKEN}`, TOKEN)).toBe(false);
    expect(await adminTokenMatches(`Bearer ${TOKEN} `, TOKEN)).toBe(false);
    expect(await adminTokenMatches(null, TOKEN)).toBe(false);
  });
});

describe("admin flip", () => {
  it("403s without an Authorization header", async () => {
    const response = await SELF.fetch(`${ORIGIN}/state/v2`, { method: "POST" });
    expect(response.status).toBe(403);
    expect(await response.text()).toBe("forbidden");
  });

  it("403s with a wrong bearer token", async () => {
    const response = await SELF.fetch(`${ORIGIN}/state/v2`, {
      method: "POST",
      headers: { Authorization: "Bearer wrong-token" },
    });
    expect(response.status).toBe(403);
  });

  it("flips state with the correct token and serves the flipped feed", async () => {
    const flip = await SELF.fetch(`${ORIGIN}/state/v2`, {
      method: "POST",
      headers: { Authorization: `Bearer ${TOKEN}` },
    });
    expect(flip.status).toBe(200);
    expect(await flip.text()).toBe("v2");

    const state = await SELF.fetch(`${ORIGIN}/state`);
    expect(await state.text()).toBe("v2");

    const feed = await SELF.fetch(`${ORIGIN}/feed.xml`);
    expect(feed.status).toBe(200);
    expect(await feed.text()).toContain("urn:castgraft:modern:001");
  });

  it("404s a flip to an unknown state even with the correct token", async () => {
    const response = await SELF.fetch(`${ORIGIN}/state/v3`, {
      method: "POST",
      headers: { Authorization: `Bearer ${TOKEN}` },
    });
    expect(response.status).toBe(404);
  });
});

describe("HEAD /feed.xml", () => {
  it("returns the feed headers with no body (EFW-1)", async () => {
    const response = await SELF.fetch(`${ORIGIN}/feed.xml`, { method: "HEAD" });
    expect(response.status).toBe(200);
    expect(response.headers.get("Content-Type")).toContain("application/rss+xml");
    expect(response.headers.get("ETag")).toBeTruthy();
    expect(await response.text()).toBe("");
  });
});
