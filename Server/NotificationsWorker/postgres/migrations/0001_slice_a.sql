-- Slice A closure of schema 0030. Apply once as the schema owner.
-- INTEGER -> BIGINT; exact TEXT bytes retained, including JSON text.
-- No production bindings or grants outside this disposable authority.
BEGIN;
CREATE SCHEMA opencast;
REVOKE ALL ON SCHEMA opencast FROM PUBLIC;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;

CREATE TABLE opencast.devices (
  install_id TEXT NOT NULL,
  key_id TEXT NOT NULL,
  device_token TEXT NOT NULL,
  device_token_hash TEXT NOT NULL,
  apns_environment TEXT NOT NULL,
  bundle_id TEXT NOT NULL,
  notifications_enabled BIGINT NOT NULL,
  created_at BIGINT NOT NULL,
  last_seen_at BIGINT NOT NULL, job_capable BIGINT NOT NULL DEFAULT 0,
  PRIMARY KEY (install_id, device_token_hash)
);

CREATE TABLE opencast.feed_subscriptions (
  install_id TEXT NOT NULL,
  feed_url TEXT NOT NULL,
  notifications_enabled BIGINT NOT NULL,
  created_at BIGINT NOT NULL,
  updated_at BIGINT NOT NULL,
  deleted_at BIGINT,
  PRIMARY KEY (install_id, feed_url)
);

CREATE TABLE opencast.n_control (name TEXT PRIMARY KEY, enabled BIGINT NOT NULL DEFAULT 0 CHECK(enabled IN(0,1)), revision BIGINT NOT NULL);

CREATE TABLE opencast."n_delivery_history" (
  send_id TEXT PRIMARY KEY,
  install_id TEXT NOT NULL,
  device_token_hash TEXT NOT NULL,
  feed_url TEXT NOT NULL,
  episode_id TEXT NOT NULL,
  apns_environment TEXT NOT NULL,
  apns_status BIGINT,
  apns_id TEXT,
  apns_error TEXT,
  created_at BIGINT NOT NULL,
  updated_at BIGINT NOT NULL, episode_fingerprint TEXT,
  UNIQUE (install_id, device_token_hash, feed_url, episode_id)
);

CREATE TABLE opencast.n_feed (
 feed_id TEXT PRIMARY KEY, canonical_url TEXT NOT NULL UNIQUE, epoch BIGINT NOT NULL,
 due_at BIGINT NOT NULL, lease_id TEXT, lease_until BIGINT, observation_generation BIGINT NOT NULL DEFAULT 0,
 eligibility_generation BIGINT NOT NULL DEFAULT 1, admission_paused BIGINT NOT NULL DEFAULT 0 CHECK(admission_paused IN(0,1)), publish_token TEXT, snapshot_key TEXT, etag TEXT, last_modified TEXT, last_success_at BIGINT, no_interest_since BIGINT, schedule_generation BIGINT NOT NULL DEFAULT 0, retry_at BIGINT NOT NULL DEFAULT 0, poll_failures BIGINT NOT NULL DEFAULT 0, origin_key TEXT, baseline_at BIGINT, credible_release_at BIGINT, credible_cadence BIGINT, send_paused BIGINT NOT NULL DEFAULT 0 CHECK(send_paused IN(0,1)), dispatch_until BIGINT NOT NULL DEFAULT 0, semantic_digest TEXT, publish_cadence BIGINT, last_poll_at BIGINT, last_poll_outcome TEXT, last_poll_error TEXT, handling_failures BIGINT NOT NULL DEFAULT 0, validator_url TEXT, validator_at BIGINT,
 CHECK((lease_id IS NULL)=(lease_until IS NULL))
);

CREATE TABLE opencast.n_feed_catalog (
 feed_url TEXT PRIMARY KEY, source_url TEXT NOT NULL, title TEXT, website_url TEXT,
 created_at BIGINT NOT NULL, updated_at BIGINT NOT NULL,
 admission_health_json TEXT CHECK(admission_health_json IS NULL OR admission_health_json IS JSON)
);

