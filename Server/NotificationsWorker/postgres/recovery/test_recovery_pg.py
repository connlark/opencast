"""Live tests for recovery.py on a real PostgreSQL; skipped unless configured.

They need a primary and a restored copy of it. The copy is a base backup of the
primary restored with its archived WAL (archive recovery) and promoted. SEED_SQL
must be committed on the primary after the base backup, so it reaches the copy
only by replay. Configure with OPENCAST_RECOVERY_PG=<config.json>:

  {"primary": [psql argv prefix, superuser, on the database],
   "primary_reader": [psql argv prefix as a role that reads every table],
   "copy": [...], "copy_reader": [...],
   "database": "...", "owner_role": "...", "runtime_role": "...",
   "crash_restart_primary": [argv: stop the primary immediately, start it, wait],
   "seed_started_at": <epoch>, "wal_switched_at": <epoch>,
   "receipts": "<a 0700 directory for this run's receipts>"}

Run from the repository root:
  OPENCAST_RECOVERY_PG=<config> python3 -m unittest discover \
    -s Server/NotificationsWorker/postgres/recovery -p 'test_recovery_pg.py' -v
The tests run in order on one primary and one fresh copy, and leave the copy
closed and the primary unfenced. `python3 test_recovery_pg.py --print-seed`
prints SEED_SQL.
"""
import contextlib
import io
import json
import os
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
TOOL = HERE / 'recovery.py'
SOURCE = HERE.parents[1] / 'src' / 'database' / 'postgres'
CONFIG = os.environ.get('OPENCAST_RECOVERY_PG')
PSQL_FLAGS = ['-X', '-q', '-A', '-t', '-v', 'ON_ERROR_STOP=1']

