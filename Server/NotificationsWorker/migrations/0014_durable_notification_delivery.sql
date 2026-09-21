-- Additive delivery foundation. All new controls default off; no ownership transfer.
PRAGMA foreign_keys = ON;
CREATE TABLE n_install (
 install_id TEXT PRIMARY KEY, epoch INTEGER NOT NULL CHECK(epoch>0), deleted_at INTEGER,
 token_generation INTEGER NOT NULL DEFAULT 1, token_hash TEXT, enabled INTEGER NOT NULL CHECK(enabled IN(0,1))
);
CREATE TABLE n_interest (
 install_id TEXT NOT NULL REFERENCES n_install ON DELETE CASCADE, feed_id TEXT NOT NULL, generation INTEGER NOT NULL,
 activated_at INTEGER NOT NULL, absence_generation INTEGER, absence_at INTEGER, enabled INTEGER NOT NULL CHECK(enabled IN(0,1)),
 PRIMARY KEY(install_id,feed_id), CHECK(generation>0)
);
CREATE TABLE n_control (name TEXT PRIMARY KEY, enabled INTEGER NOT NULL DEFAULT 0 CHECK(enabled IN(0,1)), revision INTEGER NOT NULL);
CREATE TABLE n_feed (
 feed_id TEXT PRIMARY KEY, canonical_url TEXT NOT NULL UNIQUE, owner TEXT NOT NULL CHECK(owner IN('legacy','queued','paused')), epoch INTEGER NOT NULL,
 due_at INTEGER NOT NULL, lease_id TEXT, lease_until INTEGER, observation_generation INTEGER NOT NULL DEFAULT 0,
 eligibility_generation INTEGER NOT NULL DEFAULT 1, admission_paused INTEGER NOT NULL DEFAULT 0 CHECK(admission_paused IN(0,1)), publish_token TEXT, snapshot_key TEXT, etag TEXT, last_modified TEXT, last_success_at INTEGER,
 CHECK((lease_id IS NULL)=(lease_until IS NULL))
);
CREATE TABLE n_poll (
 job_id TEXT PRIMARY KEY, feed_id TEXT NOT NULL REFERENCES n_feed, schedule_generation INTEGER NOT NULL,
 owner_epoch INTEGER NOT NULL, state TEXT NOT NULL CHECK(state IN('ready','leased','completed','obsolete','poisoned')),
 next_attempt_at INTEGER NOT NULL, lease_id TEXT, lease_until INTEGER, attempt INTEGER NOT NULL DEFAULT 0,
 UNIQUE(feed_id,schedule_generation)
);
CREATE UNIQUE INDEX n_poll_live ON n_poll(feed_id) WHERE state IN('ready','leased');
CREATE INDEX n_poll_due ON n_poll(state,next_attempt_at);
CREATE TABLE n_snapshot (
 object_key TEXT PRIMARY KEY, feed_id TEXT NOT NULL REFERENCES n_feed, owner_epoch INTEGER NOT NULL,
 lease_id TEXT NOT NULL, sha256 TEXT NOT NULL, bytes INTEGER NOT NULL,
 state TEXT NOT NULL CHECK(state IN('reserved','uploaded','referenced','gc_claimed','deleted')),
 created_at INTEGER NOT NULL, gc_after INTEGER NOT NULL, expected_pages INTEGER NOT NULL DEFAULT 0 CHECK(expected_pages>=0)
);
CREATE TABLE n_snapshot_ref (
 manifest_key TEXT NOT NULL REFERENCES n_snapshot(object_key), page_key TEXT NOT NULL REFERENCES n_snapshot(object_key),
 PRIMARY KEY(manifest_key,page_key), CHECK(manifest_key<>page_key)
);
CREATE INDEX n_snapshot_ref_page ON n_snapshot_ref(page_key);
CREATE TABLE n_observation (
 observation_id TEXT PRIMARY KEY, feed_id TEXT NOT NULL REFERENCES n_feed, generation INTEGER NOT NULL,
 owner_epoch INTEGER NOT NULL, lease_id TEXT NOT NULL, expected_generation INTEGER NOT NULL,
 snapshot_key TEXT NOT NULL REFERENCES n_snapshot(object_key), scan_started_at INTEGER NOT NULL, completed_at INTEGER,
 candidate_count INTEGER NOT NULL CHECK(candidate_count>=0), staged_count INTEGER NOT NULL DEFAULT 0 CHECK(staged_count BETWEEN 0 AND 1000), valid_eof INTEGER NOT NULL DEFAULT 0,
 candidate_storage TEXT NOT NULL DEFAULT 'd1' CHECK(candidate_storage IN('d1','r2')), spooled_count INTEGER NOT NULL DEFAULT 0,
 candidate_cursor INTEGER NOT NULL DEFAULT 0, reason_counts_json TEXT NOT NULL DEFAULT '{}',
 state TEXT NOT NULL CHECK(state IN('staging','published','abandoned')), UNIQUE(feed_id,generation,owner_epoch,lease_id)
);
CREATE TABLE n_candidate (
 observation_id TEXT NOT NULL REFERENCES n_observation, episode_id TEXT NOT NULL, fingerprint TEXT,
 first_observed_at INTEGER NOT NULL, raw_date TEXT, published_at INTEGER, eligible_at INTEGER NOT NULL,
 reason TEXT NOT NULL CHECK(reason IN('recent','undated','anomalous_date','future')), ordinal INTEGER NOT NULL CHECK(ordinal BETWEEN 0 AND 999), state TEXT NOT NULL CHECK(state IN('staged','pending_future','active','suppressed','withdrawn')), metadata_json TEXT NOT NULL DEFAULT '{}',
 PRIMARY KEY(observation_id,episode_id), UNIQUE(observation_id,ordinal)
);
CREATE TABLE n_outbox (
 source TEXT NOT NULL, event_id TEXT NOT NULL, observation_id TEXT REFERENCES n_observation, payload_digest TEXT NOT NULL,
 occurred_at INTEGER NOT NULL, expires_at INTEGER NOT NULL, next_attempt_at INTEGER NOT NULL,
 state TEXT NOT NULL CHECK(state IN('pending','accepted','expired','conflict')), receipt_id TEXT, payload_json TEXT NOT NULL DEFAULT '{}',
 PRIMARY KEY(source,event_id), CHECK(expires_at>occurred_at)
);
CREATE INDEX n_outbox_due ON n_outbox(state,next_attempt_at);
CREATE TABLE n_event (
 source TEXT NOT NULL, event_id TEXT NOT NULL, schema_version INTEGER NOT NULL CHECK(schema_version=1),
 kind TEXT NOT NULL CHECK(kind IN('episode','ad_analysis.completed','ad_analysis.failed','remote_transcription.completed','remote_transcription.failed')),
 payload_digest TEXT NOT NULL, occurred_at INTEGER NOT NULL, eligible_at INTEGER NOT NULL, expires_at INTEGER NOT NULL,
 receipt_id TEXT NOT NULL UNIQUE, envelope_json TEXT NOT NULL DEFAULT '{}', fanout_cursor TEXT, fanout_complete INTEGER NOT NULL DEFAULT 0,
 PRIMARY KEY(source,event_id), CHECK(expires_at>eligible_at)
);
CREATE TABLE n_group_member (
 group_id TEXT NOT NULL, source TEXT NOT NULL, event_id TEXT NOT NULL, ordinal INTEGER NOT NULL,
 PRIMARY KEY(group_id,source,event_id), UNIQUE(group_id,ordinal),
 FOREIGN KEY(source,event_id) REFERENCES n_event(source,event_id)
);
CREATE TABLE n_delivery (
 delivery_id TEXT PRIMARY KEY, presentation_id TEXT NOT NULL, install_id TEXT NOT NULL REFERENCES n_install ON DELETE CASCADE,
 install_epoch INTEGER NOT NULL, interest_key TEXT NOT NULL, interest_generation INTEGER NOT NULL,
 state TEXT NOT NULL CHECK(state IN('pending','leased','accepted','uncertain','suppressed','expired','permanent_failure','poisoned')),
 expires_at INTEGER NOT NULL, next_attempt_at INTEGER NOT NULL, lease_id TEXT, lease_until INTEGER,
 attempt_token_generation INTEGER, attempt_started_at INTEGER, apns_id TEXT NOT NULL, collapse_id TEXT NOT NULL,
 UNIQUE(presentation_id,install_id,install_epoch,interest_key,interest_generation)
);
CREATE INDEX n_delivery_due ON n_delivery(state,next_attempt_at);
CREATE TABLE n_requester_ticket (
 ticket_digest TEXT PRIMARY KEY, producer TEXT NOT NULL, operation_id TEXT NOT NULL, requester_ref TEXT NOT NULL,
 issued_at INTEGER NOT NULL, expires_at INTEGER NOT NULL, environment TEXT NOT NULL
);
CREATE TABLE n_job_interest (
 install_id TEXT NOT NULL REFERENCES n_install ON DELETE CASCADE, install_epoch INTEGER NOT NULL, operation_id TEXT NOT NULL,
 producer TEXT NOT NULL CHECK(producer IN('ad_analysis','remote_transcription')), requester_ref TEXT NOT NULL,
 generation INTEGER NOT NULL, grant_digest TEXT NOT NULL UNIQUE, grant_nonce TEXT NOT NULL, grant_key_version INTEGER NOT NULL,
 issued_at INTEGER NOT NULL, accept_before INTEGER NOT NULL, register_before INTEGER NOT NULL,
 accepted_at INTEGER, run_id TEXT, job_handle TEXT,
 state TEXT NOT NULL CHECK(state IN('issued','registered','revoked','seen','cancelled','superseded','expired')),
 seen_at INTEGER, reason TEXT, PRIMARY KEY(install_id,install_epoch,operation_id), CHECK(accept_before=issued_at+1800), CHECK(register_before=issued_at+604800)
);
CREATE TABLE n_legacy_bridge (
 install_id TEXT NOT NULL, feed_id TEXT NOT NULL, identity_key TEXT NOT NULL, disposition TEXT NOT NULL,
 expires_at INTEGER NOT NULL, PRIMARY KEY(install_id,feed_id,identity_key),
 CHECK(disposition IN('accepted','uncertain','pending','suppressed','expired'))
);
CREATE TABLE n_delivery_member (
 delivery_id TEXT NOT NULL REFERENCES n_delivery, source TEXT NOT NULL, event_id TEXT NOT NULL,
 install_id TEXT NOT NULL, install_epoch INTEGER NOT NULL, interest_generation INTEGER NOT NULL,
 PRIMARY KEY(delivery_id,source,event_id),
 UNIQUE(source,event_id,install_id,install_epoch,interest_generation),
 FOREIGN KEY(source,event_id) REFERENCES n_event(source,event_id)
);

