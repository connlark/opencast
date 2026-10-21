"""The parser's controls: every class from exactly its named inputs, the one C2
predicate for the positive and both negative controls, the recovery terms that
stay unknown, the retry interval only from two consecutive retained attempts,
and the join precedence. Run: python3 -m unittest discover -s <this directory>.
With STORAGE_PHASES_ROWS=<file of lines>, every line there must also parse."""
import copy
import json
import os
import unittest

import storage_phases_parse as p


def row(**over):
    """A failed dispatch whose primary crossed the authority's deadline after
    10.5 s of in-cap work: the C2 shape of the seeded sequence."""
    base = {
        'schema': 2, 'event': 'storage_phases', 'handler': 'dispatch', 'outcome': 'failed',
        'wall_ms': 12_500, 'scheduled_lag_ms': 800, 'date_vs_perf_ms': 0, 'identity': 'cached',
        'durations': {'storage': 12_400, 'r2': 0, 'service': 0, 'alert': 0, 'publisher': 0, 'queue': 0, 'idle': 100},
        'ops': {'total': 6, 'reads': 5, 'writes': 1, 'readbacks': 0, 'identity': 0, 'interactive': 0,
                'after_primary': 0, 'dropped': 0, 'detailed': 6, 'omitted': 0},
        'budget': {'handler_main_ms': 12_000, 'scope': 'main', 'source': 'HANDLER_MS'},
        'prior': {'taken_at_ordinal': 5, 'noncompleted_count': 0, 'over_local_cap_count': 0, 'close_failures': 0,
                  'lost_records': 0, 'all_within_local_caps': 'true'},
        'recovery': {'admission_ms': None, 'wait_remaining_s': None, 'first_action': None, 'last_action': None,
                     'outbox_release': {'acknowledged_txns': 0, 'attempted_txns': 0, 'unknown_txns': 0},
                     'page_repeated': 'unknown'},
        'summary': {'races': {'total': 18}, 'connect': {'union_ms': 300, 'max_ms': 60, 'timeouts': 0},
                    'read': {'max_ms': 3_500, 'timeouts': 1}, 'transaction': {'max_ms': 200, 'timeouts': 0},
                    'close': {'sum_ms': 30, 'max_ms': 5}, 'rollback': {'sum_ms': 0},
                    'gate_wait_us_max': 2_000, 'gate_reply_ms_max': 3, 'overshoot_ms_max': 0,
                    'budget_min_ms': 1_500, 'budget_min_limit': 'authority_deadline',
                    'local_cap_sum_ms': 10_500, 'affected_rows': 1, 'rows_returned': 12},
        'primary': {'ordinal': 5, 'op': 'A01', 'role': 'operation', 'parent': None, 'status': 'failed',
                    'kind': 'Deadline', 'phase': 'read', 'outcome': 'NotApplicable', 'sqlstate': None,
                    'race': {'boundary': 'read', 'limit': 'authority_deadline', 'budget_ms': 1_500,
                             'status': 'timeout', 'submitted': True, 'steps_total': None,
                             'steps_completed': None, 'gate_reply_at_ms': None, 'gate_wait_us': None,
                             'sqlstate': None, 'overshoot_ms': 0},
                    'overshoot_ms': 0, 'local_cap_sum_before_ms': 10_500},
        'failures': [], 'failures_truncated': 0, 'slowest': [], 'action': [], 'actions_truncated': 0,
        'chain': None, 'message_age_ms': None, 'sent': None, 'posts': None,
        'truncated': {'op_detail': False, 'op_races': False, 'actions': False, 'slowest': False, 'failures': False},
        'bytes_policy': 'within', 'op': [],
    }
    value = copy.deepcopy(base)
    for path, item in over.items():
        target = value
        keys = path.split('__')
        for key in keys[:-1]:
            target = target[key]
        target[keys[-1]] = item
    return value


