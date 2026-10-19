"""Unit tests for recovery.py and its SQL files; no PostgreSQL, Podman or network.

Run from the repository root:
  python3 -m unittest discover -s Server/NotificationsWorker/postgres/recovery
A small fake psql (written to a temporary directory) stands in for the target and
records every stream it receives. test_recovery_pg.py holds the live tests; they
skip unless OPENCAST_RECOVERY_PG names a configuration.
"""
import contextlib
import io
import json
import os
import re
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

import recovery

HERE = Path(__file__).resolve().parent
POSTGRES = HERE.parent
SOURCE = POSTGRES.parent / 'src' / 'database' / 'postgres'
GRANT_FILES = ('runtime-grants.sql', 'runtime-grants-slice-b.sql', 'runtime-grants-slice-c.sql', 'runtime-grants-slice-d.sql',
               'runtime-grants-slice-e.sql', 'runtime-grants-slice-f.sql', 'runtime-grants-integration.sql')
NONCE = '0123456789abcdef0123456789abcdef'
SYSID = '7000000000000000001'

FAKE_PSQL = r'''
import json, os, sys
config = json.load(open(sys.argv[1]))
request = sys.stdin.read()
log = config['log']
count = len([n for n in os.listdir(log) if n.endswith('.sql')])
open(os.path.join(log, '%03d.sql' % count), 'w').write(request)
streamed = os.path.exists(os.path.join(log, 'streamed'))
out = sys.stdout
writes = ("'recovery|stmt|R13|'", 'CREATE SCHEMA opencast_recovery', 'DROP SCHEMA opencast_recovery', 'REVOKE INSERT',
          'recovery|unfence|COMMITTED')
if any(w in request for w in writes) and "'identity|'" not in request:
    kind = 'stream'
elif "'identity|'" in request:
    kind = 'identity'
elif "'census|'" in request:
    kind = 'census'
elif "'acl|database|'" in request:
    kind = 'acl'
elif "'probe|select|'" in request:
    kind = 'probe'
else:
    kind = 'sessions'
if streamed and kind in config.get('fail_after_stream', []):
    sys.stderr.write('psql: synthetic connection loss\n')
    sys.exit(2)
if kind == 'stream':
    open(os.path.join(log, 'streamed'), 'w').close()
    out.write(config.get('stream_out', ''))
    sys.exit(config.get('stream_exit', 3))
if kind == 'identity':
    out.write(config['identity'] + '\n')
    if 'recovery_has_marker' in request:
        out.write(config.get('marker', 'marker|absent') + '\n')
        for line in config.get('endstate', []):
            out.write(line + '\n')
        out.write(config.get('gate', 'gate|1') + '\n')
elif kind == 'census':
    out.write('census|read|rows_total|99\ncensus|read|devices|4\n')
elif kind == 'acl':
    out.write('acl|table|n_feed|opencast_fixture_runtime|opencast_fixture_owner|UPDATE|false\nwritable|table|n_feed\nwritable_count|1\n')
elif kind == 'probe':
    out.write('probe|select|9\nprobe|write|1\nprobe|done\n')
else:
    out.write('role|1\n')
sys.exit(0)
'''


def identity(database='opencast_staging', sysid=SYSID, superuser='off', in_recovery='false', timeline='2', replayed='true',
             effective='opencast_fixture_owner', owner='opencast_fixture_owner', marker='true'):
    return '|'.join(['identity', database, sysid, '180006', 'UTF8', 'postgres', effective, superuser, in_recovery, timeline,
                     replayed, owner, marker])


def marker_line(nonce=NONCE, timeline='2', database='opencast_staging', sysid=SYSID, reconciled=''):
    return '|'.join(['marker', 'opencast-recovery-marker-1', recovery.nonce_sha256(nonce), '1800000000', 'latest',
                     '1799999990', '1800000000', timeline, sysid, database, reconciled])


