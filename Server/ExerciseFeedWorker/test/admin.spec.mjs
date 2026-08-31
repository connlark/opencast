// Focused tests for the constant-time admin compare and
// the flip endpoint's 403 paths. The feed itself is a fixture exercised by
// the device flows; this suite stays minimal on purpose.
import { SELF } from "cloudflare:test";
import { describe, expect, it } from "vitest";

import worker, { adminTokenMatches } from "../src/index.js";

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

describe("creator chapters fixture", () => {
  it("declares podcast:chapters on Bridge Three only, in both GUID states", async () => {
    for (const state of ["v1", "v2"]) {
      await SELF.fetch(`${ORIGIN}/state/${state}`, {
        method: "POST",
        headers: { Authorization: `Bearer ${TOKEN}` },
      });
      const feed = await SELF.fetch(`${ORIGIN}/feed.xml`);
      const xml = await feed.text();
      expect(xml).toContain('xmlns:podcast="https://podcastindex.org/namespace/1.0"');
      const tags = xml.match(/<podcast:chapters /g) ?? [];
      expect(tags.length).toBe(1);
      const bridgeItem = xml.slice(xml.indexOf("<title>Bridge Three</title>"));
      expect(bridgeItem).toContain(
        '<podcast:chapters url="https://graft.example.com/chapters/003.json" type="application/json+chapters">',
      );
    }
  });

  it("serves the chapters document", async () => {
    const response = await SELF.fetch(`${ORIGIN}/chapters/003.json`);
    expect(response.status).toBe(200);
    expect(response.headers.get("Content-Type")).toBe("application/json+chapters");
    const body = await response.json();
    expect(body.version).toBe("1.2.0");
    expect(body.chapters.length).toBe(2);
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

describe("unset ADMIN_TOKEN", () => {
  it("fails closed on the flip endpoint when no admin token is configured", async () => {
    // Exercise the remaining auth-guard arm:
    // a lane with no ADMIN_TOKEN binding must 403 every flip — including a
    // caller presenting an empty bearer against an empty configured token,
    // which the constant-time compare alone would accept.
    for (const env of [{}, { ADMIN_TOKEN: undefined }, { ADMIN_TOKEN: "" }]) {
      for (const headers of [
        {},
        { Authorization: `Bearer ${TOKEN}` },
        { Authorization: "Bearer " },
      ]) {
        const response = await worker.fetch(
          new Request("https://exercise-feed.test/state/v2", {
            method: "POST",
            headers,
          }),
          env,
        );
        expect(response.status).toBe(403);
        expect(await response.text()).toBe("forbidden");
      }
    }
  });
});
