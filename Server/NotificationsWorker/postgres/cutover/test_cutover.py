"""Unit tests for cutover.py; no PostgreSQL, Podman or network.

Run from the repository root:
  python3 -B -m unittest discover -s Server/NotificationsWorker/postgres/cutover
A small fake psql (written to a temporary directory) stands in for the target;
it answers with the checked-in catalog of a fresh install,
fixtures/target-catalog.txt (README.md says how to regenerate it).
"""
import contextlib
import hashlib
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import cutover

HERE = Path(__file__).resolve().parent
CATALOG = HERE / 'fixtures' / 'target-catalog.txt'
SCHEMA_FILES = HERE.parent / 'migrations'
IDENTITY = 'identity|%s|%s|180006|UTF8|reader|false'
TARGET = ('cutover_target', '7000000000000000001')
# The fake target's one row per table: one value per target type.
SAMPLE = {'bigint': ('integer', 1), 'text': ('text', b'a'), 'bytea': ('blob', b'\x01')}

FAKE_PSQL = r'''
import json, sys
config = json.load(open(sys.argv[1]))
request = sys.stdin.read()
out = sys.stdout
snapshot = 'cutover-catalog' in request
catalog = "'table|'" in request
if 'pg_control_system' in request:
    key = 'identity_snapshot' if snapshot else 'identity_catalog' if catalog else 'identity'
    out.write(config.get(key, config['identity']) + '\n')
if snapshot:
    out.write('cutover-catalog\n')
    out.write('\n'.join(config['catalog']) + '\n')
    for table in config['order']:
        out.write('cutover-table|%s\n' % table)
        with open(config['rows'] + '/' + table + '.lines') as stream:
            for line in stream:
                out.write(config.get('replace', {}).get(line.rstrip('\n'), line.rstrip('\n')) + '\n')
    out.write('cutover-end\n')
elif catalog:
    out.write('\n'.join(config['catalog']) + '\n')
elif 'pg_control_system' not in request:
    sys.exit(3)
'''


def catalog_fixture():
    """The fixture's migrations digest (its first line) and its catalog lines, CATALOG_SQL's output."""
    first, *catalog = CATALOG.read_text(encoding='ascii').splitlines()
    kind, _, digest = first.partition('|')
    return (digest if kind == 'migrations' else None), catalog


def sample(table):
    """The fake target's row of one table, as (class, value) pairs in column order."""
    _, columns, _, _, _ = cutover.read_catalog(catalog_fixture()[1])
    return [SAMPLE[kind] for _, _, kind in sorted(columns[table])]


class Workspace(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp())
        os.chmod(self.root, 0o700)
        self.addCleanup(shutil.rmtree, self.root)

    def run_tool(self, *argv):
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            return cutover.main([str(a) for a in argv])

    def receipt(self, name, receipts='R'):
        return json.loads((self.root / receipts / name).read_text())