def derived_writable_tables():
    """Tables on which the shipped grant files give the runtime role a write privilege (table or column level)."""
    writable = set()
    for name in GRANT_FILES:
        text = '\n'.join(l for l in (POSTGRES / name).read_text().splitlines() if not l.lstrip().startswith('--'))
        for statement in (s.strip() for s in text.split(';')):
            match = re.match(r'GRANT\s+(.+?)\s+ON\s+(?!SCHEMA)(.+?)\s+TO\s+:"runtime_role"$', statement, re.S)
            if not match:
                continue
            privileges = re.sub(r'\([^)]*\)', '', match.group(1))
            if {p.strip().split()[0] for p in privileges.split(',')} & {'INSERT', 'UPDATE', 'DELETE', 'TRUNCATE'}:
                writable.update(t.strip().split('.', 1)[1] for t in match.group(2).replace('\n', ' ').split(','))
    return sorted(writable)


def committed_reconcile_stream():
    """What reconcile.sql prints when its transaction commits (counts arbitrary, shape exact)."""
    fields = '1800000000|latest|1799999990|1800000000|2|%s|opencast_staging' % SYSID
    out = ['recovery|vars|4', 'recovery|marker|before|%s|' % fields, 'recovery|gate|1|300|1800000001.000000',
           'census|before|rows_total|99', 'census|before|devices|4']
    out += ['recovery|stmt|%s|0|%.6f' % (sid, 1800000001.0 + (i + 1) / 1000) for i, sid in enumerate(recovery.STATEMENTS)]
    out += ['recovery|marker_update|1', 'recovery|marker|after|%s|1800000002' % fields, 'recovery|post|devices|0|ok',
            'census|after|rows_total|35', 'census|after|devices|0', 'recovery|commit|COMMITTED']
    return '\n'.join(out) + '\n'


def gate_guard_evaluated(text):
    """True when the gate statement's outer SELECT reads the guard column, so 1/COUNT(*) cannot be pruned."""
    match = re.search(r"SELECT 'recovery\|gate\|'(.*?)\nFROM \(SELECT 1/COUNT\(\*\) AS guard,", text, re.S)
    return bool(match) and re.search(r'\bg\.guard\b', match.group(1)) is not None


def strip_comments(text):
    return '\n'.join(l for l in text.splitlines() if not l.lstrip().startswith('--'))


class Workspace(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.root)
        self.log = self.root / 'log'
        self.log.mkdir()
        self.fake = self.root / 'fake_psql.py'
        self.fake.write_text(FAKE_PSQL)
        self.config = self.root / 'config.json'
        self.receipts = self.root / 'receipts'
        self.receipts.mkdir(mode=0o700)

    def configure(self, **values):
        values.setdefault('identity', identity())
        values['log'] = str(self.log)
        self.config.write_text(json.dumps(values))

    def run_tool(self, *argv):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            try:
                code = recovery.main(list(argv))
            except SystemExit as error:
                code = error.code
        return code, out.getvalue(), err.getvalue()

    def target(self, *extra):
        return ['--psql', json.dumps([sys.executable, str(self.fake), str(self.config)]), '--target-database', 'opencast_staging',
                '--target-system-identifier', SYSID, '--receipts', str(self.receipts)] + list(extra)

    def receipt(self, name):
        return json.loads((self.receipts / name).read_text())

    def streams(self):
        return [p.read_text() for p in sorted(self.log.iterdir())]


