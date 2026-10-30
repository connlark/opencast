import { describe } from 'vitest';
import { installDeleteTests } from './install-delete-support.mjs';
describe('install deregistration', installDeleteTests);

import { env, createExecutionContext } from 'cloudflare:test';
import { expect, it } from 'vitest';
import worker from '../build/index.js';
import { seedInstall, counts, DELETE_PATH } from './install-delete-support.mjs';
import { postEnvelope } from './app-attest-support.mjs';

it('does not recreate a dev account when a paused bootstrap resumes after deletion', async () => {
  const identity = await seedInstall();
  await env.TRANSCRIPTION_DB.prepare('DELETE FROM accounts WHERE install_id = ?1').bind(identity.installID).run();
  const paused = Promise.withResolvers();
  const resume = Promise.withResolvers();
  const gateway = new worker(createExecutionContext(), {
    ...env,
    TRANSCRIPTION_DB: {
      constructor: env.TRANSCRIPTION_DB.constructor,
      prepare(sql) {
        const statement = env.TRANSCRIPTION_DB.prepare(sql);
        if (!sql.startsWith('INSERT INTO accounts ')) return statement;
        return {
          bind(...args) {
            const bound = statement.bind(...args);
            return {
              async run() {
                paused.resolve();
                await resume.promise;
                return bound.run();
              },
            };
          },
        };
      },
    },
  });
  const bootstrap = postEnvelope(identity, '/v1/remote-transcription/account/bootstrap', {
    schema_version: 1,
  }, (url, init) => gateway.fetch(new Request(url, init)));
  try {
    await Promise.race([paused.promise, bootstrap.then(response => {
      throw new Error(`bootstrap completed before the pause: ${response.status}`);
    })]);
    expect((await postEnvelope(identity, DELETE_PATH, {})).status).toBe(200);
  } finally {
    resume.resolve();
  }
  const response = await bootstrap;
  expect(response.status).toBe(401);
  expect(await response.json()).toEqual({ error: 'unknown_key' });
  expect(await counts(identity)).toEqual([0, 0, 0, 0]);
});
