import { env, createExecutionContext } from 'cloudflare:test';
import { expect, it } from 'vitest';
import worker from '../build/index.js';
import { makeSyntheticAppAttestIdentity, seedSyntheticKey, postEnvelope } from './app-attest-support.mjs';

export const DELETE_PATH = '/v1/install/delete';
const TABLES = ['app_attest_keys', 'app_attest_challenges', 'install_account_links', 'accounts'];
export async function seedInstall() {
  const identity = await makeSyntheticAppAttestIdentity();
  await seedSyntheticKey(identity);
  const extra = await makeSyntheticAppAttestIdentity();
  extra.installID = identity.installID;
  await seedSyntheticKey(extra);
  await env.TRANSCRIPTION_DB.batch([
    env.TRANSCRIPTION_DB.prepare('INSERT INTO app_attest_challenges (challenge_id, challenge_hash, purpose, install_id, created_at, expires_at) VALUES (?1, ?1, ?2, ?3, 1, 2)').bind(crypto.randomUUID(), 'register', identity.installID),
    env.TRANSCRIPTION_DB.prepare('INSERT INTO install_account_links (install_id, account_id, created_at, updated_at) VALUES (?1, ?2, 1, 1)').bind(identity.installID, 'shared-account'),
  ]);
  identity.accountID = crypto.randomUUID();
  identity.jobID = crypto.randomUUID();
  await env.TRANSCRIPTION_DB.batch([
    env.TRANSCRIPTION_DB.prepare('INSERT INTO accounts (account_id, install_id, created_at, updated_at) VALUES (?1, ?2, 1, 1)').bind(identity.accountID, identity.installID),
    env.TRANSCRIPTION_DB.prepare('INSERT INTO jobs (job_id, account_id, client_request_id, episode_id, state, created_at, updated_at) VALUES (?1, ?2, ?1, ?1, ?3, 1, 1)').bind(identity.jobID, identity.accountID, 'completed'),
  ]);
  return identity;
}
export async function counts(identity) {
  return Promise.all(TABLES.map(async (table) => (await env.TRANSCRIPTION_DB.prepare(
    `SELECT COUNT(*) AS n FROM ${table} WHERE install_id = ?1`,
  ).bind(identity.installID).first()).n));
}

export function installDeleteTests() {
  it('rejects bearer authentication even alongside a valid envelope', async () => {
    const a = await seedInstall();
    const fetcher = (url, init) => new worker(createExecutionContext(), env).fetch(new Request(url, {
      ...init, headers: { ...init.headers, authorization: 'Bearer integration-test-bearer-token' },
    }));
    const response = await postEnvelope(a, DELETE_PATH, {}, fetcher);
    expect(response.status).toBe(401);
    expect(await response.json()).toEqual({ error: 'missing_assertion' });
    expect(await counts(a)).toEqual([2, 1, 1, 1]);
  });
  it('deletes all keys and local links for only the authenticated install', async () => {
    const a = await seedInstall();
    const b = await seedInstall();
    const response = await postEnvelope(a, DELETE_PATH, {});
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ message: 'deleted' });
    expect(await counts(a)).toEqual([0, 0, 0, 0]);
    expect(await counts(b)).toEqual([2, 1, 1, 1]);
    for (const identity of [a, b]) {
      expect(await env.TRANSCRIPTION_DB.prepare('SELECT account_id FROM jobs WHERE job_id = ?1').bind(identity.jobID).first()).toEqual({ account_id: identity.accountID });
    }
    for (const path of ['/v1/remote-transcription/jobs', DELETE_PATH]) {
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
      ...env, PUBLIC_REMOTE_TRANSCRIPTION_ENABLED: 'false',
    });
    const fetcher = (url, init) => disabled.fetch(new Request(url, init));
    expect((await postEnvelope(a, DELETE_PATH, {}, fetcher)).status).toBe(200);
    expect(await counts(a)).toEqual([0, 0, 0, 0]);
  });
}
