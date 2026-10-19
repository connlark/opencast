// The shipped prod-staging configuration on both packaged builds:
// its vars select PostgreSQL through DB and read no other storage binding,
// with DB missing the first storage call fails closed, and without
// STORAGE_AUTHORITY, or with any value but postgres (d1 included), every
// request is refused before any storage binding is read. Binding getters
// record which storage binding each request reads.
// The pin is the config's own. A pin that does not parse (a self-hosting
// template's REPLACE_WITH_* placeholder) must fail closed: /identity refuses
// with reason pin and the storage route fails, neither reading DB. The DB
// checks then run under a valid synthetic pin; a parsing pin is used as
// shipped, and the fail-closed check runs on a synthetic placeholder instead.
// The production configuration is read for its storage shape: postgres, DB
// and no D1 binding.
// DB points at a closed local port, so this proves selection, not a live
// database; a dry run proves packaging, not either.
// OPENCAST_POSTGRES_BUILD and OPENCAST_POLLING_POSTGRES_BUILD are the output
// directories of `worker-build --release` run in
// Server/NotificationsWorker and Server/FeedPollingWorker.
import assert from 'node:assert/strict';
import { fileURLToPath } from 'node:url';
import { Miniflare, convertV4MiniflareOptions } from 'miniflare';
import { unstable_readConfig } from 'wrangler';