CREATE TABLE opencast.n_install (
 install_id TEXT PRIMARY KEY, epoch BIGINT NOT NULL CHECK(epoch>0), deleted_at BIGINT,
 token_generation BIGINT NOT NULL DEFAULT 1, token_hash TEXT, enabled BIGINT NOT NULL CHECK(enabled IN(0,1))
, job_capable BIGINT NOT NULL DEFAULT 0, registered_at BIGINT NOT NULL DEFAULT 0, next_send_at BIGINT NOT NULL DEFAULT 0, registration_revision BIGINT NOT NULL DEFAULT 1);

CREATE TABLE opencast.n_legacy_bridge (
 install_id TEXT NOT NULL, feed_id TEXT NOT NULL, identity_key TEXT NOT NULL, disposition TEXT NOT NULL,
 expires_at BIGINT NOT NULL, PRIMARY KEY(install_id,feed_id,identity_key),
 CHECK(disposition IN('accepted','uncertain','pending','suppressed','expired'))
);

CREATE TABLE opencast.n_poll_dispatch (
 id BIGINT PRIMARY KEY CHECK(id=1), lease_id TEXT, lease_until BIGINT NOT NULL DEFAULT 0,
 cleanup_lease TEXT, cleanup_until BIGINT NOT NULL DEFAULT 0,
 cleanup_generation BIGINT NOT NULL DEFAULT 0
, stall_state TEXT NOT NULL DEFAULT 'clear', stall_since BIGINT NOT NULL DEFAULT 0, stall_alerted_at BIGINT NOT NULL DEFAULT 0, alert_armed_at BIGINT NOT NULL DEFAULT 0);

CREATE TABLE opencast.n_poll_origin (
 origin_key TEXT PRIMARY KEY, cooldown_until BIGINT NOT NULL DEFAULT 0,
 failures BIGINT NOT NULL DEFAULT 0, last_status BIGINT, updated_at BIGINT NOT NULL
);

CREATE TABLE opencast.n_poll_stat (
 bucket BIGINT PRIMARY KEY,
 publisher_failures BIGINT NOT NULL DEFAULT 0, handling_failures BIGINT NOT NULL DEFAULT 0,
 redeliveries BIGINT NOT NULL DEFAULT 0, dead_letters BIGINT NOT NULL DEFAULT 0,
 stale_commits BIGINT NOT NULL DEFAULT 0, retry_after_clamps BIGINT NOT NULL DEFAULT 0
, scan_busy BIGINT NOT NULL DEFAULT 0, permit_reclaims BIGINT NOT NULL DEFAULT 0);

CREATE TABLE opencast.n_burst (
 presentation_key TEXT PRIMARY KEY, feed_id TEXT NOT NULL REFERENCES opencast.n_feed ON DELETE CASCADE,
 owner_epoch BIGINT NOT NULL, cursor TEXT NOT NULL DEFAULT '',
 lease_id TEXT, lease_until BIGINT, complete BIGINT NOT NULL DEFAULT 0
, failures BIGINT NOT NULL DEFAULT 0, next_attempt_at BIGINT NOT NULL DEFAULT 0);

CREATE TABLE opencast.n_delivery (
 delivery_id TEXT PRIMARY KEY, presentation_id TEXT NOT NULL, install_id TEXT NOT NULL REFERENCES opencast.n_install ON DELETE CASCADE,
 install_epoch BIGINT NOT NULL, interest_key TEXT NOT NULL, interest_generation BIGINT NOT NULL,
 state TEXT NOT NULL CHECK(state IN('pending','leased','accepted','uncertain','suppressed','expired','permanent_failure','poisoned')),
 expires_at BIGINT NOT NULL, next_attempt_at BIGINT NOT NULL, lease_id TEXT, lease_until BIGINT,
 attempt_token_generation BIGINT, attempt_started_at BIGINT, apns_id TEXT NOT NULL, collapse_id TEXT NOT NULL, source TEXT NOT NULL DEFAULT 'feed_polling', event_id TEXT NOT NULL DEFAULT '', attempt BIGINT NOT NULL DEFAULT 0, stale_410_generation BIGINT, failures BIGINT NOT NULL DEFAULT 0, terminal_at BIGINT, last_reason TEXT, owner_epoch BIGINT, member_count BIGINT NOT NULL DEFAULT 1,
 UNIQUE(presentation_id,install_id,install_epoch,interest_key,interest_generation)
);

