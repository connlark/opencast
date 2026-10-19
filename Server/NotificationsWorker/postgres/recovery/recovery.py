#!/usr/bin/env python3
"""Reconcile a restored PostgreSQL copy before it serves again, and fence the old primary.

A restore from backup rolls the notifications authority back to its recovery
point: consumed challenges and counters, deleted installations and opt-outs, and
deliveries already sent come back. This tool runs the conservative recovery
policy on a restored copy that its operator marked after promote (mark,
reconcile, census, close), and fences the old primary's runtime role (fence,
unfence, acl). It never contacts Cloudflare. Every command leaves a receipt in a
directory the operator names. See README.md beside this file.
Standard library only; Python 3.9 or later.
"""
from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import os
import re
import secrets
import stat
import subprocess
import sys
import time
import traceback
from pathlib import Path

FORMAT = 'opencast-recovery-1'
MARKER_FORMAT = 'opencast-recovery-marker-1'
HERE = Path(__file__).resolve().parent
TOOL = Path(__file__).resolve()
SQL_FILES = ('marker', 'census', 'reconcile', 'close', 'fence', 'unfence', 'acl', 'probe')

# reconcile.sql's statements in execution order (README.md, "The statement set").
STATEMENTS = ('R13', 'R14', 'R15', 'R7', 'R16', 'R17', 'R18', 'R10', 'R5', 'R11c', 'R6', 'R19', 'R11a', 'R20',
              'R4', 'R3', 'R11b', 'R1', 'R2', 'R11d', 'R8', 'R9', 'R12')
# The privileges fence.sql revokes: table writes, and sequence USAGE/UPDATE.
FENCED = {('table', 'INSERT'), ('table', 'UPDATE'), ('table', 'DELETE'), ('table', 'TRUNCATE'),
          ('column', 'INSERT'), ('column', 'UPDATE'), ('sequence', 'USAGE'), ('sequence', 'UPDATE')}

IDENTIFIER = re.compile(r'^[a-z_][a-z0-9_]*$')
DATABASE_NAME = re.compile(r'^[A-Za-z0-9_][A-Za-z0-9_.-]*$')
NONCE = re.compile(r'^[0-9a-f]{32}$')
RECOVERY_TARGET = re.compile(r'^(latest|lsn:[0-9A-F]{1,8}/[0-9A-F]{1,8}|time:[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:'
                             r'[0-9]{2}(\.[0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2}))$')
TIMEOUT = re.compile(r'^[1-9][0-9]{0,5}(ms|s|min)$')
LABEL = re.compile(r'^[a-z0-9][a-z0-9-]{0,40}$')
VARIABLE_VALUE = re.compile(r'^[A-Za-z0-9_.:/+-]+$')
INCLUDE = re.compile(r'^\\ir (census\.sql|\.\./runtime-grants(?:-[a-z]+)*\.sql)$')
END_STATE = re.compile(r'-- recovery:end-state begin\n(.*?)\n[ ]*-- recovery:end-state end', re.S)
SECRET_ARGUMENT = re.compile(r'password=|PGPASSWORD=|^sshpass$|/sshpass$|://[^/@\s]*:[^/@\s]*@', re.I)
REDACTED = '<refused argument>'
PSQL_FLAGS = ['-X', '-q', '-A', '-t', '-v', 'ON_ERROR_STOP=1']
SQLSTATE = re.compile(r'(?:ERROR|FATAL):\s+([0-9A-Z]{5})\b')


class Stop(Exception):
    """The command ran and its required outcome did not hold (exit 1)."""


class Refusal(Exception):
    """Identity, guard, input or usage was wrong: nothing was written (exit 2)."""


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


def nonce_sha256(nonce):
    return sha256_bytes(nonce.encode('ascii'))


def private_directory(path):
    path = Path(path)
    if not path.exists():
        path.mkdir(mode=0o700, parents=False)
    info = path.stat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise Refusal('%s must be a directory owned by this user with mode 0700' % path.name)
    return path


class Receipts:
    def __init__(self, directory):
        self.directory = private_directory(directory)

    def path(self, name):
        return self.directory / name

    def exists(self, name):
        return self.path(name).exists()

    def write(self, name, value):
        data = (json.dumps(value, indent=1, sort_keys=True) + '\n').encode() if not isinstance(value, bytes) else value
        descriptor = os.open(str(self.path(name)), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, 'wb') as stream:
            stream.write(data)


# ---------------------------------------------------------------- arguments

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
    """argv for receipts: the nonce becomes sha256:<12 hex>, a refused element becomes REDACTED."""
    out = []
    nonce_next = False
    for element in argv:
        if nonce_next:
            out.append('sha256:' + nonce_sha256(element)[:12])
            nonce_next = False
        elif element == '--nonce':
            out.append(element)
            nonce_next = True
        elif element.startswith('--nonce='):
            out.append('--nonce=sha256:' + nonce_sha256(element.split('=', 1)[1])[:12])
        elif element.startswith('--') and '=' in element:
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


