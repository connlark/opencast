// node --test scripts/analysis-policy-publisher.test.mjs
import assert from "node:assert/strict";
import { test } from "node:test";

import { PublishConflictError, publishAnalysisPolicy } from "./analysis-policy-publisher.mjs";

const PREFIX = "opencast/policies";
const bytes = (text) => new TextEncoder().encode(text);
const text = (value) => (value == null ? null : new TextDecoder().decode(value));

/**
 * In-memory R2: `putIfAbsent` is atomic, like a conditional write. Every
 * operation first yields a seeded-random number of turns, so concurrent
 * publishers interleave between steps in varying orders, the way two
 * operators' requests would.
 */
class MemoryBucket {
  objects = new Map();
  writes = [];

  constructor(seed = 1) {
    this.state = seed;
  }

  async turn() {
    this.state = (this.state * 48_271) % 2_147_483_647;
    const turns = 1 + (this.state % 3);
    for (let index = 0; index < turns; index += 1) {
      await new Promise((resolve) => setImmediate(resolve));
    }
  }

  async putIfAbsent(key, value) {
    await this.turn();
    if (this.objects.has(key)) return false;
    this.objects.set(key, value);
    this.writes.push(key);
    return true;
  }

  async get(key) {
    await this.turn();
    return this.objects.get(key) ?? null;
  }

  async put(key, value) {
    await this.turn();
    this.objects.set(key, value);
    this.writes.push(key);
  }

  read(key) {
    return text(this.objects.get(key));
  }
}

const publish = (storage, body, signature, version = 2) =>
  publishAnalysisPolicy({ storage, prefix: PREFIX, version, bundle: bytes(body), signature: bytes(signature) });

test("a fresh publish writes both versioned objects, then current, and flips the signature last", async () => {
  const bucket = new MemoryBucket();
  await publish(bucket, "body-A", "sig-A");
  assert.deepEqual(bucket.writes, [
    "opencast/policies/analysis/v2.json",
    "opencast/policies/analysis/v2.json.sig",
    "opencast/policies/analysis/current.json",
    "opencast/policies/analysis/current.json.sig",
  ]);
  assert.equal(bucket.read("opencast/policies/analysis/current.json.sig"), "sig-A");
});

test("a rerun with the same bytes succeeds without rewriting the version", async () => {
  const bucket = new MemoryBucket();
  await publish(bucket, "body-A", "sig-A");
  await publish(bucket, "body-A", "sig-A");
  assert.equal(bucket.writes.filter((key) => key.includes("/v2.")).length, 2);
  assert.equal(bucket.read("opencast/policies/analysis/v2.json"), "body-A");
});

test("different bytes under a published version abort before anything current changes", async () => {
  const bucket = new MemoryBucket();
  await publish(bucket, "body-A", "sig-A");
  const before = [...bucket.writes];
  await assert.rejects(publish(bucket, "body-B", "sig-B"), PublishConflictError);
  assert.deepEqual(bucket.writes, before);
  assert.equal(bucket.read("opencast/policies/analysis/current.json.sig"), "sig-A");
});

test("a different signature for the same bytes also aborts before the flip", async () => {
  const bucket = new MemoryBucket();
  await publish(bucket, "body-A", "sig-A");
  await assert.rejects(publish(bucket, "body-A", "sig-A2"), PublishConflictError);
  assert.equal(bucket.read("opencast/policies/analysis/current.json.sig"), "sig-A");
});

test("two publishers racing different bodies for one version: one wins, the other aborts, current stays coherent", async () => {
  const winners = new Set();
  for (let round = 0; round < 50; round += 1) {
    const bucket = new MemoryBucket(round + 1);
    const outcomes = await Promise.allSettled([
      publish(bucket, "body-A", "sig-A"),
      publish(bucket, "body-B", "sig-B"),
    ]);
    const fulfilled = outcomes.filter((outcome) => outcome.status === "fulfilled");
    const losers = outcomes.filter((outcome) => outcome.status === "rejected");
    assert.equal(fulfilled.length, 1, `round ${round}`);
    assert.equal(losers.length, 1, `round ${round}`);
    assert.ok(losers[0].reason instanceof PublishConflictError);
    const winner = outcomes[0].status === "fulfilled" ? "A" : "B";
    winners.add(winner);
    assert.equal(bucket.read("opencast/policies/analysis/v2.json"), `body-${winner}`);
    assert.equal(bucket.read("opencast/policies/analysis/v2.json.sig"), `sig-${winner}`);
    assert.equal(bucket.read("opencast/policies/analysis/current.json"), `body-${winner}`);
    assert.equal(bucket.read("opencast/policies/analysis/current.json.sig"), `sig-${winner}`);
  }
  assert.deepEqual([...winners].sort(), ["A", "B"], "both interleavings were exercised");
});

test("two publishers racing the same bytes both succeed", async () => {
  const bucket = new MemoryBucket();
  await Promise.all([publish(bucket, "body-A", "sig-A"), publish(bucket, "body-A", "sig-A")]);
  assert.equal(bucket.read("opencast/policies/analysis/current.json.sig"), "sig-A");
});

test("an invalid version is refused before any write", async () => {
  const bucket = new MemoryBucket();
  await assert.rejects(publish(bucket, "body-A", "sig-A", 0));
  assert.deepEqual(bucket.writes, []);
});