ALTER TABLE devices ADD COLUMN job_capable INTEGER NOT NULL DEFAULT 0;
ALTER TABLE n_install ADD COLUMN job_capable INTEGER NOT NULL DEFAULT 0;
ALTER TABLE n_install ADD COLUMN registered_at INTEGER NOT NULL DEFAULT 0;
ALTER TABLE n_install ADD COLUMN next_send_at INTEGER NOT NULL DEFAULT 0;
ALTER TABLE n_interest ADD COLUMN changed_at INTEGER NOT NULL DEFAULT 0;
ALTER TABLE n_feed ADD COLUMN no_interest_since INTEGER;
ALTER TABLE n_event ADD COLUMN disposition TEXT NOT NULL DEFAULT 'accepted';
ALTER TABLE n_event ADD COLUMN next_attempt_at INTEGER NOT NULL DEFAULT 0;
ALTER TABLE n_event ADD COLUMN failures INTEGER NOT NULL DEFAULT 0;
ALTER TABLE n_event ADD COLUMN lease_id TEXT;
ALTER TABLE n_event ADD COLUMN lease_until INTEGER;
ALTER TABLE n_event ADD COLUMN terminal_at INTEGER;
ALTER TABLE n_event ADD COLUMN feed_id TEXT;
ALTER TABLE n_event ADD COLUMN interest_id TEXT;
ALTER TABLE n_event ADD COLUMN owner_epoch INTEGER;
ALTER TABLE n_delivery ADD COLUMN source TEXT NOT NULL DEFAULT 'feed_polling';
ALTER TABLE n_delivery ADD COLUMN event_id TEXT NOT NULL DEFAULT '';
ALTER TABLE n_delivery ADD COLUMN attempt INTEGER NOT NULL DEFAULT 0;
ALTER TABLE n_delivery ADD COLUMN stale_410_generation INTEGER;
ALTER TABLE n_delivery ADD COLUMN failures INTEGER NOT NULL DEFAULT 0;
ALTER TABLE n_delivery ADD COLUMN terminal_at INTEGER;
ALTER TABLE n_delivery ADD COLUMN last_reason TEXT;
ALTER TABLE n_delivery ADD COLUMN owner_epoch INTEGER;
ALTER TABLE n_job_interest ADD COLUMN interest_id TEXT;
CREATE UNIQUE INDEX n_job_interest_id ON n_job_interest(interest_id);
ALTER TABLE n_job_interest ADD COLUMN receipt_id TEXT;
ALTER TABLE n_job_interest ADD COLUMN attempt_started_at INTEGER;
ALTER TABLE n_job_interest ADD COLUMN local_fallback_safe INTEGER;
CREATE INDEX n_event_due ON n_event(fanout_complete,next_attempt_at);
CREATE INDEX n_event_feed ON n_event(feed_id);
CREATE INDEX n_event_interest ON n_event(interest_id);
CREATE INDEX n_delivery_install ON n_delivery(install_id,interest_key);
CREATE INDEX n_delivery_lease ON n_delivery(state,lease_until);
CREATE INDEX n_interest_feed ON n_interest(feed_id,enabled,install_id,generation);
CREATE INDEX n_job_interest_install ON n_job_interest(install_id);
CREATE TABLE n_circuit (lane TEXT PRIMARY KEY, paused INTEGER NOT NULL DEFAULT 0, reason TEXT, updated_at INTEGER NOT NULL);
CREATE TABLE n_deleted_install(fence TEXT PRIMARY KEY, expires_at INTEGER NOT NULL);
INSERT INTO n_circuit(lane,updated_at) VALUES('apns',0);
INSERT INTO n_control(name,revision) VALUES
 ('dispatcher_admission',1),('episode_activation',1),('episode_send',1),
 ('job_enrollment',1),('job_send',1),('cleanup',1);