def consume(feed, generation, step, attempts, digest, age, wall, sent=None, **extra):
    value = row(handler='consume', outcome='ok', primary=None, prior=None, wall_ms=wall, message_age_ms=age,
                chain={'feed': feed, 'generation': generation, 'step': step, 'attempts': attempts,
                       'message_digest': digest}, sent=sent)
    value.update(extra)
    return value


class Classes(unittest.TestCase):
    def test_the_seeded_crossing_is_c2_and_only_where_its_inputs_say_so(self):
        self.assertIs(p.c2(row()), True)
        self.assertIn('C2', p.classified(row())['tags'])
        # The same crossing under a 30 s main budget: 10.5 s is under 75 %.
        self.assertIs(p.c2(row(budget__handler_main_ms=30_000)), False)
        self.assertIs(p.c2(row(budget__handler_main_ms=30_000, primary__local_cap_sum_before_ms=28_000)), True)

    def test_a_read_and_a_write_at_their_own_local_caps_are_never_c2(self):
        read = row(primary__race__limit='statement_ms', primary__race__budget_ms=4_000,
                   primary__local_cap_sum_before_ms=1_000)
        self.assertIs(p.c2(read), False)
        write = row(primary__race={'boundary': 'transaction', 'limit': 'statement_ms', 'budget_ms': 4_000,
                                   'status': 'timeout', 'submitted': True, 'steps_total': 4, 'steps_completed': 2,
                                   'gate_reply_at_ms': 1_010, 'gate_wait_us': 30, 'sqlstate': None,
                                   'overshoot_ms': 0}, primary__local_cap_sum_before_ms=1_000)
        tags = p.tags(write)
        self.assertIs(tags['C2'], False)
        self.assertIs(tags['C3'], True)
        self.assertIs(tags["C3'"], False)

    def test_the_prior_snapshot_decides_c2_never_the_close(self):
        # Invariance: a close failure is counted apart and changes no tag.
        a, b = row(), row(prior__close_failures=1)
        self.assertEqual(p.tags(a), p.tags(b))
        # A completed earlier race over its budget: prior false, C2 false.
        self.assertIs(p.c2(row(prior__over_local_cap_count=1, prior__all_within_local_caps='false')), False)
        # A lost earlier record: unknown, never false, never true.
        lost = row(prior__lost_records=1, prior__all_within_local_caps='unknown')
        self.assertEqual(p.c2(lost), p.UNKNOWN)
        self.assertIn('C2', p.classified(lost)['unknown'])

    def test_c5_differs_by_exactly_the_gate_wait(self):
        slow, fast = row(summary__gate_wait_us_max=1_200_000), row(summary__gate_wait_us_max=200_000)
        a, b = p.tags(slow), p.tags(fast)
        self.assertEqual({k for k in a if a[k] != b[k]}, {'C5'})
        self.assertEqual(p.tags(row(summary__gate_wait_us_max=None))['C5'], p.UNKNOWN)

    def test_a_server_error_and_a_no_race_failure(self):
        server = row(primary__race__status='database', primary__race__sqlstate='57014',
                     primary__race__limit='statement_ms', primary__kind='Database')
        tags = p.tags(server)
        self.assertFalse(tags['C2'] or tags['C3'] or tags["C3'"])
        decode = row(primary__race=None, primary__kind='Decode')
        tags = p.tags(decode)
        self.assertIs(tags['C2'], False)
        self.assertIs(tags['C1'], False)

    def test_the_lost_acknowledgement_is_c3_prime_not_c3(self):
        held = row(primary__race={'boundary': 'transaction', 'limit': 'statement_ms', 'budget_ms': 4_000,
                                  'status': 'timeout', 'submitted': True, 'steps_total': 4, 'steps_completed': 3,
                                  'gate_reply_at_ms': 9, 'gate_wait_us': 5, 'sqlstate': None, 'overshoot_ms': 0})
        tags = p.tags(held)
        self.assertIs(tags["C3'"], True)
        self.assertIs(tags['C3'], False)

    def test_unresolved_needs_the_platform_wall_unless_nothing_matched(self):
        quiet = row(primary__race__limit='statement_ms', scheduled_lag_ms=0, durations__idle=0,
                    summary__connect__union_ms=0)
        self.assertIs(p.tags(quiet)['U'], True)
        loud = row()
        self.assertEqual(p.tags(loud)['U'], p.UNKNOWN)
        self.assertIs(p.tags(loud, {'wallTimeMs': 14_000})['U'], True)
        self.assertIs(p.tags(loud, {'wallTimeMs': 12_600})['U'], False)
        self.assertEqual(p.tags(row(scheduled_lag_ms=None))['C0'], p.UNKNOWN)


