// Test-side statement map: a CLOSED FIXTURE DIALECT, never a general SQLite ->
// PostgreSQL translator (promoted from the earlier PostgreSQL integration
// harness's translator). It accepts the shipped suites' own direct reads and
// seeds, inventoried from that harness's per-statement tables, and raises,
// naming the statement, on anything outside these rules:
//  R1  ?NNN -> $NNN; a bare ? takes the next number after the largest so far
//      (SQLite's rule). Quoted literals and identifiers are never rewritten.
//  R2  json_each(X) -> json_array_elements_text(X::json) AS je(value), or
//      json_array_elements(X::json) AS je(value) when its value is a JSON
//      object read through json_extract(value,'$.k') -> (value->>'k').
//  R3  json_extract(col,'$.a.b') -> (col::json #>> '{a,b}'). R2 and R3 yield
//      text: a JSON string unquoted, JSON null or a missing key as NULL, a
//      number or boolean as its JSON text where SQLite returns an INTEGER. The
//      suites read strings only.
//  R4  INSERT OR REPLACE INTO n_control(name,enabled,revision) VALUES ... ->
//      the INSERT with ON CONFLICT(name) DO UPDATE of enabled and revision.
//      n_control's only key is name and it has no delete trigger; with every
//      column listed, REPLACE's delete-and-insert equals the update. Any other
//      INSERT OR raises.
//  R5  LIKE '<pattern>' -> ILIKE (SQLite's LIKE is ASCII case-insensitive),
//      only for a literal ASCII pattern with no backslash (PostgreSQL's default
//      escape). ILIKE folds by locale, so a non-ASCII or bound pattern raises.
//  R6  ORDER BY text keys take COLLATE "C" (SQLite BINARY compares bytes).
//  R7  Catalog: the harness freshness probe and the name-only absence checks
//      map to the opencast schema's pg_class/pg_trigger; every other
//      sqlite_*/PRAGMA statement is D1-physical and raises D1PhysicalStatement.
//  R8  A statement naming a table outside PG_TABLES (D1 migration lineage,
//      engine bookkeeping) raises D1PhysicalStatement.
//  R9  An unaliased numeric-literal column keeps SQLite's name: SELECT 1 ->
//      SELECT 1 AS "1" (PostgreSQL would name it ?column?).
//  R10 is gone: there is no exact-string order map. A read that needs D1's
//      row order carries its own ORDER BY (the D1 plan's index key) in the suite.
//  R11 The one exact suite trigger, and its DROP, map to the PL/pgSQL twin.
// Closure beyond the rules: one SELECT/WITH/INSERT/UPDATE/DELETE statement (or
// R11), no comment, no named parameter, no SQLite-only function, keyword,
// operator, identifier quoting or blob literal.
// Result typing is pg.mjs's: int2/4/8 and numeric -> Number (safe integers
// only), text -> string, bool -> 0/1, bytea -> Uint8Array, NULL -> null.
export const PG_TABLES = new Set(['app_attest_challenge_source_buckets','app_attest_challenges','app_attest_keys','devices',
 'feed_admission_attempts','feed_subscriptions','n_burst','n_circuit','n_control','n_deleted_install','n_delivery',
 'n_delivery_history','n_delivery_member','n_episode_release','n_event','n_feed','n_feed_catalog','n_group_member',
 'n_install','n_interest','n_job_interest','n_legacy_bridge','n_observation','n_outbox','n_poll_dispatch','n_poll_origin',
 'n_poll_stat','n_requester_ticket','n_snapshot','n_snapshot_ref','push_send_attempts','secure_hello_attempts']);
export const TEXT_ORDER_KEYS = new Set(['feed_id','episode_id','event_id','last_poll_outcome','object_key','send_id','install_id',
 'identity_key','delivery_id','observation_id','name','state','reason','feed_url','source','interest_key','presentation_key','manifest_key','page_key']);