class Usage(Workspace):
    def test_a_malformed_or_missing_flag_exits_2_before_any_receipt(self):
        for argv in (['reconcile', '--bogus'], ['reconcile'], ['mark', '--nonce', NONCE]):
            code, _, _ = self.run_tool(*argv)
            self.assertEqual(code, 2)
        self.assertEqual(list(self.receipts.iterdir()), [])

    def test_argparse_errors_do_not_echo_values(self):
        code, _, err = self.run_tool('census', '--label', 'x', '--unknown=secret-value')
        self.assertEqual(code, 2)
        self.assertNotIn('secret-value', err)

    def test_a_credential_in_psql_is_refused_and_never_recorded(self):
        self.configure()
        argv = self.target('--nonce', NONCE)
        argv[1] = json.dumps(['psql', 'postgresql://u:hunter2@db/x'])
        code, _, _ = self.run_tool('reconcile', *argv)
        receipt = self.receipt('reconcile.json')
        self.assertEqual((code, receipt['verdict']), (2, 'REFUSED'))
        self.assertNotIn('hunter2', json.dumps(receipt))
        self.assertEqual(self.streams(), [])

    def test_a_malformed_nonce_or_recovery_target_is_refused(self):
        self.configure()
        code, _, _ = self.run_tool('reconcile', *self.target('--nonce', 'ABC'))
        self.assertEqual((code, self.receipt('reconcile.json')['verdict']), (2, 'REFUSED'))
        code, _, _ = self.run_tool('mark', *self.target('--nonce', NONCE, '--recovery-target', 'yesterday'))
        self.assertEqual((code, self.receipt('mark.json')['verdict']), (2, 'REFUSED'))
        self.assertEqual(self.streams(), [])

    def test_receipts_are_private_and_never_overwritten(self):
        self.configure(marker=marker_line())
        os.chmod(self.receipts, 0o755)
        code, _, err = self.run_tool('census', *self.target())
        self.assertEqual(code, 2)
        self.assertIn('0700', err)
        os.chmod(self.receipts, 0o700)
        self.assertEqual(self.run_tool('census', *self.target())[0], 0)
        code, _, err = self.run_tool('census', *self.target())
        self.assertEqual(code, 2)
        self.assertIn('already exists', err)

    def test_the_nonce_command_prints_a_valid_nonce(self):
        code, out, _ = self.run_tool('nonce')
        self.assertEqual(code, 0)
        self.assertRegex(out.strip(), recovery.NONCE)