def prevalidate(args):
    """Every argument a handler would refuse on its form, checked before any receipt exists."""
    if getattr(args, 'psql', None) is not None:
        psql_prefix(args.psql)
    for name in ('owner_role', 'runtime_role'):
        value = getattr(args, name, None)
        if value is not None and not IDENTIFIER.match(value):
            raise Refusal('--%s is malformed' % name.replace('_', '-'))
    if getattr(args, 'target_database', None) is not None and (
            not DATABASE_NAME.match(args.target_database) or not args.target_system_identifier.isdigit()):
        raise Refusal('--target-database and --target-system-identifier are malformed')
    if getattr(args, 'nonce', None) is not None and not NONCE.match(args.nonce):
        raise Refusal('--nonce must be 32 lowercase hex digits (the output of the nonce command)')
    if getattr(args, 'recovery_target', None) is not None and not RECOVERY_TARGET.match(args.recovery_target):
        raise Refusal('--recovery-target must be lsn:<lsn>, time:<ISO 8601 with offset> or latest')
    for name in ('lock_timeout', 'statement_timeout', 'idle_timeout'):
        value = getattr(args, name, None)
        if value is not None and not TIMEOUT.match(value):
            raise Refusal('--%s is malformed' % name.replace('_', '-'))
    if getattr(args, 'label', None) is not None and not LABEL.match(args.label):
        raise Refusal('--label is malformed')


# ---------------------------------------------------------------- SQL and psql

def sql_text(name):
    return (HERE / (name + '.sql')).read_text(encoding='utf-8')


def sql_stream(name):
    """A shipped SQL file with each \\ir line replaced by the bytes of the file it names."""
    parts = []
    for line in (HERE / (name + '.sql')).read_bytes().splitlines(keepends=True):
        text = line.rstrip(b'\n').decode('utf-8')
        if text.startswith('\\ir'):
            match = INCLUDE.match(text)
            if not match:
                raise Refusal('%s.sql includes a file outside the recovery set' % name)
            target = (HERE / match.group(1)).resolve()
            if target.parent not in (HERE, HERE.parent):
                raise Refusal('%s.sql includes a file outside the recovery set' % name)
            parts.append(target.read_bytes())
            if not parts[-1].endswith(b'\n'):
                parts.append(b'\n')
        else:
            parts.append(line)
    return b''.join(parts)


def end_state_block():
    blocks = END_STATE.findall(sql_text('reconcile'))
    if len(blocks) != 2 or blocks[0] != blocks[1]:
        raise Refusal('reconcile.sql does not carry one end-state list')
    return blocks[0]


