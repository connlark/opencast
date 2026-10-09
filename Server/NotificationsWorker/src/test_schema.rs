//! Host-only schema for SQL result and plan tests: every migration, in order.
use rusqlite::{Connection, ToSql};

const MIGRATIONS: [&str; 30] = [
    include_str!("../migrations/0001_app_attest.sql"),
    include_str!("../migrations/0002_devices.sql"),
    include_str!("../migrations/0003_feed_notifications.sql"),
    include_str!("../migrations/0004_public_rollout_caps.sql"),
    include_str!("../migrations/0005_global_challenge_rate_limit.sql"),
    include_str!("../migrations/0006_challenge_source_buckets.sql"),
    include_str!("../migrations/0007_notification_fingerprint_and_device_token_cleanup.sql"),
    include_str!("../migrations/0008_cleanup_superseded_device_tokens.sql"),
    include_str!("../migrations/0009_delete_dead_device_rows.sql"),
    include_str!("../migrations/0010_index_feeds_next_poll_at.sql"),
    include_str!("../migrations/0011_feed_publish_cadence.sql"),
    include_str!("../migrations/0012_admin_history_indexes.sql"),
    include_str!("../migrations/0013_install_delete_indexes.sql"),
    include_str!("../migrations/0014_durable_notification_delivery.sql"),
    include_str!("../migrations/0015_feed_observations.sql"),
    include_str!("../migrations/0016_queued_polling.sql"),
    include_str!("../migrations/0017_episode_cutover.sql"),
    include_str!("../migrations/0018_poll_cost_reset.sql"),
    include_str!("../migrations/0019_queued_enrollment.sql"),
    include_str!("../migrations/0020_recovery_retirement.sql"),
    include_str!("../migrations/0021_retire_migration_controls.sql"),
    include_str!("../migrations/0022_preserve_delivery_history.sql"),
    include_str!("../migrations/0023_drop_retired_notification_storage.sql"),
    include_str!("../migrations/0024_drop_recovery_pending.sql"),
    include_str!("../migrations/0025_current_schema_expansion.sql"),
    include_str!("../migrations/0026_current_schema_contraction.sql"),
    include_str!("../migrations/0027_registration_confirmation.sql"),
    include_str!("../migrations/0028_poll_permit_alerting.sql"),
    include_str!("../migrations/0029_retention_indexes.sql"),
    include_str!("../migrations/0030_validator_binding.sql"),
];

/// An in-memory database at the current schema. Foreign keys go on first:
/// rusqlite leaves them off, which would hide the FK checks a DELETE plans.
pub(crate) fn connection() -> Connection {
    let db = Connection::open_in_memory().expect("open in-memory database");
    db.execute_batch("PRAGMA foreign_keys=ON")
        .expect("enable foreign keys");
    for (index, migration) in MIGRATIONS.iter().enumerate() {
        db.execute_batch(migration)
            .unwrap_or_else(|error| panic!("apply migration {}: {error}", index + 1));
    }
    db
}

/// The detail column of `EXPLAIN QUERY PLAN <sql>`, one entry per plan line.
pub(crate) fn plan(db: &Connection, sql: &str, params: &[&dyn ToSql]) -> Vec<String> {
    let mut statement = db
        .prepare(&format!("EXPLAIN QUERY PLAN {sql}"))
        .expect("prepare query plan");
    statement
        .query_map(params, |row| row.get::<_, String>(3))
        .expect("query plan")
        .collect::<rusqlite::Result<_>>()
        .expect("read query plan")
}