class Guard(Workspace):
    def reconcile(self, nonce=NONCE):
        code, _, _ = self.run_tool('reconcile', *self.target('--nonce', nonce, '--owner-role', 'opencast_fixture_owner'))
        receipt = self.receipt('reconcile.json')
        streamed = any('recovery|stmt|R13' in s for s in self.streams())
        return code, receipt, streamed

    def assertRefusedUnstreamed(self, reason):
        code, receipt, streamed = self.reconcile()
        self.assertEqual((code, receipt['verdict'], receipt['streamed'], streamed), (2, 'REFUSED', False, False))
        self.assertIn(reason, receipt['reason'])

    def test_no_marker_refuses(self):
        self.configure(identity=identity(marker='false'))
        self.assertRefusedUnstreamed('no recovery marker')

    def test_a_wrong_nonce_refuses(self):
        self.configure(marker=marker_line(nonce='f' * 32))
        self.assertRefusedUnstreamed('nonce')

    def test_another_timeline_database_or_cluster_refuses(self):
        for marker in (marker_line(timeline='3'), marker_line(database='opencast_fixture'), marker_line(sysid='7000000000000000002')):
            for path in self.receipts.iterdir():
                path.unlink()
            self.configure(marker=marker)
            self.assertRefusedUnstreamed('another database, cluster or timeline')

    def test_the_connected_database_must_be_the_one_named(self):
        self.configure(identity=identity(database='postgres'), marker=marker_line())
        self.assertRefusedUnstreamed('identity mismatch')

    def test_the_effective_role_must_own_the_schema(self):
        self.configure(identity=identity(effective='postgres'), marker=marker_line())
        self.assertRefusedUnstreamed('does not own schema opencast')

    def test_a_rerun_after_a_change_refuses(self):
        self.configure(marker=marker_line(reconciled='1800000100'), endstate=['endstate|devices|1'])
        self.assertRefusedUnstreamed('state changed after reconciliation')

    def test_a_valid_marker_streams_the_reconciliation_with_the_nonce_on_stdin_only(self):
        self.configure(marker=marker_line())
        code, receipt, streamed = self.reconcile()
        self.assertTrue(streamed)
        self.assertEqual((code, receipt['verdict']), (1, 'STOP'))
        self.assertTrue(receipt['outcome'].startswith('FAILED'))
        stream = next(s for s in self.streams() if 'recovery|stmt|R13' in s)
        self.assertIn('\\set nonce %s\n' % NONCE, stream)
        self.assertNotIn(NONCE, json.dumps(receipt))
        self.assertIn('sha256:' + recovery.nonce_sha256(NONCE)[:12], receipt['argv'])

    def test_mark_refuses_a_server_that_did_not_start_through_archive_recovery(self):
        for ident, reason in ((identity(marker='false', replayed='false'), 'archive recovery'),
                              (identity(marker='false', in_recovery='true', timeline=''), 'still in recovery'),
                              (identity(marker='true'), 'already holds')):
            for path in self.receipts.iterdir():
                path.unlink()
            self.configure(identity=ident, marker=marker_line())
            code, _, _ = self.run_tool('mark', *self.target('--nonce', NONCE, '--recovery-target', 'latest'))
            receipt = self.receipt('mark.json')
            self.assertEqual((code, receipt['verdict']), (2, 'REFUSED'))
            self.assertIn(reason, receipt['reason'])
        self.assertFalse(any('CREATE SCHEMA opencast_recovery' in s for s in self.streams()))

    def test_fence_refuses_a_marked_database_or_a_session_that_is_not_superuser(self):
        for ident, reason in ((identity(superuser='on', marker='true'), 'recovery marker'), (identity(marker='false'), 'superuser')):
            for path in self.receipts.iterdir():
                path.unlink()
            self.configure(identity=ident)
            code, _, _ = self.run_tool('fence', *self.target('--runtime-role', 'opencast_fixture_runtime'))
            receipt = self.receipt('fence.json')
            self.assertEqual((code, receipt['verdict']), (2, 'REFUSED'))
            self.assertIn(reason, receipt['reason'])
        self.assertFalse(any('REVOKE INSERT' in s for s in self.streams()))

    def test_a_missing_gate_singleton_refuses_reconcile_and_close_before_streaming(self):
        self.configure(marker=marker_line(), gate='gate|0')
        self.assertRefusedUnstreamed('dispatch gate singleton')
        for path in self.receipts.iterdir():
            path.unlink()
        self.configure(marker=marker_line(reconciled='1800000100'), gate='gate|0')
        code, _, _ = self.run_tool('close', *self.target('--nonce', NONCE))
        receipt = self.receipt('close.json')
        self.assertEqual((code, receipt['verdict']), (2, 'REFUSED'))
        self.assertIn('dispatch gate singleton', receipt['reason'])
        self.assertFalse(any('DROP SCHEMA' in s for s in self.streams()))

    def test_close_refuses_a_copy_that_was_never_reconciled(self):
        self.configure(marker=marker_line())
        code, _, _ = self.run_tool('close', *self.target('--nonce', NONCE))
        receipt = self.receipt('close.json')
        self.assertEqual((code, receipt['verdict']), (2, 'REFUSED'))
        self.assertFalse(any('DROP SCHEMA' in s for s in self.streams()))