class CanonicalForm(unittest.TestCase):
    def test_tokens_for_every_class(self):
        self.assertEqual(cutover.token('null', None), 'null')
        self.assertEqual(cutover.token('integer', -(1 << 63)), '-9223372036854775808')
        self.assertEqual(cutover.token('integer', (1 << 63) - 1), '9223372036854775807')
        self.assertEqual(cutover.token('real', 1e16), '"r:1e+16"')
        self.assertEqual(cutover.token('real', -0.0), '"r:-0.0"')
        self.assertEqual(cutover.token('real', float('inf')), '"r:inf"')
        self.assertEqual(cutover.token('text', 'é\U0001F600\x00'.encode()), '"t:c3a9f09f988000"')
        self.assertEqual(cutover.token('blob', b''), '"b:"')
        self.assertEqual(cutover.token('blob', b'\x00\xff'), '"b:00ff"')
        for bad in (1 << 63, -(1 << 63) - 1, True):
            with self.assertRaises(cutover.Stop):
                cutover.token('integer', bad)

    def test_line_round_trip_and_non_canonical_lines(self):
        values = [('integer', 1), ('null', None), ('text', b'a'), ('blob', b'\x01'), ('real', 2.5)]
        line = cutover.make_line(values)
        self.assertEqual(line, '[1,null,"t:61","b:01","r:2.5"]')
        self.assertEqual(cutover.decode_line(line), values)
        for bad in ['[1, null]', '["t:6A"]', '["t:6"]', '[true]', '[1.0]', '["x:00"]', '{}', '[01]']:
            with self.assertRaises(cutover.Stop, msg=bad):
                cutover.decode_line(bad)

    def test_two_level_digest_matches_an_independent_computation(self):
        lines = ['[1,"t:61"]', '[2,"t:62"]', '[3,null]']
        digest = cutover.TableDigest('t', [0])
        for line in lines:
            digest.add(line, cutover.decode_line(line))
        rows = b''.join(hashlib.sha256(l.encode() + b'\n').digest() for l in lines)
        self.assertEqual(digest.hexdigest(), hashlib.sha256(rows).hexdigest())
        self.assertEqual(cutover.TableDigest('t', [0]).hexdigest(), hashlib.sha256(b'').hexdigest())

    def test_strictly_ascending_order_is_enforced_by_bytes(self):
        keys = [b'Z', b'a', 'é'.encode(), '\U0001F600'.encode()]
        self.assertEqual(sorted(keys), keys)
        digest = cutover.TableDigest('t', [0])
        for key in keys:
            digest.add(cutover.make_line([('text', key)]), [('text', key)])
        for sequence in ([b'b', b'a'], [b'a', b'a']):
            digest = cutover.TableDigest('t', [0])
            digest.add('["t:%s"]' % sequence[0].hex(), [('text', sequence[0])])
            with self.assertRaises(cutover.Stop):
                digest.add('["t:%s"]' % sequence[1].hex(), [('text', sequence[1])])
        mixed = cutover.TableDigest('t', [0])
        for values in ([('null', None)], [('integer', -5)], [('real', 2.5)], [('integer', 3)], [('text', b'')], [('blob', b'')]):
            mixed.add(cutover.make_line(values), values)


class TargetSql(unittest.TestCase):
    def test_golden_value_expressions_and_order(self):
        self.assertEqual(cutover.pg_value_sql('a', 'integer'), """COALESCE("a"::text,'null')""")
        self.assertEqual(cutover.pg_value_sql('a', 'text'), """COALESCE('"t:'||encode(convert_to("a",'UTF8'),'hex')||'"','null')""")
        self.assertEqual(cutover.pg_value_sql('a', 'blob'), """COALESCE('"b:'||encode("a",'hex')||'"','null')""")
        self.assertEqual(cutover.pg_order_sql([('a', 'text'), ('b', 'integer'), ('c', 'blob')], ['a', 'b', 'c']), '"a" COLLATE "C", "b", "c"')
        self.assertIn("string_agg(sha256(convert_to('['||", cutover.pg_digest_sql('t', [('a', 'integer')], ['a']))
        with self.assertRaises(cutover.Refusal):
            cutover.pg_value_sql('a', 'real')

    def test_psql_arguments_never_carry_a_password(self):
        self.assertEqual(cutover.psql_prefix('["psql", "-d", "postgresql://reader@db.example.com/x"]')[0], 'psql')
        for bad in ['["psql", "password=x"]', '["sshpass", "-p", "x", "ssh"]', '["/usr/bin/sshpass"]',
                    '["ssh", "host", "PGPASSWORD=x psql"]', '["psql", "postgresql://u:p@db.example.com/x"]', '[]', '"psql"', '[1]']:
            with self.assertRaises(cutover.Refusal, msg=bad):
                cutover.psql_prefix(bad)