def run_psql(prefix, sql, variables=None):
    head = ['\\set VERBOSITY sqlstate', '\\set SHOW_CONTEXT never']
    for name, value in sorted((variables or {}).items()):
        if value is None:
            continue
        if not IDENTIFIER.match(name) or not VARIABLE_VALUE.match(value):
            raise Refusal('a psql variable is malformed')
        head.append('\\set %s %s' % (name, value))
    data = ('\n'.join(head) + '\n').encode() + sql
    started = time.monotonic()
    result = subprocess.run(prefix + PSQL_FLAGS, input=data, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    elapsed = round(time.monotonic() - started, 3)
    return result.returncode, result.stdout.decode('utf-8', 'replace'), result.stderr.decode('utf-8', 'replace'), elapsed


def sqlstates(stderr):
    return SQLSTATE.findall(stderr)


def lines(out, prefix):
    return [l.split('|')[1:] for l in out.splitlines() if l.startswith(prefix + '|')]


IDENTITY_SQL = (
    "SELECT 'identity|'||current_database()||'|'||(SELECT system_identifier::text FROM pg_control_system())||'|'||"
    "current_setting('server_version_num')||'|'||current_setting('server_encoding')||'|'||session_user||'|'||current_user||'|'||"
    "current_setting('is_superuser')||'|'||pg_is_in_recovery()::text||'|'||"
    "CASE WHEN pg_is_in_recovery() THEN '' ELSE (('x'||substr(pg_walfile_name(pg_current_wal_lsn()),1,8))::bit(32)::bigint)::text END||'|'||"
    "(pg_last_xact_replay_timestamp() IS NOT NULL)::text||'|'||"
    "COALESCE((SELECT pg_get_userbyid(nspowner)::text FROM pg_namespace WHERE nspname='opencast'),'')||'|'||"
    # The marker probe needs no privilege on its schema: to_regnamespace needs none, and the regclass lookup
    # (which needs USAGE) runs only for a role that holds it; otherwise the field says 'unreadable'.
    "CASE WHEN to_regnamespace('opencast_recovery') IS NULL THEN 'false' "
    "WHEN has_schema_privilege('opencast_recovery', 'USAGE') THEN (to_regclass('opencast_recovery.marker') IS NOT NULL)::text "
    "ELSE 'unreadable' END;\n")
MARKER_FIELDS = ('format', 'nonce_sha256', 'restored_at', 'recovery_target', 'last_replayed_at', 'boundary', 'timeline',
                 'system_identifier', 'database', 'reconciled_at')


def preflight_sql(read_marker):
    out = ['\\pset format unaligned', '\\pset tuples_only on', 'BEGIN TRANSACTION READ ONLY;',
           '\\if :{?owner_role}', 'SET LOCAL ROLE :"owner_role";', '\\endif', IDENTITY_SQL.rstrip('\n')]
    if read_marker:
        out += ["SELECT to_regclass('opencast_recovery.marker') IS NOT NULL AS recovery_has_marker \\gset",
                '\\if :recovery_has_marker',
                "SELECT 'marker|'||format||'|'||nonce_sha256||'|'||restored_at||'|'||recovery_target||'|'||last_replayed_at"
                "||'|'||boundary||'|'||timeline||'|'||system_identifier||'|'||database||'|'||COALESCE(reconciled_at::text,'')"
                " FROM opencast_recovery.marker WHERE id = 1;",
                "SELECT 'endstate|'||e.name||'|'||e.n FROM (VALUES\n%s\n) AS e(name, n) WHERE e.n <> 0;" % end_state_block(),
                '\\else', '\\echo marker|absent', '\\endif',
                "SELECT 'gate|'||count(*) FROM opencast.n_poll_dispatch WHERE id = 1;"]
    out.append('ROLLBACK;')
    return ('\n'.join(out) + '\n').encode()


def read_identity(prefix, args, *, owner_role=None, read_marker=False):
    """The connected database, read in a read-only transaction; refuses unless it is the one named."""
    code, out, err, _ = run_psql(prefix, preflight_sql(read_marker), dict(owner_role=owner_role))
    found = lines(out, 'identity')
    if code or len(found) != 1:
        raise Refusal('the target could not be read (psql exit %d, SQLSTATE %s)' % (code, ','.join(sqlstates(err)) or 'none'))
    f = found[0]
    identity = dict(database=f[0], system_identifier=f[1], server_version_num=f[2], server_encoding=f[3], session_role=f[4],
                    effective_role=f[5], superuser=f[6] == 'on', in_recovery=f[7] == 'true',
                    timeline=int(f[8]) if f[8] else None, replay_timestamp_present=f[9] == 'true', opencast_owner=f[10],
                    marker_present=None if f[11] == 'unreadable' else f[11] == 'true')
    if identity['database'] != args.target_database or identity['system_identifier'] != args.target_system_identifier:
        raise Refusal('target identity mismatch: connected to a database other than the one named')
    if identity['server_encoding'] != 'UTF8':
        raise Refusal('the target server encoding is not UTF8')
    marker = None
    violations = []
    if read_marker and identity['marker_present'] is None:
        raise Refusal('the recovery marker schema is not readable by this role')
    if read_marker:
        rows = lines(out, 'marker')
        if rows and rows[0] != ['absent']:
            if len(rows) != 1 or len(rows[0]) != len(MARKER_FIELDS):
                raise Refusal('the recovery marker is not one well-formed row')
            marker = dict(zip(MARKER_FIELDS, rows[0]))
        violations = [dict(name=r[0], rows=int(r[1])) for r in lines(out, 'endstate')]
        gate = lines(out, 'gate')
        identity['gate_rows'] = int(gate[0][0]) if gate else None
    return identity, marker, violations


def public_marker(marker):
    """The marker as receipts record it: every field but the nonce's digest."""
    if marker is None:
        return None
    return {k: v for k, v in marker.items() if k != 'nonce_sha256'}


def check_marker(args, identity, marker):
    if marker is None:
        raise Refusal('no recovery marker: this database is not a marked restored copy')
    if marker['format'] != MARKER_FORMAT:
        raise Refusal('the recovery marker has an unknown format')
    if marker['nonce_sha256'] != nonce_sha256(args.nonce):
        raise Refusal('the nonce does not match the recovery marker')
    if (marker['database'] != identity['database'] or marker['system_identifier'] != identity['system_identifier']
            or identity['timeline'] is None or int(marker['timeline']) != identity['timeline']):
        raise Refusal('the recovery marker names another database, cluster or timeline')
    if identity['effective_role'] != identity['opencast_owner']:
        raise Refusal('the effective role does not own schema opencast (use --owner-role)')


def census_sql():
    return (b'\\pset format unaligned\n\\pset tuples_only on\nBEGIN TRANSACTION READ ONLY;\n'
            b'\\if :{?owner_role}\nSET LOCAL ROLE :"owner_role";\n\\endif\n' + sql_stream('census') + b'ROLLBACK;\n')


def parse_census(out, phase):
    census = {}
    for row in lines(out, 'census'):
        if row[0] == phase:
            census['|'.join(row[1:-1])] = int(row[-1])
    return census


def read_census(prefix, owner_role=None):
    code, out, err, _ = run_psql(prefix, census_sql(), dict(owner_role=owner_role))
    census = parse_census(out, 'read')
    if code or 'rows_total' not in census:
        raise Refusal('the census could not be read (psql exit %d, SQLSTATE %s)' % (code, ','.join(sqlstates(err)) or 'none'))
    return census


def read_acl(prefix, runtime_role=None):
    code, out, err, _ = run_psql(prefix, sql_stream('acl'), dict(runtime_role=runtime_role))
    if code:
        raise Refusal('the privileges could not be read (psql exit %d, SQLSTATE %s)' % (code, ','.join(sqlstates(err)) or 'none'))
    entries = sorted(l for l in out.splitlines() if l.startswith('acl|') or l.startswith('aclnull|'))
    writable = sorted(l.split('|', 1)[1] for l in out.splitlines() if l.startswith('writable|'))
    counts = lines(out, 'writable_count')
    return dict(entries=entries, entries_sha256=sha256_bytes('\n'.join(entries).encode()), writable=writable,
                writable_count=int(counts[0][0]) if counts else None)


def run_probe(prefix, runtime_role):
    code, out, err, _ = run_psql(prefix, sql_stream('probe'), dict(runtime_role=runtime_role))
    selects = [r[1] for r in lines(out, 'probe') if r[0] == 'select']
    writes = [r[1] for r in lines(out, 'probe') if r[0] == 'write']
    done = any(r[0] == 'done' for r in lines(out, 'probe'))
    return dict(psql_exit=code, select_rows=int(selects[0]) if selects else None,
                write_allowed=bool(writes), write_rows=int(writes[0]) if writes else None,
                write_sqlstates=sqlstates(err), completed=done)


def runtime_sessions(prefix, runtime_role):
    sql = ("\\pset format unaligned\n\\pset tuples_only on\n"
           "SELECT 'role|'||count(*) FROM pg_roles WHERE rolname = :'runtime_role';\n"
           "SELECT 'session|'||COALESCE(state,'unknown')||'|'||count(*) FROM pg_stat_activity"
           " WHERE usename = :'runtime_role' AND datname = current_database() GROUP BY state ORDER BY 1;\n").encode()
    code, out, err, _ = run_psql(prefix, sql, dict(runtime_role=runtime_role))
    roles = lines(out, 'role')
    if code or not roles:
        raise Refusal('the runtime role could not be read (psql exit %d)' % code)
    return int(roles[0][0]), {r[0]: int(r[1]) for r in lines(out, 'session')}


# The line each mutating SQL file prints after its COMMIT, and the reconciliation's rollback line.
COMMIT_LINES = {'marker': 'recovery|mark|COMMITTED', 'reconcile': 'recovery|commit|COMMITTED',
                'close': 'recovery|close|COMMITTED', 'fence': 'recovery|fence|COMMITTED', 'unfence': 'recovery|unfence|COMMITTED'}
ROLLBACK_LINE = 'recovery|commit|ROLLED_BACK'


def stream_write(receipt, prefix, name, variables):
    """Send a mutating SQL file. From here on a write may have run: the receipt says so before psql starts, and
    the stream's own commit evidence is recorded before any later read can fail (see main)."""
    receipt['mutation_attempted'] = True
    started = now()
    code, out, err, elapsed = run_psql(prefix, sql_stream(name), variables)
    printed = out.splitlines()
    receipt['psql'] = dict(exit_code=code, started_utc=started, elapsed_seconds=elapsed, sqlstates=sqlstates(err),
                           commit_reported=COMMIT_LINES[name] in printed, rollback_reported=ROLLBACK_LINE in printed)
    return code, out, err, elapsed


def write_transcript(receipts, name, out, err):
    receipts.write(name + '-psql.txt', ('--- stdout\n' + out + '--- stderr\n' + err).encode())


def unverified_outcome(receipt):
    """What a post-write failure can truthfully say: the stream's own report, marked unverified."""
    stream = receipt.get('psql') or {}
    if stream.get('commit_reported'):
        return 'COMMITTED_UNVERIFIED'
    if stream.get('rollback_reported'):
        return 'ROLLED_BACK_UNVERIFIED'
    return 'UNKNOWN'


# ---------------------------------------------------------------- commands

def command_mark(args, receipts, receipt):
    prefix = psql_prefix(args.psql)
    identity, marker, _ = read_identity(prefix, args, owner_role=args.owner_role, read_marker=True)
    receipt.update(target=identity, owner_role=args.owner_role, recovery_target=args.recovery_target)
    if identity['in_recovery']:
        raise Refusal('the server is still in recovery: promote it first')
    if not identity['replay_timestamp_present']:
        raise Refusal('this server\'s current run did not begin with archive recovery: it is not a promoted restored '
                      'copy, or it was restarted after promote')
    if marker is not None or identity['marker_present']:
        raise Refusal('this database already holds a recovery marker')
    if identity['effective_role'] != identity['opencast_owner']:
        raise Refusal('the effective role does not own schema opencast (use --owner-role)')
    code, out, err, _ = stream_write(receipt, prefix, 'marker', dict(
        nonce=args.nonce, recovery_target=args.recovery_target, target_database=args.target_database,
        system_identifier=args.target_system_identifier, owner_role=args.owner_role))
    committed = receipt['psql']['commit_reported']
    write_transcript(receipts, 'mark', out, err)
    _, after, _ = read_identity(prefix, args, owner_role=args.owner_role, read_marker=True)
    receipt['marker'] = public_marker(after)
    if code == 0 and committed and after is not None and after['nonce_sha256'] == nonce_sha256(args.nonce):
        receipt['nonce_matched'] = True
        return 'PASS'
    raise Stop('the marker was not written (psql exit %d, SQLSTATE %s)' % (code, ','.join(sqlstates(err)) or 'none'))


def command_census(args, receipts, receipt):
    prefix = psql_prefix(args.psql)
    identity, _, _ = read_identity(prefix, args, owner_role=args.owner_role)
    receipt.update(target=identity, label=args.label)
    receipt['census'] = read_census(prefix, args.owner_role)
    return 'PASS'


def parse_reconcile(out):
    statements = []
    previous = None
    gate_rows = [r[1:] for r in lines(out, 'recovery') if r[0] == 'gate']
    if gate_rows:
        previous = float(gate_rows[0][2])
    for row in lines(out, 'recovery'):
        if row[0] == 'stmt':
            at = float(row[3])
            statements.append(dict(id=row[1], rows=int(row[2]),
                                   elapsed_ms=round((at - previous) * 1000, 3) if previous is not None else None))
            previous = at
    markers = {r[1]: dict(zip(('restored_at', 'recovery_target', 'last_replayed_at', 'boundary', 'timeline',
                                'system_identifier', 'database', 'reconciled_at'), r[2:]))
               for r in lines(out, 'recovery') if r[0] == 'marker'}
    post = {r[1]: dict(value=int(r[2]), ok=r[3] == 'ok') for r in lines(out, 'recovery') if r[0] == 'post'}
    commit = [r[1] for r in lines(out, 'recovery') if r[0] == 'commit']
    update = [int(r[1]) for r in lines(out, 'recovery') if r[0] == 'marker_update']
    return dict(statements=statements, markers=markers, postconditions=post, commit=commit[0] if commit else None,
                marker_update=update[0] if update else None,
                gate_guard=int(gate_rows[0][0]) if gate_rows else None,
                gate_wait_us=int(gate_rows[0][1]) if gate_rows else None,
                census_before=parse_census(out, 'before'), census_after=parse_census(out, 'after'))


def command_reconcile(args, receipts, receipt):
    receipt['streamed'] = False
    prefix = psql_prefix(args.psql)
    identity, marker, violations = read_identity(prefix, args, owner_role=args.owner_role, read_marker=True)
    receipt.update(target=identity, owner_role=args.owner_role,
                   timeouts=dict(lock=args.lock_timeout, statement=args.statement_timeout, idle=args.idle_timeout))
    check_marker(args, identity, marker)
    receipt['marker_before'] = public_marker(marker)
    receipt['nonce_matched'] = True
    first_run = marker['reconciled_at'] == ''
    receipt['first_run'] = first_run
    if identity['gate_rows'] != 1:
        raise Refusal('the dispatch gate singleton n_poll_dispatch(id=1) is missing: no direct maintenance without it')
    if not first_run and violations:
        receipt['end_state_violations'] = violations
        raise Refusal('the state changed after reconciliation: this database is no longer the reconciled copy')
    census_pre = read_census(prefix, args.owner_role)
    receipt['census_pre'] = census_pre
    total = time.monotonic()
    receipt['streamed'] = True
    code, out, err, elapsed = stream_write(receipt, prefix, 'reconcile', dict(
        nonce=args.nonce, target_database=args.target_database, system_identifier=args.target_system_identifier,
        owner_role=args.owner_role, lock_timeout=args.lock_timeout, statement_timeout=args.statement_timeout,
        idle_timeout=args.idle_timeout))
    parsed = parse_reconcile(out)
    receipt.update(statements=parsed['statements'], postconditions=parsed['postconditions'],
                   census_before=parsed['census_before'], census_after=parsed['census_after'],
                   gate_guard=parsed['gate_guard'], gate_wait_us=parsed['gate_wait_us'],
                   marker_update=parsed['marker_update'], marker_after=parsed['markers'].get('after'))
    write_transcript(receipts, 'reconcile', out, err)
    committed_census = read_census(prefix, args.owner_role)
    receipt['census_committed'] = committed_census
    _, marker_now, violations_now = read_identity(prefix, args, owner_role=args.owner_role, read_marker=True)
    receipt['marker_committed'] = public_marker(marker_now)
    receipt['elapsed_seconds'] = dict(transaction=elapsed, command=round(time.monotonic() - total, 3))
    ids = tuple(s['id'] for s in parsed['statements'])
    if (code == 0 and parsed['commit'] == 'COMMITTED' and ids == STATEMENTS and parsed['postconditions']
            and all(p['ok'] for p in parsed['postconditions'].values())):
        receipt['outcome'] = 'COMMITTED'
        if committed_census != parsed['census_after'] or violations_now:
            raise Stop('the committed state differs from the transaction\'s own census after')
        return 'PASS'
    witnessed = marker_now is not None and marker_now['reconciled_at'] != ''
    if first_run and witnessed:
        receipt['outcome'] = 'COMMITTED_UNREPORTED'
        raise Stop('psql did not report the commit but the marker records it: read the census, then rerun reconcile '
                   'to confirm the end state (a rerun changes nothing when it holds)')
    if committed_census != census_pre:
        receipt['outcome'] = 'TARGET_STATE_UNKNOWN'
    elif parsed['commit'] == 'ROLLED_BACK':
        receipt['outcome'] = 'ROLLED_BACK'
    else:
        receipt['outcome'] = 'FAILED ' + (sqlstates(err) or ['unknown'])[0]
    raise Stop('the reconciliation did not commit: %s' % receipt['outcome'])


def command_close(args, receipts, receipt):
    prefix = psql_prefix(args.psql)
    identity, marker, violations = read_identity(prefix, args, owner_role=args.owner_role, read_marker=True)
    receipt.update(target=identity, owner_role=args.owner_role)
    check_marker(args, identity, marker)
    receipt['marker'] = public_marker(marker)
    if marker['reconciled_at'] == '':
        raise Refusal('this copy was never reconciled')
    if identity['gate_rows'] != 1:
        raise Refusal('the dispatch gate singleton n_poll_dispatch(id=1) is missing: no direct maintenance without it')
    if violations:
        receipt['end_state_violations'] = violations
        raise Refusal('the reconciled end state no longer holds')
    code, out, err, _ = stream_write(receipt, prefix, 'close', dict(
        nonce=args.nonce, target_database=args.target_database, system_identifier=args.target_system_identifier,
        owner_role=args.owner_role))
    write_transcript(receipts, 'close', out, err)
    after, _, _ = read_identity(prefix, args, owner_role=args.owner_role)
    receipt['marker_present_after'] = after['marker_present']
    if code == 0 and receipt['psql']['commit_reported'] and not after['marker_present']:
        return 'PASS'
    raise Stop('the marker was not dropped (psql exit %d, SQLSTATE %s)' % (code, ','.join(sqlstates(err)) or 'none'))


def superuser_target(prefix, args, receipt):
    identity, _, _ = read_identity(prefix, args)
    receipt['target'] = identity
    if not identity['superuser']:
        raise Refusal('this command needs a superuser session (it probes as the runtime role)')
    return identity


def acl_differences(before, after):
    return sorted(set(before) - set(after)), sorted(set(after) - set(before))


def is_fenced_privilege(entry, runtime_role):
    parts = entry.split('|')
    return parts[0] == 'acl' and parts[3] == runtime_role and (parts[1], parts[5]) in FENCED


def command_fence(args, receipts, receipt):
    prefix = psql_prefix(args.psql)
    identity = superuser_target(prefix, args, receipt)
    receipt['runtime_role'] = args.runtime_role
    if identity['marker_present']:
        raise Refusal('this database holds a recovery marker: it is a restored copy, not the old primary')
    roles, sessions = runtime_sessions(prefix, args.runtime_role)
    if roles != 1:
        raise Refusal('the runtime role does not exist')
    receipt['runtime_sessions'] = sessions
    before = read_acl(prefix, args.runtime_role)
    receipt['acl_before'] = before
    receipt['probe_before'] = run_probe(prefix, args.runtime_role)
    code, out, err, _ = stream_write(receipt, prefix, 'fence', dict(
        runtime_role=args.runtime_role, target_database=args.target_database, system_identifier=args.target_system_identifier))
    write_transcript(receipts, 'fence', out, err)
    after = read_acl(prefix, args.runtime_role)
    receipt['acl_after'] = after
    probe = run_probe(prefix, args.runtime_role)
    receipt['probe_after'] = probe
    removed, added = acl_differences(before['entries'], after['entries'])
    receipt['acl_removed'] = removed
    receipt['acl_added'] = added
    unexpected = [e for e in removed if not is_fenced_privilege(e, args.runtime_role)]
    checks = dict(committed=receipt['psql']['commit_reported'] and code == 0,
                  writable_after_zero=after['writable_count'] == 0 and not after['writable'],
                  probe_write_refused=not probe['write_allowed'] and '42501' in probe['write_sqlstates'],
                  probe_select_allowed=probe['select_rows'] is not None,
                  nothing_added=not added, only_runtime_writes_removed=not unexpected)
    receipt['checks'] = checks
    if all(checks.values()):
        return 'PASS'
    raise Stop('the fence did not read back as complete: %s' % ', '.join(k for k, v in checks.items() if not v))


def read_fence_receipt(args):
    try:
        fence = json.loads(Path(args.fence_receipt).read_text(encoding='utf-8'))
    except (OSError, ValueError):
        raise Refusal('--fence-receipt is not a readable receipt')
    if fence.get('format') != FORMAT or fence.get('command') != 'fence' or fence.get('verdict') != 'PASS':
        raise Refusal('--fence-receipt is not a passing fence receipt')
    target = fence.get('target') or {}
    if target.get('database') != args.target_database or target.get('system_identifier') != args.target_system_identifier:
        raise Refusal('--fence-receipt names another database or cluster')
    if getattr(args, 'runtime_role', None) is not None and fence.get('runtime_role') != args.runtime_role:
        raise Refusal('--fence-receipt names another runtime role')
    return fence


def command_unfence(args, receipts, receipt):
    prefix = psql_prefix(args.psql)
    superuser_target(prefix, args, receipt)
    receipt['runtime_role'] = args.runtime_role
    fence = read_fence_receipt(args)
    receipt['fence_receipt_sha256'] = sha256_file(args.fence_receipt)
    expected = fence['acl_before']['entries']
    receipt['acl_before_unfence'] = read_acl(prefix, args.runtime_role)
    code, out, err, _ = stream_write(receipt, prefix, 'unfence', dict(
        runtime_role=args.runtime_role, target_database=args.target_database, system_identifier=args.target_system_identifier))
    write_transcript(receipts, 'unfence', out, err)
    after = read_acl(prefix, args.runtime_role)
    receipt['acl_after'] = after
    missing, extra = acl_differences(expected, after['entries'])
    receipt['acl_missing'] = missing
    receipt['acl_extra'] = extra
    probe = run_probe(prefix, args.runtime_role)
    receipt['probe_after'] = probe
    checks = dict(committed=receipt['psql']['commit_reported'] and code == 0,
                  acl_equal_to_fence_readback=not missing and not extra,
                  probe_write_allowed=probe['write_allowed'] and probe['write_rows'] == 1)
    receipt['checks'] = checks
    if all(checks.values()):
        return 'PASS'
    raise Stop('the privileges differ from the fence receipt\'s readback (%d missing, %d extra) or the probe failed'
               % (len(missing), len(extra)))


def command_acl(args, receipts, receipt):
    prefix = psql_prefix(args.psql)
    identity, _, _ = read_identity(prefix, args)
    receipt['target'] = identity
    current = read_acl(prefix, args.runtime_role)
    receipt['acl'] = current
    if args.compare is None:
        return 'PASS'
    args.fence_receipt = args.compare
    fence = read_fence_receipt(args)
    missing, extra = acl_differences(fence['acl_before']['entries'], current['entries'])
    receipt.update(compared_with_sha256=sha256_file(args.compare), acl_missing=missing, acl_extra=extra)
    if missing or extra:
        raise Stop('the privileges differ from the fence receipt\'s readback (%d missing, %d extra)' % (len(missing), len(extra)))
    return 'PASS'


# ---------------------------------------------------------------- main

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

    def target(p, owner=True):
        p.add_argument('--psql', required=True, help='JSON array: the psql argv prefix')
        p.add_argument('--target-database', required=True)
        p.add_argument('--target-system-identifier', required=True)
        if owner:
            p.add_argument('--owner-role', help='SET LOCAL ROLE to the owner of schema opencast')
        p.add_argument('--receipts', required=True)

    commands.add_parser('nonce', help='print a fresh nonce for mark, reconcile and close')
    for name in SQL_FILES:
        commands.add_parser(name + '-sql', help='print %s.sql (includes expanded)' % name)
    p = commands.add_parser('mark', help='write the recovery marker on a promoted restored copy')
    target(p)
    p.add_argument('--recovery-target', required=True)
    p.add_argument('--nonce', required=True)
    p = commands.add_parser('census', help='counts and state vocabularies, read-only')
    target(p)
    p.add_argument('--label', default='read')
    p = commands.add_parser('reconcile', help='the guarded reconciliation transaction on a marked copy')
    target(p)
    p.add_argument('--nonce', required=True)
    p.add_argument('--lock-timeout', default='10s')
    p.add_argument('--statement-timeout', default='300s')
    p.add_argument('--idle-timeout', default='60s')
    p = commands.add_parser('close', help='drop the marker of a reconciled copy before it serves again')
    target(p)
    p.add_argument('--nonce', required=True)
    p = commands.add_parser('fence', help='revoke the runtime role\'s writes on the old primary')
    target(p, owner=False)
    p.add_argument('--runtime-role', required=True)
    p = commands.add_parser('unfence', help='re-apply the shipped runtime grants, proved by ACL equality')
    target(p, owner=False)
    p.add_argument('--runtime-role', required=True)
    p.add_argument('--fence-receipt', required=True)
    p = commands.add_parser('acl', help='the privilege readback, optionally compared with a fence receipt')
    target(p, owner=False)
    p.add_argument('--runtime-role')
    p.add_argument('--compare', help='a fence receipt whose acl_before the readback must equal')
    return top


HANDLERS = {
    'mark': command_mark,
    'census': command_census,
    'reconcile': command_reconcile,
    'close': command_close,
    'fence': command_fence,
    'unfence': command_unfence,
    'acl': command_acl,
}


def receipt_name(args):
    return 'census-%s.json' % args.label if args.command == 'census' and LABEL.match(args.label) else args.command + '.json'


def main(argv=None):
    os.umask(0o077)
    raw_argv = list(sys.argv[1:] if argv is None else argv)
    args = parser().parse_args(raw_argv)
    if args.command == 'nonce':
        print(secrets.token_hex(16))
        return 0
    if args.command.endswith('-sql'):
        sys.stdout.write(sql_stream(args.command[:-4]).decode('utf-8'))
        return 0
    name = receipt_name(args)
    try:
        receipts = Receipts(args.receipts)
        if receipts.exists(name):
            raise Refusal('receipt %s already exists' % name)
    except Refusal as error:
        print(json.dumps(dict(command=args.command, verdict='REFUSED', reason=str(error))), file=sys.stderr)
        return 2
    receipt = dict(format=FORMAT, command=args.command, argv=redact_argv(raw_argv), tool_sha256=sha256_file(TOOL),
                   sql_sha256={n: sha256_bytes(sql_stream(n)) for n in SQL_FILES},
                   python=sys.version.split()[0], started_utc=now())
    try:
        prevalidate(args)
        receipt['verdict'] = HANDLERS[args.command](args, receipts, receipt)
        code = 0
    except Stop as error:
        receipt.update(verdict='STOP', reason=str(error))
        code = 1
    except Exception as error:  # Refusal, OSError and anything unexpected; never print a traceback
        if receipt.get('mutation_attempted'):
            # A write stream was sent, so a write may have run: never report this as a refusal before writing.
            receipt.update(verdict='STOP', outcome=unverified_outcome(receipt),
                           reason='after the write stream: ' + describe(error))
            code = 1
        elif isinstance(error, Refusal):
            receipt.update(verdict='REFUSED', reason=str(error))
            code = 2
        elif isinstance(error, OSError):
            receipt.update(verdict='REFUSED', reason=describe(error))
            code = 2
        else:
            receipt.update(verdict='ERROR', reason=describe(error))
            code = 2
    if receipt.get('mutation_attempted') and 'outcome' not in receipt:
        receipt['outcome'] = 'COMMITTED' if receipt['psql'].get('commit_reported') else 'NOT_COMMITTED'
    receipt.update(finished_utc=now(), exit_code=code)
    summary = dict(command=args.command, verdict=receipt['verdict'], outcome=receipt.get('outcome'),
                   reason=receipt.get('reason'), receipt=str(receipts.path(name)))
    try:
        receipts.write(name, receipt)
    except OSError as error:
        summary.update(receipt=None, receipt_error=type(error).__name__)
        print(json.dumps(summary), file=sys.stderr)
        return 1 if receipt.get('mutation_attempted') else 2
    print(json.dumps(summary))
    return code


def describe(error):
    if isinstance(error, Refusal):
        return str(error)
    if isinstance(error, OSError):
        return '%s on an input or output path' % type(error).__name__
    frame = traceback.extract_tb(error.__traceback__)[-1]
    return 'internal error %s at %s:%d in %s' % (type(error).__name__, Path(frame.filename).name, frame.lineno, frame.name)


if __name__ == '__main__':
    sys.exit(main())