# Synthetic, FK- and CHECK-consistent; every time lies before any boundary. 99 rows
# over the 32 tables (with the schema files' seeds). Applied as a superuser with
# session_replication_role=replica, so no projection trigger adds rows.
SEED_SQL = r"""
BEGIN;
SET LOCAL session_replication_role = replica;
SET LOCAL search_path = opencast, pg_catalog;
INSERT INTO n_feed(feed_id, canonical_url, epoch, due_at, lease_id, lease_until, eligibility_generation, no_interest_since) VALUES
 ('feed-1', 'https://feeds.example.com/one.xml', 1, 1700000000, 'feed-lease-1', 1700000300, 5, NULL),
 ('feed-2', 'https://feeds.example.com/two.xml', 1, 1700000000, NULL, NULL, 7, NULL),
 ('feed-3', 'https://feeds.example.com/three.xml', 1, 1700000000, NULL, NULL, 2, 1700000900);
INSERT INTO n_feed_catalog(feed_url, source_url, created_at, updated_at) VALUES
 ('https://feeds.example.com/one.xml', 'https://feeds.example.com/one.xml', 1700000000, 1700000000),
 ('https://feeds.example.com/two.xml', 'https://feeds.example.com/two.xml', 1700000000, 1700000000),
 ('https://feeds.example.com/three.xml', 'https://feeds.example.com/three.xml', 1700000000, 1700000000);
INSERT INTO n_install(install_id, epoch, deleted_at, token_generation, token_hash, enabled, job_capable, registered_at) VALUES
 ('install-1', 1, NULL, 1, 'token-hash-1', 1, 0, 1700000100),
 ('install-2', 2, NULL, 3, 'token-hash-2', 1, 0, 1700000100),
 ('install-3', 1, NULL, 1, 'token-hash-3', 1, 1, 1700000100),
 ('install-4', 1, NULL, 2, 'token-hash-4-old', 1, 0, 1700000100),
 ('install-5', 1, NULL, 2, NULL, 0, 0, 1700000100);
INSERT INTO devices(install_id, key_id, device_token, device_token_hash, apns_environment, bundle_id, notifications_enabled, created_at, last_seen_at, job_capable) VALUES
 ('install-1', 'key-1', 'token-1', 'token-hash-1', 'production', 'com.example.cast', 1, 1700000100, 1700000100, 0),
 ('install-2', 'key-2', 'token-2', 'token-hash-2', 'production', 'com.example.cast', 1, 1700000100, 1700000100, 0),
 ('install-3', 'key-3', 'token-3', 'token-hash-3', 'production', 'com.example.cast', 1, 1700000100, 1700000100, 1),
 ('install-4', 'key-4', '', 'token-hash-4', 'production', 'com.example.cast', 0, 1700000100, 1700000100, 0);
INSERT INTO app_attest_keys(install_id, key_id, public_key, sign_counter, app_id, environment, created_at, last_used_at) VALUES
 ('install-1', 'key-1', '\x0102'::bytea, 7, 'TEAM.com.example.cast', 'production', 1700000000, 1700000100),
 ('install-2', 'key-2', '\x0304'::bytea, 0, 'TEAM.com.example.cast', 'production', 1700000000, 1700000100),
 ('install-3', 'key-3', '\x0506'::bytea, 12, 'TEAM.com.example.cast', 'production', 1700000000, 1700000100),
 ('install-4', 'key-4', '\x0708'::bytea, 3, 'TEAM.com.example.cast', 'production', 1700000000, 1700000100);
INSERT INTO app_attest_challenges(challenge_id, challenge_hash, purpose, install_id, created_at, expires_at, consumed_at) VALUES
 ('challenge-1', 'challenge-hash-1', 'register', 'install-1', 1700000000, 4102444800, NULL),
 ('challenge-2', 'challenge-hash-2', 'assert', 'install-2', 1700000000, 1700000300, 1700000050),
 ('challenge-3', 'challenge-hash-3', 'register', 'install-3', 1700000000, 1700000100, NULL);
INSERT INTO app_attest_challenge_source_buckets(source_token, window_start, request_count, updated_at) VALUES
 ('source-1', 1700000000, 3, 1700000100), ('source-2', 1700003600, 1, 1700003700);
INSERT INTO feed_subscriptions(install_id, feed_url, notifications_enabled, created_at, updated_at, deleted_at) VALUES
 ('install-1', 'https://feeds.example.com/one.xml', 1, 1700000100, 1700000100, NULL),
 ('install-1', 'https://feeds.example.com/two.xml', 1, 1700000100, 1700000100, NULL),
 ('install-2', 'https://feeds.example.com/one.xml', 1, 1700000100, 1700000100, NULL),
 ('install-2', 'https://feeds.example.com/two.xml', 0, 1700000100, 1700000950, 1700000950),
 ('install-3', 'https://feeds.example.com/two.xml', 1, 1700000100, 1700000100, NULL),
 ('install-5', 'https://feeds.example.com/three.xml', 0, 1700000100, 1700000100, NULL);
INSERT INTO n_interest(install_id, feed_id, generation, activated_at, absence_generation, absence_at, enabled, changed_at) VALUES
 ('install-1', 'feed-1', 1, 1700000100, NULL, NULL, 1, 1700000100),
 ('install-1', 'feed-2', 1, 1700000100, NULL, NULL, 1, 1700000100),
 ('install-2', 'feed-1', 2, 1700000100, NULL, NULL, 1, 1700000100),
 ('install-2', 'feed-2', 3, 1700000100, NULL, NULL, 0, 1700000950),
 ('install-3', 'feed-2', 1, 1700000100, NULL, NULL, 1, 1700000100);
INSERT INTO n_job_interest(install_id, install_epoch, operation_id, producer, requester_ref, generation, grant_digest, grant_nonce, grant_key_version, issued_at, accept_before, register_before, accepted_at, run_id, job_handle, state, interest_id) VALUES
 ('install-3', 1, 'op-1', 'ad_analysis', 'req-1', 1, 'grant-1', 'grant-nonce-1', 1, 1700000000, 1700001800, 1700604800, 1700000100, 'run-1', 'job-1', 'registered', 'job-interest-1'),
 ('install-1', 1, 'op-2', 'remote_transcription', 'req-2', 1, 'grant-2', 'grant-nonce-2', 1, 1700000000, 1700001800, 1700604800, NULL, NULL, NULL, 'issued', 'job-interest-2'),
 ('install-2', 2, 'op-3', 'ad_analysis', 'req-3', 1, 'grant-3', 'grant-nonce-3', 1, 1700000000, 1700001800, 1700604800, NULL, NULL, NULL, 'revoked', 'job-interest-3');
INSERT INTO n_requester_ticket(ticket_digest, producer, operation_id, requester_ref, issued_at, expires_at, environment) VALUES
 ('ticket-1', 'ad_analysis', 'op-1', 'req-1', 1700000000, 1700086400, 'production'),
 ('ticket-2', 'remote_transcription', 'op-9', 'req-9', 1700000000, 1700086400, 'production');
INSERT INTO n_event(source, event_id, schema_version, kind, payload_digest, occurred_at, eligible_at, expires_at, receipt_id, envelope_json, fanout_complete, disposition, next_attempt_at, failures, lease_id, lease_until, terminal_at, feed_id, interest_id, owner_epoch) VALUES
 ('feed_polling', 'event-1', 1, 'episode', 'digest-1', 1700000200, 1700000200, 1700086600, 'receipt-1', '{}', 0, 'accepted', 1700000200, 0, NULL, NULL, NULL, 'feed-1', NULL, 1),
 ('feed_polling', 'event-2', 1, 'episode', 'digest-2', 1700000200, 1700000200, 1700086600, 'receipt-2', '{}', 0, 'accepted', 1700000200, 0, 'event-lease-2', 1700000260, NULL, 'feed-1', NULL, 1),
 ('feed_polling', 'event-3', 1, 'episode', 'digest-3', 1700000200, 1700000200, 1700086600, 'receipt-3', '{}', 1, 'accepted', 1700000200, 0, NULL, NULL, 1700000210, 'feed-2', NULL, 1),
 ('feed_polling', 'event-4', 1, 'episode', 'digest-4', 1700000200, 1700000200, 1700086600, 'receipt-4', '{}', 1, 'suppressed', 1700000200, 0, NULL, NULL, 1700000210, 'feed-2', NULL, 1),
 ('ad_analysis', 'event-5', 1, 'ad_analysis.completed', 'digest-5', 1700000200, 1700000200, 1700086600, 'receipt-5', '{}', 0, 'accepted', 1700000200, 0, NULL, NULL, NULL, NULL, 'job-interest-1', 1),
 ('remote_transcription', 'event-6', 1, 'remote_transcription.completed', 'digest-6', 1700000200, 1700000200, 1700086600, 'receipt-6', '{}', 1, 'accepted', 1700000200, 0, NULL, NULL, 1700000210, NULL, 'job-interest-2', 1),
 ('ad_analysis', 'event-7', 1, 'ad_analysis.failed', 'digest-7', 1700000200, 1700000200, 1700086600, 'receipt-7', '{}', 1, 'accepted', 1700000200, 0, NULL, NULL, 1700000210, NULL, 'job-interest-x', 1);
INSERT INTO n_group_member(group_id, source, event_id, ordinal) VALUES
 ('presentation-1', 'feed_polling', 'event-1', 1), ('presentation-5', 'ad_analysis', 'event-5', 1);
INSERT INTO n_delivery(delivery_id, presentation_id, install_id, install_epoch, interest_key, interest_generation, state, expires_at, next_attempt_at, lease_id, lease_until, apns_id, collapse_id, source, event_id, failures, terminal_at, last_reason, owner_epoch, member_count) VALUES
 ('delivery-1', 'presentation-1', 'install-1', 1, 'feed-1', 1, 'pending', 1700086600, 1700000200, NULL, NULL, 'apns-1', 'collapse-1', 'feed_polling', 'event-1', 0, NULL, NULL, 1, 1),
 ('delivery-2', 'presentation-2', 'install-1', 1, 'feed-1', 1, 'leased', 1700086600, 1700000200, 'delivery-lease-2', 1700000260, 'apns-2', 'collapse-2', 'feed_polling', 'event-2', 0, NULL, NULL, 1, 1),
 ('delivery-3', 'presentation-3', 'install-2', 2, 'feed-1', 2, 'accepted', 1700086600, 1700000200, NULL, NULL, 'apns-3', 'collapse-3', 'feed_polling', 'event-3', 0, 1700000205, 'accepted', 1, 1),
 ('delivery-4', 'presentation-1', 'install-2', 2, 'feed-1', 2, 'uncertain', 1700086600, 1700000200, NULL, NULL, 'apns-4', 'collapse-4', 'feed_polling', 'event-1', 1, NULL, 'lease_expired', 1, 1),
 ('delivery-5', 'presentation-5', 'install-3', 1, 'job-interest-1', 1, 'suppressed', 1700086600, 1700000200, NULL, NULL, 'apns-5', 'collapse-5', 'ad_analysis', 'event-5', 0, 1700000205, 'unregistered', 1, 1),
 ('delivery-6', 'presentation-3', 'install-3', 1, 'feed-2', 1, 'expired', 1700086600, 1700000200, NULL, NULL, 'apns-6', 'collapse-6', 'feed_polling', 'event-3', 0, 1700000205, 'expired', 1, 1),
 ('delivery-7', 'presentation-3', 'install-1', 1, 'feed-2', 1, 'permanent_failure', 1700086600, 1700000200, NULL, NULL, 'apns-7', 'collapse-7', 'feed_polling', 'event-3', 1, 1700000205, 'bad_device_token', 1, 1),
 ('delivery-8', 'presentation-2', 'install-3', 1, 'feed-2', 1, 'poisoned', 1700086600, 1700000200, NULL, NULL, 'apns-8', 'collapse-8', 'feed_polling', 'event-2', 10, NULL, 'failures', 1, 1);
INSERT INTO n_delivery_member(delivery_id, source, event_id, install_id, install_epoch, interest_generation) VALUES
 ('delivery-1', 'feed_polling', 'event-1', 'install-1', 1, 1), ('delivery-2', 'feed_polling', 'event-2', 'install-1', 1, 1),
 ('delivery-3', 'feed_polling', 'event-3', 'install-2', 2, 2), ('delivery-4', 'feed_polling', 'event-1', 'install-2', 2, 2),
 ('delivery-5', 'ad_analysis', 'event-5', 'install-3', 1, 1), ('delivery-6', 'feed_polling', 'event-3', 'install-3', 1, 1),
 ('delivery-7', 'feed_polling', 'event-3', 'install-1', 1, 1), ('delivery-8', 'feed_polling', 'event-2', 'install-3', 1, 1);
INSERT INTO n_legacy_bridge(install_id, feed_id, identity_key, disposition, expires_at) VALUES
 ('install-1', 'feed-1', 'episode:episode-a', 'accepted', 1702592000), ('install-2', 'feed-2', 'episode:episode-b', 'uncertain', 1702592000);
INSERT INTO n_delivery_history(send_id, install_id, device_token_hash, feed_url, episode_id, apns_environment, apns_status, apns_id, apns_error, created_at, updated_at, episode_fingerprint) VALUES
 ('send-1', 'install-1', 'token-hash-1', 'https://feeds.example.com/one.xml', 'episode-a', 'production', 200, 'apns-a', NULL, 1700000000, 1700000000, NULL),
 ('send-2', 'install-2', 'token-hash-2', 'https://feeds.example.com/two.xml', 'episode-b', 'production', NULL, NULL, NULL, 1700000000, 1700000000, NULL);
INSERT INTO push_send_attempts(attempt_id, install_id, device_token_hash, apns_environment, apns_status, apns_id, apns_error, created_at) VALUES
 ('push-1', 'install-1', 'token-hash-1', 'production', 200, 'apns-p1', NULL, 1700000000),
 ('push-2', 'install-2', 'token-hash-2', 'production', 410, 'apns-p2', 'Unregistered', 1700000000),
 ('push-3', NULL, 'token-hash-9', 'production', 400, NULL, 'BadDeviceToken', 1700000000);
INSERT INTO secure_hello_attempts(attempt_id, install_id, key_id, accepted, error_code, created_at) VALUES
 ('hello-1', 'install-1', 'key-1', 1, NULL, 1700000000);
INSERT INTO feed_admission_attempts(attempt_id, install_id, key_id, host, accepted, error_code, created_at) VALUES
 ('admission-1', 'install-1', 'key-1', 'feeds.example.com', 1, NULL, 1700000000),
 ('admission-2', 'install-2', 'key-2', 'feeds.example.com', 0, 'rate_limited', 1700000000);
INSERT INTO n_deleted_install(fence, expires_at) VALUES ('deletion-fence-1', 1700604800);
INSERT INTO n_snapshot(object_key, feed_id, owner_epoch, lease_id, sha256, bytes, state, created_at, gc_after, expected_pages) VALUES
 ('snapshot-1', 'feed-1', 1, 'snapshot-lease-1', 'snapshot-digest-1', 10, 'referenced', 1700000000, 1700604800, 0);
INSERT INTO n_observation(observation_id, feed_id, generation, owner_epoch, lease_id, expected_generation, snapshot_key, scan_started_at, completed_at, candidate_count, valid_eof, state, eligibility_generation) VALUES
 ('observation-1', 'feed-1', 1, 1, 'observation-lease-1', 0, 'snapshot-1', 1700000000, 1700000005, 2, 1, 'published', 5);
INSERT INTO n_episode_release(feed_id, episode_id, observation_id, generation, owner_epoch, event_id, presentation_key, first_observed_at, eligible_at, expires_at, reason, fingerprint, published_at, metadata_json, state, disposition) VALUES
 ('feed-1', 'episode-1', 'observation-1', 1, 1, 'event-r1', 'presentation-r1', 1700000000, 1700000000, 1700259200, 'recent', NULL, 1700000000, '{}', 'ready', NULL),
 ('feed-1', 'episode-2', 'observation-1', 1, 1, 'event-r2', 'presentation-r2', 1700000000, 1700000000, 1700259200, 'recent', NULL, 1700000000, '{}', 'outboxed', NULL);
INSERT INTO n_outbox(source, event_id, observation_id, payload_digest, occurred_at, expires_at, next_attempt_at, state, receipt_id, payload_json) VALUES
 ('feed_polling', 'outbox-1', NULL, 'outbox-digest-1', 1700000000, 1700086400, 1700000000, 'pending', NULL, '{}'),
 ('feed_polling', 'outbox-2', NULL, 'outbox-digest-2', 1700000000, 1700086400, 1700000000, 'pending', NULL, '{}'),
 ('feed_polling', 'outbox-3', NULL, 'outbox-digest-3', 1700000000, 1700086400, 1700000000, 'accepted', 'outbox-receipt-3', '{}'),
 ('feed_polling', 'outbox-4', NULL, 'outbox-digest-4', 1700000000, 1700086400, 1700000000, 'expired', NULL, '{}'),
 ('feed_polling', 'outbox-5', NULL, 'outbox-digest-5', 1700000000, 1700086400, 1700000000, 'conflict', NULL, '{}');
INSERT INTO n_burst(presentation_key, feed_id, owner_epoch) VALUES ('presentation-b', 'feed-1', 1);
INSERT INTO n_poll_origin(origin_key, cooldown_until, failures, last_status, updated_at) VALUES ('feeds.example.com', 0, 0, 200, 1700000000);
INSERT INTO n_poll_stat(bucket) VALUES (1700000000);
UPDATE n_control SET enabled = 1 WHERE name IN ('dispatcher_admission', 'episode_activation', 'episode_send', 'cleanup', 'feed_observation');
COMMIT;
"""

