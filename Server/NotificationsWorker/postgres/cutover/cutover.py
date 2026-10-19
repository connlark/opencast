#!/usr/bin/env python3
"""Manifest the notifications PostgreSQL schema and compare a restored copy with its reference.

manifest-target reads every application table of one database, as a role that
can read them all and write none, into a canonical manifest of per-table row
counts and digests; compare-targets lists every difference between two such
manifests. The tool never contacts Cloudflare and never writes to a database.
See README.md beside this file. Standard library only; Python 3.9 or later.
"""
from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import os
import re
import stat
import subprocess
import sys
import tempfile
import traceback
from pathlib import Path

FORMAT = 'opencast-cutover-1'
SCHEMA = 'opencast'
TOOL = Path(__file__).resolve()

# Application tables in foreign-key order: depth from the roots, then name.
# manifest-target reads them in this order; test_cutover.py pins the set
# against the checked-in catalog of a fresh install.
COPY_ORDER = (
    'app_attest_challenge_source_buckets', 'app_attest_challenges', 'app_attest_keys', 'devices',
    'feed_admission_attempts', 'feed_subscriptions', 'n_circuit', 'n_control', 'n_deleted_install',
    'n_delivery_history', 'n_event', 'n_feed', 'n_feed_catalog', 'n_install', 'n_legacy_bridge',
    'n_poll_dispatch', 'n_poll_origin', 'n_poll_stat', 'n_requester_ticket', 'push_send_attempts',
    'secure_hello_attempts',
    'n_burst', 'n_delivery', 'n_group_member', 'n_interest', 'n_job_interest', 'n_snapshot',
    'n_delivery_member', 'n_observation', 'n_snapshot_ref',
    'n_episode_release', 'n_outbox',
)
APPLICATION_TABLES = frozenset(COPY_ORDER)
# The projection triggers; every installed copy has them enabled ('O').
TRIGGERS = {
    'devices': ('n_device_delete', 'n_device_insert', 'n_device_update'),
    'feed_subscriptions': ('n_subscription_delete', 'n_subscription_insert', 'n_subscription_update'),
    'n_feed': ('n_catalog_enrolled', 'n_feed_insert'),
    'n_install': ('n_install_disable', 'n_install_insert'),
    'n_interest': ('n_interest_changed', 'n_interest_inserted', 'n_interest_removed'),
}
TARGET_TYPES = {'bigint': 'integer', 'text': 'text', 'bytea': 'blob'}
TARGET_TYPE_FOR = {'integer': 'bigint', 'text': 'text', 'blob': 'bytea'}
RANK = {'null': 0, 'integer': 1, 'real': 1, 'text': 2, 'blob': 3}
IDENTIFIER = re.compile(r'^[a-z_][a-z0-9_]*$')
DATABASE_NAME = re.compile(r'^[A-Za-z0-9_][A-Za-z0-9_.-]*$')
SECRET_ARGUMENT = re.compile(r'password=|PGPASSWORD=|^sshpass$|/sshpass$|://[^/@\s]*:[^/@\s]*@', re.I)
REDACTED = '<refused argument>'


class Stop(Exception):
    """A data gate failed: the target must not be used (exit 1)."""


class Refusal(Exception):
    """Identity, input or usage was wrong: nothing was evaluated (exit 2)."""


def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat(timespec='milliseconds')


def sha256_bytes(data):
    return hashlib.sha256(data).hexdigest()


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, 'rb') as stream:
        for block in iter(lambda: stream.read(1 << 20), b''):
            digest.update(block)
    return digest.hexdigest()


def canonical_json(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=True)


def quote_ident(name):
    if not IDENTIFIER.match(name):
        raise Refusal('unexpected identifier in schema')
    return '"' + name + '"'


def sql_literal(text):
    if '\\' in text or '\n' in text or '\x00' in text:
        raise Refusal('unexpected character in a generated literal')
    return "'" + text.replace("'", "''") + "'"


# ---------------------------------------------------------------- canonical form