class MissingInputs(unittest.TestCase):
    """An absent input is unavailable evidence: unknown, never false. An
    explicit null keeps its schema meaning, and a decisive operand still
    decides."""

    @staticmethod
    def without(path, **over):
        value = row(**over)
        target = value
        keys = path.split('__')
        for key in keys[:-1]:
            target = target[key]
        del target[keys[-1]]
        return value

    def test_c2_without_its_limit_its_prior_or_its_prefix_validity(self):
        for path in ('primary__race__limit', 'prior', 'prior__all_within_local_caps', 'primary__race'):
            self.assertEqual(p.c2(self.without(path)), p.UNKNOWN, path)
            self.assertIn('C2', p.classified(self.without(path))['unknown'], path)
        # Explicit: a race-free primary or no primary is never C2.
        self.assertIs(p.c2(row(primary__race=None, primary__kind='Decode')), False)
        self.assertIs(p.c2(row(primary=None, prior=None)), False)
        # Decisive: a local-cap limit is not C2 whatever the prior says.
        self.assertIs(p.c2(self.without('prior', primary__race__limit='statement_ms')), False)

    def write(self, **race):
        value = {'boundary': 'transaction', 'limit': 'statement_ms', 'budget_ms': 4_000, 'status': 'timeout',
                 'submitted': True, 'steps_total': 4, 'steps_completed': 2, 'gate_reply_at_ms': 1_010,
                 'gate_wait_us': 30, 'sqlstate': None, 'overshoot_ms': 0}
        value.update(race)
        return row(primary__race=value)

    def test_incomplete_transaction_operands(self):
        self.assertEqual((p.tags(self.write())['C3'], p.tags(self.write())["C3'"]), (True, False))
        for key in ('boundary', 'status', 'submitted', 'steps_total', 'steps_completed'):
            tags = p.tags(self.without('primary__race__' + key, primary__race=self.write()['primary']['race']))
            self.assertEqual((tags['C3'], tags["C3'"]), (p.UNKNOWN, p.UNKNOWN), key)
        # Without the gate's reply time, BEGIN complete and not all but COMMIT:
        # the lost acknowledgement is unknown, and so is the slow write.
        tags = p.tags(self.without('primary__race__gate_reply_at_ms', primary__race=self.write()['primary']['race']))
        self.assertEqual((tags['C3'], tags["C3'"]), (p.UNKNOWN, p.UNKNOWN))
        # Decisive: all but COMMIT is C3' whatever the gate field; a read is neither.
        held = self.write(steps_completed=3)
        del held['primary']['race']['gate_reply_at_ms']
        self.assertEqual((p.tags(held)['C3'], p.tags(held)["C3'"]), (False, True))
        read = self.without('primary__race__submitted')
        self.assertEqual((p.tags(read)['C3'], p.tags(read)["C3'"]), (False, False))

    def test_overshoot_null_is_no_timeout_and_absent_is_unknown(self):
        self.assertIs(p.tags(row(summary__overshoot_ms_max=None, primary__overshoot_ms=None))['C7'], False)
        self.assertEqual(p.tags(self.without('summary__overshoot_ms_max'))['C7'], p.UNKNOWN)
        self.assertEqual(p.tags(self.without('primary__overshoot_ms'))['C7'], p.UNKNOWN)
        self.assertIs(p.tags(self.without('primary__overshoot_ms', summary__overshoot_ms_max=1_200))['C7'], True)

    def test_the_other_classes_under_the_same_rule(self):
        self.assertEqual(p.tags(self.without('scheduled_lag_ms'))['C0'], p.UNKNOWN)
        self.assertEqual(p.tags(self.without('summary__connect__union_ms', primary__race__boundary='read'))['C1'],
                         p.UNKNOWN)
        self.assertIs(p.tags(self.without('summary__connect__union_ms', primary__race__boundary='connect'))['C1'],
                      True)
        self.assertEqual(p.tags(self.without('primary__race__boundary', summary__connect__union_ms=0))['C1'],
                         p.UNKNOWN)
        self.assertEqual(p.tags(self.without('durations__r2'))['C4'], p.UNKNOWN)
        self.assertEqual(p.tags(self.without('summary__gate_wait_us_max'))['C5'], p.UNKNOWN)
        self.assertEqual(p.tags(self.without('durations__idle'))['C6'], p.UNKNOWN)
        # U: no signature still decides it; without one, its own absent inputs are unknown.
        quiet = dict(primary__race__limit='statement_ms', scheduled_lag_ms=0, durations__idle=0,
                     summary__connect__union_ms=0)
        self.assertIs(p.tags(self.without('ops__dropped', **quiet))['U'], True)
        loud = self.without('ops__dropped')
        self.assertEqual(p.tags(loud, {'wallTimeMs': 12_600})['U'], p.UNKNOWN)
        self.assertIs(p.tags(row(), {'wallTimeMs': 12_600})['U'], False)

    def test_a_refused_consume_is_not_a_storage_failure(self):
        refused = row(handler='consume', outcome='refused', primary=None, prior=None)
        self.assertEqual(p.classified(refused), {'tags': [], 'unknown': [], 'classified': False})
        self.assertTrue(p.classified(row(handler='consume', outcome='failed', primary=None, prior=None))['classified'])

    def test_a_malformed_structure_is_rejected_not_read_as_false(self):
        for key, value in (('summary', None), ('ops', []), ('primary', 'A01')):
            with self.assertRaises(p.Rejected):
                p.parse(row(**{key: value}))
        with self.assertRaises(p.Rejected):
            p.parse(row(primary__race='read'))