class MarkerSchemaPrivilege(Workspace):
    """A role without USAGE on the marker schema (the reader) still reads the identity; marker presence is then unknown."""

    def test_a_census_by_a_role_that_cannot_read_the_marker_schema_records_the_marker_as_unknown(self):
        self.configure(identity=identity(effective='opencast_fixture_reader', marker='unreadable'))
        code, _, _ = self.run_tool('census', *self.target('--label', 'reader'))
        receipt = self.receipt('census-reader.json')
        self.assertEqual((code, receipt['verdict']), (0, 'PASS'))
        self.assertIsNone(receipt['target']['marker_present'])

    def test_reconcile_refuses_before_any_stream_when_the_marker_schema_is_unreadable(self):
        self.configure(identity=identity(marker='unreadable'), marker=marker_line())
        code, _, _ = self.run_tool('reconcile', *self.target('--nonce', NONCE, '--owner-role', 'opencast_fixture_owner'))
        receipt = self.receipt('reconcile.json')
        self.assertEqual((code, receipt['verdict'], receipt['streamed']), (2, 'REFUSED', False))
        self.assertIn('marker schema is not readable', receipt['reason'])
        self.assertFalse(any('recovery|stmt|R13' in s for s in self.streams()))

    def test_the_identity_probe_needs_no_privilege_on_the_marker_schema(self):
        sql = recovery.preflight_sql(False).decode()
        self.assertIn("to_regnamespace('opencast_recovery')", sql)
        self.assertIn("has_schema_privilege('opencast_recovery', 'USAGE')", sql)
        self.assertNotIn("(to_regclass('opencast_recovery.marker') IS NOT NULL)::text;", sql)


class PostWrite(Workspace):
    """Once a write stream is sent, a later failure is STOP with the stream's own evidence, never REFUSED."""

    def reconcile(self, **config):
        self.configure(marker=marker_line(), **config)
        code, out, _ = self.run_tool('reconcile', *self.target('--nonce', NONCE, '--owner-role', 'opencast_fixture_owner'))
        return code, self.receipt('reconcile.json'), json.loads(out.strip().splitlines()[-1])

    def assertCommittedUnverified(self, code, receipt):
        self.assertEqual((code, receipt['verdict'], receipt['outcome']), (1, 'STOP', 'COMMITTED_UNVERIFIED'))
        self.assertTrue(receipt['mutation_attempted'])
        self.assertTrue(receipt['psql']['commit_reported'])
        self.assertEqual(receipt['psql']['exit_code'], 0)
        self.assertTrue(receipt['reason'].startswith('after the write stream: '))

    def test_a_lost_census_after_a_committed_stream_is_stop_committed_unverified(self):
        code, receipt, console = self.reconcile(stream_out=committed_reconcile_stream(), stream_exit=0, fail_after_stream=['census'])
        self.assertCommittedUnverified(code, receipt)
        self.assertEqual(tuple(s['id'] for s in receipt['statements']), recovery.STATEMENTS)
        self.assertEqual(receipt['census_after'], {'rows_total': 35, 'devices': 0})
        self.assertEqual(console['outcome'], 'COMMITTED_UNVERIFIED')

    def test_a_lost_witness_read_after_a_committed_stream_is_stop_committed_unverified(self):
        code, receipt, _ = self.reconcile(stream_out=committed_reconcile_stream(), stream_exit=0, fail_after_stream=['identity'])
        self.assertCommittedUnverified(code, receipt)
        self.assertIn('census_committed', receipt)
        self.assertNotIn('marker_committed', receipt)

    def test_an_output_failure_after_the_stream_is_stop_not_refused(self):
        (self.receipts / 'reconcile-psql.txt').write_text('in the way')
        code, receipt, _ = self.reconcile(stream_out=committed_reconcile_stream(), stream_exit=0)
        self.assertCommittedUnverified(code, receipt)
        self.assertIn('FileExistsError', receipt['reason'])
        self.assertEqual(len(receipt['statements']), len(recovery.STATEMENTS))

    def test_an_unreadable_stream_outcome_is_unknown(self):
        code, receipt, _ = self.reconcile(stream_out='', stream_exit=2, fail_after_stream=['census'])
        self.assertEqual((code, receipt['verdict'], receipt['outcome']), (1, 'STOP', 'UNKNOWN'))
        self.assertFalse(receipt['psql']['commit_reported'])

    def test_every_mutating_subcommand_reports_a_post_stream_failure_as_stop(self):
        fence = self.root / 'fence.json'
        fence.write_text(json.dumps(dict(format=recovery.FORMAT, command='fence', verdict='PASS', runtime_role='opencast_fixture_runtime',
                                         target=dict(database='opencast_staging', system_identifier=SYSID),
                                         acl_before=dict(entries=[]))))
        cases = (
            ('mark', ['--nonce', NONCE, '--recovery-target', 'latest'], 'recovery|mark|COMMITTED',
             dict(identity=identity(marker='false')), 'identity'),
            ('close', ['--nonce', NONCE], 'recovery|close|COMMITTED', dict(marker=marker_line(reconciled='1800000100')), 'identity'),
            ('fence', ['--runtime-role', 'opencast_fixture_runtime'], 'recovery|fence|COMMITTED',
             dict(identity=identity(superuser='on', marker='false')), 'acl'),
            ('unfence', ['--runtime-role', 'opencast_fixture_runtime', '--fence-receipt', str(fence)], 'recovery|unfence|COMMITTED',
             dict(identity=identity(superuser='on', marker='false')), 'acl'),
        )
        for command, extra, line, config, lost in cases:
            for path in list(self.receipts.iterdir()) + list(self.log.iterdir()):
                path.unlink()
            self.configure(stream_out=line + '\n', stream_exit=0, fail_after_stream=[lost], **config)
            code, _, _ = self.run_tool(command, *self.target(*extra))
            receipt = self.receipt(command + '.json')
            self.assertCommittedUnverified(code, receipt)