-- Legacy switches preserve existing service until operations explicitly pause it.
INSERT INTO n_control(name,enabled,revision) VALUES('legacy_send',1,1),('legacy_admission',1,1),('diagnostic_send',1,1),('legacy_cleanup',1,1);

-- Device projection is in the same transaction as registration/rotation/erasure.
CREATE TRIGGER n_device_insert AFTER INSERT ON devices BEGIN
 INSERT INTO n_install(install_id,epoch,token_generation,token_hash,enabled,job_capable,registered_at)
 VALUES(NEW.install_id,1,1,NEW.device_token_hash,NEW.notifications_enabled,NEW.job_capable,NEW.last_seen_at)
 ON CONFLICT(install_id) DO UPDATE SET token_generation=token_generation+1,
 token_hash=excluded.token_hash,enabled=excluded.enabled,job_capable=excluded.job_capable,registered_at=excluded.registered_at;
END;
CREATE TRIGGER n_device_update AFTER UPDATE ON devices BEGIN
 UPDATE n_install SET token_generation=token_generation+1,token_hash=NEW.device_token_hash,
 enabled=NEW.notifications_enabled,job_capable=NEW.job_capable,registered_at=NEW.last_seen_at
 WHERE install_id=NEW.install_id AND (token_hash=OLD.device_token_hash OR NEW.notifications_enabled=1);