CREATE TABLE opencast.n_interest (
 install_id TEXT NOT NULL REFERENCES opencast.n_install ON DELETE CASCADE, feed_id TEXT NOT NULL, generation BIGINT NOT NULL,
 activated_at BIGINT NOT NULL, absence_generation BIGINT, absence_at BIGINT, enabled BIGINT NOT NULL CHECK(enabled IN(0,1)), changed_at BIGINT NOT NULL DEFAULT 0,
 PRIMARY KEY(install_id,feed_id), CHECK(generation>0)
);

CREATE TABLE opencast.n_job_interest (
 install_id TEXT NOT NULL REFERENCES opencast.n_install ON DELETE CASCADE, install_epoch BIGINT NOT NULL, operation_id TEXT NOT NULL,
 producer TEXT NOT NULL CHECK(producer IN('ad_analysis','remote_transcription')), requester_ref TEXT NOT NULL,
 generation BIGINT NOT NULL, grant_digest TEXT NOT NULL UNIQUE, grant_nonce TEXT NOT NULL, grant_key_version BIGINT NOT NULL,
 issued_at BIGINT NOT NULL, accept_before BIGINT NOT NULL, register_before BIGINT NOT NULL,
 accepted_at BIGINT, run_id TEXT, job_handle TEXT,
 state TEXT NOT NULL CHECK(state IN('issued','registered','revoked','seen','cancelled','superseded','expired')),
 seen_at BIGINT, reason TEXT, interest_id TEXT, receipt_id TEXT, attempt_started_at BIGINT, local_fallback_safe BIGINT, PRIMARY KEY(install_id,install_epoch,operation_id), CHECK(accept_before=issued_at+1800), CHECK(register_before=issued_at+604800)
);

CREATE TABLE opencast.n_snapshot (
 object_key TEXT PRIMARY KEY, feed_id TEXT NOT NULL REFERENCES opencast.n_feed, owner_epoch BIGINT NOT NULL,
 lease_id TEXT NOT NULL, sha256 TEXT NOT NULL, bytes BIGINT NOT NULL,
 state TEXT NOT NULL CHECK(state IN('reserved','uploaded','referenced','gc_claimed','deleted')),
 created_at BIGINT NOT NULL, gc_after BIGINT NOT NULL, expected_pages BIGINT NOT NULL DEFAULT 0 CHECK(expected_pages>=0)
);

CREATE TABLE opencast.n_observation (
 observation_id TEXT PRIMARY KEY, feed_id TEXT NOT NULL REFERENCES opencast.n_feed, generation BIGINT NOT NULL,
 owner_epoch BIGINT NOT NULL, lease_id TEXT NOT NULL, expected_generation BIGINT NOT NULL,
 snapshot_key TEXT NOT NULL REFERENCES opencast.n_snapshot(object_key), scan_started_at BIGINT NOT NULL, completed_at BIGINT,
 candidate_count BIGINT NOT NULL CHECK(candidate_count>=0), staged_count BIGINT NOT NULL DEFAULT 0 CHECK(staged_count BETWEEN 0 AND 1000), valid_eof BIGINT NOT NULL DEFAULT 0,
 candidate_storage TEXT NOT NULL DEFAULT 'd1' CHECK(candidate_storage IN('d1','r2')), spooled_count BIGINT NOT NULL DEFAULT 0,
 candidate_cursor BIGINT NOT NULL DEFAULT 0, reason_counts_json TEXT NOT NULL DEFAULT '{}',
 state TEXT NOT NULL CHECK(state IN('staging','published','abandoned')), eligibility_generation BIGINT NOT NULL DEFAULT 1, etag TEXT, last_modified TEXT, metadata_json TEXT NOT NULL DEFAULT '{}', drain_complete BIGINT NOT NULL DEFAULT 0, recovery_evidence BIGINT NOT NULL DEFAULT 1, preparation_key TEXT, processing_token TEXT, processing_until BIGINT, processing_failures BIGINT NOT NULL DEFAULT 0, processing_next_at BIGINT NOT NULL DEFAULT 0, UNIQUE(feed_id,generation,owner_epoch,lease_id)
);