class StatementSet(unittest.TestCase):
    def setUp(self):
        self.reconcile = strip_comments(recovery.sql_text('reconcile'))

    def test_the_marker_precedes_the_gate_which_precedes_every_application_row(self):
        marker = self.reconcile.index('FROM opencast_recovery.marker WHERE id = 1 FOR UPDATE')
        gate = self.reconcile.index('FROM (SELECT id FROM opencast.n_poll_dispatch WHERE id=1 FOR UPDATE) AS gate')
        first_application = min(m.start() for m in re.finditer(r'\bopencast\.(?!n_poll_dispatch\b)[a-z_]+', self.reconcile))
        self.assertLess(marker, gate)
        self.assertLess(gate, first_application)
        self.assertNotRegex(self.reconcile[:gate], r'\bopencast\.[a-z_]+')

    def test_the_gate_is_the_storage_interfaces_fail_closed_probe(self):
        gate = re.search(r'pub\(super\) const GATE: &str = "([^"]+)";', (SOURCE / 'mod.rs').read_text()).group(1)
        self.assertIn(gate.replace('n_poll_dispatch', 'opencast.n_poll_dispatch'), self.reconcile.replace('\n      ', ' '))

    def test_the_gate_guard_is_evaluated_in_reconcile_and_close(self):
        for name in ('reconcile', 'close'):
            self.assertTrue(gate_guard_evaluated(recovery.sql_text(name)), name)

    def test_a_gate_whose_guard_is_not_read_is_caught(self):
        for name in ('reconcile', 'close'):
            dropped = recovery.sql_text(name).replace("g.guard || '|' || ", '')
            self.assertNotEqual(dropped, recovery.sql_text(name))
            self.assertFalse(gate_guard_evaluated(dropped), name)

    def test_statement_ids_and_order(self):
        ids = tuple(re.findall(r"'recovery\|stmt\|([A-Za-z0-9]+)\|'", self.reconcile))
        self.assertEqual(ids, recovery.STATEMENTS)

    def test_the_erasure_is_the_products_installation_erasure_table_wide(self):
        erase = re.search(r'EraseInstall \{install,fence,now\}=>\{(.*?)\n        \},', (SOURCE / 'slice_c.rs').read_text(), re.S).group(1)
        product = re.findall(r'"DELETE FROM ([a-z_]+) WHERE', erase)
        ours = re.findall(r'DELETE FROM opencast\.([a-z_]+)', self.reconcile)
        self.assertEqual(ours, product + ['app_attest_challenge_source_buckets'])
        predicated = re.findall(r'DELETE FROM opencast\.([a-z_]+) WHERE', self.reconcile)
        self.assertEqual(predicated, ['n_group_member', 'n_event'])
        span = self.reconcile[self.reconcile.index("'recovery|stmt|R7|'"):self.reconcile.index("'recovery|stmt|R17|'")]
        self.assertEqual(len(re.findall(r"kind <> 'episode'", span)), 2)

    def test_one_end_state_list_in_every_file_covering_every_table_wide_erasure(self):
        blocks = recovery.END_STATE.findall(recovery.sql_text('reconcile')) + recovery.END_STATE.findall(recovery.sql_text('close'))
        self.assertEqual(len(blocks), 3)
        self.assertEqual(len(set(blocks)), 1)
        self.assertIn(blocks[0], recovery.preflight_sql(True).decode())
        names = set(re.findall(r"\('([a-z_]+)',", blocks[0]))
        erased = set(re.findall(r'DELETE FROM opencast\.([a-z_]+) RETURNING', self.reconcile))
        self.assertTrue(erased <= names, erased - names)
        self.assertTrue({'n_event_job', 'n_group_member_job', 'n_event_unfinished', 'n_outbox_pending', 'n_control_enabled',
                         'n_feed_leased'} <= names)

    def test_closures_write_the_boundary_and_r12_runs_once_per_marker(self):
        self.assertIn("terminal_at = current_setting('opencast_recovery.boundary')::bigint", self.reconcile)
        self.assertIn("SET changed_at = current_setting('opencast_recovery.boundary')::bigint", self.reconcile)
        self.assertIn('WHERE (SELECT reconciled_at FROM opencast_recovery.marker WHERE id = 1) IS NULL', self.reconcile)
        self.assertIn("WHERE fanout_complete = 0", self.reconcile)
        self.assertNotIn("disposition IN ('pending'", self.reconcile)

    def test_no_trigger_is_disabled(self):
        for name in recovery.SQL_FILES:
            self.assertNotRegex(recovery.sql_text(name), r'(?i)DISABLE\s+TRIGGER|session_replication_role')

    def test_census_tables_are_the_32_application_tables_and_print_no_row_value(self):
        sys.path.insert(0, str(POSTGRES / 'cutover'))
        try:
            import cutover
        finally:
            sys.path.pop(0)
        census = recovery.sql_text('census')
        counted = set(re.findall(r"\('([a-z_]+)', \(SELECT count\(\*\) FROM opencast\.\1\)\)", census))
        self.assertEqual(counted, set(cutover.COPY_ORDER))
        concatenated = set(re.findall(r'\|\|\s*([a-z_.]+)\b(?!\s*\()', census))
        self.assertEqual(concatenated, {'c.k', 'c.v', 'state', 'disposition', 'name', 'lane'})