class Recovery(unittest.TestCase):
    def drain(self, cursor_end, cursor_start=None, status='committed'):
        action = {'name': 'drain', 'start_checkpoint': None if cursor_start is None else
                  {'kind': 'drain', 'phase': None, 'candidate_cursor': cursor_start, 'status': 'committed'},
                  'end_checkpoint': None if cursor_end is None else
                  {'kind': 'drain', 'phase': None, 'candidate_cursor': cursor_end, 'status': status}}
        return row(recovery__first_action=action, recovery__last_action=action)

    def test_cursor_equality_is_coarse_and_never_page_repetition(self):
        defects = []
        same, other = self.drain(100, 0), self.drain(100, 100)
        self.assertEqual(p.cursor_comparison(same, other), 'equal')
        self.assertEqual(p.cursor_comparison(self.drain(100, 0), self.drain(200, 200)), 'unequal')
        # Different observations, both at offset 0; an obsolete retry; a maturity-only drain.
        self.assertEqual(p.cursor_comparison(self.drain(0, 0), self.drain(0, 0)), 'equal')
        self.assertIsNone(p.cursor_comparison(self.drain(100, 0), self.drain(None, None)))
        for value in (same, other, self.drain(None, None)):
            self.assertEqual(p.page_repeated(value, defects), p.UNKNOWN)
        self.assertEqual(defects, [])
        claimed = row(recovery__page_repeated='true')
        self.assertEqual(p.page_repeated(claimed, defects), p.UNKNOWN)
        self.assertEqual(defects, [('page_repeated', 'true')])

    def test_an_unknown_checkpoint_stays_unknown_whatever_comes_after(self):
        # alpha (committed, ack lost) and beta (never committed; another delivery
        # redid it) leave the same fields: unknown in both.
        def prepare(start, end, status):
            return {'name': 'prepare',
                    'start_checkpoint': {'kind': 'prepare', 'phase': start, 'candidate_cursor': None, 'status': 'committed'},
                    'end_checkpoint': {'kind': 'prepare', 'phase': end, 'candidate_cursor': None, 'status': status}}
        cancelled = row(recovery__last_action=prepare(2, 3, 'unknown'), recovery__first_action=prepare(2, 3, 'unknown'))
        resumed = row(recovery__first_action=prepare(3, 4, 'committed'))
        self.assertEqual(p.checkpoint_outcome(cancelled), p.UNKNOWN)
        terms = p.recovery(cancelled, resumed)
        self.assertEqual(terms['checkpoint_outcome'], p.UNKNOWN)
        self.assertEqual((terms['prepare_redo'], terms['skipped_rows'], terms['page_repeated']), (p.UNKNOWN,) * 3)

    def test_a_trimmed_input_is_unavailable_never_zero(self):
        trimmed = row(action=[], recovery__first_action=None, recovery__last_action=None,
                      recovery__admission_ms=None)
        self.assertEqual(p.action_r2(trimmed, 'drain'), 'unavailable')
        terms = p.recovery(trimmed, trimmed)
        self.assertEqual(terms['admission_ms'], 'unavailable')
        self.assertEqual(terms['resuming_first'], 'unavailable')

    def test_the_retry_wait_needs_two_consecutive_retained_attempts(self):
        second = consume('f', 1, 2, 2, 'abc', 61_000, 500)
        third = consume('f', 1, 2, 3, 'abc', 122_500, 300)
        fourth_gap = consume('f', 1, 2, 4, 'abc', 300_000, 300)
        waits = p.retry_wait([second, third])
        # The first attempt predates retention: (a) unknown for attempts 2.
        self.assertEqual(waits[('abc', 2)], p.UNKNOWN)
        # (b) 3's age minus 2's age and wall.
        self.assertEqual(waits[('abc', 3)], {'wait_ms': 122_500 - 61_500, 'rows': [2, 3]})
        # (c) 2 and 4 retained without 3: unknown.
        self.assertEqual(p.retry_wait([second, fourth_gap])[('abc', 4)], p.UNKNOWN)
        # No digest: unknown.
        self.assertEqual(p.retry_wait([consume('f', 1, 2, 2, None, 61_000, 500)]), {(None, 2): p.UNKNOWN})