class CatalogFixture(unittest.TestCase):
    def test_the_catalog_fixture_is_the_shipped_schema(self):
        digest, catalog = catalog_fixture()
        shipped = hashlib.sha256(b''.join(p.read_bytes() for p in sorted(SCHEMA_FILES.glob('*.sql')))).hexdigest()
        self.assertEqual(digest, shipped, 'the shipped migrations changed: regenerate the catalog fixture (README.md)')
        self.assertEqual(catalog, sorted(catalog))
        tables, columns, keys, triggers, privileges = cutover.read_catalog(catalog)
        self.assertEqual(len(cutover.COPY_ORDER), 32)
        self.assertEqual(tables, set(cutover.COPY_ORDER))
        self.assertEqual({t: tuple(sorted(n)) for t, n in triggers.items()}, cutover.TRIGGERS)
        self.assertEqual({s for states in triggers.values() for s in states.values()}, {'O'})
        # Read as the read-only role manifest-target requires.
        self.assertEqual(privileges, {t: (True, False) for t in cutover.COPY_ORDER})
        for table in cutover.COPY_ORDER:
            self.assertTrue(keys.get(table), table)
            self.assertTrue(all(kind in cutover.TARGET_TYPES for _, _, kind in columns[table]), table)


class FakePsql(Workspace):
    """A fake psql per name: the fixture catalog, one sample row per table, an identity."""

    def prepare(self, replace=None, catalog_edit=None, identity=None, name='fake'):
        rows = self.root / (name + '-rows')
        rows.mkdir(mode=0o700)
        for table in cutover.COPY_ORDER:
            (rows / (table + '.lines')).write_text(cutover.make_line(sample(table)) + '\n', encoding='ascii')
        catalog = catalog_fixture()[1]
        if catalog_edit:
            catalog = catalog_edit(catalog)
        config = dict(catalog=sorted(catalog), order=list(cutover.COPY_ORDER), rows=str(rows), replace=replace or {},
                      identity=identity or IDENTITY % TARGET)
        (self.root / (name + '.json')).write_text(json.dumps(config))
        (self.root / 'fake_psql.py').write_text(FAKE_PSQL)
        self.psql = json.dumps([sys.executable, str(self.root / 'fake_psql.py'), str(self.root / (name + '.json'))])

    def target(self, *extra, receipts='R', database=TARGET):
        return self.run_tool('manifest-target', '--psql', self.psql, '--target-database', database[0],
                             '--target-system-identifier', database[1], '--receipts', self.root / receipts, *extra)


class FakeTarget(FakePsql):
    def test_non_canonical_target_lines_and_writable_roles_stop(self):
        line = cutover.make_line(sample('n_feed'))
        self.prepare(replace={line: line.replace('"t:', '"t:'.upper(), 1)})
        self.assertEqual(self.target(), 1)
        self.setUp()
        self.prepare(catalog_edit=lambda c: [l.replace('privilege|n_feed|true|false', 'privilege|n_feed|true|true') for l in c])
        self.assertEqual(self.target(), 2)
        self.setUp()
        self.prepare(catalog_edit=lambda c: [l.replace('|epoch|bigint', '|epoch|numeric') for l in c])
        self.assertEqual(self.target(), 1)

    def test_identity_is_read_again_in_every_session(self):
        for key, reason in (('identity_catalog', 'catalog session'), ('identity_snapshot', 'inside the read snapshot')):
            self.setUp()
            self.prepare()
            config = json.loads((self.root / 'fake.json').read_text())
            config[key] = 'identity|cutover_target|7000000000000000002|180006|UTF8|reader|false'
            (self.root / 'fake.json').write_text(json.dumps(config))
            self.assertEqual(self.target(), 2, key)
            receipt = self.receipt('manifest-target.json')
            self.assertIn(reason, receipt['reason'])
            self.assertFalse((self.root / 'R/target-manifest.json').exists())
        self.setUp()
        self.prepare()
        self.assertEqual(self.target(), 0)
        self.assertEqual(len(self.receipt('manifest-target.json')['identity_checks']), 3)

    def test_identity_must_be_the_named_database(self):
        self.prepare(identity='identity|other_database|7000000000000000001|180006|UTF8|reader|false')
        self.assertEqual(self.target(), 2)
        self.assertIn('identity mismatch', self.receipt('manifest-target.json')['reason'])