class FenceSet(unittest.TestCase):
    def test_the_fence_refuses_a_marker_before_it_revokes(self):
        fence = strip_comments(recovery.sql_text('fence'))
        self.assertLess(fence.index("to_regclass('opencast_recovery.marker')"), fence.index('REVOKE INSERT'))
        self.assertIn('REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON ALL TABLES IN SCHEMA opencast FROM :"runtime_role";', fence)
        self.assertIn('REVOKE USAGE, UPDATE ON ALL SEQUENCES IN SCHEMA opencast FROM :"runtime_role";', fence)

    def test_the_unfence_is_the_seven_grant_files_in_the_readme_order(self):
        readme = (POSTGRES / 'README.md').read_text()
        order = re.search(r'A production\ninstall has one runtime role and applies, in this order, every file to that\n'
                          r'role with `-v runtime_role=<runtime role>`: (.*?), then\n`(runtime-grants-integration\.sql)`', readme, re.S)
        files = re.findall(r'`([a-z0-9/_.-]+\.sql)`', order.group(1)) + [order.group(2)]
        self.assertEqual(len(files), 11)
        grants = tuple(f for f in files if not f.startswith('migrations/'))
        self.assertEqual(grants, GRANT_FILES)
        includes = tuple(re.findall(r'^\\ir \.\./([a-z0-9-]+\.sql)$', recovery.sql_text('unfence'), re.M))
        self.assertEqual(includes, GRANT_FILES)
        stream = recovery.sql_stream('unfence').decode()
        for name in GRANT_FILES:
            self.assertIn((POSTGRES / name).read_text(), stream)
        self.assertNotRegex(''.join((POSTGRES / n).read_text() for n in GRANT_FILES), r'(?im)^\s*(REVOKE|BEGIN|COMMIT)\b')

    def test_the_derived_writable_tables_cover_every_grant_statement(self):
        statements = sum(len(re.findall(r'(?m)^GRANT\b', (POSTGRES / n).read_text())) for n in GRANT_FILES)
        self.assertEqual(statements, 126)
        tables = derived_writable_tables()
        self.assertIn('n_poll_dispatch', tables)
        self.assertNotIn('n_control', tables)
        self.assertEqual(len(tables), len(set(tables)))

    def test_the_fenced_privilege_set_names_only_writes(self):
        self.assertEqual({p for _, p in recovery.FENCED}, {'INSERT', 'UPDATE', 'DELETE', 'TRUNCATE', 'USAGE'})
        self.assertTrue(recovery.is_fenced_privilege('acl|table|n_feed|rt|owner|UPDATE|false', 'rt'))
        self.assertFalse(recovery.is_fenced_privilege('acl|table|n_feed|rt|owner|SELECT|false', 'rt'))
        self.assertFalse(recovery.is_fenced_privilege('acl|table|n_feed|reader|owner|UPDATE|false', 'rt'))


