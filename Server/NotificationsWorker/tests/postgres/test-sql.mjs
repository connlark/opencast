// sql.mjs, the closed fixture dialect, pinned rule by rule with no database:
// every accepted shape's exact PostgreSQL text, and every raise naming its
// statement. Run: node Server/NotificationsWorker/tests/postgres/test-sql.mjs
import assert from 'node:assert/strict';
import * as dialect from './sql.mjs';
const {translate,placeholders,UnmappedStatement,D1PhysicalStatement}=dialect;
let failed=0;
const test=(name,fn)=>{try{fn();console.log('ok',name);}catch(error){failed++;console.log('not ok',name);console.log(error);}};
const mapped=(sql,pg,rules,extra={})=>{const t=translate(sql);assert.equal(t.pg,pg,sql);if(rules)assert.deepEqual(t.rules,rules,sql);for(const [k,v] of Object.entries(extra))assert.deepEqual(t[k],v,`${k}: ${sql}`);return t;};
// A raise is typed, carries its reason or kind, and names the whole statement.
const raises=(sql,type,detail)=>assert.throws(()=>translate(sql),error=>{
 assert.ok(error instanceof type,`${sql}: ${error}`);
 assert.ok(error.message.includes(sql),`the raise names the statement: ${error.message}`);
 assert.equal(error.sql,sql);
 if(detail)assert.match(type===D1PhysicalStatement?error.kind:error.reason,detail);
 return true;
});

