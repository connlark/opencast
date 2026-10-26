#!/usr/bin/env node
// Writes one verified analysis policy version to R2 so that a version, once
// published, never changes and the current signature only ever names a
// version whose bundle and signature are both in place.
//
// Each versioned object is created with a conditional write (R2 `onlyIf`
// etag-does-not-match `*`, the binding form of `If-None-Match: *`): it lands
// only if the key is absent. If the key exists, the stored bytes are compared:
// identical is a no-op (a rerun), different aborts before anything current
// changes. Two publishers racing on one version therefore cannot both win.
// Only after both versioned objects are confirmed does `current.json` change,
// and `current.json.sig` flips last.
//
// upload-analysis-policy.sh verifies the bundle first and then runs this.

import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

export const CONTENT_TYPE = "application/json; charset=utf-8";

export class PublishConflictError extends Error {}

/**
 * @param {{
 *   storage: {
 *     putIfAbsent(key: string, bytes: Uint8Array): Promise<boolean>,
 *     get(key: string): Promise<Uint8Array | null>,
 *     put(key: string, bytes: Uint8Array): Promise<void>,
 *   },
 *   prefix: string, version: number, bundle: Uint8Array, signature: Uint8Array,
 *   log?: (line: string) => void,
 * }} options
 */
export async function publishAnalysisPolicy({ storage, prefix, version, bundle, signature, log = () => {} }) {
  if (!Number.isInteger(version) || version < 1) {
    throw new Error(`version must be a positive integer, not ${version}`);
  }
  const base = `${prefix.replace(/^\/+|\/+$/g, "")}/analysis`;
  const versioned = [
    [`${base}/v${version}.json`, bundle],
    [`${base}/v${version}.json.sig`, signature],
  ];

  for (const [key, bytes] of versioned) {
    if (await storage.putIfAbsent(key, bytes)) {
      log(`created ${key}`);
      continue;
    }
    const existing = await storage.get(key);
    if (existing == null) {
      throw new PublishConflictError(`${key} was refused as existing but cannot be read; nothing current changed`);
    }
    if (!sameBytes(existing, bytes)) {
      throw new PublishConflictError(
        `${key} already holds different bytes; a version is immutable, so publish a new version. Nothing current changed`,
      );
    }
    log(`${key} already published with these bytes`);
  }

  for (const [key, bytes] of versioned) {
    const stored = await storage.get(key);
    if (stored == null || !sameBytes(stored, bytes)) {
      throw new PublishConflictError(`${key} did not read back as written; nothing current changed`);
    }
  }

  await storage.put(`${base}/current.json`, bundle);
  log(`wrote ${base}/current.json`);
  // The flip: from here clients fetch and verify this version.
  await storage.put(`${base}/current.json.sig`, signature);
  log(`flipped ${base}/current.json.sig to version ${version}`);
}

export function sameBytes(lhs, rhs) {
  return Buffer.compare(Buffer.from(lhs), Buffer.from(rhs)) === 0;
}

/** The storage interface over an R2 bucket binding. */
export function r2BucketStorage(bucket) {
  const httpMetadata = { contentType: CONTENT_TYPE };
  return {
    async putIfAbsent(key, bytes) {
      const stored = await bucket.put(key, bytes, { onlyIf: { etagDoesNotMatch: "*" }, httpMetadata });
      return stored != null;
    },
    async get(key) {
      const object = await bucket.get(key);
      return object == null ? null : new Uint8Array(await object.arrayBuffer());
    },
    async put(key, bytes) {
      await bucket.put(key, bytes, { httpMetadata });
    },
  };
}

function argument(argv, flag) {
  const index = argv.indexOf(flag);
  if (index < 0 || index + 1 >= argv.length) {
    throw new Error(`missing ${flag}`);
  }
  return argv[index + 1];
}

async function main(argv) {
  const version = Number(argument(argv, "--version"));
  const bundle = readFileSync(argument(argv, "--bundle"));
  const signature = readFileSync(argument(argv, "--signature"));
  const bucketName = argument(argv, "--bucket");
  const prefix = argument(argv, "--prefix");

  // A throwaway Wrangler config whose only binding is the bucket, used
  // remotely: the conditional write runs against the real bucket through the
  // binding API, with the operator's Wrangler login.
  const configDirectory = mkdtempSync(join(tmpdir(), "analysis-policy-publisher-"));
  try {
    const configPath = join(configDirectory, "wrangler.json");
    writeFileSync(configPath, JSON.stringify({
      name: "analysis-policy-publisher",
      compatibility_date: "2026-09-30",
      r2_buckets: [{ binding: "BUCKET", bucket_name: bucketName, remote: true }],
    }));
    const { getPlatformProxy } = await import("wrangler");
    const proxy = await getPlatformProxy({ configPath, remoteBindings: true });
    try {
      await publishAnalysisPolicy({
        storage: r2BucketStorage(proxy.env.BUCKET),
        prefix,
        version,
        bundle,
        signature,
        log: (line) => console.log(line),
      });
    } finally {
      await proxy.dispose();
    }
  } finally {
    rmSync(configDirectory, { recursive: true, force: true });
  }
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? "").href) {
  main(process.argv.slice(2)).catch((error) => {
    console.error(`analysis-policy-publisher: ${error.message}`);
    process.exit(1);
  });
}