def token(kind, value):
    """One column value as its canonical token."""
    if kind == 'null':
        return 'null'
    if kind == 'integer':
        if type(value) is not int or not -(1 << 63) <= value < (1 << 63):
            raise Stop('integer outside the signed 64-bit range')
        return str(value)
    if kind == 'real':
        return '"r:' + repr(float(value)) + '"'
    if kind == 'text':
        return '"t:' + bytes(value).hex() + '"'
    if kind == 'blob':
        return '"b:' + bytes(value).hex() + '"'
    raise Stop('unknown storage class')


def make_line(values):
    return '[' + ','.join(token(kind, value) for kind, value in values) + ']'


def decode_line(line):
    """Parse a canonical line back to (class, value) pairs; non-canonical text stops."""
    try:
        items = json.loads(line)
    except ValueError:
        raise Stop('a target line is not JSON')
    if not isinstance(items, list):
        raise Stop('a target line is not an array')
    values = []
    for item in items:
        if item is None:
            values.append(('null', None))
        elif type(item) is int:
            values.append(('integer', item))
        elif isinstance(item, str) and item[:2] in ('t:', 'b:') and re.fullmatch(r'(?:[0-9a-f]{2})*', item[2:]):
            values.append(('text' if item[0] == 't' else 'blob', bytes.fromhex(item[2:])))
        elif isinstance(item, str) and item[:2] == 'r:':
            try:
                values.append(('real', float(item[2:])))
            except ValueError:
                raise Stop('a target line carries a malformed real token')
        else:
            raise Stop('a target line carries a non-canonical token')
    if make_line(values) != line:
        raise Stop('a target line does not re-tokenise to itself')
    return values


def sort_key(values):
    return tuple((RANK[kind], 0 if kind == 'null' else value) for kind, value in values)


class TableDigest:
    """Two-level digest: sha256 over the per-row sha256(line + LF), in order."""

    def __init__(self, table, key_positions):
        self.table = table
        self.key_positions = key_positions
        self.rows = 0
        self._digest = hashlib.sha256()
        self._last = None

    def add(self, line, values):
        key = sort_key([values[i] for i in self.key_positions])
        if self._last is not None and not key > self._last:
            raise Stop('%s: rows are not in strictly ascending primary-key order' % self.table)
        self._last = key
        self.rows += 1
        self._digest.update(hashlib.sha256(line.encode('ascii') + b'\n').digest())

    def hexdigest(self):
        return self._digest.hexdigest()


def plain(kind, value):
    """A readable rendering for the control manifest (operational state only)."""
    if kind == 'text':
        try:
            return value.decode('utf-8')
        except UnicodeDecodeError:
            return 't:' + value.hex()
    if kind == 'blob':
        return 'b:' + value.hex()
    if kind == 'real':
        return 'r:' + repr(value)
    return value


class Controls:
    """n_control, the dispatch singleton, the circuit and the epoch high-water marks."""

    TABLES = ('n_circuit', 'n_control', 'n_poll_dispatch')
    EPOCHS = {'n_install': 'max_install_epoch', 'n_feed': 'max_feed_epoch'}

    def __init__(self):
        self.result = {name: [] for name in self.TABLES}
        self.result.update({name: None for name in self.EPOCHS.values()})

    def add(self, table, columns, values):
        if table in self.TABLES:
            self.result[table].append([plain(kind, value) for kind, value in values])
        elif table in self.EPOCHS:
            kind, value = values[[name for name, _ in columns].index('epoch')]
            key = self.EPOCHS[table]
            if kind == 'integer' and (self.result[key] is None or value > self.result[key]):
                self.result[key] = value


