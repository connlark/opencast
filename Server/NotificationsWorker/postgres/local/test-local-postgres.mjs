// The local PostgreSQL topology's own test, against a topology that is up:
//   Server/NotificationsWorker/postgres/local/local-postgres.sh up
//   node Server/NotificationsWorker/postgres/local/test-local-postgres.mjs
// It drives only the script's subcommands, so it runs unchanged on either psql
// transport (OPENCAST_PG_PSQL=container|host), and it reads every posture back
// from the server instead of inferring it from the install files. Its clones are
// opencast_t_topotest_<run>_<n>, dropped at the end; it restores what it alters.
// It needs exclusive use of the topology: it alters shared state that clones do
// not isolate (the local roles' settings, the install marker's provenance columns
// and its recorded image), so never run it beside another run of it, `install`,
// `reset`, `prune` or anything relying on the local roles or the marker. Suites
// that only clone the template need no such serialization.
// The shipped Worker's /identity reads (direct, and through the proxy) are
// tests/postgres/test-proxy.mjs's authentication gate.
// It inspects the container through the runtime the script selects (its
// `runtime`), never a second rule. On the container transport it also drives the
// script's container half, and this test's own provenance read and runtime
// selection, through strict podman and docker stubs (every operation recorded,
// anything not allowed refused with 64, `exec` passed to the real runtime so the
// SQL half still reaches this topology), all under /bin/bash.
import assert from 'node:assert/strict';
import { execFileSync, spawn, spawnSync } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import { chmodSync, cpSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { basename, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { isDeepStrictEqual } from 'node:util';

const script = fileURLToPath(new URL('./local-postgres.sh', import.meta.url));
const source = process.env.OPENCAST_PG_SOURCE ?? fileURLToPath(new URL('../', import.meta.url));
const passwords = ['opencast-local-postgres', 'opencast-local-owner', 'opencast-local-runtime', 'opencast-local-reader'];
const [owner, runtime, reader] = ['opencast_local_owner', 'opencast_local_runtime', 'opencast_local_reader'];
const gate = 'SELECT 1/COUNT(*) AS guard FROM (SELECT id FROM n_poll_dispatch WHERE id=1 FOR UPDATE) AS gate;';
// This process's environment with env laid over it; an undefined value removes the variable.
const withEnv = env => Object.fromEntries(Object.entries({ ...process.env, ...env }).filter(([, v]) => v !== undefined));
const run = (args, { input = '', env = {}, bash = false } = {}) => new Promise((resolve, reject) => {
  const started = performance.now(), child = bash ? spawn('/bin/bash', [script, ...args], { env: withEnv(env) })
    : spawn(script, args, { env: withEnv(env) });
  let stdout = '', stderr = '';
  child.stdout.on('data', chunk => { stdout += chunk; });
  child.stderr.on('data', chunk => { stderr += chunk; });
  child.stdin.on('error', () => {}); // a subcommand that never reads stdin
  child.on('error', reject);
  child.on('close', code => resolve({ code, stdout, stderr, started, ended: performance.now() }));
  child.stdin.end(input);
});
// One psql session through `sql`; its rows as `|`-joined lines.
const sql = async (database, text, role) => {
  const r = await run(['sql', database, ...(role ? [role] : [])], { input: text });
  assert.equal(r.code, 0, `sql ${database} as ${role ?? 'postgres'}: ${r.stderr.trim()}`);
  return r.stdout === '' ? [] : r.stdout.replace(/\n$/, '').split('\n');
};
// The role must be refused, by SQLSTATE and message.
const refused = async (database, role, text, pattern) => {
  const r = await run(['sql', database, role], { input: `\\set VERBOSITY verbose\n${text}\n` });
  assert.notEqual(r.code, 0, `${role} on ${database} must be refused: ${text}`);
  assert.match(r.stderr, pattern);
};
// Everything install may touch, in one session: the marker, the roles (verifier
// included) and the two databases' identities.
const snapshot = () => sql('postgres', `
SELECT template, files_sha256, installed_at, server_version, image, image_requested, image_resolved, platform
  FROM public.opencast_local_install ORDER BY template;
SELECT a.oid, a.rolname, a.rolpassword, a.rolinherit, a.rolconnlimit, r.rolconfig FROM pg_authid a
  JOIN pg_roles r ON r.oid = a.oid WHERE a.rolname LIKE 'opencast\\_local\\_%' ORDER BY a.rolname;
SELECT datname, oid, datistemplate, datallowconn FROM pg_database WHERE datname IN ('opencast_template', 'opencast_dev') ORDER BY 1;`);
const noPasswords = r => { for (const p of passwords) assert.ok(!(r.stdout + r.stderr).includes(p), 'output must not carry a password'); };
const tag = randomBytes(4).toString('hex'), clones = [];
const clone = async () => {
  const name = `opencast_t_topotest_${tag}_${clones.length + 1}`;
  clones.push(name);
  return { name, ...await run(['sql', 'postgres'], { input: `CREATE DATABASE ${name} TEMPLATE opencast_template OWNER ${owner};` }) };
};
const INDEX = 'sha256:74935e72241653ca55e0414067e6d8763aceb8a810eb51b452253ec3dcfc4336';
// The 18.6 index's children for the two platforms a contributor or runner runs.
const CHILD = { 'linux/arm64': 'sha256:a63b24165ea0eacced7585766d790ac08bbaefe10a1841f87783a4505d29a69c',
  'linux/amd64': 'sha256:885953109528ad3dfc90362b1a6f50a78620b5315be19f187753d267e484dc5b' };
// The container CLI the script selects (OPENCAST_CONTAINER_RUNTIME, else podman,
// else docker on PATH), read from the script, as an absolute path.
const selectedRuntime = async (env = {}) => {
  const r = await run(['runtime'], { env });
  assert.equal(r.code, 0, r.stderr);
  return execFileSync('/bin/sh', ['-c', 'command -v "$1"', 'sh', r.stdout.trim()], { encoding: 'utf8', env: withEnv(env) }).trim();
};
// What the container runs, read through the runtime without the script and
// reduced by the marker's rule: Podman records the container's own digest;
// Docker has none, so the image's RepoDigests less the index must leave one child.
const runtimeDigest = (cli, env = {}) => {
  const kind = basename(cli), environment = withEnv(env), name = environment.OPENCAST_PG_CONTAINER ?? 'opencast-postgres-local';
  assert.ok(['podman', 'docker'].includes(kind), `a podman or docker CLI, not ${cli}`);
  const inspect = (...args) => execFileSync(cli, args, { encoding: 'utf8', env: environment }).trim();
  if (kind === 'podman') return inspect('container', 'inspect', '--format', '{{.ImageDigest}}', name);
  const listed = JSON.parse(inspect('image', 'inspect', '--format', '{{json .RepoDigests}}',
    inspect('container', 'inspect', '--format', '{{.Image}}', name))) ?? [];
  const children = [...new Set(listed.map(r => r.slice(r.lastIndexOf('@') + 1)))].filter(d => /^sha256:[0-9a-f]{64}$/.test(d) && d !== INDEX);
  assert.equal(children.length, 1, `docker RepoDigests less the index must name one child, not ${JSON.stringify(listed)}`);
  return children[0];
};
// The marker against the runtime's own answer, and for the 18.6 index the child
// of the marker's platform.
const provenanceAgrees = (marker, cli, env = {}) => {
  assert.equal(marker.image_resolved, runtimeDigest(cli, env), 'the digest this test reads through the runtime');
  if (marker.image_requested !== `docker.io/library/postgres@${INDEX}`) {
    console.log(`SKIP the index children: OPENCAST_PG_IMAGE is ${marker.image_requested}`);
    return;
  }
  assert.ok(marker.platform in CHILD, `a platform of the index's two tested children, not ${marker.platform}`);
  assert.equal(marker.image_resolved, CHILD[marker.platform]);
};
const stamp = () => new Date().toISOString();
const markerRow = async () => (await sql('postgres', 'SELECT row_to_json(m)::text FROM public.opencast_local_install m;'))[0];
// The marker's columns as the catalog lists them, in order: name, type, NOT NULL, default.
const markerColumns = () => sql('postgres', `SELECT a.attname || '|' || format_type(a.atttypid, a.atttypmod) || '|' || a.attnotnull
    || '|' || coalesce(pg_get_expr(d.adbin, d.adrelid), '')
  FROM pg_attribute a LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
  WHERE a.attrelid = 'public.opencast_local_install'::regclass AND a.attnum > 0 AND NOT a.attisdropped ORDER BY a.attnum;`);
// What install never moves: the marker's identity and every non-transient database's.
const identity = () => sql('postgres', `SELECT row_to_json(t)::text FROM (SELECT template, files_sha256, installed_at FROM public.opencast_local_install) t;
SELECT datname||'|'||oid||'|'||datistemplate||'|'||datallowconn FROM pg_database WHERE datname NOT LIKE 'opencast\\_t\\_%' AND datname LIKE 'opencast\\_%' ORDER BY 1;`);
const PROVENANCE = ['image_requested', 'image_resolved', 'platform'];
// A saved marker put back by this test's own SQL, never through install: each
// saved provenance column re-added with its saved type where absent, then the
// saved values. Nothing is written when the marker already matches.
const restoreMarker = async saved => {
  if (await markerRow() === saved.row && isDeepStrictEqual(await markerColumns(), saved.columns)) return false;
  const kept = saved.columns.map(c => c.split('|')).filter(([name]) => PROVENANCE.includes(name));
  await sql('postgres', `ALTER TABLE public.opencast_local_install ${kept.map(([name, type]) => `ADD COLUMN IF NOT EXISTS ${name} ${type}`).join(', ')};
UPDATE public.opencast_local_install m SET ${kept.map(([name]) => `${name} = s.${name}`).join(', ')}
  FROM json_populate_record(NULL::public.opencast_local_install, $saved$${saved.row}$saved$) s WHERE m.template = s.template;`);
  assert.equal(await markerRow(), saved.row, 'the saved marker row is back');
  assert.deepEqual(await markerColumns(), saved.columns, 'the saved marker columns are back');
  return true;
};
// The old-marker upgrade on the shared marker: the provenance columns dropped,
// then install (or a stand-in for it) must bring back the whole row and its
// columns. Whatever install does, restoreMarker puts the saved marker back after
// it; install's failure stays the failure, and a restore failure is reported beside it.
const markerUpgrade = async (install = () => run(['install'])) => {
  const saved = { row: await markerRow(), columns: await markerColumns() }, started = stamp();
  let failure;
  try {
    await sql('postgres', `ALTER TABLE public.opencast_local_install ${PROVENANCE.map(c => `DROP COLUMN IF EXISTS ${c}`).join(', ')};`);
    const first = await install();
    assert.equal(first.code, 0, first.stderr);
    assert.doesNotMatch(first.stderr, /building/);
    assert.equal(await markerRow(), saved.row, 'install restores the whole marker row');
    assert.deepEqual(await markerColumns(), saved.columns, 'install restores the marker columns');
  } catch (error) { failure = error; }
  try {
    if (await restoreMarker(saved)) console.log(`REPORT marker restored by the test's own SQL after: ${String(failure?.message).split('\n')[0]}`);
  } catch (error) {
    if (!failure) throw error;
    console.error(`CLEANUP FAILED: the marker was not restored after the failure that follows: ${error.message}`);
  } finally {
    console.log(`REPORT marker flip (old five-column marker): ${started} to ${stamp()}`);
  }
  if (failure) throw failure;
};

let passed = 0, fresh;
const check = async (name, fn) => { await fn(); passed++; console.log(`PASS ${name}`); };
try {
  await check('status: ready, marked, and opencast_template is a template', async () => {
    const r = await run(['status']);
    assert.equal(r.code, 0, r.stderr);
    assert.match(r.stdout, /^ready: opencast_template sha256 [0-9a-f]{64}, matching /);
  });
  await check('status fails closed when the server is unreachable', async () => {
    const r = await run(['status'], { env: { OPENCAST_PG_CONTAINER: `opencast-postgres-absent-${tag}`, OPENCAST_PG_PORT: '9', PGPORT: '9' } });
    assert.equal(r.code, 1);
    assert.match(r.stderr, /not ready/);
  });
  const before = await snapshot();
  await check('install is idempotent: the marker, the roles and the databases are unchanged', async () => {
    const r = await run(['install']);
    assert.equal(r.code, 0, r.stderr);
    assert.doesNotMatch(r.stderr, /building/);
    noPasswords(r);
    assert.deepEqual(await snapshot(), before);
  });
  await check('stale-hash refusal through OPENCAST_PG_SOURCE on a scratch copy with one byte changed', async () => {
    const scratch = mkdtempSync(join(tmpdir(), 'opencast-topotest-'));
    try {
      cpSync(join(source, 'migrations'), join(scratch, 'migrations'), { recursive: true });
      for (const f of readdirSync(source)) if (f.endsWith('.sql')) cpSync(join(source, f), join(scratch, f));
      const same = await run(['install'], { env: { OPENCAST_PG_SOURCE: scratch } });
      assert.equal(same.code, 0, `an identical copy is current: ${same.stderr}`);
      const file = join(scratch, 'runtime-grants-integration.sql'), bytes = readFileSync(file);
      bytes[bytes.findIndex(b => b >= 0x61 && b <= 0x7a)] ^= 0x20; // one letter's case, in the leading comment
      writeFileSync(file, bytes);
      const stale = await run(['install'], { env: { OPENCAST_PG_SOURCE: scratch } });
      assert.equal(stale.code, 1);
      assert.match(stale.stderr, /template is stale: run reset/);
      const status = await run(['status'], { env: { OPENCAST_PG_SOURCE: scratch } });
      assert.match(status.stdout, /install will refuse: run reset/);
    } finally { rmSync(scratch, { recursive: true, force: true }); }
    assert.deepEqual(await snapshot(), before);
  });
  await check('opencast_template refuses every connection and clones while ALLOW_CONNECTIONS is false', async () => {
    assert.deepEqual(await sql('postgres', "SELECT datistemplate, datallowconn FROM pg_database WHERE datname = 'opencast_template';"), ['t|f']);
    for (const role of ['postgres', owner]) {
      const r = await run(['sql', 'opencast_template', role], { input: 'SELECT 1;' });
      assert.notEqual(r.code, 0);
      assert.match(r.stderr, /database "opencast_template" is not currently accepting connections/);
    }
    const r = await clone();
    assert.equal(r.code, 0, r.stderr);
    fresh = r.name;
  });
  await check('search_path: on the fresh clone the owner reads and gate-writes unqualified; search_path comes from the ROLE', async () => {
    // A per-database role setting is not carried by CREATE DATABASE … TEMPLATE; the role-level one is.
    assert.deepEqual(await sql('postgres', `SELECT count(*) FROM pg_db_role_setting s JOIN pg_database d ON d.oid = s.setdatabase WHERE d.datname = '${fresh}';`), ['0']);
    assert.deepEqual(await sql(fresh, 'SELECT COUNT(*) FROM n_feed;', owner), ['0']);
    assert.deepEqual(await sql(fresh, `BEGIN;\n${gate}\nUPDATE n_control SET enabled=1 WHERE name='cleanup';\nCOMMIT;\nSELECT enabled FROM n_control WHERE name='cleanup';`, owner), ['1', '1']);
    for (const role of [owner, runtime]) assert.deepEqual(await sql(fresh, 'SHOW search_path;', role), ['opencast, pg_catalog'], role);
  });
  await check('runtime role on the clone: no CREATE in opencast or public, no TRUNCATE, the gate SELECT … FOR UPDATE', async () => {
    await refused(fresh, runtime, 'CREATE TABLE opencast.topotest_probe(x int);', /42501: permission denied for schema opencast/);
    await refused(fresh, runtime, 'CREATE TABLE public.topotest_probe(x int);', /42501: permission denied for schema public/);
    await refused(fresh, runtime, 'TRUNCATE n_feed;', /42501: permission denied for table n_feed/);
    assert.deepEqual(await sql(fresh, `BEGIN;\n${gate}\nROLLBACK;`, runtime), ['1']);
  });
  const shows = ['search_path', 'statement_timeout', 'idle_in_transaction_session_timeout', 'lock_timeout',
    'default_transaction_isolation', 'work_mem', 'password_encryption', 'server_version_num', 'server_version'];
  let serverVersion;
  await check('posture read-backs in runtime, reader and owner sessions, and the locale, provider included, of the template and the clone', async () => {
    const timeouts = { [runtime]: ['5s', '10s', '2s'], [reader]: ['5s', '10s', '2s'], [owner]: ['0', '0', '0'] };
    for (const [role, expected] of Object.entries(timeouts)) {
      const values = await sql(fresh, shows.map(s => `SHOW ${s};`).join('\n'), role);
      serverVersion = values.pop();
      assert.match(serverVersion, /^18\.6( |$)/, role);
      assert.deepEqual(values, ['opencast, pg_catalog', ...expected, 'read committed', '4MB', 'scram-sha-256', '180006'], role);
    }
    assert.deepEqual(await sql('postgres', `SELECT datname, datcollate, datctype, datlocprovider, pg_encoding_to_char(encoding) FROM pg_database
      WHERE datname IN ('opencast_template', '${fresh}') ORDER BY datname = 'opencast_template';`),
    [`${fresh}|en_US.utf8|en_US.utf8|c|UTF8`, 'opencast_template|en_US.utf8|en_US.utf8|c|UTF8']);
  });
  let localRules;
  await check('privileged read-backs: as the superuser, every host rule is SCRAM and every verifier is SCRAM; the owner can read neither', async () => {
    const rules = (await sql('postgres', "SELECT type, auth_method, coalesce(error, '') FROM pg_hba_file_rules ORDER BY rule_number;")).map(l => l.split('|'));
    const host = rules.filter(([type]) => type !== 'local');
    assert.ok(host.length > 0, 'at least one host rule');
    assert.deepEqual([...new Set(host.map(([, method]) => method))], ['scram-sha-256']);
    assert.ok(rules.every(([, , error]) => error === ''), 'pg_hba.conf parses cleanly');
    localRules = rules.filter(([type]) => type === 'local').map(([, method]) => method);
    assert.deepEqual(await sql('postgres', "SELECT rolname, left(rolpassword, 14) FROM pg_authid WHERE rolname LIKE 'opencast\\_local\\_%' OR rolname = 'postgres' ORDER BY 1;"),
      [owner, reader, runtime, 'postgres'].map(r => `${r}|SCRAM-SHA-256$`));
    await refused('postgres', owner, 'SELECT count(*) FROM pg_authid;', /42501: permission denied for table pg_authid/);
    await refused('postgres', owner, 'SELECT count(*) FROM pg_hba_file_rules;', /42501: permission denied for view pg_hba_file_rules/);
  });
  await check('role reconcile: a differing setting or attribute is refused, and once restored install is a no-op again', async () => {
    const baseline = await snapshot(), restore = `ALTER ROLE ${reader} SET lock_timeout = '2s';\nALTER ROLE ${reader} CONNECTION LIMIT -1;`;
    try {
      for (const change of [`ALTER ROLE ${reader} SET lock_timeout = '3s';`, `ALTER ROLE ${reader} CONNECTION LIMIT 3;`]) {
        await sql('postgres', change);
        const r = await run(['install']);
        assert.equal(r.code, 1, change);
        assert.match(r.stderr, new RegExp(`role ${reader} differs: run reset`), change);
        await sql('postgres', restore);
        const again = await run(['install']);
        assert.equal(again.code, 0, again.stderr);
        assert.deepEqual(await snapshot(), baseline, change);
      }
    } finally { await sql('postgres', restore); }
  });
  await check('two concurrent clones from the connection-free template', async () => {
    const pair = await Promise.all([clone(), clone()]);
    for (const c of pair) assert.equal(c.code, 0, c.stderr);
    assert.ok(pair[0].started < pair[1].ended && pair[1].started < pair[0].ended, 'both sessions in flight together');
    for (const c of pair) assert.deepEqual(await sql(c.name, "SELECT count(*) FROM pg_tables WHERE schemaname = 'opencast'; SELECT count(*) FROM n_control;", owner), ['32', '9'], c.name);
  });
  await check('opencast_dev: a connectable clone owned by the owner, open to the runtime role', async () => {
    assert.deepEqual(await sql('postgres', "SELECT pg_get_userbyid(datdba), datistemplate, datallowconn, datcollate, datlocprovider FROM pg_database WHERE datname = 'opencast_dev';"),
      [`${owner}|f|t|en_US.utf8|c`]);
    assert.deepEqual(await sql('opencast_dev', "SELECT count(*) FROM pg_tables WHERE schemaname = 'opencast';", runtime), ['32']);
  });
  const transport = process.env.OPENCAST_PG_PSQL ?? 'container';
  const runtimeCli = transport === 'host' ? null : await selectedRuntime();
  let marker;
  await check('provenance: the marker names the requested image, the image the runtime runs and its platform', async () => {
    marker = JSON.parse(await markerRow());
    if (transport === 'host') {
      // The host transport consults no container runtime: it records the request alone.
      assert.deepEqual([marker.image_resolved, marker.platform], ['unresolved', 'unresolved']);
      return;
    }
    provenanceAgrees(marker, runtimeCli);
  });
  await check('marker upgrade: an old five-column marker gains the provenance columns and nothing else moves', async () => {
    const row = await markerRow(), kept = await identity();
    await markerUpgrade();
    assert.deepEqual(await identity(), kept, 'installed_at, files_sha256, the template and every non-transient database');
    const second = await run(['install']);
    assert.equal(second.code, 0, second.stderr);
    assert.equal(await markerRow(), row, 'a second install leaves the row byte-identical');
  });
  await check('status: the container transport refuses an unresolved provenance; the host transport reports it', async () => {
    if (transport === 'host') {
      const r = await run(['status']);
      assert.equal(r.code, 0, r.stderr);
      assert.match(r.stdout, /\nimage_resolved unresolved\nplatform unresolved\ntransport host\n/);
      return;
    }
    const row = await markerRow();
    let started, refused, ended;
    try {
      started = stamp();
      await sql('postgres', "UPDATE public.opencast_local_install SET image_resolved = 'unresolved: index-not-child';");
      refused = await run(['status']);
    } finally {
      await sql('postgres', `UPDATE public.opencast_local_install SET image_resolved = '${marker.image_resolved}';`);
      ended = stamp();
      console.log(`REPORT marker flip (status gate): ${started} to ${ended}, status the only reader inside`);
    }
    assert.equal(await markerRow(), row, 'the whole marker row restored');
    assert.equal(refused.code, 1);
    assert.match(refused.stderr, /image provenance unresolved: index-not-child/);
    const ok = await run(['status']);
    assert.equal(ok.code, 0, ok.stderr);
  });
  await check('endpoint: inherited libpq settings never redirect the script, each override is named, the container transport stays on loopback', async () => {
    const inherited = { PGHOST: '127.0.0.2', PGHOSTADDR: '127.0.0.2', PGPORT: '55438', PGSERVICE: 'bogus', PGSERVICEFILE: '/nonexistent',
      PGSSLMODE: 'require', PGOPTIONS: '-c work_mem=1MB', PGUSER: 'nobody', PGDATABASE: 'nowhere' };
    const tools = mkdtempSync(join(tmpdir(), 'opencast-topotest-libpq-'));
    try {
      let env = {};
      if (transport !== 'host') {
        // No host psql here: stand-ins record the environment they are given and
        // send the session to this topology's own psql, so the gate still reads.
        const record = `env | grep -E '^PG(HOST|HOSTADDR|PORT|SERVICE|SERVICEFILE|SSLMODE|OPTIONS|USER|DATABASE)=' | sort > "${tools}/$(basename "$0").env"`;
        writeFileSync(join(tools, 'pg_isready'), `#!/bin/sh\n${record}\nexit 0\n`);
        writeFileSync(join(tools, 'psql'), `#!/bin/sh\n${record}\nexec "${runtimeCli}" exec -i --user postgres "${process.env.OPENCAST_PG_CONTAINER ?? 'opencast-postgres-local'}" psql "$@"\n`);
        for (const f of ['pg_isready', 'psql']) chmodSync(join(tools, f), 0o755);
        env = { PATH: `${tools}:${process.env.PATH}`, OPENCAST_PG_PSQL: 'host' };
      }
      const r = await run(['status'], { env: { ...env, ...inherited } });
      assert.equal(r.code, 0, r.stderr);
      for (const name of Object.keys(inherited)) assert.match(r.stderr, new RegExp(`overriding inherited ${name}\\n`), name);
      assert.match(r.stdout, /^ready: opencast_template sha256 [0-9a-f]{64}, matching /);
      if (transport !== 'host') {
        const port = process.env.OPENCAST_PG_PORT ?? '55432', host = process.env.OPENCAST_PG_HOST ?? '127.0.0.1';
        for (const tool of ['pg_isready', 'psql'])
          assert.deepEqual(readFileSync(join(tools, `${tool}.env`), 'utf8').trim().split('\n'), [`PGHOST=${host}`, `PGPORT=${port}`, 'PGSSLMODE=disable'], tool);
      }
    } finally { rmSync(tools, { recursive: true, force: true }); }
    const outside = await run(['status'], { env: { OPENCAST_PG_PSQL: 'container', OPENCAST_PG_HOST: '10.0.0.1' } });
    assert.equal(outside.code, 1);
    assert.match(outside.stderr, /OPENCAST_PG_HOST=10\.0\.0\.1 needs OPENCAST_PG_PSQL=host: the container publishes on 127\.0\.0\.1 only/);
  });
  if (transport === 'host') console.log('SKIP the runtime stubs: their SQL half reaches the topology through the container (host transport here)');
  else await runtimeStubs(marker, runtimeCli);
  const [, files, , , , requested, resolved, platform] = before[0].split('|');
  console.log(JSON.stringify({ checks: passed, transport, server_version: serverVersion, image_requested: requested, image_resolved: resolved, platform, files_sha256: files, local_rules: localRules }));
} finally {
  if (clones.length) {
    const r = await run(['sql', 'postgres'], { input: clones.map(name => `DROP DATABASE IF EXISTS ${name};`).join('\n') });
    if (r.code !== 0) console.error(`could not drop ${clones.join(', ')}: ${r.stderr.trim()}`);
  }
}
assert.deepEqual(await sql('postgres', `SELECT count(*) FROM pg_database WHERE datname LIKE 'opencast\\_t\\_topotest\\_${tag}\\_%';`), ['0'], 'the clones are dropped');

// The strict stub: one script answers as podman or docker by its own name, from
// state.json beside it; `exec` goes to the real runtime; every call is logged and
// any operation the script may not issue is refused with 64 (refused.log).
function stubSource() { return `#!/usr/bin/env node
const fs = require('node:fs'), path = require('node:path'), { spawnSync } = require('node:child_process');
const dir = path.dirname(process.argv[1]), kind = path.basename(process.argv[1]), argv = process.argv.slice(2);
const statePath = path.join(dir, 'state.json'), s = JSON.parse(fs.readFileSync(statePath, 'utf8'));
fs.appendFileSync(path.join(dir, 'calls.log'), JSON.stringify([kind, ...argv]) + '\\n');
const save = () => fs.writeFileSync(statePath, JSON.stringify(s));
const ok = text => { if (text !== undefined) process.stdout.write(text + '\\n'); process.exit(0); };
const fail = (code, text) => { process.stderr.write(text + '\\n'); process.exit(code); };
const refuse = () => { fs.appendFileSync(path.join(dir, 'refused.log'), JSON.stringify([kind, ...argv]) + '\\n'); fail(64, 'stub ' + kind + ' refuses: ' + argv.join(' ')); };
const format = argv.includes('--format') ? argv[argv.indexOf('--format') + 1] : null, last = argv[argv.length - 1];
const noSuch = what => fail(kind === 'docker' ? 1 : 125, kind === 'docker' ? 'Error: No such ' + what + ': ' + last : 'Error: no such ' + what + ' "' + last + '"');
if (s.daemonError) fail(1, 'Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?');
const op = ['container', 'image', 'volume', 'machine'].includes(argv[0]) ? argv[0] + ' ' + argv[1] : argv[0];
switch (op) {
  case 'container inspect': {
    if (!s.exists) noSuch('container');
    const fields = { '{{.Name}}': s.container, '{{.Image}}': s.containerImage, '{{.Config.Image}}': s.configImage, '{{.State.Running}}': String(s.running) };
    if (kind === 'podman') fields['{{.ImageDigest}}'] = s.imageDigest;
    if (!(format in fields)) refuse();
    ok(fields[format]);
  }
  case 'image inspect': {
    if (format === '{{.Id}}') { const id = s.requested[last]; if (!id || !(s.requestedKnown || s.pulled)) fail(125, 'Error: ' + last + ': image not known'); ok(id); }
    const image = s.images[last];
    if (!image) fail(kind === 'docker' ? 1 : 125, 'Error: No such image: ' + last);
    if (format === '{{json .RepoDigests}}') ok(JSON.stringify(image.repoDigests));
    if (format === '{{.Os}}/{{.Architecture}}') ok(image.platform);
    refuse();
  }
  case 'image pull': s.pulled = true; save(); ok('pulled');
  case 'volume inspect': if (format !== '{{.Name}}') refuse(); if (!s.volumeExists) noSuch('volume'); ok(last);
  case 'volume rm': s.volumeExists = false; save(); ok(last);
  case 'run': Object.assign(s, { exists: true, running: true, containerImage: s.requested[last], imageDigest: s.runDigest, configImage: last }); save(); ok('stub-container');
  case 'start': s.running = true; save(); ok(last);
  case 'stop': s.running = false; save(); ok(last);
  case 'rm': s.exists = false; save(); ok(last);
  case 'port': ok(s.port);
  case 'exec': { const r = spawnSync(process.env.STUB_REAL_RUNTIME, argv, { stdio: 'inherit' }); process.exit(r.status ?? 1); }
  case 'machine inspect': if (kind !== 'podman') refuse(); ok('running');
  case 'info': if (kind !== 'podman') refuse(); ok('');
  default: refuse();
}
`; }
async function runtimeStubs(marker, real) {
  const stubs = mkdtempSync(join(tmpdir(), 'opencast-topotest-stubs-')), container = process.env.OPENCAST_PG_CONTAINER ?? 'opencast-postgres-local';
  const port = process.env.OPENCAST_PG_PORT ?? '55432', indexRef = `docker.io/library/postgres@${INDEX}`;
  const child = marker.image_resolved, platform = marker.platform, repo = d => `docker.io/library/postgres@${d}`;
  const OTHER = `sha256:${'b'.repeat(64)}`, THIRD = `sha256:${'c'.repeat(64)}`;
  for (const kind of ['podman', 'docker']) { writeFileSync(join(stubs, kind), stubSource()); chmodSync(join(stubs, kind), 0o755); }
  writeFileSync(join(stubs, 'refused.log'), '');
  // The live shape: the index requested, its child running. Install's provenance then equals the marker's, so
  // the marker never moves while the stubs drive install on this shared topology.
  const live = (kind, over = {}) => ({ container, exists: true, running: true, containerImage: 'img-live', imageDigest: child, configImage: repo(child),
    runDigest: child, port: `127.0.0.1:${port}`, volumeExists: true, requestedKnown: true, requested: { [indexRef]: 'img-live' },
    images: { 'img-live': { repoDigests: kind === 'podman' ? [repo(INDEX), repo(child)] : [repo(child)], platform } }, ...over });
  const arm = (state, dir = stubs) => {
    writeFileSync(join(dir, 'state.json'), JSON.stringify(state));
    writeFileSync(join(dir, 'calls.log'), '');
  };
  const stubEnv = { STUB_REAL_RUNTIME: real, OPENCAST_PG_CONTAINER: container, OPENCAST_PG_PSQL: 'container' };
  const stub = async (kind, state, args, env = {}) => {
    arm(state);
    const r = await run(args, { bash: true, env: { PATH: `${stubs}:${process.env.PATH}`, ...stubEnv,
      OPENCAST_CONTAINER_RUNTIME: kind === 'docker' ? 'docker' : '', ...env } });
    r.ops = readFileSync(join(stubs, 'calls.log'), 'utf8').trim().split('\n').filter(Boolean).map(l => JSON.parse(l))
      .map(c => c.slice(1, ['container', 'image', 'volume', 'machine'].includes(c[1]) ? 3 : 2).join(' '));
    r.state = JSON.parse(readFileSync(join(stubs, 'state.json'), 'utf8'));
    return r;
  };
  const row = await (async () => (await sql('postgres', 'SELECT row_to_json(m)::text FROM public.opencast_local_install m;'))[0])();
  try {
    for (const kind of ['podman', 'docker']) {
      await check(`${kind} stub: create, then up on a stopped and on a running container, under /bin/bash`, async () => {
        const created = await stub(kind, live(kind, { exists: false, running: false }), ['up']);
        assert.equal(created.code, 0, created.stderr);
        assert.ok(created.ops.includes('run') && created.ops.includes('port'), created.ops.join(','));
        assert.match(created.stderr, new RegExp(`creating ${container} from docker\\.io/library/postgres@sha256:74935e72`));
        const stopped = await stub(kind, live(kind, { running: false, requestedKnown: false }), ['up']);
        assert.equal(stopped.code, 0, stopped.stderr);
        assert.ok(stopped.ops.includes('image pull') && stopped.ops.includes('start') && !stopped.ops.includes('run'), stopped.ops.join(','));
        const running = await stub(kind, live(kind), ['up']);
        assert.equal(running.code, 0, running.stderr);
        assert.ok(!running.ops.includes('start') && !running.ops.includes('run'), running.ops.join(','));
        // Only Podman on macOS has a machine to check.
        assert.equal(running.ops.filter(o => o === 'machine inspect').length, kind === 'podman' && process.platform === 'darwin' ? 1 : 0);
        assert.match(running.stdout, new RegExp(`runs +${child.replace(/[:]/g, '.')} \\(${platform.replace('/', '.')}\\)`));
      });
      await check(`${kind} stub: an image mismatch and a wrong published port refuse before install; down and reset touch only the stub`, async () => {
        const mismatch = await stub(kind, live(kind, { containerImage: 'img-old', imageDigest: OTHER, configImage: repo(OTHER),
          images: { 'img-live': live(kind).images['img-live'], 'img-old': { repoDigests: [repo(OTHER)], platform } } }), ['up']);
        assert.equal(mismatch.code, 1);
        assert.match(mismatch.stderr, new RegExp(`runs ${OTHER}, not ${child}.*run reset`));
        assert.ok(!mismatch.ops.includes('exec') && !mismatch.ops.includes('start'), mismatch.ops.join(','));
        const port = await stub(kind, live(kind, { port: '127.0.0.1:1' }), ['up']);
        assert.equal(port.code, 1);
        assert.match(port.stderr, /publishes 127\.0\.0\.1:1, not 127\.0\.0\.1:\d+: run reset/);
        const down = await stub(kind, live(kind), ['down']);
        assert.equal(down.code, 0, down.stderr);
        assert.deepEqual(down.ops.filter(o => ['stop', 'rm'].includes(o)), ['stop', 'rm']);
        const reset = await stub(kind, live(kind), ['reset']);
        assert.equal(reset.code, 0, reset.stderr);
        assert.deepEqual(reset.ops.filter(o => ['stop', 'rm', 'volume inspect', 'volume rm', 'run'].includes(o)), ['stop', 'rm', 'volume inspect', 'volume rm', 'run']);
        assert.equal(reset.state.volumeExists, false);
      });
    }
    await check('provenance rule: the six cases and missing metadata, read-only through `provenance`', async () => {
      const childRef = repo(child);
      const cases = [
        ['the index requested, [index, child]', {}, [repo(INDEX), repo(child)], 0, child],
        ['a child requested, [index, child]', { OPENCAST_PG_IMAGE: childRef }, [repo(INDEX), repo(child)], 0, child],
        ['the index requested, [index] only (the docker shape)', {}, [repo(INDEX)], 1, 'unresolved: index-not-child'],
        ['a child requested, [child] only', { OPENCAST_PG_IMAGE: childRef }, [repo(child)], 0, child],
        ['[index, child-a, child-b]', {}, [repo(INDEX), repo(OTHER), repo(THIRD)], 1, 'unresolved: multiple'],
        ['no RepoDigests', {}, null, 1, 'unresolved: empty'],
      ];
      for (const [label, env, repoDigests, code, expected] of cases) {
        const state = live('docker', { images: { 'img-live': { repoDigests, platform } } });
        const r = await stub('docker', state, ['provenance'], env);
        assert.equal(r.code, code, `${label}: ${r.stderr}`);
        assert.match(r.stdout, new RegExp(`image_resolved ${expected}\\n`), label);
        if (code) assert.match(r.stderr, new RegExp(`image provenance ${expected}`), label);
        assert.ok(!r.ops.includes('exec'), `${label}: read-only`);
      }
      // Podman's own container digest wins when it remains: a child requested with only the index listed.
      const own = await stub('podman', live('podman', { images: { 'img-live': { repoDigests: [repo(INDEX)], platform } } }), ['provenance']);
      assert.equal(own.code, 0, own.stderr);
      assert.match(own.stdout, new RegExp(`image_resolved ${child}\\n`));
      const missing = await stub('docker', live('docker', { images: {} }), ['provenance']);
      assert.equal(missing.code, 1);
      assert.match(missing.stderr, /image provenance error: no metadata for image img-live/);
      assert.doesNotMatch(missing.stderr, /run reset/);
    });
    await check('this test\'s provenance check through the stubs: podman and a docker-shaped container with a valid child pass; index-only, multiple and empty refuse', async () => {
      for (const kind of ['podman', 'docker']) {
        arm(live(kind));
        provenanceAgrees(marker, join(stubs, kind), stubEnv);
      }
      for (const [label, repoDigests] of [['index-only', [repo(INDEX)]], ['multiple', [repo(INDEX), repo(OTHER), repo(THIRD)]], ['empty', null]]) {
        arm(live('docker', { images: { 'img-live': { repoDigests, platform } } }));
        assert.throws(() => provenanceAgrees(marker, join(stubs, 'docker'), stubEnv), /docker RepoDigests less the index must name one child/, label);
      }
    });
    await check('a Docker-only PATH without OPENCAST_CONTAINER_RUNTIME selects docker, in the script and in this test, and both provenance reads pass through it', async () => {
      const only = join(stubs, 'docker-only'), bin = join(stubs, 'node-only');
      for (const dir of [only, bin]) mkdirSync(dir);
      writeFileSync(join(only, 'docker'), stubSource());
      chmodSync(join(only, 'docker'), 0o755);
      writeFileSync(join(only, 'refused.log'), '');
      symlinkSync(process.execPath, join(bin, 'node'));
      const env = { ...stubEnv, PATH: `${only}:${bin}:/usr/bin:/bin`, OPENCAST_CONTAINER_RUNTIME: undefined };
      assert.notEqual(spawnSync('/bin/sh', ['-c', 'command -v podman'], { env: withEnv(env) }).status, 0, 'no podman on this PATH');
      arm(live('docker'), only);
      const cli = await selectedRuntime(env);
      assert.equal(cli, join(only, 'docker'));
      const r = await run(['provenance'], { bash: true, env });
      assert.equal(r.code, 0, r.stderr);
      assert.equal(r.stdout, `image_requested ${indexRef}\nimage_resolved ${child}\nplatform ${platform}\nruntime docker\n`);
      provenanceAgrees(marker, cli, env);
      assert.equal(readFileSync(join(only, 'refused.log'), 'utf8'), '', 'nothing refused on the Docker-only PATH');
    });
    await check('marker upgrade with install failing after the drop (the stub refuses image inspect): the test\'s own SQL restores the marker, the install failure stands, status reads ready', async () => {
      const saved = { row: await markerRow(), columns: await markerColumns() }, kept = await identity();
      await assert.rejects(markerUpgrade(() => stub('podman', live('podman', { images: {} }), ['install'])),
        /image provenance error: no metadata for image img-live/);
      assert.equal(await markerRow(), saved.row, 'the marker row');
      assert.deepEqual(await markerColumns(), saved.columns, 'the marker columns');
      assert.deepEqual(await identity(), kept, 'the marker identity and every non-transient database');
      const status = await run(['status']);
      assert.equal(status.code, 0, status.stderr);
    });
    await check('docker index-only: up warns, compares the requested references and refuses a different one before install', async () => {
      const r = await stub('docker', live('docker', { configImage: repo(OTHER), images: { 'img-live': { repoDigests: [repo(INDEX)], platform } } }), ['up']);
      assert.equal(r.code, 1);
      assert.match(r.stderr, /warning: image provenance unresolved: index-not-child; comparing requested references/);
      assert.match(r.stderr, new RegExp(`runs ${repo(OTHER).replace(/[.]/g, '\\.')}, not .*: run reset`));
      assert.ok(!r.ops.includes('exec'), r.ops.join(','));
    });
    await check('a missing CLI and a daemon error refuse; neither reads as an absent container', async () => {
      const missing = await stub('docker', live('docker'), ['status'], { OPENCAST_CONTAINER_RUNTIME: 'nonexistent' });
      assert.equal(missing.code, 1);
      assert.match(missing.stderr, /install Podman \(or Docker\) or set OPENCAST_CONTAINER_RUNTIME/);
      const daemon = await stub('docker', live('docker', { daemonError: true }), ['down']);
      assert.equal(daemon.code, 1);
      assert.match(daemon.stderr, /docker container inspect .* failed: Cannot connect to the Docker daemon/);
      assert.ok(!daemon.ops.includes('stop') && !daemon.ops.includes('rm'), daemon.ops.join(','));
    });
  } finally {
    const refused = readFileSync(join(stubs, 'refused.log'), 'utf8');
    rmSync(stubs, { recursive: true, force: true });
    assert.equal(refused, '', `operations the script may not issue: ${refused}`);
  }
  assert.equal((await sql('postgres', 'SELECT row_to_json(m)::text FROM public.opencast_local_install m;'))[0], row, 'the stubs never moved the marker');
}