class RecoveryPairs(unittest.TestCase):
    """Pairs whose coarse checkpoint tuples are equal while the work behind them
    differs: the parser keeps every redo and repetition term unknown."""

    @staticmethod
    def prepare(start, end, status='committed'):
        return {'name': 'prepare',
                'start_checkpoint': {'kind': 'prepare', 'phase': start, 'candidate_cursor': None, 'status': 'committed'},
                'end_checkpoint': None if end is None else
                {'kind': 'prepare', 'phase': end, 'candidate_cursor': None, 'status': status}}

    def pair(self, cancelled_action, resuming_action):
        cancelled = row(recovery__first_action=cancelled_action, recovery__last_action=cancelled_action)
        resuming = row(recovery__first_action=resuming_action, recovery__last_action=resuming_action)
        return p.recovery(cancelled, resuming)

    def test_successive_phase_two_checkpoints_never_decide_a_redo(self):
        # A classify step that checkpointed phase-2 again (its spool unfinished),
        # cancelled after its next phase-2 write, resumed at phase-2.
        terms = self.pair(self.prepare(2, 2, 'unknown'), self.prepare(2, 2))
        self.assertEqual((terms['prepare_redo'], terms['skipped_rows'], terms['checkpoint_outcome']),
                         (p.UNKNOWN, p.UNKNOWN, p.UNKNOWN))
        self.assertIsNone(terms['cursor_comparison'])

    def test_an_incomplete_merge_and_a_merge_round_reset_read_the_same(self):
        # Both stop at the same coarse tuple (phase-3 then phase-3). The pair
        # differs in the one input that decides its checkpoint outcome: the
        # incomplete merge's last round write was never acknowledged (unknown),
        # the reset round's was (committed). Neither becomes a redo claim.
        incomplete = self.pair(self.prepare(3, 3, 'unknown'), self.prepare(3, 3))
        reset = self.pair(self.prepare(3, 3, 'committed'), self.prepare(3, 3))
        self.assertEqual((incomplete['checkpoint_outcome'], reset['checkpoint_outcome']), (p.UNKNOWN, 'committed'))
        for terms in (incomplete, reset):
            self.assertEqual((terms['prepare_redo'], terms['page_repeated'], terms['skipped_rows']), (p.UNKNOWN,) * 3)
        self.assertEqual({k for k in incomplete if incomplete[k] != reset[k]}, {'checkpoint_outcome', 'cancelled_last'})

    def test_a_delayed_uncertain_duplicate_keeps_its_own_retry_wait(self):
        # Step 3 sent twice: an uncertain send whose message ran late, and an ok
        # one; each message's attempts carry its own digest.
        sender = lambda result, digest: consume('f', 1, 2, 1, digest, 1_000, 200,
                                                sent={'step': 3, 'delay_s': 0, 'result': result})
        a1 = consume('f', 1, 3, 1, 'message-a', 2_000, 400)
        a2 = consume('f', 1, 3, 2, 'message-a', 62_400, 300)
        b1 = consume('f', 1, 3, 1, 'message-b', 600_000, 400)
        b2 = consume('f', 1, 3, 2, 'message-b', 660_900, 300)
        rows = [sender('uncertain', 'p1'), sender('ok', 'p2'), a1, a2, b1, b2]
        joined = {id(j['row']): j['join'] for j in p.joins(rows)}
        self.assertEqual((joined[id(a1)], joined[id(b1)]), ('ambiguous', 'ambiguous'))
        waits = p.retry_wait(rows)
        self.assertEqual(waits[('message-a', 2)], {'wait_ms': 62_400 - 2_400, 'rows': [1, 2]})
        self.assertEqual(waits[('message-b', 2)], {'wait_ms': 660_900 - 600_400, 'rows': [1, 2]})

    def test_a_trimmed_trace_keeps_its_protected_recovery(self):
        """The emitter's own trimmed line (its op detail and actions beyond two
        dropped) and its resumption: the protected recovery yields its terms; a
        trimmed action's own evidence is unavailable, never zero."""
        here = os.path.dirname(os.path.abspath(__file__))
        with open(os.path.join(here, 'trimmed_recovery.jsonl'), encoding='utf-8') as handle:
            cancelled, resuming = [p.parse(line)[1] for line in handle if line.strip()]
        self.assertEqual((cancelled['bytes_policy'], cancelled['truncated']['actions']), ('trimmed', True))
        terms = p.recovery(cancelled, resuming)
        self.assertIsInstance(terms['admission_ms'], int)
        self.assertEqual(terms['cancelled_last']['name'], 'settle')
        self.assertEqual(terms['cancelled_last']['end_checkpoint']['status'], 'unknown')
        self.assertEqual(terms['resuming_first']['name'], 'drain')
        self.assertEqual(terms['checkpoint_outcome'], p.UNKNOWN)
        self.assertEqual(terms['cursor_comparison'], 'equal')
        self.assertIsInstance(terms['outbox_release'], dict)
        self.assertEqual((terms['page_repeated'], terms['prepare_redo'], terms['skipped_rows']), (p.UNKNOWN,) * 3)
        # The kept actions are the first and the first not completed; an outbox
        # action between them was trimmed, so its R2 evidence is unavailable.
        self.assertNotIn('outbox', {a['name'] for a in cancelled['action']})
        self.assertEqual(p.action_r2(cancelled, 'outbox'), 'unavailable')