class CompareTargets(FakePsql):
    def sides(self, database=TARGET, **restored):
        """manifest-target on the reference (R1) and on the restored copy (R2), each over its own fake psql."""
        self.prepare(name='reference')
        self.assertEqual(self.target('--rows-dir', self.root / 'rows-1', receipts='R1'), 0)
        self.prepare(name='restored', **restored)
        self.assertEqual(self.target('--rows-dir', self.root / 'rows-2', receipts='R2', database=database), 0)

    def compare(self, *extra, receipts='R3'):
        return self.run_tool('compare-targets', '--reference', self.root / 'R1', '--restored', self.root / 'R2',
                             '--receipts', self.root / receipts, *extra)

    def rewrite(self, receipts, edit):
        """A target manifest edited as another database would read, with its receipt naming it."""
        path = self.root / receipts / 'target-manifest.json'
        body = json.loads(path.read_text())['manifest']
        edit(body)
        digest = cutover.sha256_bytes(cutover.canonical_json(body).encode())
        path.write_text(json.dumps(dict(format=cutover.FORMAT, manifest=body, manifest_digest=digest)))
        receipt = self.receipt('manifest-target.json', receipts)
        (self.root / receipts / 'manifest-target.json').write_text(json.dumps(dict(receipt, manifest_digest=digest)))

    def differences(self, receipts='R3'):
        return sorted((d['kind'], d['table']) for d in self.receipt('compare-targets.json', receipts)['differences'])

    def test_equal_targets_pass_with_no_difference(self):
        self.sides()
        self.assertEqual(self.compare(), 0)
        receipt = self.receipt('compare-targets.json', 'R3')
        self.assertEqual((receipt['verdict'], receipt['differences'], receipt['difference_count']), ('PASS', [], 0))
        self.assertEqual(receipt['reference_manifest_digest'], self.receipt('manifest-target.json', 'R1')['manifest_digest'])
        self.assertEqual(receipt['restored_manifest_digest'], receipt['reference_manifest_digest'])
        self.assertNotIn('operator_action', receipt)

    def test_a_changed_or_added_row_is_listed_with_its_rows_detail(self):
        origin, stat = cutover.make_line(sample('n_poll_origin')), cutover.make_line(sample('n_poll_stat'))
        self.assertEqual((origin, stat), ('["t:61",1,1,1,1]', '[1,1,1,1,1,1,1,1,1]'))
        # n_poll_origin: its one row changed and a second row added; n_poll_stat: its one row changed.
        self.sides(replace={origin: '["t:61",1,2,1,1]\n["t:62",1,1,1,1]', stat: '[1,2,1,1,1,1,1,1,1]'})
        self.assertEqual(self.compare('--reference-rows', self.root / 'rows-1', '--restored-rows', self.root / 'rows-2'), 1)
        self.assertEqual(self.differences(), [('digest', 'n_poll_origin'), ('digest', 'n_poll_stat'), ('rows', 'n_poll_origin')])
        details = {d['table']: d.get('rows_detail') for d in self.receipt('compare-targets.json', 'R3')['differences'] if d['kind'] == 'digest'}
        self.assertEqual(details, {'n_poll_origin': dict(missing=0, extra=1, changed=1), 'n_poll_stat': dict(missing=0, extra=0, changed=1)})
        self.assertEqual(self.receipt('compare-targets.json', 'R3')['operator_action'],
                         'The restored copy does not equal its reference: do not promote it.')
        # Without both row directories the differences carry no detail.
        self.assertEqual(self.compare('--reference-rows', self.root / 'rows-1', receipts='R4'), 1)
        self.assertFalse(any('rows_detail' in d for d in self.receipt('compare-targets.json', 'R4')['differences']))

    def test_a_disabled_trigger_on_either_side_is_a_difference(self):
        self.sides(catalog_edit=lambda c: [l.replace('trigger|devices|n_device_insert|O', 'trigger|devices|n_device_insert|D') for l in c])
        self.assertEqual(self.compare(), 1)
        self.assertEqual(self.receipt('compare-targets.json', 'R3')['differences'],
                         [dict(kind='trigger_state', table=None, reference=[], restored=['devices.n_device_insert'])])
        self.setUp()
        self.sides()
        self.rewrite('R1', lambda body: body['trigger_states']['n_feed'].update(n_feed_insert='D'))
        self.assertEqual(self.compare(), 1)
        self.assertEqual(self.receipt('compare-targets.json', 'R3')['differences'],
                         [dict(kind='trigger_state', table=None, reference=['n_feed.n_feed_insert'], restored=[])])

    def test_a_missing_table_is_a_table_set_difference(self):
        self.sides()
        self.rewrite('R2', lambda body: body['tables'].pop('n_deleted_install'))
        self.assertEqual(self.compare(), 1)
        self.assertEqual(self.receipt('compare-targets.json', 'R3')['differences'],
                         [dict(kind='table_set', table='n_deleted_install', reference=True, restored=False)])

    def test_a_control_difference_is_listed(self):
        self.sides()
        reference = self.receipt('target-manifest.json', 'R1')['manifest']['controls']
        self.assertEqual((reference['n_control'], reference['max_feed_epoch']), ([['a', 1, 1]], 1))

        def edit(body):
            body['controls']['n_control'] = [['a', 0, 2]]
            body['controls']['max_feed_epoch'] = 2
        self.rewrite('R2', edit)
        self.assertEqual(self.compare(), 1)
        self.assertEqual(self.receipt('compare-targets.json', 'R3')['differences'],
                         [dict(kind='controls', table='max_feed_epoch', reference=1, restored=2),
                          dict(kind='controls', table='n_control', reference=[['a', 1, 1]], restored=[['a', 0, 2]])])

    def test_target_identities_are_recorded_and_never_compared(self):
        restored = ('restored_copy', '7000000000000000002')
        self.sides(database=restored, identity=IDENTITY % restored)
        self.assertEqual(self.compare(), 0)
        receipt = self.receipt('compare-targets.json', 'R3')
        self.assertEqual((receipt['difference_count'], receipt['differences']), (0, []))
        self.assertEqual((receipt['reference_target']['database'], receipt['reference_target']['system_identifier']), TARGET)
        self.assertEqual((receipt['restored_target']['database'], receipt['restored_target']['system_identifier']), restored)
        self.assertNotEqual(receipt['reference_manifest_digest'], receipt['restored_manifest_digest'])

    def test_compare_targets_lists_each_difference_kind(self):
        self.sides()

        def edit(body):
            body['tables']['n_poll_origin']['rows'] += 1
            body['tables']['n_poll_stat']['digest'] = '0' * 64
            body['tables']['n_circuit']['columns'][0][0] = 'lane_renamed'
            body['tables']['n_control']['primary_key'] = ['enabled']
            del body['tables']['n_deleted_install']
            body['controls']['max_install_epoch'] = 7
            body['triggers']['n_feed'] = ['n_catalog_enrolled']
            body['trigger_states']['devices']['n_device_insert'] = 'D'
        self.rewrite('R2', edit)
        self.assertEqual(self.compare(), 1)
        self.assertEqual(self.differences(), [('columns', 'n_circuit'), ('controls', 'max_install_epoch'), ('digest', 'n_poll_stat'),
                                              ('primary_key', 'n_control'), ('rows', 'n_poll_origin'), ('table_set', 'n_deleted_install'),
                                              ('trigger_names', None), ('trigger_state', None)])

    def test_both_sides_must_be_passing_target_manifests_their_receipts_name(self):
        self.sides()
        receipt = self.receipt('manifest-target.json', 'R2')
        (self.root / 'R2/manifest-target.json').write_text(json.dumps(dict(receipt, verdict='STOP')))
        self.assertEqual(self.compare(), 1)
        self.assertEqual(self.receipt('compare-targets.json', 'R3')['differences'],
                         [dict(kind='receipt', table=None, reference='PASS', restored='STOP')])
        cases = {
            'the restored target manifest is not the one its receipt recorded':
                lambda: (self.root / 'R2/manifest-target.json').write_text(json.dumps(dict(receipt, manifest_digest='0' * 64))),
            'the restored manifest is not a target manifest': lambda: self.rewrite('R2', lambda body: body.update(side='source')),
            'the restored manifest-target receipt is missing or unreadable': lambda: (self.root / 'R2/manifest-target.json').unlink(),
            'the manifest file is not an intact cutover manifest (restored)': lambda: (self.root / 'R2/target-manifest.json').write_text('{}'),
        }
        for reason, damage in cases.items():
            self.setUp()
            self.sides()
            receipt = self.receipt('manifest-target.json', 'R2')
            damage()
            self.assertEqual(self.compare(), 2, reason)
            self.assertEqual(self.receipt('compare-targets.json', 'R3')['reason'], reason)