# Stated at the design stop, before any implementation; never edited after a run.
PREDICTED_BEFORE = dict(
    n_control=9, n_control_enabled=6, n_interest=5, n_interest_enabled=4, n_delivery_member=8, n_delivery=8,
    n_group_member=2, n_event=7, n_event_unfinished=3, n_requester_ticket=2, n_job_interest=3, n_legacy_bridge=2,
    n_install=5, n_install_enabled=4, n_delivery_history=2, push_send_attempts=3, feed_admission_attempts=2,
    feed_subscriptions=6, devices=4, devices_enabled=3, secure_hello_attempts=1, app_attest_challenges=3,
    app_attest_keys=4, app_attest_keys_counter_positive=3, app_attest_challenge_source_buckets=2,
    n_outbox=5, n_outbox_pending=2, n_feed=3, n_feed_generation_sum=14, n_feed_leased=1, n_feed_no_interest_null=2,
    n_deleted_install=1, n_feed_catalog=3, n_snapshot=1, n_observation=1, n_episode_release=2, n_snapshot_ref=0,
    n_burst=1, n_poll_origin=1, n_poll_stat=1, n_circuit=1, n_poll_dispatch=1, rows_total=99)
PREDICTED_AFTER = dict(
    PREDICTED_BEFORE, n_control_enabled=0, n_interest=0, n_interest_enabled=0, n_delivery_member=0, n_delivery=0,
    n_group_member=1, n_event=4, n_event_unfinished=0, n_requester_ticket=0, n_job_interest=0, n_legacy_bridge=0,
    n_install=0, n_install_enabled=0, n_delivery_history=0, push_send_attempts=0, feed_admission_attempts=0,
    feed_subscriptions=0, devices=0, devices_enabled=0, secure_hello_attempts=0, app_attest_challenges=0,
    app_attest_keys=0, app_attest_keys_counter_positive=0, app_attest_challenge_source_buckets=0,
    n_outbox_pending=0, n_feed_generation_sum=22, n_feed_leased=0, n_feed_no_interest_null=0, rows_total=35)