const builds = { notifications: process.env.OPENCAST_POSTGRES_BUILD, polling: process.env.OPENCAST_POLLING_POSTGRES_BUILD };
for (const [name, build] of Object.entries(builds)) assert.ok(build, `${name}: set the build directory`);
const server = new URL('../../', import.meta.url);
const read = (file, env) => unstable_readConfig({ config: fileURLToPath(new URL(file, server)), env }, { hideWarnings: true });
// database_identity.rs's pin grammar; anything else refuses with reason pin.
const PIN = /^v1;[a-z0-9_-]+;postgres;pg:[a-z0-9_]+(:[0-9]+)?$/;
const SYNTHETIC_PIN = 'v1;prod-staging;postgres;pg:opencast_staging:1';
const PLACEHOLDER_PIN = 'v1;prod-staging;postgres;pg:REPLACE_WITH_DATABASE_NAME:REPLACE_WITH_SYSTEM_IDENTIFIER';
const workers = {
  notifications: { file: 'NotificationsWorker/wrangler.toml', capability: { NOTIFICATION_CAPABILITY: 'feed_control' }, storage: '/inspect' },
  polling: { file: 'FeedPollingWorker/wrangler.jsonc', capability: { POLLING_CAPABILITY: 'private' }, storage: '/stats' },
};
const entry = capability => `import {WorkerEntrypoint} from 'cloudflare:workers';import RustWorker from './index.js';
let lines=[];
for(const level of ['log','warn','error']){const native=console[level].bind(console);console[level]=(...args)=>{lines.push(args.map(String).join(' '));native(...args);};}
export default class extends WorkerEntrypoint { async fetch(request) {
 const input=await request.json(),touched=[];lines=[];
 const env={...this.env,...${JSON.stringify(capability)},...input.set};
 for(const name of input.remove)delete env[name];
 if('DB' in env){const value=env.DB;Object.defineProperty(env,'DB',{enumerable:true,get(){touched.push('DB');return value;}});}
 const r=await new RustWorker(this.ctx,env).fetch(new Request('https://local.invalid'+input.path,{method:'POST',body:JSON.stringify(input.value)}));
 return Response.json({status:r.status,body:await r.text(),log:lines.join('\\n'),touched:[...new Set(touched)]});
} }`;
let passed = 0;
const check = async (name, fn) => { await fn(); passed++; console.log(`PASS ${name}`); };
for (const [name, worker] of Object.entries(workers)) {
  const config = read(worker.file, 'prod-staging');
  const { vars, compatibility_date: compatibilityDate, compatibility_flags: compatibilityFlags } = config;
  assert.deepEqual([vars.STORAGE_AUTHORITY, config.hyperdrive.map(h => h.binding), config.d1_databases?.length ?? 0], ['postgres', ['DB'], 0], `${name}: the shipped prod-staging shape`);
  const production = read(worker.file, 'production');
  assert.deepEqual([production.vars.STORAGE_AUTHORITY, production.hyperdrive.map(h => h.binding), production.d1_databases?.length ?? 0], ['postgres', ['DB'], 0], `${name}: the shipped production shape`);
  console.log(`${name}: prod-staging and production: STORAGE_AUTHORITY postgres, hyperdrive DB, no d1_databases`);
  for (const env of ['prod-staging', 'production'])
    assert.equal(typeof read(worker.file, env).vars.STORAGE_IDENTITY, 'string', `${name}: ${env} declares STORAGE_IDENTITY`);
  const shippedPin = vars.STORAGE_IDENTITY, parses = PIN.test(shippedPin);
  const pin = parses ? shippedPin : SYNTHETIC_PIN, placeholder = parses ? PLACEHOLDER_PIN : shippedPin;
  console.log(`${name}: the shipped pin ${parses ? 'parses' : 'is an unparseable placeholder'}; the DB checks run on ${parses ? 'it' : 'a synthetic pin'}`);
  const build = builds[name];
  const mf = new Miniflare(convertV4MiniflareOptions({ cf: false, workers: [{ name, modulesRoot: build,
    modules: [{ type: 'ESModule', path: build + '/selection-entry.mjs', contents: entry(worker.capability) }, { type: 'ESModule', path: build + '/index.js' }, { type: 'CompiledWasm', path: build + '/index_bg.wasm' }],
    compatibilityDate, compatibilityFlags, bindings: vars,
    hyperdrives: { DB: 'postgres://selection:selection@127.0.0.1:9/opencast_staging' },
    outboundService: () => { throw Error('external networking forbidden'); } }] }));
  // `set` overrides vars before `remove` deletes bindings.
  const call = (path, remove = [], set = {}, value = { feed_id: 'a'.repeat(64), expected_epoch: 1 }) =>
    mf.dispatchFetch('https://fixture.invalid/', { method: 'POST', body: JSON.stringify({ path, remove, set, value }) }).then(r => r.json());
  const pinned = { STORAGE_IDENTITY: pin };
  try {
    await check(`${name}: the shipped vars select PostgreSQL through DB and read no other storage binding`, async () => {
      const identity = await call('/identity', [], pinned);
      assert.equal(identity.status, 200);
      const report = JSON.parse(identity.body);
      // Database: the connection through DB was attempted and refused.
      assert.deepEqual([report.gated, report.backend, report.environment, report.verdict, report.reason, report.fence], [true, 'postgres', 'prod-staging', 'unreadable', 'Database', null]);
      assert.deepEqual(identity.touched, ['DB']);
      const storage = await call(worker.storage, [], pinned);
      assert.equal(storage.status, 500, 'no database answers on the closed port');
      assert.deepEqual(storage.touched, ['DB']);
    });
    await check(`${name}: with DB missing the first storage call fails closed`, async () => {
      const identity = await call('/identity', ['DB'], pinned);
      const report = JSON.parse(identity.body);
      // Configuration: there is no DB binding to connect through.
      assert.deepEqual([report.backend, report.verdict, report.reason], ['postgres', 'unreadable', 'Configuration']);
      assert.deepEqual(identity.touched, []);
      const storage = await call(worker.storage, ['DB'], pinned);
      assert.equal(storage.status, 500); assert.deepEqual(storage.touched, []);
    });
    await check(`${name}: without STORAGE_AUTHORITY, or with d1, every request is refused before any storage binding, pinned or not`, async () => {
      // The selection error surfaces through the fetch glue: one logged line
      // with the code, a bare 500, and no identity report.
      for (const [authority, code, set] of [['absent', 'storage_authority_missing', {}], ['d1', 'invalid_storage_authority', { STORAGE_AUTHORITY: 'd1' }]])
        for (const [label, remove] of [['pinned', authority === 'absent' ? ['STORAGE_AUTHORITY'] : []], ['unpinned', [...(authority === 'absent' ? ['STORAGE_AUTHORITY'] : []), 'STORAGE_IDENTITY']]])
          for (const path of ['/identity', worker.storage]) {
            const refused = await call(path, remove, { ...pinned, ...set }), at = `${authority} ${label} ${path}: ${JSON.stringify(refused)}`;
            assert.deepEqual([refused.status, refused.body, refused.touched], [500, 'INTERNAL SERVER ERROR', []], at);
            assert.equal(refused.log.split('\n').filter(line => line.includes(code)).length, 1, at);
            assert.doesNotMatch(refused.log, /storage_identity/, at);
          }
    });
    await check(`${name}: an unparseable pin fails closed before any storage binding`, async () => {
      const set = { STORAGE_IDENTITY: placeholder };
      const identity = await call('/identity', [], set);
      assert.equal(identity.status, 200);
      const report = JSON.parse(identity.body);
      assert.deepEqual([report.backend, report.verdict, report.reason, report.database], ['postgres', 'refused', 'pin', null]);
      assert.deepEqual(identity.touched, []);
      const storage = await call(worker.storage, [], set);
      assert.equal(storage.status, 500); assert.match(storage.log, /_Identity_NotApplicable/); assert.deepEqual(storage.touched, []);
    });
  } finally { await mf.dispose(); }
}
console.log(`${passed} storage selection checks passed`);