CREATE TABLE opencast.n_snapshot_ref (
 manifest_key TEXT NOT NULL REFERENCES opencast.n_snapshot(object_key), page_key TEXT NOT NULL REFERENCES opencast.n_snapshot(object_key),
 PRIMARY KEY(manifest_key,page_key), CHECK(manifest_key<>page_key)
);

CREATE TABLE opencast."n_episode_release" (
 feed_id TEXT NOT NULL REFERENCES opencast.n_feed, episode_id TEXT NOT NULL,
 observation_id TEXT NOT NULL REFERENCES opencast.n_observation,
 generation BIGINT NOT NULL, owner_epoch BIGINT NOT NULL,
 event_id TEXT NOT NULL, presentation_key TEXT NOT NULL,
 first_observed_at BIGINT NOT NULL, eligible_at BIGINT NOT NULL,
 expires_at BIGINT NOT NULL, reason TEXT NOT NULL,
 fingerprint TEXT, published_at BIGINT, metadata_json TEXT NOT NULL,
 state TEXT NOT NULL CHECK(state IN('pending_future','ready','outboxed','withdrawn','expired')),
 disposition TEXT, PRIMARY KEY(feed_id,episode_id)
);

CREATE TABLE opencast.n_outbox (
 source TEXT NOT NULL, event_id TEXT NOT NULL, observation_id TEXT REFERENCES opencast.n_observation, payload_digest TEXT NOT NULL,
 occurred_at BIGINT NOT NULL, expires_at BIGINT NOT NULL, next_attempt_at BIGINT NOT NULL,
 state TEXT NOT NULL CHECK(state IN('pending','accepted','expired','conflict')), receipt_id TEXT, payload_json TEXT NOT NULL DEFAULT '{}',
 PRIMARY KEY(source,event_id), CHECK(expires_at>occurred_at)
);

CREATE INDEX idx_devices_install
  ON opencast.devices (install_id);
CREATE INDEX idx_feed_subscriptions_feed_enabled
  ON opencast.feed_subscriptions (feed_url, notifications_enabled, deleted_at);
CREATE INDEX n_delivery_due ON opencast.n_delivery(state,next_attempt_at);
CREATE INDEX n_delivery_history_feed_episode ON opencast.n_delivery_history(feed_url,episode_id);
CREATE UNIQUE INDEX n_delivery_history_fingerprint
 ON opencast.n_delivery_history(install_id,device_token_hash,feed_url,episode_fingerprint)
 WHERE episode_fingerprint IS NOT NULL;
CREATE INDEX n_delivery_install ON opencast.n_delivery(install_id,interest_key);
CREATE INDEX n_delivery_lease ON opencast.n_delivery(state,lease_until);
CREATE INDEX n_episode_release_due ON opencast.n_episode_release(state,eligible_at);
CREATE INDEX n_episode_release_expiry ON opencast.n_episode_release(expires_at);
CREATE INDEX n_episode_release_observation ON opencast.n_episode_release(observation_id,episode_id);
CREATE INDEX n_episode_release_presentation ON opencast.n_episode_release(presentation_key,event_id);
CREATE INDEX n_feed_due ON opencast.n_feed(admission_paused,retry_at,due_at);
CREATE INDEX n_feed_no_interest ON opencast.n_feed(no_interest_since) WHERE no_interest_since IS NOT NULL;
CREATE INDEX n_feed_snapshot ON opencast.n_feed(snapshot_key);
CREATE INDEX n_interest_feed ON opencast.n_interest(feed_id,enabled,install_id,generation);
CREATE UNIQUE INDEX n_job_interest_id ON opencast.n_job_interest(interest_id);
CREATE INDEX n_job_interest_install ON opencast.n_job_interest(install_id);
CREATE INDEX n_observation_age ON opencast.n_observation(scan_started_at);
CREATE INDEX n_observation_drain ON opencast.n_observation(state,drain_complete,completed_at);
CREATE INDEX n_observation_recovery ON opencast.n_observation(feed_id,state,scan_started_at);
CREATE INDEX n_observation_snapshot ON opencast.n_observation(snapshot_key);
CREATE INDEX n_outbox_due ON opencast.n_outbox(state,next_attempt_at);
CREATE INDEX n_outbox_expiry ON opencast.n_outbox(source,expires_at);
CREATE INDEX n_outbox_observation ON opencast.n_outbox(observation_id);
CREATE INDEX n_snapshot_gc ON opencast.n_snapshot(state,gc_after);
CREATE INDEX n_snapshot_lease ON opencast.n_snapshot(lease_id);
CREATE INDEX n_snapshot_ref_page ON opencast.n_snapshot_ref(page_key);

