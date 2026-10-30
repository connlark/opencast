// Synthetic identities only: seed local D1, never contact Apple or use device keys.
// Ported from TranscriptAnalysisWorker/test/support.mjs.
import { SELF, env } from 'cloudflare:test';
export const BASE = 'https://transcription.integration.test';
const appID = () => `${env.APPLE_TEAM_ID}.${env.APPLE_BUNDLE_ID}`;

export function bytesToBase64(bytes) {
  return btoa(String.fromCharCode(...bytes));
}

function bytesToHex(bytes) {
  return Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join(
    "",
  );
}

function concatBytes(...parts) {
  const result = new Uint8Array(
    parts.reduce((total, part) => total + part.length, 0),
  );
  let offset = 0;
  for (const part of parts) {
    result.set(part, offset);
    offset += part.length;
  }
  return result;
}

export async function sha256Bytes(value) {
  const bytes =
    typeof value === "string" ? new TextEncoder().encode(value) : value;
  return new Uint8Array(await crypto.subtle.digest("SHA-256", bytes));
}

function derInteger(bytes) {
  let first = 0;
  while (first < bytes.length - 1 && bytes[first] === 0) {
    first += 1;
  }
  let value = bytes.slice(first);
  if ((value[0] & 0x80) !== 0) {
    value = concatBytes(Uint8Array.of(0), value);
  }
  return concatBytes(Uint8Array.of(0x02, value.length), value);
}

function ecdsaSignatureDER(signature) {
  // WebCrypto ECDSA always yields raw r||s (64 bytes for P-256). Never sniff
  // for DER by leading byte: r starts with 0x30 one time in 256, and the
  // verifier then rejects the raw bytes as malformed DER (2026-09-12 flake).
  if (signature.length !== 64) {
    throw new Error(`unexpected ECDSA signature length ${signature.length}`);
  }
  const r = derInteger(signature.slice(0, 32));
  const s = derInteger(signature.slice(32));
  return concatBytes(Uint8Array.of(0x30, r.length + s.length), r, s);
}

function cborByteString(bytes) {
  if (bytes.length >= 256) {
    throw new Error(
      "test CBOR helper only supports byte strings under 256 bytes",
    );
  }
  return concatBytes(Uint8Array.of(0x58, bytes.length), bytes);
}

function cborText(value) {
  const bytes = new TextEncoder().encode(value);
  if (bytes.length > 23) {
    throw new Error("test CBOR helper only supports short text keys");
  }
  return concatBytes(Uint8Array.of(0x60 + bytes.length), bytes);
}

export async function makeSyntheticAppAttestIdentity() {
  const keys = await crypto.subtle.generateKey(
    { name: "ECDSA", namedCurve: "P-256" },
    true,
    ["sign", "verify"],
  );
  const publicKey = new Uint8Array(
    await crypto.subtle.exportKey("raw", keys.publicKey),
  );
  return {
    installID: `synthetic-${crypto.randomUUID()}`,
    keyID: bytesToBase64(await sha256Bytes(publicKey)),
    privateKey: keys.privateKey,
    publicKey,
    counter: 0,
  };
}

export async function seedSyntheticKey(identity) {
  const now = Math.floor(Date.now() / 1000);
  await env.TRANSCRIPTION_DB.prepare(
    "INSERT INTO app_attest_keys \
     (install_id, key_id, public_key, sign_counter, app_id, environment, created_at, last_used_at) \
     VALUES (?1, ?2, ?3, 0, ?4, ?5, ?6, ?6)",
  )
    .bind(
      identity.installID,
      identity.keyID,
      identity.publicKey.buffer,
      appID(),
      env.APP_ATTEST_ENVIRONMENT,
      now,
    )
    .run();
}

export async function syntheticAssertion(identity, path, payload, counter) {
  const payloadHash = bytesToHex(await sha256Bytes(payload));
  const clientDataHash = await sha256Bytes(`POST\n${path}\n${payloadHash}`);
  const authenticatorData = new Uint8Array(37);
  authenticatorData.set(await sha256Bytes(appID()), 0);
  new DataView(authenticatorData.buffer).setUint32(33, counter, false);
  const nonce = await sha256Bytes(
    concatBytes(authenticatorData, clientDataHash),
  );
  const rawSignature = new Uint8Array(
    await crypto.subtle.sign(
      { name: "ECDSA", hash: "SHA-256" },
      identity.privateKey,
      nonce,
    ),
  );
  const signature = ecdsaSignatureDER(rawSignature);
  const cbor = concatBytes(
    Uint8Array.of(0xa2),
    cborText("signature"),
    cborByteString(signature),
    cborText("authenticatorData"),
    cborByteString(authenticatorData),
  );
  return bytesToBase64(cbor);
}

/// Envelope POST as the given seeded identity, auto-incrementing its sign
/// counter (each identity's counter is process-local test state).
export async function postEnvelope(identity, path, payloadObject, fetcher = SELF.fetch.bind(SELF)) {
  const payload = JSON.stringify(payloadObject);
  identity.counter += 1;
  const assertion = await syntheticAssertion(
    identity,
    path,
    payload,
    identity.counter,
  );
  return fetcher(`${BASE}${path}`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      install_id: identity.installID,
      key_id: identity.keyID,
      payload,
      assertion,
    }),
  });
}