class Joins(unittest.TestCase):
    def sender(self, step, result, delay=0, generation=1):
        return consume('f', generation, step - 1, 1, 'd%s' % step, 1_000, 200,
                       sent={'step': step, 'delay_s': delay, 'result': result})

    def test_the_join_precedence(self):
        successor = consume('f', 1, 3, 1, 'x', 5_000, 100)
        # (i') one ok sender: exact, the wait less the send's delay.
        joined = p.joins([self.sender(3, 'ok', delay=2), successor])
        self.assertEqual([j['join'] for j in joined if j['row'] is successor], ['exact'])
        self.assertEqual([j.get('ready_to_run_wait_ms') for j in joined if j['row'] is successor], [3_000])
        # (i) a duplicate producer: two senders, uncertain then ok: ambiguous.
        joined = p.joins([self.sender(3, 'uncertain'), self.sender(3, 'ok'), successor])
        self.assertEqual([j['join'] for j in joined if j['row'] is successor], ['ambiguous'])
        # (ii) no sender retained: unknown.
        self.assertEqual([j['join'] for j in p.joins([successor])], ['unknown'])
        # (iii) a staged wait of 300 s: exact, the wait less 300 000 ms.
        late = consume('f', 1, 3, 1, 'y', 301_000, 100)
        joined = p.joins([self.sender(3, 'ok', delay=300), late])
        self.assertEqual([j.get('ready_to_run_wait_ms') for j in joined if j['row'] is late], [1_000])
        # (iv) a single err sender (the message delivered anyway): ambiguous.
        joined = p.joins([self.sender(3, 'err'), successor])
        self.assertEqual([j['join'] for j in joined if j['row'] is successor], ['ambiguous'])
        # (v) a coverage gap: ambiguous.
        joined = p.joins([self.sender(3, 'ok'), successor], coverage_complete=False)
        self.assertEqual([j['join'] for j in joined if j['row'] is successor], ['ambiguous'])
        # Any retry is a retry; a historical join is uncertain.
        retried = consume('f', 1, 3, 2, 'x', 70_000, 100)
        joined = p.joins([self.sender(3, 'ok'), retried])
        self.assertEqual([j['join'] for j in joined if j['row'] is retried], ['retry'])
        self.assertEqual(p.historical_join(), 'uncertain')