-- 0030 trigger: n_catalog_enrolled; invoker privileges, same transaction as the caller.
CREATE FUNCTION opencast.n_catalog_enrolled_fn() RETURNS trigger LANGUAGE plpgsql AS $trigger$
BEGIN
 UPDATE opencast.n_feed_catalog SET admission_health_json=NULL WHERE feed_url=NEW.canonical_url AND admission_health_json IS NOT NULL;
 RETURN NULL;
END
$trigger$;
CREATE TRIGGER n_catalog_enrolled AFTER INSERT ON opencast.n_feed
 FOR EACH ROW EXECUTE FUNCTION opencast.n_catalog_enrolled_fn();

-- 0030 trigger: n_device_delete; invoker privileges, same transaction as the caller.
CREATE FUNCTION opencast.n_device_delete_fn() RETURNS trigger LANGUAGE plpgsql AS $trigger$
BEGIN
 UPDATE opencast.n_install SET enabled=0,token_hash=NULL,token_generation=token_generation+1
 WHERE install_id=OLD.install_id AND token_hash=OLD.device_token_hash;
 RETURN NULL;
END
$trigger$;
CREATE TRIGGER n_device_delete AFTER DELETE ON opencast.devices
 FOR EACH ROW EXECUTE FUNCTION opencast.n_device_delete_fn();

-- 0030 trigger: n_device_insert; invoker privileges, same transaction as the caller.
CREATE FUNCTION opencast.n_device_insert_fn() RETURNS trigger LANGUAGE plpgsql AS $trigger$
BEGIN
 INSERT INTO opencast.n_install(install_id,epoch,token_generation,token_hash,enabled,job_capable,registered_at)
 VALUES(NEW.install_id,1,1,NEW.device_token_hash,NEW.notifications_enabled,NEW.job_capable,NEW.last_seen_at)
 ON CONFLICT(install_id) DO UPDATE SET token_generation=opencast.n_install.token_generation+1,
 token_hash=excluded.token_hash,enabled=excluded.enabled,job_capable=excluded.job_capable,registered_at=excluded.registered_at;
 RETURN NULL;
END
$trigger$;
CREATE TRIGGER n_device_insert AFTER INSERT ON opencast.devices
 FOR EACH ROW EXECUTE FUNCTION opencast.n_device_insert_fn();

-- 0030 trigger: n_device_update; invoker privileges, same transaction as the caller.
CREATE FUNCTION opencast.n_device_update_fn() RETURNS trigger LANGUAGE plpgsql AS $trigger$
BEGIN
 UPDATE opencast.n_install SET
 token_generation=token_generation+CASE WHEN token_hash IS DISTINCT FROM NEW.device_token_hash
   OR enabled<>NEW.notifications_enabled OR job_capable<>NEW.job_capable
   OR OLD.device_token<>NEW.device_token OR OLD.apns_environment<>NEW.apns_environment
   OR OLD.bundle_id<>NEW.bundle_id THEN 1 ELSE 0 END,
 token_hash=NEW.device_token_hash,enabled=NEW.notifications_enabled,
 registration_revision=registration_revision+1,
 job_capable=NEW.job_capable,registered_at=GREATEST(registered_at,NEW.last_seen_at)
 WHERE install_id=NEW.install_id AND (token_hash=OLD.device_token_hash OR NEW.notifications_enabled=1);
 RETURN NULL;