test('R1 ?NNN is reused and a bare ? numbers after the largest so far',()=>{
 mapped('SELECT feed_id FROM n_feed WHERE due_at>?1 AND dispatch_until>?1','SELECT feed_id FROM n_feed WHERE due_at>$1 AND dispatch_until>$1',['R1'],{parameters:1});
 mapped('UPDATE n_feed SET due_at=?2,retry_at=? WHERE feed_id=?1 AND epoch=?','UPDATE n_feed SET due_at=$2,retry_at=$3 WHERE feed_id=$1 AND epoch=$4',['R1'],{parameters:4});
 mapped('SELECT feed_id FROM n_feed WHERE feed_id=? AND due_at<=?','SELECT feed_id FROM n_feed WHERE feed_id=$1 AND due_at<=$2',['R1'],{parameters:2});
 assert.deepEqual(placeholders('SELECT ?3,?,?1'),{pg:'SELECT $3,$4,$1',parameters:4,occurrences:3});
});
test('R1 never rewrites inside quoted literals or identifiers',()=>{
 mapped(`UPDATE n_feed SET snapshot_key='a?1 LIKE ? ORDER BY name' WHERE feed_id=?`,`UPDATE n_feed SET snapshot_key='a?1 LIKE ? ORDER BY name' WHERE feed_id=$1`,['R1'],{parameters:1});
 mapped(`SELECT etag AS "x?" FROM n_feed WHERE feed_id='it''s ?'`,`SELECT etag AS "x?" FROM n_feed WHERE feed_id='it''s ?'`,[],{parameters:0});
 raises('SELECT feed_id FROM n_feed WHERE due_at=?0',UnmappedStatement,/\?0/);
});
test('R2 json_each of strings: json_array_elements_text, values stay text',()=>{
 mapped("UPDATE n_feed SET snapshot_key='fixture-scanned' WHERE feed_id IN(SELECT value FROM json_each(?))",
  "UPDATE n_feed SET snapshot_key='fixture-scanned' WHERE feed_id IN(SELECT value FROM json_array_elements_text($1::json) AS je(value))",['R1','R2'],{parameters:1,read:false});
 mapped('SELECT COUNT(*) AS n FROM n_snapshot WHERE object_key IN(SELECT value FROM json_each(?))',
  'SELECT COUNT(*) AS n FROM n_snapshot WHERE object_key IN(SELECT value FROM json_array_elements_text($1::json) AS je(value))',['R1','R2'],{read:true});
});
test('R2 json_each of objects: json_array_elements with ->> for json_extract(value)',()=>{
 mapped("SELECT (f.snapshot_key IS NULL) AS baseline,COUNT(*) AS n FROM n_feed f WHERE f.feed_id IN(SELECT json_extract(value,'$.feed_id') FROM json_each(?)) GROUP BY baseline",
  "SELECT (f.snapshot_key IS NULL) AS baseline,COUNT(*) AS n FROM n_feed f WHERE f.feed_id IN(SELECT (value->>'feed_id') FROM json_array_elements($1::json) AS je(value)) GROUP BY baseline",['R1','R2']);
 raises('SELECT value FROM json_each(json(?))',UnmappedStatement,/json_each shape|SQLite-only function/);
});
test('R3 json_extract: #>> text over the dotted path; other paths raise',()=>{
 mapped("SELECT json_extract(x.payload_json,'$.data.episode_title') AS title FROM n_outbox x WHERE x.event_id=?",
  "SELECT (x.payload_json::json #>> '{data,episode_title}') AS title FROM n_outbox x WHERE x.event_id=$1",['R1','R3']);
 mapped("SELECT json_extract(admission_health_json,'$.state') AS s FROM n_feed_catalog",
  "SELECT (admission_health_json::json #>> '{state}') AS s FROM n_feed_catalog",['R3']);
 raises("SELECT json_extract(payload_json,'$[0]') AS v FROM n_outbox",UnmappedStatement,/json_extract shape/);
 raises("SELECT json_extract(payload_json,'$.a[1].b') AS v FROM n_outbox",UnmappedStatement,/json_extract shape/);
 raises("SELECT json_extract(?,'$.a') AS v FROM n_outbox",UnmappedStatement,/json_extract shape/);
});
test('R4 INSERT OR REPLACE INTO n_control with every column; any other INSERT OR raises',()=>{
 mapped("INSERT OR REPLACE INTO n_control(name,enabled,revision) VALUES('legacy_admission',1,1),('legacy_send',1,1),('legacy_cleanup',1,1)",
  "INSERT INTO n_control(name,enabled,revision) VALUES('legacy_admission',1,1),('legacy_send',1,1),('legacy_cleanup',1,1) ON CONFLICT(name) DO UPDATE SET enabled=excluded.enabled,revision=excluded.revision",['R4'],{read:false});
 mapped('INSERT OR REPLACE INTO n_control(revision,name,enabled) VALUES(?,?,?)',
  'INSERT INTO n_control(revision,name,enabled) VALUES($1,$2,$3) ON CONFLICT(name) DO UPDATE SET revision=excluded.revision,enabled=excluded.enabled',['R1','R4']);
 raises("INSERT OR REPLACE INTO n_control(name,revision) VALUES('x',1)",UnmappedStatement,/INSERT OR/);
 raises("INSERT OR IGNORE INTO n_control(name,enabled,revision) VALUES('x',1,1)",UnmappedStatement,/INSERT OR/);
 raises("INSERT OR REPLACE INTO n_feed(feed_id,canonical_url,epoch,due_at) VALUES('f','u',1,0)",UnmappedStatement,/INSERT OR/);
 raises("INSERT OR REPLACE INTO n_control(name,enabled,revision) SELECT name,1,1 FROM n_control",UnmappedStatement,/INSERT OR/);
 raises("REPLACE INTO n_control(name,enabled,revision) VALUES('x',1,1)",UnmappedStatement,/statement kind/);
});
test('R5 an ASCII literal LIKE pattern maps to ILIKE',()=>{
 mapped("SELECT COUNT(*) AS n FROM n_feed WHERE canonical_url LIKE 'https://crowded.example.com%' AND dispatch_until>?",
  "SELECT COUNT(*) AS n FROM n_feed WHERE canonical_url ILIKE 'https://crowded.example.com%' AND dispatch_until>$1",['R1','R5']);
 mapped("SELECT feed_id FROM n_feed WHERE canonical_url NOT like 'a_b%'","SELECT feed_id FROM n_feed WHERE canonical_url NOT ILIKE 'a_b%'",['R5']);
});
test('R5 a non-ASCII, bound, escaped or backslash pattern raises',()=>{
 raises("SELECT feed_id FROM n_feed WHERE canonical_url LIKE 'https://example.com/café/%'",UnmappedStatement,/non-ASCII LIKE/);
 raises("SELECT feed_id FROM n_feed WHERE canonical_url LIKE 'https://Kelvin/%'",UnmappedStatement,/non-ASCII LIKE/);
 raises('SELECT feed_id FROM n_feed WHERE canonical_url LIKE ?',UnmappedStatement,/non-literal/);
 raises('SELECT feed_id FROM n_feed WHERE canonical_url LIKE etag',UnmappedStatement,/non-literal/);
 raises("SELECT feed_id FROM n_feed WHERE canonical_url LIKE 'a\\_%'",UnmappedStatement,/backslash/);
 raises("SELECT feed_id FROM n_feed WHERE canonical_url LIKE 'a!_%' ESCAPE '!'",UnmappedStatement,/ESCAPE/);
});
test('R6 text ORDER BY keys take COLLATE "C"; other keys are unchanged',()=>{
 mapped("SELECT * FROM n_delivery WHERE install_id=? ORDER BY interest_key",'SELECT * FROM n_delivery WHERE install_id=$1 ORDER BY interest_key COLLATE "C"',['R1','R6']);
 mapped("SELECT * FROM n_delivery d ORDER BY d.state DESC,lease_until LIMIT 1",'SELECT * FROM n_delivery d ORDER BY d.state COLLATE "C" DESC,lease_until LIMIT 1',['R6']);
 mapped('SELECT feed_id FROM n_feed ORDER BY due_at','SELECT feed_id FROM n_feed ORDER BY due_at',[]);
 mapped("SELECT event_id FROM n_event order by source,event_id limit 5",'SELECT event_id FROM n_event ORDER BY source COLLATE "C",event_id COLLATE "C" limit 5',['R6']);
});
test('no ORDER map: an unordered read passes through unchanged apart from R1/R6',()=>{
 assert.equal('ORDER' in dialect,false);assert.equal('ORDER_NOTES' in dialect,false);
 mapped('SELECT event_id FROM n_episode_release WHERE feed_id=?','SELECT event_id FROM n_episode_release WHERE feed_id=$1',['R1']);
 mapped("SELECT * FROM n_delivery WHERE state IN('pending','uncertain')","SELECT * FROM n_delivery WHERE state IN('pending','uncertain')",[]);
 mapped("SELECT * FROM n_delivery WHERE install_id='install-012' LIMIT 1","SELECT * FROM n_delivery WHERE install_id='install-012' LIMIT 1",[]);
 mapped('SELECT event_id FROM n_event WHERE fanout_complete=0','SELECT event_id FROM n_event WHERE fanout_complete=0',[]);
});
test('R7 the freshness probe and name-only absence map to pg_class/pg_trigger',()=>{
 const fresh=translate("SELECT 1 FROM sqlite_master WHERE name='n_feed'");
 assert.equal(fresh.kind,'freshness-probe');assert.match(fresh.pg,/pg_catalog\.pg_class/);assert.match(fresh.pg,/^SELECT 1 AS "1" /);assert.equal(fresh.read,true);
 const one=translate("SELECT COUNT(*) AS n FROM sqlite_master WHERE name='n_poll'");
 assert.equal(one.kind,'catalog-absence');assert.equal(one.parameters,0);
 assert.match(one.pg,/^SELECT COUNT\(\*\)::bigint AS n FROM \(.*pg_class.*relname IN\('n_poll'\).*pg_trigger.*tgname IN\('n_poll'\)\) o$/);
 assert.match(translate("SELECT COUNT(*) AS n FROM sqlite_master WHERE name IN('n_origin_permit','n_poll')").pg,/relname IN\('n_origin_permit','n_poll'\)/);
 const bound=translate('SELECT name FROM sqlite_master WHERE name=?');
 assert.equal(bound.parameters,1);assert.match(bound.pg,/^SELECT name::text AS name FROM \(.*relname IN\(\$1\).*tgname IN\(\$1\)\) o$/);
 assert.match(translate("SELECT name FROM sqlite_schema WHERE name IN('feeds','n_catalog_from_feeds')").pg,/^SELECT name::text AS name/);
});
test('R7 every other catalog or PRAGMA statement raises D1PhysicalStatement',()=>{
 for(const sql of ['PRAGMA foreign_key_check','PRAGMA table_info(n_feed)','SELECT name,sql FROM sqlite_master ORDER BY name',
  "SELECT sql FROM sqlite_master WHERE name='n_feed_insert'","SELECT name FROM sqlite_schema WHERE type='table' AND name='n_feed'",
  "SELECT count(*) FROM sqlite_master WHERE type='trigger' AND name GLOB 'n_authority_fence_*'",'SELECT seq FROM sqlite_sequence'])raises(sql,D1PhysicalStatement,/^catalog$/);
});
test('R8 a table outside PG_TABLES (lineage, bookkeeping, retired) raises',()=>{
 raises('SELECT id,name,applied_at FROM d1_migrations ORDER BY id',D1PhysicalStatement,/^lineage$/);
 raises("INSERT INTO n_recovery_seed VALUES('feed','unresolved')",D1PhysicalStatement,/^lineage$/);
 raises("SELECT p.job_id FROM n_feed f JOIN n_poll p ON p.feed_id=f.feed_id",D1PhysicalStatement,/^lineage$/);
 raises("UPDATE feeds SET source_url='x' WHERE feed_url='y'",D1PhysicalStatement,/^lineage$/);
 assert.throws(()=>translate('DELETE FROM episode_notification_sends'),/D1PhysicalStatement\(lineage episode_notification_sends\)/);
 // A CTE name is not a table.
 mapped('WITH due AS (SELECT feed_id FROM n_feed WHERE due_at<=?) SELECT COUNT(*) AS n FROM due','WITH due AS (SELECT feed_id FROM n_feed WHERE due_at<=$1) SELECT COUNT(*) AS n FROM due',['R1'],{read:true});
});
test('R9 an unaliased numeric column keeps SQLite\'s name',()=>{
 mapped('SELECT 1 FROM n_feed WHERE feed_id=?','SELECT 1 AS "1" FROM n_feed WHERE feed_id=$1',['R1','R9']);
 mapped("SELECT 1 FROM n_observation WHERE feed_id=? AND state='published' AND drain_complete=0 UNION ALL SELECT 1 FROM n_episode_release WHERE feed_id=? AND state='ready' LIMIT 1",
  `SELECT 1 AS "1" FROM n_observation WHERE feed_id=$1 AND state='published' AND drain_complete=0 UNION ALL SELECT 1 AS "1" FROM n_episode_release WHERE feed_id=$2 AND state='ready' LIMIT 1`,['R1','R9']);
 mapped('SELECT 1 AS n FROM n_feed','SELECT 1 AS n FROM n_feed',[]);
});
test('R11 the one exact suite trigger and its DROP; any other DDL raises',()=>{
 const create=translate("CREATE TRIGGER reject_redelivery_stat BEFORE INSERT ON n_poll_stat WHEN NEW.redeliveries>0 BEGIN SELECT RAISE(ABORT,'fixture:redelivery_stat'); END");
 assert.deepEqual([create.rules,create.script,create.read,create.parameters],[['R11'],true,false,0]);
 assert.match(create.pg,/^CREATE FUNCTION opencast\.reject_redelivery_stat\(\) RETURNS trigger LANGUAGE plpgsql .*EXECUTE FUNCTION opencast\.reject_redelivery_stat\(\)$/);
 assert.equal(translate('DROP TRIGGER reject_redelivery_stat').pg,'DROP TRIGGER reject_redelivery_stat ON opencast.n_poll_stat; DROP FUNCTION opencast.reject_redelivery_stat()');
 raises("CREATE TRIGGER fixture_refusal BEFORE UPDATE ON n_feed BEGIN SELECT RAISE(ABORT, 'fixture_refused'); END",UnmappedStatement,/statement kind/);
 raises('DROP TRIGGER fixture_refusal',UnmappedStatement,/statement kind/);
 raises('CREATE TABLE d1_migrations(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT UNIQUE)',UnmappedStatement,/statement kind/);
 raises("CREATE TRIGGER reject_redelivery_stat BEFORE INSERT ON n_poll_stat WHEN NEW.redeliveries>1 BEGIN SELECT RAISE(ABORT,'fixture:redelivery_stat'); END",UnmappedStatement,/statement kind/);
});
test('an unmapped statement raises, naming it',()=>{
 raises('SELECT ifnull(etag,\'\') AS e FROM n_feed',UnmappedStatement,/SQLite-only function ifnull/);
 raises("SELECT strftime('%s','now') AS t FROM n_feed",UnmappedStatement,/SQLite-only function strftime/);
 raises("SELECT group_concat(feed_id) AS ids FROM n_feed",UnmappedStatement,/SQLite-only function/);
 raises('SELECT rowid FROM n_feed',UnmappedStatement,/SQLite-only keyword rowid/);
 raises("SELECT feed_id FROM n_feed WHERE canonical_url GLOB 'a*'",UnmappedStatement,/SQLite-only keyword GLOB/);
 raises('SELECT feed_id FROM n_feed ORDER BY feed_id COLLATE NOCASE',UnmappedStatement,/SQLite-only keyword COLLATE/);
 raises("SELECT payload_json->>'$.a' AS a FROM n_outbox",UnmappedStatement,/SQLite JSON operator/);
 raises('SELECT feed_id FROM n_feed WHERE feed_id=:feed',UnmappedStatement,/named parameter/);
 raises('SELECT feed_id FROM n_feed WHERE feed_id=$feed',UnmappedStatement,/named parameter/);
 raises('SELECT feed_id FROM n_feed; SELECT 1',UnmappedStatement,/more than one statement/);
 raises('SELECT feed_id FROM n_feed -- trailing',UnmappedStatement,/comment/);
 raises('SELECT [feed_id] FROM n_feed',UnmappedStatement,/identifier quoting/);
 raises("SELECT feed_id FROM n_feed WHERE etag=X'00'",UnmappedStatement,/blob literal/);
 raises("SELECT feed_id FROM n_feed WHERE etag='open",UnmappedStatement,/unterminated quote/);
 raises('VACUUM',UnmappedStatement,/statement kind/);
 raises("ATTACH DATABASE 'x' AS y",UnmappedStatement,/statement kind/);
});
test('reads are SELECT or a WITH without a write; everything else is a write',()=>{
 assert.equal(translate('SELECT feed_id FROM n_feed').read,true);
 assert.equal(translate('UPDATE n_feed SET due_at=?').read,false);
 assert.equal(translate('DELETE FROM n_poll_origin').read,false);
 assert.equal(translate("INSERT INTO devices(install_id) VALUES('x')").read,false);
 assert.equal(translate('WITH d AS (SELECT feed_id FROM n_feed) UPDATE n_feed SET due_at=0 WHERE feed_id IN(SELECT feed_id FROM d)').read,false);
});

if(failed){console.log(`${failed} failed`);process.exit(1);}
console.log('test-sql: all passed');