PREDICTED_STATES_BEFORE = {
    'n_delivery': {s: 1 for s in ('pending', 'leased', 'accepted', 'uncertain', 'suppressed', 'expired',
                                  'permanent_failure', 'poisoned')},
    'n_outbox': dict(pending=2, accepted=1, expired=1, conflict=1),
    'n_job_interest': dict(registered=1, issued=1, revoked=1),
    'n_episode_release': dict(ready=1, outboxed=1),
    'n_event_episode': dict(unfinished=2, complete_accepted=1, complete_suppressed=1),
    'n_event_job': dict(unfinished_linked=1, complete_linked=1, complete_orphan=1),
}
PREDICTED_STATES_AFTER = {
    'n_outbox': dict(accepted=1, expired=3, conflict=1),
    'n_event_disposition': dict(accepted=1, suppressed=3),
    'n_feed_generation': {'f1': 8, 'f2': 11, 'f3': 3},
    'n_control_revision_sum_delta': 6,
}
PREDICTED_STATEMENTS = (('R13', 6), ('R14', 5), ('R15', 8), ('R7', 8), ('R16', 1), ('R17', 3), ('R18', 2), ('R10', 3),
                        ('R5', 5), ('R11c', 2), ('R6', 5), ('R19', 2), ('R11a', 3), ('R20', 2), ('R4', 6), ('R3', 4),
                        ('R11b', 1), ('R1', 3), ('R2', 4), ('R11d', 2), ('R8', 2), ('R9', 2), ('R12', 3))
# The fix round's tests (T18-T20), stated before their first run.
PREDICTED_FIXES = {
    'T18_missing_gate_reconcile': dict(exit=2, verdict='REFUSED', streamed=False, direct_sqlstates=['22012'],
                                       statements_printed=0, rows_total_while_missing=98, census_unchanged=True),
    'T19_missing_gate_close': dict(exit=2, verdict='REFUSED', direct_sqlstates=['22012'], marker_intact=True,
                                   rows_total_while_missing=34, census_unchanged=True),
    'T20_post_stream_read_loss': dict(exit=1, verdict='STOP', outcome='COMMITTED_UNVERIFIED', stream_exit=0,
                                      statement_rows=[0] * 23, census_after_rows_total=35, independent_rows_total=35),
}
SEEDED_VALUES = ('install-1', 'install-2', 'install-3', 'install-4', 'install-5', 'token-hash-', 'token-1', 'key-1',
                 'challenge-hash', 'grant-nonce', 'ticket-1', 'feeds.example.com', 'apns-1', 'source-1', 'send-1')


def load_config():
    return json.loads(Path(CONFIG).read_text(encoding='utf-8'))


def rust_sql(path, pattern):
    """A statement's SQL text from the Worker source, so the probe runs what the product runs."""
    match = re.search(pattern, path.read_text(encoding='utf-8'))
    if not match:
        raise AssertionError('statement not found in %s' % path.name)
    return match.group(1)


