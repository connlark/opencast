import { env, createExecutionContext } from 'cloudflare:test';
import { expect, it } from 'vitest';
import worker from '../build/index.js';
import { makeSyntheticAppAttestIdentity, seedSyntheticKey, postEnvelope } from './support.mjs';

export const DELETE_PATH = '/v1/install/delete';
const TABLES = ['app_attest_keys', 'app_attest_challenges', 'install_account_links'];
export async function seedInstall() {
  const identity = await makeSyntheticAppAttestIdentity();
  await seedSyntheticKey(identity);
  const extra = await makeSyntheticAppAttestIdentity();
  extra.installID = identity.installID;
  await seedSyntheticKey(extra);
  await env.TRANSCRIPT_ANALYSIS_DB.batch([
    env.TRANSCRIPT_ANALYSIS_DB.prepare('INSERT INTO app_attest_challenges (challenge_id, challenge_hash, purpose, install_id, created_at, expires_at) VALUES (?1, ?1, ?2, ?3, 1, 2)').bind(crypto.randomUUID(), 'register', identity.installID),
    env.TRANSCRIPT_ANALYSIS_DB.prepare('INSERT INTO install_account_links (install_id, account_id, created_at, updated_at) VALUES (?1, ?2, 1, 1)').bind(identity.installID, 'shared-account'),
  ]);
  return identity;
}
export async function counts(identity) {
  return Promise.all(TABLES.map(async (table) => (await env.TRANSCRIPT_ANALYSIS_DB.prepare(
    `SELECT COUNT(*) AS n FROM ${table} WHERE install_id = ?1`,
  ).bind(identity.installID).first()).n));
}

export function installDeleteTests() {
  it('deletes all keys and local links for only the authenticated install', async () => {
    const a = await seedInstall();
    const b = await seedInstall();
    const response = await postEnvelope(a, DELETE_PATH, {});
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ message: 'deleted' });
    expect(await counts(a)).toEqual([0, 0, 0]);
    expect(await counts(b)).toEqual([2, 1, 1]);
    for (const path of ['/v1/transcript-analysis/account/bootstrap', DELETE_PATH]) {
      const old = await postEnvelope(a, path, {});
      expect(old.status).toBe(401);
      expect(await old.json()).toEqual({ error: 'unknown_key' });
    }
    // A replacement D1 fixture, not an Apple registration round trip.
    const replacement = await makeSyntheticAppAttestIdentity();
    replacement.installID = a.installID;
    await seedSyntheticKey(replacement);
    expect((await postEnvelope(replacement, DELETE_PATH, {})).status).toBe(200);
  });

  it('accepts an authenticated delete with feature admission disabled', async () => {
    const a = await seedInstall();
    const disabled = new worker(createExecutionContext(), {
      ...env, PUBLIC_TRANSCRIPT_ANALYSIS_ENABLED: 'false',
    });
    const fetcher = (url, init) => disabled.fetch(new Request(url, init));
    expect((await postEnvelope(a, DELETE_PATH, {}, fetcher)).status).toBe(200);
    expect(await counts(a)).toEqual([0, 0, 0]);
  });
}
