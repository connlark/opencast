-- Pre-fanout D-family closure from frozen D1 schema 0030.
-- Apply once as owner after 0001, A grants to both roles, 0002 and B grants.
-- INTEGER -> BIGINT; preserve exact TEXT, defaults, keys and NO ACTION FKs.
-- These three tables have no D1 triggers. Key constraints create their indexes.
-- No runtime grants: slices C, D and E add only their own authority.
BEGIN;

CREATE TABLE opencast.n_event (
 source TEXT NOT NULL, event_id TEXT NOT NULL, schema_version BIGINT NOT NULL CHECK(schema_version=1),
 kind TEXT NOT NULL CHECK(kind IN('episode','ad_analysis.completed','ad_analysis.failed','remote_transcription.completed','remote_transcription.failed')),
 payload_digest TEXT NOT NULL, occurred_at BIGINT NOT NULL, eligible_at BIGINT NOT NULL, expires_at BIGINT NOT NULL,
 receipt_id TEXT NOT NULL UNIQUE, envelope_json TEXT NOT NULL DEFAULT '{}', fanout_cursor TEXT, fanout_complete BIGINT NOT NULL DEFAULT 0, disposition TEXT NOT NULL DEFAULT 'accepted', next_attempt_at BIGINT NOT NULL DEFAULT 0, failures BIGINT NOT NULL DEFAULT 0, lease_id TEXT, lease_until BIGINT, terminal_at BIGINT, feed_id TEXT, interest_id TEXT, owner_epoch BIGINT,
 PRIMARY KEY(source,event_id), CHECK(expires_at>eligible_at)
);

CREATE TABLE opencast.n_delivery_member (
 delivery_id TEXT NOT NULL REFERENCES opencast.n_delivery(delivery_id), source TEXT NOT NULL, event_id TEXT NOT NULL,
 install_id TEXT NOT NULL, install_epoch BIGINT NOT NULL, interest_generation BIGINT NOT NULL,
 PRIMARY KEY(delivery_id,source,event_id),
 UNIQUE(source,event_id,install_id,install_epoch,interest_generation),
 FOREIGN KEY(source,event_id) REFERENCES opencast.n_event(source,event_id)
);

CREATE TABLE opencast.n_group_member (
 group_id TEXT NOT NULL, source TEXT NOT NULL, event_id TEXT NOT NULL, ordinal BIGINT NOT NULL,
 PRIMARY KEY(group_id,source,event_id), UNIQUE(group_id,ordinal),
 FOREIGN KEY(source,event_id) REFERENCES opencast.n_event(source,event_id)
);

CREATE INDEX n_event_due ON opencast.n_event(fanout_complete,next_attempt_at);
CREATE INDEX n_event_feed ON opencast.n_event(feed_id);
CREATE INDEX n_event_interest ON opencast.n_event(interest_id);

COMMIT;