export const EXACT = new Map([
 ["CREATE TRIGGER reject_redelivery_stat BEFORE INSERT ON n_poll_stat WHEN NEW.redeliveries>0 BEGIN SELECT RAISE(ABORT,'fixture:redelivery_stat'); END",
  "CREATE FUNCTION opencast.reject_redelivery_stat() RETURNS trigger LANGUAGE plpgsql AS $f$BEGIN RAISE EXCEPTION 'fixture:redelivery_stat'; END$f$; CREATE TRIGGER reject_redelivery_stat BEFORE INSERT ON opencast.n_poll_stat FOR EACH ROW WHEN (NEW.redeliveries>0) EXECUTE FUNCTION opencast.reject_redelivery_stat()"],
 ['DROP TRIGGER reject_redelivery_stat', 'DROP TRIGGER reject_redelivery_stat ON opencast.n_poll_stat; DROP FUNCTION opencast.reject_redelivery_stat()'],
]);
const N_CONTROL_COLUMNS = ['enabled', 'name', 'revision'];
export class UnmappedStatement extends Error {
 constructor(reason, sql) { super(`UnmappedStatement(${reason}): ${sql}`); this.name = 'UnmappedStatement'; this.reason = reason; this.sql = sql; }
}
export class D1PhysicalStatement extends Error {
 constructor(kind, sql, detail) { super(`D1PhysicalStatement(${kind}${detail ? ` ${detail}` : ''}): ${sql}`); this.name = 'D1PhysicalStatement'; this.kind = kind; this.sql = sql; }
}
const FRESHNESS = "SELECT 1 FROM sqlite_master WHERE name='n_feed'";
// Split into code and quoted spans so rewrites never touch literal text.
function spans(sql) {
 const out = []; let i = 0, start = 0;
 while (i < sql.length) {
  const c = sql[i];
  if (c === "'" || c === '"') {
   if (i > start) out.push({ code: true, text: sql.slice(start, i) });
   let j = i + 1;
   while (j < sql.length) { if (sql[j] === c) { if (sql[j + 1] === c) { j += 2; continue; } break; } j++; }
   if (j >= sql.length) throw new UnmappedStatement('unterminated quote', sql);
   out.push({ code: false, text: sql.slice(i, j + 1) }); i = j + 1; start = i;
  } else i++;
 }
 if (start < sql.length) out.push({ code: true, text: sql.slice(start) });
 return out;
}
const mapCode = (sql, fn) => spans(sql).map(s => (s.code ? fn(s.text) : s.text)).join('');
// The statement with every quoted span blanked: what the closure checks scan.
const codeOf = sql => spans(sql).map(s => (s.code ? s.text : ' ')).join('');
export function placeholders(sql, statement = sql) {
 let highest = 0, count = 0;
 const pg = mapCode(sql, code => code.replace(/\?(\d*)/g, (_, n) => {
  const index = n ? Number(n) : highest + 1;
  if (index < 1) throw new UnmappedStatement('parameter ?0', statement);
  highest = Math.max(highest, index); count++; return '$' + index;
 }));
 return { pg, parameters: highest, occurrences: count };
}
const FUNCTIONS = new Set(['json_each', 'json_tree']);
function tablesOf(sql) {
 const code = codeOf(sql), names = new Set(), ctes = new Set();
 if (/^\s*WITH\b/i.test(code)) for (const m of code.matchAll(/(?:\bWITH\s+(?:RECURSIVE\s+)?|,\s*)([A-Za-z_][A-Za-z0-9_]*)\s*(?:\([^)]*\)\s*)?AS\s*(?:NOT\s+)?(?:MATERIALIZED\s+)?\(/gi)) ctes.add(m[1].toLowerCase());
 for (const m of code.matchAll(/\b(?:FROM|JOIN|INTO|UPDATE|TABLE)\s+([A-Za-z_][A-Za-z0-9_]*)\b/gi)) {
  const name = m[1].toLowerCase();
  if (!FUNCTIONS.has(name) && !ctes.has(name) && name !== 'select' && name !== 'set') names.add(m[1]);
 }
 return names;
}
// Name-only reads: COUNT(*) AS n, or the name column itself, filtered by name
// equality or an IN list (literal or one bound name).
const NAME_FILTER = "WHERE name(?:='[a-z_0-9]+'|=\\?| IN\\('[a-z_0-9]+'(?:,'[a-z_0-9]+')*\\))";
const ABSENCE = new RegExp(`^SELECT (COUNT\\(\\*\\) AS n|name) FROM (sqlite_master|sqlite_schema) ${NAME_FILTER}$`);
export function catalogKind(sql) {
 if (sql === FRESHNESS) return 'freshness-probe';
 if (!/\bsqlite_[A-Za-z0-9_]*|\bPRAGMA\b/i.test(codeOf(sql))) return null;
 if (ABSENCE.test(sql)) return 'catalog-absence';
 return 'catalog-structural';
}
// Retired-object absence: tables, views, indexes and triggers share one
// SQLite namespace; PostgreSQL keeps relations in pg_class and triggers in
// pg_trigger, both scoped to the opencast schema.
export function absenceSql(sql) {
 const names = [...sql.matchAll(/'([a-z_0-9]+)'/g)].map(m => m[1]);
 const list = sql.includes('name=?') ? '$1' : names.map(n => `'${n}'`).join(',');
 const objects = `SELECT c.relname AS name FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace s ON s.oid=c.relnamespace WHERE s.nspname='opencast' AND c.relname IN(${list}) UNION ALL SELECT t.tgname AS name FROM pg_catalog.pg_trigger t JOIN pg_catalog.pg_class c ON c.oid=t.tgrelid JOIN pg_catalog.pg_namespace s ON s.oid=c.relnamespace WHERE s.nspname='opencast' AND NOT t.tgisinternal AND t.tgname IN(${list})`;
 return sql.startsWith('SELECT name ') ? `SELECT name::text AS name FROM (${objects}) o` : `SELECT COUNT(*)::bigint AS n FROM (${objects}) o`;
}
// SQLite constructs with no rule here. R2/R3's json_each/json_extract shapes
// and R4's INSERT OR are checked by the rules themselves.
const SQLITE_ONLY = [
 [/\b(json_tree|json_insert|json_replace|json_set|json_remove|json_patch|json_type|json_valid|json_quote|json_array|json_array_length|json_object|json_group_array|json_group_object|jsonb?|jsonb_[a-z_]+|ifnull|iif|strftime|datetime|date|time|julianday|unixepoch|group_concat|total|typeof|printf|format|randomblob|zeroblob|last_insert_rowid|changes|total_changes|instr|hex|unhex|char|unicode|quote|likely|unlikely|likelihood|glob)\s*\(/i, 'SQLite-only function'],
 [/\b(GLOB|REGEXP|MATCH|ESCAPE|COLLATE|INDEXED|AUTOINCREMENT|RAISE|rowid|_rowid_)\b/i, 'SQLite-only keyword'],
 [/->/, 'SQLite JSON operator'],
 [/[:@$][A-Za-z_]/, 'named parameter'],
 [/;/, 'more than one statement'],
 [/--|\/\*/, 'comment'],
 [/[`[\]]/, 'SQLite identifier quoting'],
];
const VERB = /^\s*(SELECT|WITH|INSERT|UPDATE|DELETE)\b/i;
const isRead = code => /^\s*SELECT\b/i.test(code) || (/^\s*WITH\b/i.test(code) && !/\b(INSERT|UPDATE|DELETE)\b/i.test(code));
// R5 on spans: every LIKE must end its code span and be followed by a quoted
// ASCII literal; X'..' (a SQLite blob, a PostgreSQL bit string) never passes.
function like(sql) {
 const parts = spans(sql); let rewritten = false;
 parts.forEach((s, k) => {
  if (!s.code) return;
  if (/\b[xX]$/.test(s.text) && parts[k + 1]?.text.startsWith("'")) throw new UnmappedStatement('blob literal', sql);
  if (!/\bLIKE\b/i.test(s.text)) return;
  const pattern = parts[k + 1];
  if ([...s.text.matchAll(/\bLIKE\b/gi)].length > 1 || !/\bLIKE\s*$/i.test(s.text) || !pattern?.text.startsWith("'")) throw new UnmappedStatement('LIKE with a non-literal pattern', sql);
  const text = pattern.text.slice(1, -1).replace(/''/g, "'");
  if (!/^[\x20-\x7e]*$/.test(text)) throw new UnmappedStatement('non-ASCII LIKE pattern', sql);
  if (text.includes('\\')) throw new UnmappedStatement('LIKE pattern with a backslash', sql);
  s.text = s.text.replace(/\bLIKE(\s*)$/i, 'ILIKE$1'); rewritten = true;
 });
 return { pg: parts.map(s => s.text).join(''), rewritten };
}
// Returns {kind, pg, rules, parameters, read, script?}; throws UnmappedStatement
// or D1PhysicalStatement, each naming the statement.
export function translate(sql) {
 if (typeof sql !== 'string') throw new TypeError('translate() takes SQL text');
 if (EXACT.has(sql)) return { kind: 'mapped', pg: EXACT.get(sql), rules: ['R11'], parameters: 0, read: false, script: true };
 const catalog = catalogKind(sql);
 if (catalog === 'freshness-probe') return { kind: catalog, pg: "SELECT 1 AS \"1\" FROM pg_catalog.pg_namespace WHERE nspname='opencast' AND EXISTS(SELECT 1 FROM pg_catalog.pg_class c WHERE c.relnamespace=pg_namespace.oid AND c.relname='n_feed')", rules: ['R7'], parameters: 0, read: true };
 if (catalog === 'catalog-absence') return { kind: catalog, pg: absenceSql(sql), rules: ['R7'], parameters: sql.includes('name=?') ? 1 : 0, read: true };
 if (catalog === 'catalog-structural') throw new D1PhysicalStatement('catalog', sql);
 const code = codeOf(sql);
 if (!VERB.test(code)) throw new UnmappedStatement('statement kind outside the fixture dialect', sql);
 const missing = [...tablesOf(sql)].filter(t => !PG_TABLES.has(t));
 if (missing.length) throw new D1PhysicalStatement('lineage', sql, missing.join(','));
 for (const [pattern, reason] of SQLITE_ONLY) { const m = code.match(pattern); if (m) throw new UnmappedStatement(`${reason} ${m[0].trim()}`, sql); }
 const rules = [];
 let pg = sql;
 if (/\bjson_each\s*\(/i.test(code)) {
  const objects = /json_extract\(value,/.test(pg);
  pg = mapCode(pg, c => c.replace(/json_each\(([^()]+)\)/g, (_, x) => `${objects ? 'json_array_elements' : 'json_array_elements_text'}(${x}::json) AS je(value)`));
  if (objects) pg = pg.replace(/json_extract\(value,'\$\.([a-z_]+)'\)/g, "(value->>'$1')");
  if (/\bjson_each\s*\(/i.test(codeOf(pg))) throw new UnmappedStatement('json_each shape', sql);
  rules.push('R2');
 }
 if (/\bjson_extract\s*\(/i.test(codeOf(pg))) {
  pg = pg.replace(/json_extract\(([A-Za-z_][A-Za-z0-9_.]*),'\$((?:\.[A-Za-z_][A-Za-z0-9_]*)+)'\)/g, (_, col, path) => `(${col}::json #>> '{${path.slice(1).split('.').join(',')}}')`);
  if (/\bjson_extract\s*\(/i.test(codeOf(pg))) throw new UnmappedStatement('json_extract shape', sql);
  rules.push('R3');
 }
 if (/\bINSERT\s+OR\b/i.test(code)) {
  const replace = pg.match(/^INSERT OR REPLACE INTO (n_control)\(([^)]*)\) (VALUES.*)$/s);
  const cols = replace?.[2].split(',').map(c => c.trim());
  if (!replace || cols.slice().sort().join() !== N_CONTROL_COLUMNS.join()) throw new UnmappedStatement('INSERT OR conflict clause without a recorded rewrite', sql);
  pg = `INSERT INTO ${replace[1]}(${replace[2]}) ${replace[3]} ON CONFLICT(name) DO UPDATE SET ${cols.filter(c => c !== 'name').map(c => `${c}=excluded.${c}`).join(',')}`;
  rules.push('R4');
 }
 const liked = like(pg); if (liked.rewritten) { pg = liked.pg; rules.push('R5'); }
 pg = mapCode(pg, c => c.replace(/ORDER\s+BY ([^;]*?)(?= LIMIT|$)/gi, (_, keys) => 'ORDER BY ' + keys.split(',').map(key => {
  const m = key.trim().match(/^((?:[a-z]\.)?([a-z_]+))(\s+(?:ASC|DESC))?$/i);
  if (m && TEXT_ORDER_KEYS.has(m[2])) { rules.includes('R6') || rules.push('R6'); return `${m[1]} COLLATE "C"${m[3] ?? ''}`; }
  return key.trim();
 }).join(',')));
 if (/\bSELECT \d+ (FROM|WHERE)\b/.test(codeOf(pg))) { pg = mapCode(pg, c => c.replace(/\bSELECT (\d+) (?=FROM\b|WHERE\b)/g, 'SELECT $1 AS "$1" ')); rules.push('R9'); }
 const p = placeholders(pg, sql); pg = p.pg; if (p.occurrences) rules.unshift('R1');
 return { kind: 'mapped', pg, rules, parameters: p.parameters, read: isRead(code) };
}