END
$trigger$;
CREATE TRIGGER n_device_update AFTER UPDATE ON opencast.devices
 FOR EACH ROW EXECUTE FUNCTION opencast.n_device_update_fn();

-- 0030 trigger: n_feed_insert; invoker privileges, same transaction as the caller.
CREATE FUNCTION opencast.n_feed_insert_fn() RETURNS trigger LANGUAGE plpgsql AS $trigger$
BEGIN
 -- Preserve OR IGNORE for the enabled CHECK as well as duplicate keys.
 INSERT INTO opencast.n_interest(install_id,feed_id,generation,activated_at,enabled,changed_at)
 SELECT s.install_id,NEW.feed_id,1,s.created_at, CASE WHEN s.deleted_at IS NULL THEN s.notifications_enabled ELSE 0 END ,s.updated_at
 FROM opencast.feed_subscriptions s JOIN opencast.n_install i ON i.install_id=s.install_id WHERE s.feed_url=NEW.canonical_url
 AND (CASE WHEN s.deleted_at IS NULL THEN s.notifications_enabled ELSE 0 END) IN (0,1)
 ON CONFLICT DO NOTHING;
 UPDATE opencast.n_feed SET no_interest_since=NEW.due_at WHERE feed_id=NEW.feed_id AND NOT EXISTS(SELECT 1 FROM opencast.n_interest WHERE feed_id=NEW.feed_id AND enabled=1);
 INSERT INTO opencast.n_legacy_bridge(install_id,feed_id,identity_key,disposition,expires_at)
 SELECT install_id,NEW.feed_id,'episode:'||episode_id, CASE WHEN BOOL_OR(COALESCE(apns_status=200,FALSE)) THEN 'accepted' WHEN BOOL_OR(apns_status IS NULL AND apns_error IS NULL) THEN 'uncertain' ELSE 'suppressed' END ,MAX(updated_at)+2592000 FROM opencast.n_delivery_history
 WHERE feed_url=NEW.canonical_url GROUP BY install_id,episode_id ON CONFLICT DO NOTHING;
 INSERT INTO opencast.n_legacy_bridge(install_id,feed_id,identity_key,disposition,expires_at)
 SELECT install_id,NEW.feed_id,'fingerprint:v2:'||episode_fingerprint, CASE WHEN BOOL_OR(COALESCE(apns_status=200,FALSE)) THEN 'accepted' WHEN BOOL_OR(apns_status IS NULL AND apns_error IS NULL) THEN 'uncertain' ELSE 'suppressed' END ,MAX(updated_at)+2592000 FROM opencast.n_delivery_history
 WHERE feed_url=NEW.canonical_url AND episode_fingerprint IS NOT NULL GROUP BY install_id,episode_fingerprint ON CONFLICT DO NOTHING;
 RETURN NULL;
END
$trigger$;
CREATE TRIGGER n_feed_insert AFTER INSERT ON opencast.n_feed
 FOR EACH ROW EXECUTE FUNCTION opencast.n_feed_insert_fn();

-- 0030 trigger: n_install_disable; invoker privileges, same transaction as the caller.
CREATE FUNCTION opencast.n_install_disable_fn() RETURNS trigger LANGUAGE plpgsql AS $trigger$
BEGIN
 UPDATE opencast.n_delivery SET state='suppressed',terminal_at=NEW.registered_at,last_reason='unregistered',lease_id=NULL,lease_until=NULL
 WHERE install_id=NEW.install_id AND state IN('pending','leased','uncertain','poisoned');
 UPDATE opencast.n_job_interest SET state='revoked' WHERE install_id=NEW.install_id AND state IN('issued','registered');
 RETURN NULL;
END
$trigger$;
CREATE TRIGGER n_install_disable AFTER UPDATE OF enabled ON opencast.n_install
 FOR EACH ROW WHEN (NEW.enabled=0) EXECUTE FUNCTION opencast.n_install_disable_fn();

