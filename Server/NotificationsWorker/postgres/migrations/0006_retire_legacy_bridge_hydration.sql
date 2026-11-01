-- Retire the legacy handoff-dedupe bridge's hydration.
-- Replaces 0001's n_feed_insert_fn with the same body less its two
-- INSERT INTO opencast.n_legacy_bridge statements: the n_interest insert, the
-- no_interest_since update and RETURN NULL are byte-identical. The trigger
-- n_feed_insert keeps its name, table and enabled state, so no catalog digest
-- changes. Apply once as the owner AFTER the release of both Workers whose
-- builds list 31 application tables; 0007 then drops the table, separately.
-- Maintenance takes the n_poll_dispatch gate first (postgres/README.md); a
-- missing singleton aborts by division by zero. Idempotent: a second run
-- replaces the function with the same text.
BEGIN;

SELECT 1/COUNT(*) FROM (SELECT id FROM opencast.n_poll_dispatch WHERE id = 1 FOR UPDATE) AS gate;

-- 0030 trigger: n_feed_insert; invoker privileges, same transaction as the caller.
CREATE OR REPLACE FUNCTION opencast.n_feed_insert_fn() RETURNS trigger LANGUAGE plpgsql AS $trigger$
BEGIN
 -- Preserve OR IGNORE for the enabled CHECK as well as duplicate keys.
 INSERT INTO opencast.n_interest(install_id,feed_id,generation,activated_at,enabled,changed_at)
 SELECT s.install_id,NEW.feed_id,1,s.created_at, CASE WHEN s.deleted_at IS NULL THEN s.notifications_enabled ELSE 0 END ,s.updated_at
 FROM opencast.feed_subscriptions s JOIN opencast.n_install i ON i.install_id=s.install_id WHERE s.feed_url=NEW.canonical_url
 AND (CASE WHEN s.deleted_at IS NULL THEN s.notifications_enabled ELSE 0 END) IN (0,1)
 ON CONFLICT DO NOTHING;
 UPDATE opencast.n_feed SET no_interest_since=NEW.due_at WHERE feed_id=NEW.feed_id AND NOT EXISTS(SELECT 1 FROM opencast.n_interest WHERE feed_id=NEW.feed_id AND enabled=1);
 RETURN NULL;
END
$trigger$;

COMMIT;
