import { SELF } from "cloudflare:test";
import { describe, expect, it } from "vitest";

const BASE = "https://remote-transcription.example.com";

async function post(path, body) {
  return SELF.fetch(`${BASE}${path}`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
}

describe("production self-hosting posture", () => {
  it("keeps health live and customer gates closed by default", async () => {
    const health = await SELF.fetch(`${BASE}/health`);
    expect(health.status).toBe(200);

    const create = await post("/v1/remote-transcription/jobs", {
      schema_version: 1,
    });
    expect(create.status).toBe(503);
    expect((await create.json()).error).toBe("feature_disabled");

    const redeem = await post(
      "/v1/remote-transcription/purchases/redeem",
      { schema_version: 1, transaction_jws: "junk" },
    );
    expect(redeem.status).toBe(503);
    expect((await redeem.json()).error).toBe("purchases_disabled");

    const challenge = await post("/v1/app-attest/challenge", {
      install_id: "self-hosting-posture-install",
      purpose: "register",
    });
    expect(challenge.status).toBe(503);
    expect((await challenge.json()).error).toBe("feature_disabled");
  });

  it("keeps the verifier reachable but rejects junk registration", async () => {
    const response = await post("/v1/app-attest/register", {
      install_id: "self-hosting-posture-install",
      key_id: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
      challenge_id: "no-such-challenge",
      challenge: "junk",
      attestation_object: "junk",
    });
    expect(response.status).toBe(401);
    expect((await response.json()).error).toBe("invalid_challenge");
  });
});