END;
CREATE TRIGGER n_device_delete AFTER DELETE ON devices BEGIN
 UPDATE n_install SET enabled=0,token_hash=NULL,token_generation=token_generation+1
 WHERE install_id=OLD.install_id AND token_hash=OLD.device_token_hash;
END;
CREATE TRIGGER n_install_disable AFTER UPDATE OF enabled ON n_install WHEN NEW.enabled=0 BEGIN
 UPDATE n_delivery SET state='suppressed',terminal_at=NEW.registered_at,last_reason='unregistered',lease_id=NULL,lease_until=NULL
 WHERE install_id=NEW.install_id AND state IN('pending','leased','uncertain','poisoned');
 UPDATE n_job_interest SET state='revoked' WHERE install_id=NEW.install_id AND state IN('issued','registered');
END;
-- Existing registrations are copied before any queued work can be admitted.
INSERT INTO n_install(install_id,epoch,token_generation,token_hash,enabled,registered_at)
 SELECT d.install_id,1,1,d.device_token_hash,d.notifications_enabled,d.last_seen_at FROM devices d
 WHERE NOT EXISTS(SELECT 1 FROM devices newer WHERE newer.install_id=d.install_id
 AND (newer.last_seen_at>d.last_seen_at OR (newer.last_seen_at=d.last_seen_at AND newer.device_token_hash>d.device_token_hash)));