@unittest.skipUnless(CONFIG, 'set OPENCAST_RECOVERY_PG to run the live recovery tests')
class Live(unittest.TestCase):
    state = {}

    @classmethod
    def setUpClass(cls):
        cls.c = load_config()
        cls.db = cls.c['database']

    # ---------------------------------------------------------- helpers

    def psql(self, which, sql, variables=None, check=True):
        argv = list(self.c[which]) + PSQL_FLAGS
        head = '\\set VERBOSITY sqlstate\n\\set SHOW_CONTEXT never\n' + ''.join(
            '\\set %s %s\n' % kv for kv in sorted((variables or {}).items()))
        r = subprocess.run(argv, input=(head + sql).encode(), stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        out, err = r.stdout.decode(), r.stderr.decode()
        if check and r.returncode:
            raise AssertionError('psql exit %d: %s' % (r.returncode, re.findall(r'ERROR:\s+([0-9A-Z]{5})', err)))
        return r.returncode, out, err

    def value(self, which, sql):
        return self.psql(which, sql)[1].strip()

    def sqlstates(self, err):
        return re.findall(r'(?:ERROR|FATAL):\s+([0-9A-Z]{5})\b', err)

    def system_identifier(self, which):
        return self.value(which, 'SELECT system_identifier FROM pg_control_system();')

    def timeline(self, which):
        return int(self.value(which, "SELECT (('x'||substr(pg_walfile_name(pg_current_wal_lsn()),1,8))::bit(32)::bigint);"))

    def gate_row(self, which):
        return self.value(which, 'SELECT xmin::text||\'|\'||xmax::text FROM opencast.n_poll_dispatch;')

    def census(self, which):
        code, out, err = self.psql(which + '_reader', 'BEGIN TRANSACTION READ ONLY;\n' + (HERE / 'census.sql').read_text() + 'ROLLBACK;\n')
        return {'|'.join(l.split('|')[2:-1]): int(l.split('|')[-1]) for l in out.splitlines() if l.startswith('census|')}

    def tool(self, *args, name=None):
        receipts = Path(tempfile.mkdtemp(prefix=(name or args[0]) + '-', dir=self.c['receipts']))
        os.chmod(receipts, 0o700)
        r = subprocess.run([sys.executable, str(TOOL)] + list(args) + ['--receipts', str(receipts)],
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        line = json.loads(r.stdout.decode().strip().splitlines()[-1]) if r.stdout.strip() else None
        receipt = None
        if line and line.get('receipt'):
            receipt = json.loads(Path(line['receipt']).read_text())
        return r.returncode, receipt, receipts

    def target(self, which, owner=True):
        args = ['--psql', json.dumps(self.c[which]), '--target-database', self.db,
                '--target-system-identifier', self.system_identifier(which)]
        return args + (['--owner-role', self.c['owner_role']] if owner else [])

    def nonce(self):
        return subprocess.run([sys.executable, str(TOOL), 'nonce'], stdout=subprocess.PIPE, check=True).stdout.decode().strip()

    def has_marker_schema(self, which):
        return self.value(which, "SELECT to_regnamespace('opencast_recovery') IS NOT NULL;") == 't'

    def delete_gate(self, which):
        row = self.value(which, 'SELECT row_to_json(g) FROM opencast.n_poll_dispatch g;')
        self.psql(which, 'DELETE FROM opencast.n_poll_dispatch;\n')
        return row

    def restore_gate(self, which, row):
        self.psql(which, "INSERT INTO opencast.n_poll_dispatch SELECT * FROM json_populate_record(NULL::opencast.n_poll_dispatch, '%s');\n"
                  % row.replace("'", "''"))

    def direct(self, which, name, variables):
        return self.psql(which, (HERE / (name + '.sql')).read_text(), variables, check=False)

    # ---------------------------------------------------------- T1-T16

    def test_01_mark_refused_on_a_primary_that_never_recovered(self):
        nonce = self.nonce()
        replay = self.value('primary', 'SELECT pg_last_xact_replay_timestamp() IS NULL;')
        code, receipt, _ = self.tool('mark', *self.target('primary'), '--recovery-target', 'latest', '--nonce', nonce)
        self.assertEqual(replay, 't')
        self.assertEqual((code, receipt['verdict']), (2, 'REFUSED'))
        code, _, err = self.direct('primary', 'marker', dict(nonce=nonce, recovery_target='latest', target_database=self.db,
                                                             system_identifier=self.system_identifier('primary'),
                                                             owner_role=self.c['owner_role']))
        self.assertNotEqual(code, 0)
        self.assertEqual(self.sqlstates(err), ['ORM01'])
        self.assertFalse(self.has_marker_schema('primary'))

    def test_02_mark_refused_on_the_primary_after_a_crash_restart(self):
        subprocess.run(self.c['crash_restart_primary'], check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.assertEqual(self.value('primary', 'SELECT pg_is_in_recovery()::text;'), 'false')
        self.assertEqual(self.value('primary', 'SELECT pg_last_xact_replay_timestamp() IS NULL;'), 't')
        nonce = self.nonce()
        code, receipt, _ = self.tool('mark', *self.target('primary'), '--recovery-target', 'latest', '--nonce', nonce)
        self.assertEqual((code, receipt['verdict']), (2, 'REFUSED'))
        code, _, err = self.direct('primary', 'marker', dict(nonce=nonce, recovery_target='latest', target_database=self.db,
                                                             system_identifier=self.system_identifier('primary'),
                                                             owner_role=self.c['owner_role']))
        self.assertEqual(self.sqlstates(err), ['ORM01'])
        self.assertFalse(self.has_marker_schema('primary'))

    def test_03_identity_cannot_tell_the_copy_from_the_primary(self):
        self.assertEqual(self.value('primary', 'SELECT current_database();'), self.value('copy', 'SELECT current_database();'))
        self.assertEqual(self.system_identifier('primary'), self.system_identifier('copy'))
        self.assertEqual((self.timeline('primary'), self.timeline('copy')), (1, 2))
        self.assertEqual(self.value('copy', 'SELECT pg_last_xact_replay_timestamp() IS NOT NULL;'), 't')

    def test_04_reconcile_refused_on_the_primary_before_any_write(self):
        gate, census = self.gate_row('primary'), self.census('primary')
        code, receipt, _ = self.tool('reconcile', *self.target('primary'), '--nonce', self.nonce())
        self.assertEqual((code, receipt['verdict'], receipt['streamed']), (2, 'REFUSED', False))
        self.assertEqual((self.gate_row('primary'), self.census('primary')), (gate, census))
        code, _, err = self.direct('primary', 'reconcile', dict(nonce=self.nonce(), target_database=self.db,
                                                                system_identifier=self.system_identifier('primary'),
                                                                owner_role=self.c['owner_role']))
        self.assertEqual(self.sqlstates(err), ['42P01'])
        self.assertEqual((self.gate_row('primary'), self.census('primary')), (gate, census))

    def test_05_mark_the_restored_copy(self):
        Live.state['nonce'] = nonce = self.nonce()
        code, receipt, _ = self.tool('mark', *self.target('copy'), '--recovery-target', 'latest', '--nonce', nonce)
        self.assertEqual((code, receipt['verdict']), (0, 'PASS'), receipt.get('reason'))
        marker = receipt['marker']
        self.assertEqual((int(marker['timeline']), marker['database'], marker['format']), (2, self.db, 'opencast-recovery-marker-1'))
        self.assertTrue(self.c['seed_started_at'] <= int(marker['last_replayed_at']) <= self.c['wal_switched_at'])
        self.assertEqual(marker['boundary'], marker['restored_at'])
        Live.state['boundary'] = int(marker['boundary'])
        self.assertNotIn('nonce_sha256', marker)

    def test_06_a_wrong_nonce_refuses_before_any_write(self):
        gate, census = self.gate_row('copy'), self.census('copy')
        code, receipt, _ = self.tool('reconcile', *self.target('copy'), '--nonce', self.nonce())
        self.assertEqual((code, receipt['verdict'], receipt['streamed']), (2, 'REFUSED', False))
        code, _, err = self.direct('copy', 'reconcile', dict(nonce=self.nonce(), target_database=self.db,
                                                             system_identifier=self.system_identifier('copy'),
                                                             owner_role=self.c['owner_role']))
        self.assertEqual(self.sqlstates(err), ['ORG01'])
        self.assertEqual((self.gate_row('copy'), self.census('copy')), (gate, census))

    def test_07_another_identity_refuses(self):
        args = self.target('copy')
        wrong_id = list(args)
        wrong_id[wrong_id.index('--target-system-identifier') + 1] = '1'
        code, receipt, _ = self.tool('reconcile', *wrong_id, '--nonce', Live.state['nonce'])
        self.assertEqual((code, receipt['verdict']), (2, 'REFUSED'))
        wrong_db = list(args)
        wrong_db[wrong_db.index('--target-database') + 1] = 'postgres'
        code, receipt, _ = self.tool('reconcile', *wrong_db, '--nonce', Live.state['nonce'])
        self.assertEqual((code, receipt['verdict']), (2, 'REFUSED'))

    def test_07b_a_missing_gate_refuses_reconcile_before_any_application_statement(self):
        expected = PREDICTED_FIXES['T18_missing_gate_reconcile']
        row = self.delete_gate('copy')
        try:
            census = self.census('copy')
            self.assertEqual((census['n_poll_dispatch'], census['rows_total']), (0, expected['rows_total_while_missing']))
            code, receipt, _ = self.tool('reconcile', *self.target('copy'), '--nonce', Live.state['nonce'])
            self.assertEqual((code, receipt['verdict'], receipt['streamed']), (expected['exit'], expected['verdict'], expected['streamed']))
            self.assertIn('dispatch gate singleton', receipt['reason'])
            code, out, err = self.direct('copy', 'reconcile', dict(nonce=Live.state['nonce'], target_database=self.db,
                                                                   system_identifier=self.system_identifier('copy'),
                                                                   owner_role=self.c['owner_role']))
            self.assertEqual(self.sqlstates(err), expected['direct_sqlstates'])
            self.assertEqual(len(re.findall(r'^recovery\|stmt\|', out, re.M)), expected['statements_printed'])
            self.assertEqual(self.census('copy') == census, expected['census_unchanged'])
            self.assertEqual(self.value('copy', 'SELECT reconciled_at IS NULL FROM opencast_recovery.marker;'), 't')
        finally:
            self.restore_gate('copy', row)
        self.assertEqual(self.census('copy')['rows_total'], PREDICTED_BEFORE['rows_total'])

    def test_08_reconcile_commits_the_predicted_end_state(self):
        before = self.census('copy')
        self.assertEqual({k: before.get(k) for k in PREDICTED_BEFORE}, PREDICTED_BEFORE)
        for table, states in PREDICTED_STATES_BEFORE.items():
            if table.startswith('n_event_'):
                continue
            self.assertEqual({s: before.get('state|%s|%s' % (table, s)) for s in states}, states, table)
        events = self.value('copy', "SELECT string_agg((kind<>'episode')::text||':'||fanout_complete||':'||disposition||':'||"
                                    "COALESCE(interest_id IN (SELECT interest_id FROM opencast.n_job_interest), false)::text,"
                                    "',' ORDER BY event_id) FROM opencast.n_event;")
        self.assertEqual(events, 'false:0:accepted:false,false:0:accepted:false,false:1:accepted:false,'
                                 'false:1:suppressed:false,true:0:accepted:true,true:1:accepted:true,true:1:accepted:false')
        revisions = int(self.value('copy', 'SELECT sum(revision) FROM opencast.n_control;'))
        code, receipt, _ = self.tool('reconcile', *self.target('copy'), '--nonce', Live.state['nonce'])
        self.assertEqual((code, receipt['verdict'], receipt['outcome']), (0, 'PASS', 'COMMITTED'), receipt.get('reason'))
        self.assertEqual(tuple((s['id'], s['rows']) for s in receipt['statements']), PREDICTED_STATEMENTS)
        after = receipt['census_after']
        self.assertEqual({k: after.get(k) for k in PREDICTED_AFTER}, PREDICTED_AFTER)
        self.assertEqual(receipt['census_committed'], after)
        self.assertEqual({k: v for k, v in receipt['census_before'].items()}, before)
        self.assertTrue(all(p['ok'] for p in receipt['postconditions'].values()))
        self.assertNotEqual(receipt['marker_committed']['reconciled_at'], '')
        states = PREDICTED_STATES_AFTER
        self.assertEqual({s: after.get('state|n_outbox|' + s) for s in states['n_outbox']}, states['n_outbox'])
        self.assertEqual({s: after.get('state|n_event_disposition|' + s) for s in states['n_event_disposition']},
                         states['n_event_disposition'])
        generations = dict(l.split('|') for l in self.psql('copy', "SELECT replace(feed_id,'feed-','f')||'|'||eligibility_generation "
                                                                   "FROM opencast.n_feed ORDER BY 1;")[1].split())
        self.assertEqual({k: int(v) for k, v in generations.items()}, states['n_feed_generation'])
        self.assertEqual(int(self.value('copy', 'SELECT sum(revision) FROM opencast.n_control;')) - revisions,
                         states['n_control_revision_sum_delta'])
        boundary = Live.state['boundary']
        self.assertEqual(self.value('copy', "SELECT string_agg(feed_id||'='||no_interest_since, ',' ORDER BY feed_id) FROM opencast.n_feed;"),
                         'feed-1=%d,feed-2=%d,feed-3=1700000900' % (boundary, boundary))
        self.assertEqual(self.value('copy', "SELECT string_agg(event_id||'='||terminal_at, ',' ORDER BY event_id) FROM opencast.n_event "
                                            "WHERE event_id IN ('event-1','event-2');"), 'event-1=%d,event-2=%d' % (boundary, boundary))
        Live.state['after'] = after
        Live.state['reconcile_receipt'] = receipt

    def test_09_a_second_run_changes_nothing(self):
        code, receipt, _ = self.tool('reconcile', *self.target('copy'), '--nonce', Live.state['nonce'])
        self.assertEqual((code, receipt['verdict'], receipt['first_run']), (0, 'PASS', False), receipt.get('reason'))
        self.assertEqual(tuple((s['id'], s['rows']) for s in receipt['statements']), tuple((i, 0) for i, _ in PREDICTED_STATEMENTS))
        self.assertEqual(receipt['census_before'], Live.state['after'])
        self.assertEqual(receipt['census_after'], Live.state['after'])
        self.assertEqual(receipt['census_committed'], Live.state['after'])

    def test_09b_a_lost_read_after_a_committed_stream_is_stop_committed_unverified(self):
        expected = PREDICTED_FIXES['T20_post_stream_read_loss']
        sys.path.insert(0, str(HERE))
        import recovery
        receipts = Path(tempfile.mkdtemp(prefix='reconcile-read-loss-', dir=self.c['receipts']))
        os.chmod(receipts, 0o700)
        original, state = recovery.run_psql, dict(sent=False, failed=False)

        def disconnected(prefix, sql, variables=None):
            if state['sent'] and not state['failed']:
                state['failed'] = True
                return 2, '', 'psql: synthetic post-commit connection loss\n', 0.0
            result = original(prefix, sql, variables)
            if b"'recovery|stmt|R13|'" in sql:
                state['sent'] = True
            return result

        recovery.run_psql = disconnected
        try:
            with contextlib.redirect_stdout(io.StringIO()):
                code = recovery.main(['reconcile'] + self.target('copy') + ['--nonce', Live.state['nonce'], '--receipts', str(receipts)])
        finally:
            recovery.run_psql = original
        receipt = json.loads((receipts / 'reconcile.json').read_text())
        self.assertEqual(state, dict(sent=True, failed=True))
        self.assertEqual((code, receipt['verdict'], receipt['outcome']), (expected['exit'], expected['verdict'], expected['outcome']))
        self.assertEqual((receipt['psql']['exit_code'], receipt['psql']['commit_reported']), (expected['stream_exit'], True))
        self.assertEqual([s['rows'] for s in receipt['statements']], expected['statement_rows'])
        self.assertEqual(receipt['census_after']['rows_total'], expected['census_after_rows_total'])
        self.assertEqual(self.census('copy')['rows_total'], expected['independent_rows_total'])
        self.assertEqual(self.census('copy'), Live.state['after'])

    def test_10_a_fresh_enrolment_inherits_nothing_and_no_old_release_reaches_it(self):
        b = Live.state['boundary']
        device = rust_sql(SOURCE / 'slice_c.rs', r'RegisterDevice \{device:d\}=>vec!\[\s*statement\("([^"]+)"')
        subscribe = rust_sql(SOURCE / 'slice_c.rs', r'bulk\("(INSERT INTO feed_subscriptions[^"]+)"')
        recipients = rust_sql(SOURCE / 'slice_d.rs', r'ReadEpisodeRecipients\{[^}]*\} => statement\("([^"]+)"')
        sql = '\n'.join([
            'BEGIN;', 'SET LOCAL ROLE %s;' % self.c['owner_role'], 'SET LOCAL search_path = opencast, pg_catalog;',
            "INSERT INTO app_attest_keys VALUES ('install-1','key-new','\\x09'::bytea,0,'TEAM.com.example.cast','production',%d,%d);" % (b + 5, b + 5),
            'PREPARE register_device(text,text,text,text,text,text,bigint,bigint,bigint,bigint) AS %s;' % device,
            "EXECUTE register_device('install-1','key-new','token-new','token-hash-new','production','com.example.cast',1,%d,%d,0);" % (b + 10, b + 10),
            "SELECT 'probe|devices|'||count(*) FROM devices;",
            "SELECT 'probe|installs|'||count(*)||'|'||min(epoch)||'|'||min(enabled) FROM n_install;",
            "SELECT 'probe|interests_inherited|'||count(*) FROM n_interest;",
            'PREPARE subscribe(text[],text[],bigint[],bigint[],text[]) AS %s;' % subscribe,
            "EXECUTE subscribe(ARRAY['install-1'],ARRAY['https://feeds.example.com/one.xml'],ARRAY[1]::bigint[],ARRAY[%d]::bigint[],ARRAY['key-new']);" % (b + 20),
            "SELECT 'probe|interests|'||count(*)||'|'||min(activated_at) FROM n_interest;",
            'PREPARE recipients(text,bigint,text,text,bigint,bigint,bigint) AS %s;' % recipients,
            "\\echo probe|old_release",
            "EXECUTE recipients('feed-1',%d,'','recent',1,%d,%d);" % (b - 100, b - 100, b - 100),
            "\\echo probe|control",
            "EXECUTE recipients('feed-1',%d,'','recent',1,%d,%d);" % (b + 30, b + 30, b + 30),
            'ROLLBACK;'])
        code, out, err = self.psql('copy', sql + '\n')
        probe = [l for l in out.splitlines() if l]
        self.assertIn('probe|devices|1', probe)
        self.assertIn('probe|installs|1|1|1', probe)
        self.assertIn('probe|interests_inherited|0', probe)
        self.assertIn('probe|interests|1|%d' % (b + 20), probe)
        old = probe[probe.index('probe|old_release') + 1:probe.index('probe|control')]
        new = probe[probe.index('probe|control') + 1:]
        self.assertEqual(old, [])
        self.assertEqual(len(new), 1)
        self.assertTrue(new[0].startswith('install-1|'))
        self.assertEqual(self.census('copy'), Live.state['after'])

    def test_11_a_rerun_after_a_change_refuses(self):
        self.psql('copy', "BEGIN; SET LOCAL ROLE %s; INSERT INTO opencast.devices VALUES ('install-9','key-9','token-9','token-hash-9',"
                          "'production','com.example.cast',1,1,1,0); COMMIT;\n" % self.c['owner_role'])
        code, receipt, _ = self.tool('reconcile', *self.target('copy'), '--nonce', Live.state['nonce'])
        self.assertEqual((code, receipt['verdict'], receipt['streamed']), (2, 'REFUSED', False))
        code, _, err = self.direct('copy', 'reconcile', dict(nonce=Live.state['nonce'], target_database=self.db,
                                                             system_identifier=self.system_identifier('copy'),
                                                             owner_role=self.c['owner_role']))
        self.assertEqual(self.sqlstates(err), ['ORG02'])
        self.assertEqual(self.value('copy', 'SELECT count(*) FROM opencast.devices;'), '1')
        self.psql('copy', "BEGIN; SET LOCAL ROLE %s; DELETE FROM opencast.devices; DELETE FROM opencast.n_install; COMMIT;\n"
                  % self.c['owner_role'])
        self.assertEqual(self.census('copy'), Live.state['after'])

    def test_11b_a_missing_gate_refuses_close_and_keeps_the_marker(self):
        expected = PREDICTED_FIXES['T19_missing_gate_close']
        row = self.delete_gate('copy')
        try:
            census = self.census('copy')
            self.assertEqual(census['rows_total'], expected['rows_total_while_missing'])
            code, receipt, _ = self.tool('close', *self.target('copy'), '--nonce', Live.state['nonce'])
            self.assertEqual((code, receipt['verdict']), (expected['exit'], expected['verdict']))
            code, _, err = self.direct('copy', 'close', dict(nonce=Live.state['nonce'], target_database=self.db,
                                                             system_identifier=self.system_identifier('copy'),
                                                             owner_role=self.c['owner_role']))
            self.assertEqual(self.sqlstates(err), expected['direct_sqlstates'])
            intact = self.has_marker_schema('copy') and self.value(
                'copy', 'SELECT reconciled_at IS NOT NULL FROM opencast_recovery.marker;') == 't'
            self.assertEqual(intact, expected['marker_intact'])
            self.assertEqual(self.census('copy') == census, expected['census_unchanged'])
        finally:
            self.restore_gate('copy', row)
        self.assertEqual(self.census('copy'), Live.state['after'])

    def test_12_fence_refused_on_the_marked_copy(self):
        acl = self.psql('copy', (HERE / 'acl.sql').read_text())[1]
        code, receipt, _ = self.tool('fence', *self.target('copy', owner=False), '--runtime-role', self.c['runtime_role'])
        self.assertEqual((code, receipt['verdict']), (2, 'REFUSED'))
        code, _, err = self.direct('copy', 'fence', dict(runtime_role=self.c['runtime_role'], target_database=self.db,
                                                         system_identifier=self.system_identifier('copy')))
        self.assertEqual(self.sqlstates(err), ['ORF01'])
        self.assertEqual(self.psql('copy', (HERE / 'acl.sql').read_text())[1], acl)

    def test_13_close_drops_the_marker_and_the_tool_then_refuses(self):
        code, receipt, _ = self.tool('close', *self.target('copy'), '--nonce', Live.state['nonce'])
        self.assertEqual((code, receipt['verdict']), (0, 'PASS'), receipt.get('reason'))
        self.assertFalse(self.has_marker_schema('copy'))
        code, receipt, _ = self.tool('reconcile', *self.target('copy'), '--nonce', Live.state['nonce'])
        self.assertEqual((code, receipt['verdict'], receipt['streamed']), (2, 'REFUSED', False))

    def test_14_fence_the_primary(self):
        from test_recovery import derived_writable_tables
        code, receipt, receipts = self.tool('fence', *self.target('primary', owner=False), '--runtime-role', self.c['runtime_role'])
        self.assertEqual((code, receipt['verdict']), (0, 'PASS'), receipt.get('reason'))
        self.assertTrue(receipt['probe_before']['write_allowed'])
        self.assertEqual(receipt['acl_before']['writable_count'], len(derived_writable_tables()))
        self.assertEqual(sorted(w.split('|')[1] for w in receipt['acl_before']['writable']), sorted(derived_writable_tables()))
        self.assertEqual((receipt['acl_after']['writable_count'], receipt['acl_after']['writable']), (0, []))
        self.assertEqual(receipt['probe_after']['write_sqlstates'], ['42501'])
        self.assertEqual(receipt['probe_after']['select_rows'], 9)
        self.assertEqual(receipt['acl_added'], [])
        Live.state['fence_receipt'] = str(receipts / 'fence.json')

    def test_15_unfence_proves_acl_equality_and_catches_a_difference(self):
        role = self.c['runtime_role']
        self.psql('primary', 'GRANT TRUNCATE ON opencast.n_feed TO %s;\n' % role)
        code, receipt, _ = self.tool('unfence', *self.target('primary', owner=False), '--runtime-role', role,
                                     '--fence-receipt', Live.state['fence_receipt'], name='unfence-tampered')
        self.assertEqual((code, receipt['verdict']), (1, 'STOP'))
        self.assertEqual(receipt['acl_missing'], [])
        self.assertEqual(receipt['acl_extra'], ['acl|table|n_feed|%s|%s|TRUNCATE|false' % (role, self.c['owner_role'])])
        self.psql('primary', 'REVOKE TRUNCATE ON opencast.n_feed FROM %s;\n' % role)
        code, receipt, _ = self.tool('unfence', *self.target('primary', owner=False), '--runtime-role', role,
                                     '--fence-receipt', Live.state['fence_receipt'])
        self.assertEqual((code, receipt['verdict']), (0, 'PASS'), receipt.get('reason'))
        self.assertEqual((receipt['acl_missing'], receipt['acl_extra']), ([], []))
        self.assertTrue(receipt['probe_after']['write_allowed'])

    def test_16_receipts_carry_no_nonce_and_no_seeded_value(self):
        receipt = Live.state['reconcile_receipt']
        for key in ('format', 'command', 'argv', 'tool_sha256', 'sql_sha256', 'python', 'started_utc', 'finished_utc',
                    'exit_code', 'verdict', 'target', 'marker_before', 'nonce_matched', 'census_before', 'census_after',
                    'census_committed', 'statements', 'postconditions', 'outcome', 'elapsed_seconds', 'gate_wait_us',
                    'marker_after', 'marker_committed', 'psql'):
            self.assertIn(key, receipt)
        nonce = Live.state['nonce'].encode()
        for path in Path(self.c['receipts']).rglob('*'):
            if path.is_file():
                data = path.read_bytes()
                self.assertNotIn(nonce, data, path.name)
                for value in SEEDED_VALUES:
                    self.assertNotIn(value.encode(), data, '%s carries %s' % (path.name, value))


if __name__ == '__main__':
    if sys.argv[1:] == ['--print-seed']:
        sys.stdout.write(SEED_SQL)
    else:
        unittest.main()