class Conventions(unittest.TestCase):
    def test_parity_with_the_cutover_tool(self):
        sys.path.insert(0, str(POSTGRES / 'cutover'))
        try:
            import cutover
        finally:
            sys.path.pop(0)
        self.assertEqual(recovery.SECRET_ARGUMENT.pattern, cutover.SECRET_ARGUMENT.pattern)
        self.assertEqual(recovery.PSQL_FLAGS, cutover.PSQL_FLAGS)
        self.assertEqual(recovery.SQLSTATE.pattern, cutover.SQLSTATE.pattern)

    def test_every_sql_file_reports_sqlstates_only_and_stops_on_error(self):
        for name in ('marker', 'reconcile', 'close', 'fence', 'unfence'):
            text = recovery.sql_text(name)
            for line in ('\\set ON_ERROR_STOP on', '\\set VERBOSITY sqlstate', '\\set SHOW_CONTEXT never'):
                self.assertIn(line, text, name)

    def test_redaction_keeps_every_other_element(self):
        argv = ['reconcile', '--nonce', NONCE, '--psql', '["psql"]', '--nonce=%s' % NONCE]
        out = recovery.redact_argv(argv)
        self.assertEqual(out[:2] + out[3:5], ['reconcile', '--nonce', '--psql', '["psql"]'])
        self.assertNotIn(NONCE, json.dumps(out))

    def test_no_shipped_file_names_a_plan_path(self):
        for path in HERE.iterdir():
            if path.suffix in ('.py', '.sql', '.md'):
                self.assertNotRegex(path.read_text(), 'no' + 'tes/|pa' + 'ss 0[0-9]|la' + r'ne [A-Z]\b', path.name)


if __name__ == '__main__':
    unittest.main()