-- feed IDs are computed by Rust on API admission/backfill; SQL selects current
-- subscriptions at commit time, so backfill cannot resurrect an earlier opt-out.
CREATE TRIGGER n_feed_insert AFTER INSERT ON n_feed BEGIN
 INSERT OR IGNORE INTO n_interest(install_id,feed_id,generation,activated_at,enabled,changed_at)
 SELECT s.install_id,NEW.feed_id,1,s.created_at, CASE WHEN s.deleted_at IS NULL THEN s.notifications_enabled ELSE 0 END ,s.updated_at
 FROM feed_subscriptions s JOIN n_install i ON i.install_id=s.install_id WHERE s.feed_url=NEW.canonical_url;
 UPDATE n_feed SET no_interest_since=NEW.due_at WHERE feed_id=NEW.feed_id AND NOT EXISTS(SELECT 1 FROM n_interest WHERE feed_id=NEW.feed_id AND enabled=1);
 INSERT INTO n_legacy_bridge(install_id,feed_id,identity_key,disposition,expires_at)
 SELECT install_id,NEW.feed_id,'episode:'||episode_id, CASE WHEN MAX(COALESCE(apns_status=200,0))=1 THEN 'accepted' WHEN MAX(apns_status IS NULL AND apns_error IS NULL)=1 THEN 'uncertain' ELSE 'suppressed' END ,MAX(updated_at)+2592000 FROM episode_notification_sends
 WHERE feed_url=NEW.canonical_url GROUP BY install_id,episode_id ON CONFLICT DO NOTHING;
 INSERT INTO n_legacy_bridge(install_id,feed_id,identity_key,disposition,expires_at)
 SELECT install_id,NEW.feed_id,'fingerprint:v2:'||episode_fingerprint, CASE WHEN MAX(COALESCE(apns_status=200,0))=1 THEN 'accepted' WHEN MAX(apns_status IS NULL AND apns_error IS NULL)=1 THEN 'uncertain' ELSE 'suppressed' END ,MAX(updated_at)+2592000 FROM episode_notification_sends
 WHERE feed_url=NEW.canonical_url AND episode_fingerprint IS NOT NULL GROUP BY install_id,episode_fingerprint ON CONFLICT DO NOTHING;
END;
CREATE TRIGGER n_subscription_insert AFTER INSERT ON feed_subscriptions BEGIN
 INSERT INTO n_interest(install_id,feed_id,generation,activated_at,enabled,changed_at)
 SELECT NEW.install_id,f.feed_id,1,NEW.created_at, CASE WHEN NEW.deleted_at IS NULL THEN NEW.notifications_enabled ELSE 0 END ,NEW.updated_at
 FROM n_feed f JOIN n_install i ON i.install_id=NEW.install_id WHERE f.canonical_url=NEW.feed_url
 ON CONFLICT(install_id,feed_id) DO NOTHING;