-- 0030 trigger: n_install_insert; invoker privileges, same transaction as the caller.
CREATE FUNCTION opencast.n_install_insert_fn() RETURNS trigger LANGUAGE plpgsql AS $trigger$
BEGIN
 -- Preserve OR IGNORE for the enabled CHECK as well as duplicate keys.
 INSERT INTO opencast.n_interest(install_id,feed_id,generation,activated_at,enabled,changed_at)
 SELECT NEW.install_id,f.feed_id,1,s.created_at, CASE WHEN s.deleted_at IS NULL THEN s.notifications_enabled ELSE 0 END ,s.updated_at
 FROM opencast.feed_subscriptions s JOIN opencast.n_feed f ON f.canonical_url=s.feed_url WHERE s.install_id=NEW.install_id
 AND (CASE WHEN s.deleted_at IS NULL THEN s.notifications_enabled ELSE 0 END) IN (0,1)
 ON CONFLICT DO NOTHING;
 RETURN NULL;
END
$trigger$;
CREATE TRIGGER n_install_insert AFTER INSERT ON opencast.n_install
 FOR EACH ROW EXECUTE FUNCTION opencast.n_install_insert_fn();

-- 0030 trigger: n_interest_changed; invoker privileges, same transaction as the caller.
CREATE FUNCTION opencast.n_interest_changed_fn() RETURNS trigger LANGUAGE plpgsql AS $trigger$
BEGIN
 UPDATE opencast.n_feed SET eligibility_generation=eligibility_generation+1,lease_id=NULL,lease_until=NULL WHERE feed_id=NEW.feed_id;
 UPDATE opencast.n_feed SET no_interest_since= CASE WHEN EXISTS(SELECT 1 FROM opencast.n_interest WHERE feed_id=NEW.feed_id AND enabled=1) THEN NULL ELSE COALESCE(no_interest_since,NEW.changed_at) END WHERE feed_id=NEW.feed_id;
 UPDATE opencast.n_delivery SET state='suppressed',terminal_at=NEW.changed_at,last_reason='interest_changed',lease_id=NULL,lease_until=NULL
 WHERE install_id=NEW.install_id AND interest_key=NEW.feed_id AND interest_generation<>NEW.generation AND state IN('pending','leased','uncertain','poisoned');
 RETURN NULL;
END
$trigger$;
CREATE TRIGGER n_interest_changed AFTER UPDATE ON opencast.n_interest
 FOR EACH ROW WHEN (OLD.enabled<>NEW.enabled OR OLD.generation<>NEW.generation) EXECUTE FUNCTION opencast.n_interest_changed_fn();

-- 0030 trigger: n_interest_inserted; invoker privileges, same transaction as the caller.
CREATE FUNCTION opencast.n_interest_inserted_fn() RETURNS trigger LANGUAGE plpgsql AS $trigger$
BEGIN
 UPDATE opencast.n_feed SET no_interest_since=NULL,eligibility_generation=eligibility_generation+1,lease_id=NULL,lease_until=NULL WHERE feed_id=NEW.feed_id;
 RETURN NULL;
END
$trigger$;
CREATE TRIGGER n_interest_inserted AFTER INSERT ON opencast.n_interest
 FOR EACH ROW WHEN (NEW.enabled=1) EXECUTE FUNCTION opencast.n_interest_inserted_fn();

-- 0030 trigger: n_interest_removed; invoker privileges, same transaction as the caller.
CREATE FUNCTION opencast.n_interest_removed_fn() RETURNS trigger LANGUAGE plpgsql AS $trigger$
BEGIN
 UPDATE opencast.n_feed SET eligibility_generation=eligibility_generation+1,lease_id=NULL,lease_until=NULL WHERE feed_id=OLD.feed_id;
 UPDATE opencast.n_feed SET no_interest_since=COALESCE(no_interest_since,OLD.changed_at) WHERE feed_id=OLD.feed_id AND NOT EXISTS(SELECT 1 FROM opencast.n_interest WHERE feed_id=OLD.feed_id AND enabled=1);
 RETURN NULL;
END
$trigger$;
CREATE TRIGGER n_interest_removed AFTER DELETE ON opencast.n_interest
 FOR EACH ROW EXECUTE FUNCTION opencast.n_interest_removed_fn();

