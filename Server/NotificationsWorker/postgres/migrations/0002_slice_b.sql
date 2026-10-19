-- Slice B: observations, catalog reads and R2 references, local-only.
-- The recomputed 0030 closure has 15 tables, all already installed by 0001.
-- No new table, index, trigger, CHECK or FK is needed. Do not recreate or alter
-- inherited objects: inventory/slice-b-schema.json records the exact closure.
-- Inbound snapshot FKs are present, including observation and both ref columns.
-- n_delivery_member remains omitted: B never deletes n_delivery. Reclose before
-- B05/B06/B11/B20. Apply runtime-grants-slice-b.sql separately as owner.
DO $slice_b$
DECLARE relation_name text;
BEGIN
  FOREACH relation_name IN ARRAY ARRAY[
    'feed_subscriptions','n_control','n_delivery','n_delivery_history',
    'n_episode_release','n_feed','n_feed_catalog','n_install','n_interest',
    'n_job_interest','n_legacy_bridge','n_observation','n_poll_dispatch',
    'n_snapshot','n_snapshot_ref'
  ] LOOP
    IF to_regclass('opencast.' || relation_name) IS NULL THEN
      RAISE EXCEPTION 'slice B requires the complete slice A schema';
    END IF;
  END LOOP;
END;
$slice_b$;