END;
CREATE TRIGGER n_subscription_update AFTER UPDATE ON feed_subscriptions BEGIN
 INSERT INTO n_interest(install_id,feed_id,generation,activated_at,enabled,changed_at)
 SELECT NEW.install_id,f.feed_id,1,NEW.created_at, CASE WHEN NEW.deleted_at IS NULL THEN NEW.notifications_enabled ELSE 0 END ,NEW.updated_at
 FROM n_feed f JOIN n_install i ON i.install_id=NEW.install_id WHERE f.canonical_url=NEW.feed_url
 ON CONFLICT(install_id,feed_id) DO UPDATE SET
 generation= CASE WHEN n_interest.enabled<>excluded.enabled THEN n_interest.generation+1 ELSE n_interest.generation END ,
 activated_at= CASE WHEN n_interest.enabled=0 AND excluded.enabled=1 THEN excluded.activated_at ELSE n_interest.activated_at END ,
 absence_generation= CASE WHEN n_interest.enabled=excluded.enabled THEN n_interest.absence_generation ELSE NULL END ,
 absence_at= CASE WHEN n_interest.enabled=excluded.enabled THEN n_interest.absence_at ELSE NULL END ,enabled=excluded.enabled,changed_at=excluded.changed_at;
END;
CREATE TRIGGER n_subscription_delete AFTER DELETE ON feed_subscriptions BEGIN
 UPDATE n_interest SET enabled=0,generation=generation+1,changed_at=OLD.updated_at WHERE install_id=OLD.install_id
 AND feed_id=(SELECT feed_id FROM n_feed WHERE canonical_url=OLD.feed_url) AND enabled=1;
END;
CREATE TRIGGER n_interest_changed AFTER UPDATE ON n_interest WHEN OLD.enabled<>NEW.enabled OR OLD.generation<>NEW.generation BEGIN
 UPDATE n_feed SET eligibility_generation=eligibility_generation+1,lease_id=NULL,lease_until=NULL WHERE feed_id=NEW.feed_id;
 UPDATE n_feed SET no_interest_since= CASE WHEN EXISTS(SELECT 1 FROM n_interest WHERE feed_id=NEW.feed_id AND enabled=1) THEN NULL ELSE COALESCE(no_interest_since,NEW.changed_at) END WHERE feed_id=NEW.feed_id;
 UPDATE n_delivery SET state='suppressed',terminal_at=NEW.changed_at,last_reason='interest_changed',lease_id=NULL,lease_until=NULL
 WHERE install_id=NEW.install_id AND interest_key=NEW.feed_id AND interest_generation<>NEW.generation AND state IN('pending','leased','uncertain','poisoned');
END;
CREATE TRIGGER n_interest_removed AFTER DELETE ON n_interest BEGIN
 UPDATE n_feed SET eligibility_generation=eligibility_generation+1,lease_id=NULL,lease_until=NULL WHERE feed_id=OLD.feed_id;
 UPDATE n_feed SET no_interest_since=COALESCE(no_interest_since,OLD.changed_at) WHERE feed_id=OLD.feed_id AND NOT EXISTS(SELECT 1 FROM n_interest WHERE feed_id=OLD.feed_id AND enabled=1);
END;
CREATE TRIGGER n_interest_inserted AFTER INSERT ON n_interest WHEN NEW.enabled=1 BEGIN
 UPDATE n_feed SET no_interest_since=NULL,eligibility_generation=eligibility_generation+1,lease_id=NULL,lease_until=NULL WHERE feed_id=NEW.feed_id;
END;
CREATE TRIGGER n_install_insert AFTER INSERT ON n_install BEGIN
 INSERT OR IGNORE INTO n_interest(install_id,feed_id,generation,activated_at,enabled,changed_at)
 SELECT NEW.install_id,f.feed_id,1,s.created_at, CASE WHEN s.deleted_at IS NULL THEN s.notifications_enabled ELSE 0 END ,s.updated_at
 FROM feed_subscriptions s JOIN n_feed f ON f.canonical_url=s.feed_url WHERE s.install_id=NEW.install_id;
END;
CREATE TRIGGER n_legacy_outcome AFTER UPDATE OF state ON n_delivery WHEN NEW.source='legacy' BEGIN
 UPDATE episode_notification_sends SET apns_status= CASE WHEN NEW.state='accepted' THEN 200 ELSE NULL END ,
 apns_id=NEW.apns_id,apns_error= CASE WHEN NEW.state='accepted' THEN NULL ELSE NEW.last_reason END ,
 updated_at=COALESCE(NEW.terminal_at,NEW.next_attempt_at) WHERE send_id=NEW.delivery_id;
END;