class CompactModel(unittest.TestCase):
    def test_the_compact_model_prints_its_bound_and_names_the_emitter_s_properties(self):
        import contextlib
        import importlib.util
        import io
        here = os.path.dirname(os.path.abspath(__file__))
        spec = importlib.util.spec_from_file_location('compact_width', os.path.join(here, 'compact_width.py'))
        model = importlib.util.module_from_spec(spec)
        printed = io.StringIO()
        with contextlib.redirect_stdout(printed):
            spec.loader.exec_module(model)
        self.assertEqual(printed.getvalue().strip(), '6349')
        self.assertEqual(model.line['schema'], 2)

        def paths(value, prefix=''):
            if isinstance(value, dict):
                return set().union(*(paths(v, prefix + '.' + k) for k, v in value.items()))
            if isinstance(value, list):
                return paths(value[0], prefix + '[]') if value else {prefix + '[]'}
            return {prefix}
        with open(os.path.join(here, 'compact_keys.json'), encoding='utf-8') as handle:
            self.assertEqual(sorted(paths(model.line)), json.load(handle))


class Lines(unittest.TestCase):
    def test_an_overflow_is_unavailable_and_another_schema_is_rejected(self):
        self.assertEqual(p.parse({'event': 'storage_phases_overflow', 'schema': 2})[0], 'unavailable')
        with self.assertRaises(p.Rejected):
            p.parse(dict(row(), schema=3))
        self.assertEqual(p.parse(json.dumps(row()))[0], 'row')

    def test_every_given_row_parses(self):
        path = os.environ.get('STORAGE_PHASES_ROWS')
        if not path:
            self.skipTest('STORAGE_PHASES_ROWS not set')
        count = 0
        with open(path, encoding='utf-8') as handle:
            for line in handle:
                if line.strip():
                    kind, value = p.parse(line)
                    if kind == 'row':
                        p.classified(value)
                    count += 1
        self.assertGreater(count, 0)


if __name__ == '__main__':
    unittest.main()