-- 0030 trigger: n_subscription_delete; invoker privileges, same transaction as the caller.
CREATE FUNCTION opencast.n_subscription_delete_fn() RETURNS trigger LANGUAGE plpgsql AS $trigger$
BEGIN
 UPDATE opencast.n_interest SET enabled=0,generation=generation+1,changed_at=OLD.updated_at WHERE install_id=OLD.install_id
 AND feed_id=(SELECT feed_id FROM opencast.n_feed WHERE canonical_url=OLD.feed_url) AND enabled=1;
 RETURN NULL;
END
$trigger$;
CREATE TRIGGER n_subscription_delete AFTER DELETE ON opencast.feed_subscriptions
 FOR EACH ROW EXECUTE FUNCTION opencast.n_subscription_delete_fn();

-- 0030 trigger: n_subscription_insert; invoker privileges, same transaction as the caller.
CREATE FUNCTION opencast.n_subscription_insert_fn() RETURNS trigger LANGUAGE plpgsql AS $trigger$
BEGIN
 INSERT INTO opencast.n_interest(install_id,feed_id,generation,activated_at,enabled,changed_at)
 SELECT NEW.install_id,f.feed_id,1,NEW.created_at, CASE WHEN NEW.deleted_at IS NULL THEN NEW.notifications_enabled ELSE 0 END ,NEW.updated_at
 FROM opencast.n_feed f JOIN opencast.n_install i ON i.install_id=NEW.install_id WHERE f.canonical_url=NEW.feed_url
 ON CONFLICT(install_id,feed_id) DO NOTHING;
 RETURN NULL;
END
$trigger$;
CREATE TRIGGER n_subscription_insert AFTER INSERT ON opencast.feed_subscriptions
 FOR EACH ROW EXECUTE FUNCTION opencast.n_subscription_insert_fn();

-- 0030 trigger: n_subscription_update; invoker privileges, same transaction as the caller.
CREATE FUNCTION opencast.n_subscription_update_fn() RETURNS trigger LANGUAGE plpgsql AS $trigger$
BEGIN
 INSERT INTO opencast.n_interest(install_id,feed_id,generation,activated_at,enabled,changed_at)
 SELECT NEW.install_id,f.feed_id,1,NEW.created_at, CASE WHEN NEW.deleted_at IS NULL THEN NEW.notifications_enabled ELSE 0 END ,NEW.updated_at
 FROM opencast.n_feed f JOIN opencast.n_install i ON i.install_id=NEW.install_id WHERE f.canonical_url=NEW.feed_url
 ON CONFLICT(install_id,feed_id) DO UPDATE SET
 generation= CASE WHEN opencast.n_interest.enabled<>excluded.enabled THEN opencast.n_interest.generation+1 ELSE opencast.n_interest.generation END ,
 activated_at= CASE WHEN opencast.n_interest.enabled=0 AND excluded.enabled=1 THEN excluded.activated_at ELSE opencast.n_interest.activated_at END ,
 absence_generation= CASE WHEN opencast.n_interest.enabled=excluded.enabled THEN opencast.n_interest.absence_generation ELSE NULL END ,
 absence_at= CASE WHEN opencast.n_interest.enabled=excluded.enabled THEN opencast.n_interest.absence_at ELSE NULL END ,enabled=excluded.enabled,changed_at=excluded.changed_at;
 RETURN NULL;
END
$trigger$;
CREATE TRIGGER n_subscription_update AFTER UPDATE ON opencast.feed_subscriptions
 FOR EACH ROW EXECUTE FUNCTION opencast.n_subscription_update_fn();

-- Seed the singleton before any runtime connection. Runtime cannot insert/delete it.
INSERT INTO opencast.n_poll_dispatch(id) VALUES(1);
-- Fresh-authority defaults, matching 0030. Fixtures enable controls explicitly.
INSERT INTO opencast.n_control(name,enabled,revision) VALUES
 ('dispatcher_admission',0,1),('episode_activation',0,1),('episode_send',0,1),
 ('job_enrollment',0,1),('job_send',0,1),('cleanup',0,1),
 ('diagnostic_send',1,1),('feed_observation',0,1),('five_minute_polling',0,1);
REVOKE ALL ON ALL TABLES IN SCHEMA opencast FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA opencast FROM PUBLIC;
COMMIT;