class RowWriter:
    def __init__(self, directory, table):
        self.stream = None
        if directory is not None:
            descriptor = os.open(str(directory / (table + '.lines')), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            self.stream = os.fdopen(descriptor, 'w', encoding='ascii', newline='\n')

    def write(self, line):
        if self.stream:
            self.stream.write(line + '\n')

    def close(self):
        if self.stream:
            self.stream.close()


def private_directory(path, *, must_be_new):
    path = Path(path)
    if path.exists():
        if must_be_new and (not path.is_dir() or any(path.iterdir())):
            raise Refusal('%s must be a new or empty directory' % path.name)
    else:
        path.mkdir(mode=0o700, parents=False)
    check_private(path)
    return path


def check_private(path):
    info = path.stat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise Refusal('%s must be a directory owned by this user with mode 0700' % path.name)


# ---------------------------------------------------------------- PostgreSQL side

def pg_value_sql(name, kind):
    column = quote_ident(name)
    if kind == 'integer':
        return "COALESCE(%s::text,'null')" % column
    if kind == 'text':
        return "COALESCE('\"t:'||encode(convert_to(%s,'UTF8'),'hex')||'\"','null')" % column
    if kind == 'blob':
        return "COALESCE('\"b:'||encode(%s,'hex')||'\"','null')" % column
    raise Refusal('unmapped target type')


def pg_line_sql(columns):
    return "'['||" + "||','||".join(pg_value_sql(n, k) for n, k in columns) + "||']'"


def pg_order_sql(columns, key):
    kinds = dict(columns)
    return ', '.join(quote_ident(n) + (' COLLATE "C"' if kinds[n] == 'text' else '') for n in key)


def pg_digest_sql(table, columns, key):
    """count(*) and the two-level digest of one table, as columns row_count, digest."""
    return ("SELECT count(*) AS row_count, encode(sha256(COALESCE(string_agg(sha256(convert_to(%s||E'\\n','UTF8')),"
            " ''::bytea ORDER BY %s), ''::bytea)), 'hex') AS digest FROM %s.%s"
            % (pg_line_sql(columns), pg_order_sql(columns, key), SCHEMA, quote_ident(table)))


IDENTITY_SQL = (
    "SELECT 'identity|'||current_database()||'|'||(SELECT system_identifier::text FROM pg_control_system())||'|'||"
    "current_setting('server_version_num')||'|'||current_setting('server_encoding')||'|'||current_user||'|'||"
    "(SELECT rolsuper::text FROM pg_roles WHERE rolname=current_user);\n")
CATALOG_SQL = (
    "SELECT line FROM ("
    "SELECT 'table|'||c.relname AS line FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace"
    " WHERE n.nspname='opencast' AND c.relkind IN ('r','p')"
    " UNION ALL SELECT 'column|'||c.relname||'|'||a.attnum||'|'||a.attname||'|'||format_type(a.atttypid, a.atttypmod)"
    " FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace JOIN pg_attribute a ON a.attrelid=c.oid"
    " WHERE n.nspname='opencast' AND c.relkind IN ('r','p') AND a.attnum>0 AND NOT a.attisdropped"
    " UNION ALL SELECT 'key|'||c.relname||'|'||k.ord||'|'||a.attname FROM pg_index i JOIN pg_class c ON c.oid=i.indrelid"
    " JOIN pg_namespace n ON n.oid=c.relnamespace CROSS JOIN LATERAL unnest(i.indkey::int2[]) WITH ORDINALITY k(attnum, ord)"
    " JOIN pg_attribute a ON a.attrelid=c.oid AND a.attnum=k.attnum WHERE n.nspname='opencast' AND i.indisprimary"
    " UNION ALL SELECT 'trigger|'||c.relname||'|'||t.tgname||'|'||t.tgenabled::text FROM pg_trigger t"
    " JOIN pg_class c ON c.oid=t.tgrelid JOIN pg_namespace n ON n.oid=c.relnamespace"
    " WHERE n.nspname='opencast' AND NOT t.tgisinternal"
    " UNION ALL SELECT 'privilege|'||c.relname||'|'||has_table_privilege(c.oid, 'SELECT')::text||'|'||"
    "(has_table_privilege(c.oid, 'INSERT') OR has_table_privilege(c.oid, 'UPDATE') OR has_table_privilege(c.oid, 'DELETE')"
    " OR has_table_privilege(c.oid, 'TRUNCATE'))::text FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace"
    " WHERE n.nspname='opencast' AND c.relkind IN ('r','p')"
    ") catalog ORDER BY line COLLATE \"C\";\n")
PSQL_FLAGS = ['-X', '-q', '-A', '-t', '-v', 'ON_ERROR_STOP=1']
SQLSTATE = re.compile(r'(?:ERROR|FATAL):\s+([0-9A-Z]{5})\b')


def refused_element(value):
    """True when an argv element would be refused for carrying a credential (a JSON array: any of its items)."""
    if SECRET_ARGUMENT.search(value):
        return True
    try:
        items = json.loads(value)
    except ValueError:
        return False
    return isinstance(items, list) and any(isinstance(i, str) and SECRET_ARGUMENT.search(i) for i in items)


def redact_argv(argv):
    """argv for receipts: a refused element becomes REDACTED as a whole (a password can sit in its own
    item beside the one that betrays it, as in sshpass -p <password>); every other element is kept."""
    out = []
    for element in argv:
        if element.startswith('--') and '=' in element:
            flag, value = element.split('=', 1)
            out.append(flag + '=' + REDACTED if refused_element(value) else element)
        else:
            out.append(REDACTED if refused_element(element) else element)
    return out


def psql_prefix(text):
    try:
        argv = json.loads(text)
    except ValueError:
        raise Refusal('--psql must be a JSON array of strings')
    if not isinstance(argv, list) or not argv or not all(isinstance(a, str) and a for a in argv):
        raise Refusal('--psql must be a JSON array of strings')
    if any(SECRET_ARGUMENT.search(a) for a in argv):
        raise Refusal('--psql must not carry a password; use the environment or a password file')
    return argv


def run_psql(prefix, sql, extra=()):
    head = b'\\set VERBOSITY sqlstate\n\\set SHOW_CONTEXT never\n'
    result = subprocess.run(prefix + PSQL_FLAGS + list(extra), input=head + sql,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    return result.returncode, result.stdout.decode('utf-8', 'replace'), result.stderr.decode('utf-8', 'replace')


def sqlstates(stderr):
    return SQLSTATE.findall(stderr)


def session_identity(line, database, system_identifier, expected, session):
    try:
        identity = identity_from(line, database, system_identifier)
    except Refusal as error:
        raise Refusal('%s (%s)' % (error, session))
    if identity != expected:
        raise Refusal('target identity mismatch: %s' % session)
    return identity


def identity_from(line, database, system_identifier):
    """One IDENTITY_SQL line, checked against the named target; any mismatch refuses."""
    _, name, identifier, version, encoding, role, superuser = line.split('|')
    identity = dict(database=name, system_identifier=identifier, server_version_num=version,
                    server_encoding=encoding, role=role, superuser=superuser == 'true')
    if name != database or identifier != system_identifier:
        raise Refusal('target identity mismatch: connected to a database other than the one named')
    if encoding != 'UTF8':
        raise Refusal('the target server encoding is not UTF8')
    return identity


def target_identity(prefix, database, system_identifier):
    if not DATABASE_NAME.match(database) or not system_identifier.isdigit():
        raise Refusal('--target-database and --target-system-identifier are malformed')
    code, out, err = run_psql(prefix, IDENTITY_SQL.encode())
    lines = [l for l in out.splitlines() if l.startswith('identity|')]
    if code or len(lines) != 1:
        raise Refusal('the target identity could not be read (psql exit %d, SQLSTATE %s)'
                      % (code, ','.join(sqlstates(err)) or 'none'))
    return identity_from(lines[0], database, system_identifier)


# ---------------------------------------------------------------- receipts

class Receipts:
    def __init__(self, directory):
        self.directory = private_directory(directory, must_be_new=False)

    def path(self, name):
        return self.directory / name

    def exists(self, name):
        return self.path(name).exists()

    def write(self, name, value):
        data = (json.dumps(value, indent=1, sort_keys=True) + '\n').encode() if not isinstance(value, bytes) else value
        descriptor = os.open(str(self.path(name)), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, 'wb') as stream:
            stream.write(data)

    def read(self, name):
        try:
            return json.loads(self.path(name).read_text(encoding='utf-8'))
        except (OSError, ValueError):
            raise Refusal('receipt %s is missing or unreadable' % name)


def write_manifest(receipts, name, body):
    digest = sha256_bytes(canonical_json(body).encode())
    receipts.write(name, dict(format=FORMAT, manifest=body, manifest_digest=digest))
    return digest


def read_manifest(path):
    try:
        value = json.loads(Path(path).read_text(encoding='utf-8'))
    except (OSError, ValueError):
        raise Refusal('the manifest file is not readable JSON')
    if value.get('format') != FORMAT or sha256_bytes(canonical_json(value.get('manifest')).encode()) != value.get('manifest_digest'):
        raise Refusal('the manifest file is not an intact cutover manifest')
    return value['manifest'], value['manifest_digest']


# ---------------------------------------------------------------- commands

def read_catalog(lines):
    tables, columns, keys, triggers, privileges = set(), {}, {}, {}, {}
    for line in lines:
        part = line.split('|')
        if part[0] == 'table':
            tables.add(part[1])
        elif part[0] == 'column':
            columns.setdefault(part[1], []).append((int(part[2]), part[3], part[4]))
        elif part[0] == 'key':
            keys.setdefault(part[1], []).append((int(part[2]), part[3]))
        elif part[0] == 'trigger':
            triggers.setdefault(part[1], {})[part[2]] = part[3]
        elif part[0] == 'privilege':
            privileges[part[1]] = (part[2] == 'true', part[3] == 'true')
    return tables, columns, keys, triggers, privileges


def command_manifest_target(args, receipts, receipt):
    prefix = psql_prefix(args.psql)
    identity = target_identity(prefix, args.target_database, args.target_system_identifier)
    receipt['target'] = identity
    receipt['psql'] = prefix
    # Every psql session this command starts reads the identity again (a routed prefix could land elsewhere).
    code, out, err = run_psql(prefix, (IDENTITY_SQL + CATALOG_SQL).encode())
    if code:
        raise Stop('catalog read failed (SQLSTATE %s)' % (','.join(sqlstates(err)) or 'none'))
    identities = [l for l in out.splitlines() if l.startswith('identity|')]
    if len(identities) != 1:
        raise Refusal('the catalog session did not report the target identity')
    session_identity(identities[0], args.target_database, args.target_system_identifier, identity, 'catalog session')
    catalog = sorted(l for l in out.splitlines() if l and not l.startswith('identity|'))
    tables, columns, keys, triggers, privileges = read_catalog(catalog)
    if tables != APPLICATION_TABLES:
        raise Stop('target table set differs: missing %s, unexpected %s'
                   % (sorted(APPLICATION_TABLES - tables), sorted(tables - APPLICATION_TABLES)))
    writable = sorted(t for t, (_, write) in privileges.items() if write)
    unreadable = sorted(t for t, (read, _) in privileges.items() if not read)
    receipt['privileges'] = dict(superuser=identity['superuser'], writable=writable, unreadable=unreadable)
    if identity['superuser'] or writable or unreadable:
        raise Refusal('manifest-target must run as a role that can read every table and write none')
    shape = {}
    for table in COPY_ORDER:
        typed_columns = []
        for _, name, kind in sorted(columns[table]):
            if kind not in TARGET_TYPES:
                raise Stop('%s.%s has an unmapped target type' % (table, name))
            typed_columns.append((name, TARGET_TYPES[kind]))
        shape[table] = (typed_columns, [n for _, n in sorted(keys.get(table, []))])
        if not shape[table][1]:
            raise Stop('%s has no primary key on the target' % table)
    script = ["BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY;\n",
              "SET LOCAL statement_timeout = %s;\n" % sql_literal(args.statement_timeout),
              IDENTITY_SQL, "\\echo cutover-catalog\n", CATALOG_SQL]
    for table in COPY_ORDER:
        cols, key = shape[table]
        script.append('\\echo cutover-table|%s\n' % table)
        script.append('COPY (SELECT %s FROM %s.%s ORDER BY %s) TO STDOUT;\n'
                      % (pg_line_sql(cols), SCHEMA, quote_ident(table), pg_order_sql(cols, key)))
    script.append('COMMIT;\n\\echo cutover-end\n')
    rows_dir = private_directory(args.rows_dir, must_be_new=True) if args.rows_dir else None
    tables_out, controls = {}, Controls()
    head = b'\\set VERBOSITY sqlstate\n\\set SHOW_CONTEXT never\n'
    with tempfile.TemporaryFile() as errors:
        process = subprocess.Popen(prefix + PSQL_FLAGS, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=errors)
        process.stdin.write(head + ''.join(script).encode('ascii'))
        process.stdin.close()
        section, second_catalog, current, writer, ended, snapshot = None, [], None, None, False, None
        try:
            for raw in process.stdout:
                line = raw.decode('ascii').rstrip('\n')
                if section is None and line.startswith('identity|'):
                    snapshot = session_identity(line, args.target_database, args.target_system_identifier, identity,
                                                'inside the read snapshot')
                    continue
                if line == 'cutover-catalog':
                    if snapshot is None:
                        raise Refusal('the read snapshot did not report the target identity before the first read')
                    section = 'catalog'
                elif line.startswith('cutover-table|') or line == 'cutover-end':
                    if current:
                        finish_table(tables_out, current, writer)
                    if line == 'cutover-end':
                        current, ended = None, True
                        continue
                    table = line.split('|', 1)[1]
                    cols, key = shape[table]
                    section = 'rows'
                    writer = RowWriter(rows_dir, table)
                    current = (table, cols, key, TableDigest(table, [[n for n, _ in cols].index(k) for k in key]))
                elif section == 'catalog':
                    if line:
                        second_catalog.append(line)
                elif section == 'rows':
                    table, cols, key, digest = current
                    values = decode_line(line)
                    if len(values) != len(cols) or any(k != 'null' and k != c for (k, _), (_, c) in zip(values, cols)):
                        raise Stop('%s: a target line does not match the column types' % table)
                    digest.add(line, values)
                    controls.add(table, cols, values)
                    writer.write(line)
                elif line:
                    raise Stop('unexpected psql output')
        finally:
            process.stdout.close()
            code = process.wait()
            if writer:
                writer.close()
        errors.seek(0)
        err = errors.read().decode('utf-8', 'replace')
    if code or not ended:
        raise Stop('target read failed (psql exit %d, SQLSTATE %s)' % (code, ','.join(sqlstates(err)) or 'none'))
    if sorted(second_catalog) != catalog:
        raise Stop('the target catalog changed between the two reads')
    trigger_names = {t: sorted(v) for t, v in triggers.items()}
    trigger_states = {t: dict(sorted(v.items())) for t, v in triggers.items()}
    for table in COPY_ORDER:
        if table not in tables_out:
            raise Stop('%s: the target read returned no section' % table)
        tables_out[table].update(columns=[[n, k] for n, k in shape[table][0]], primary_key=shape[table][1])
    body = dict(side='target', target=identity, tables=tables_out, controls=controls.result,
                triggers=trigger_names, trigger_states=trigger_states)
    receipt['identity_checks'] = ['session', 'catalog session', 'read snapshot before the first COPY']
    receipt['counts'] = {t: v['rows'] for t, v in tables_out.items()}
    receipt['digests'] = {t: v['digest'] for t, v in tables_out.items()}
    receipt['trigger_states'] = trigger_states
    receipt['statement_timeout'] = args.statement_timeout
    receipt['manifest_digest'] = write_manifest(receipts, 'target-manifest.json', body)
    return 'PASS'


def finish_table(tables_out, current, writer):
    table, _, _, digest = current
    tables_out[table] = dict(rows=digest.rows, digest=digest.hexdigest())
    if writer:
        writer.close()


def row_differences(reference_dir, restored_dir, table, columns, key):
    positions = [[n for n, _ in columns].index(k) for k in key]

    def read(directory):
        rows = {}
        with open(Path(directory) / (table + '.lines'), encoding='ascii') as stream:
            for line in stream:
                line = line.rstrip('\n')
                rows[tuple(json.loads(line)[i] for i in positions)] = line
        return rows

    reference, restored = read(reference_dir), read(restored_dir)
    return dict(missing=len(reference.keys() - restored.keys()), extra=len(restored.keys() - reference.keys()),
                changed=sum(reference[k] != restored[k] for k in reference.keys() & restored.keys()))


TARGET_MANIFEST_KEYS = ('side', 'target', 'tables', 'controls', 'triggers', 'trigger_states')


def read_target_side(directory, side):
    """(receipt, manifest, digest) of one manifest-target receipts directory; the receipt must name the manifest."""
    directory = Path(directory)
    try:
        receipt = json.loads((directory / 'manifest-target.json').read_text(encoding='utf-8'))
    except (OSError, ValueError):
        raise Refusal('the %s manifest-target receipt is missing or unreadable' % side)
    try:
        manifest, digest = read_manifest(directory / 'target-manifest.json')
    except Refusal as error:
        raise Refusal('%s (%s)' % (error, side))
    if not isinstance(manifest, dict) or any(k not in manifest for k in TARGET_MANIFEST_KEYS) or manifest['side'] != 'target':
        raise Refusal('the %s manifest is not a target manifest' % side)
    if not isinstance(receipt, dict) or receipt.get('manifest_digest') != digest:
        raise Refusal('the %s target manifest is not the one its receipt recorded' % side)
    return receipt, manifest, digest


def command_compare_targets(args, receipts, receipt):
    reference_receipt, reference, reference_digest = read_target_side(args.reference, 'reference')
    restored_receipt, restored, restored_digest = read_target_side(args.restored, 'restored')
    # A restore lands in another cluster: the identities are recorded, never compared.
    receipt.update(reference_target=reference['target'], restored_target=restored['target'],
                   reference_manifest_digest=reference_digest, restored_manifest_digest=restored_digest)
    differences = []

    def differ(kind, table, reference_value, restored_value):
        differences.append(dict(kind=kind, table=table, reference=reference_value, restored=restored_value))

    if reference_receipt.get('verdict') != 'PASS' or restored_receipt.get('verdict') != 'PASS':
        differ('receipt', None, reference_receipt.get('verdict'), restored_receipt.get('verdict'))
    for table in sorted(set(reference['tables']) | set(restored['tables'])):
        r, s = reference['tables'].get(table), restored['tables'].get(table)
        if r is None or s is None:
            differ('table_set', table, r is not None, s is not None)
            continue
        for field in ('columns', 'primary_key', 'rows', 'digest'):
            if r[field] != s[field]:
                differ(field, table, r[field], s[field])
        if (args.reference_rows and args.restored_rows and (r['rows'], r['digest']) != (s['rows'], s['digest'])
                and (r['columns'], r['primary_key']) == (s['columns'], s['primary_key'])):
            differences[-1]['rows_detail'] = row_differences(args.reference_rows, args.restored_rows, table,
                                                             r['columns'], r['primary_key'])
    for key in sorted(set(reference['controls']) | set(restored['controls'])):
        if reference['controls'].get(key) != restored['controls'].get(key):
            differ('controls', key, reference['controls'].get(key), restored['controls'].get(key))
    if reference['triggers'] != restored['triggers']:
        differ('trigger_names', None, reference['triggers'], restored['triggers'])
    disabled = [sorted('%s.%s' % (t, n) for t, states in side['trigger_states'].items() for n, state in states.items() if state != 'O')
                for side in (reference, restored)]
    if any(disabled):
        differ('trigger_state', None, *disabled)
    receipt.update(differences=differences, difference_count=len(differences))
    if differences:
        receipt['operator_action'] = 'The restored copy does not equal its reference: do not promote it.'
        raise Stop('%d difference(s) between the reference and the restored copy' % len(differences))
    return 'PASS'


# ---------------------------------------------------------------- entry point

class Parser(argparse.ArgumentParser):
    """argparse that never echoes an argument value in its error (it would otherwise print unrecognized ones)."""

    def error(self, message):
        if not message.startswith('the following arguments are required'):
            option = re.match(r'argument (\S+):', message)
            message = 'invalid argument%s (values are not echoed)' % (' ' + option.group(1) if option else '')
        self.print_usage(sys.stderr)
        self.exit(2, '%s: error: %s\n' % (self.prog, message))


def parser():
    top = Parser(description=__doc__.splitlines()[0])
    commands = top.add_subparsers(dest='command', required=True)

    def target_args(p):
        p.add_argument('--target-database', required=True)
        p.add_argument('--target-system-identifier', required=True)

    p = commands.add_parser('manifest-target', help='canonical manifest of the target as a read-only role')
    p.add_argument('--psql', required=True)
    target_args(p)
    p.add_argument('--statement-timeout', default='60s')
    p.add_argument('--rows-dir')
    p.add_argument('--receipts', required=True)
    p = commands.add_parser('compare-targets', help='a restored copy against its reference, every difference listed')
    p.add_argument('--reference', required=True, help='manifest-target receipts of the reference')
    p.add_argument('--restored', required=True, help='manifest-target receipts of the restored copy')
    p.add_argument('--reference-rows')
    p.add_argument('--restored-rows')
    p.add_argument('--receipts', required=True)
    return top


HANDLERS = {
    'manifest-target': ('manifest-target.json', command_manifest_target),
    'compare-targets': ('compare-targets.json', command_compare_targets),
}


def prevalidate(args):
    """Every argument a handler would refuse on its form, checked before any receipt exists."""
    if getattr(args, 'psql', None) is not None:
        psql_prefix(args.psql)
    if getattr(args, 'target_database', None) is not None and (
            not DATABASE_NAME.match(args.target_database) or not args.target_system_identifier.isdigit()):
        raise Refusal('--target-database and --target-system-identifier are malformed')


def main(argv=None):
    os.umask(0o077)
    raw_argv = list(sys.argv[1:] if argv is None else argv)
    args = parser().parse_args(raw_argv)
    name, handler = HANDLERS[args.command]
    try:
        receipts = Receipts(args.receipts)
        if receipts.exists(name):
            raise Refusal('receipt %s already exists' % name)
    except Refusal as error:
        print(json.dumps(dict(command=args.command, verdict='REFUSED', reason=str(error))), file=sys.stderr)
        return 2
    receipt = dict(format=FORMAT, command=args.command, argv=redact_argv(raw_argv),
                   tool_sha256=sha256_file(TOOL), python=sys.version.split()[0], started_utc=now())
    try:
        prevalidate(args)
        receipt['verdict'] = handler(args, receipts, receipt)
        code = 0
    except Stop as error:
        receipt.update(verdict='STOP', reason=str(error))
        code = 1
    except Refusal as error:
        receipt.update(verdict='REFUSED', reason=str(error))
        code = 2
    except OSError as error:
        receipt.update(verdict='REFUSED', reason='%s on an input or output path' % type(error).__name__)
        code = 2
    except Exception as error:  # never print a traceback: its messages can carry row values
        frame = traceback.extract_tb(error.__traceback__)[-1]
        receipt.update(verdict='ERROR', reason='internal error %s at %s:%d in %s' % (
            type(error).__name__, Path(frame.filename).name, frame.lineno, frame.name))
        code = 2
    receipt.update(finished_utc=now(), exit_code=code)
    receipts.write(name, receipt)
    print(json.dumps(dict(command=args.command, verdict=receipt['verdict'], reason=receipt.get('reason'),
                          receipt=str(receipts.path(name)))))
    return code


if __name__ == '__main__':
    sys.exit(main())