class CredentialRedaction(Workspace):
    SENTINEL = 'TEST_SYNTHETIC_CREDENTIAL_F1'
    FORMS = [('password', ['psql', 'password=' + SENTINEL]),
             ('uri', ['psql', 'postgresql://u:' + SENTINEL + '@db.example.com/x']),
             ('ssh-pgpassword', ['ssh', 'host', 'PGPASSWORD=' + SENTINEL + ' psql']),
             ('sshpass', ['sshpass', '-p', SENTINEL, 'ssh'])]

    def cli(self, *argv):
        return subprocess.run([sys.executable, '-I', str(HERE / 'cutover.py')] + [str(a) for a in argv],
                              capture_output=True, text=True)

    def assert_sentinel_absent(self, result, receipts):
        self.assertNotIn(self.SENTINEL, result.stdout + result.stderr)
        for path in receipts.rglob('*') if receipts.exists() else []:
            if path.is_file():
                self.assertNotIn(self.SENTINEL, path.read_text(), path)

    def test_refused_credentials_never_reach_receipts_or_output(self):
        command = 'manifest-target'
        for name, prefix in self.FORMS:
            receipts = self.root / ('%s-%s' % (command, name))
            for psql in (['--psql', json.dumps(prefix)], ['--psql=' + json.dumps(prefix)]):
                if receipts.exists():
                    shutil.rmtree(receipts)
                result = self.cli(command, *psql, '--target-database', 'x', '--target-system-identifier', '1',
                                  '--receipts', receipts)
                self.assertEqual(result.returncode, 2, (command, name))
                self.assert_sentinel_absent(result, receipts)
                self.assertEqual(sorted(p.name for p in receipts.iterdir()), [command + '.json'])
                receipt = json.loads((receipts / (command + '.json')).read_text())
                self.assertEqual(receipt['verdict'], 'REFUSED')
                self.assertIn('password', receipt['reason'])
                self.assertTrue(any(cutover.REDACTED in a for a in receipt['argv']))
                self.assertIn('--target-database', receipt['argv'])

    def test_argparse_errors_do_not_echo_values(self):
        receipts = self.root / 'R'
        result = self.cli('compare-targets', '--reference', 'a', '--restored', 'b', '--receipts', receipts,
                          'password=' + self.SENTINEL)
        self.assertEqual(result.returncode, 2)
        self.assert_sentinel_absent(result, receipts)
        self.assertFalse(receipts.exists())
        self.assertIn('values are not echoed', result.stderr)

    def test_redaction_keeps_every_other_element(self):
        argv = ['manifest-target', '--psql', '["sshpass", "-p", "x", "ssh"]', '--target-database', 'db', '--statement-timeout=60s']
        self.assertEqual(cutover.redact_argv(argv),
                         ['manifest-target', '--psql', cutover.REDACTED, '--target-database', 'db', '--statement-timeout=60s'])
        self.assertEqual(cutover.redact_argv(['--psql=["psql", "password=x"]']), ['--psql=' + cutover.REDACTED])


class Receipts(Workspace):
    def test_receipts_are_private_and_never_overwritten(self):
        compare = ['compare-targets', '--reference', self.root / 'absent-1', '--restored', self.root / 'absent-2']
        open_dir = self.root / 'open'
        open_dir.mkdir(mode=0o755)
        os.chmod(open_dir, 0o755)
        self.assertEqual(self.run_tool(*compare, '--receipts', open_dir), 2)
        self.assertFalse((open_dir / 'compare-targets.json').exists())
        receipts = self.root / 'R'
        self.assertEqual(self.run_tool(*compare, '--receipts', receipts), 2)
        self.assertEqual(self.receipt('compare-targets.json')['verdict'], 'REFUSED')
        self.assertEqual(self.run_tool(*compare, '--receipts', receipts), 2)
        self.assertEqual(oct((receipts / 'compare-targets.json').stat().st_mode & 0o777), '0o600')


if __name__ == '__main__':
    unittest.main()
