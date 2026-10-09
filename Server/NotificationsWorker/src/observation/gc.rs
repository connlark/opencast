//! Claim-before-delete protects every live manifest, including unfinished drains.
use super::retention_sql;
use crate::delivery::{db::*, wire::string};
use serde_json::json;
use worker::{Bucket, D1Database, Result};

/// A cooperative wall budget: finish the current object's fenced delete, then
/// start no new object. The caller retains its cursor when this expires.
pub struct Budget {
    until_ms: u64,
}
impl Budget {
    pub fn new(seconds: u64) -> Self {
        Self {
            until_ms: worker::Date::now().as_millis() + seconds * 1000,
        }
    }
    pub fn expired(&self) -> bool {
        worker::Date::now().as_millis() >= self.until_ms
    }
}

pub(crate) fn live(alias: &str) -> String {
    // A reused page is protected by *any* live manifest, not only its original
    // upload lease. Abandoned recovery evidence has its own seven-day grace.
    let root = |key: &str| {
        format!("EXISTS(SELECT 1 FROM n_feed WHERE snapshot_key={key}) OR EXISTS(SELECT 1 FROM n_observation WHERE snapshot_key={key} AND state='published' AND drain_complete=0)")
    };
    // Lease IDs are NOT NULL in both tables. Materialize the recovery set once
    // per statement instead of scanning observation history for every object.
    format!("{alias}.lease_id IN(SELECT o.lease_id FROM n_observation o WHERE o.state IN('staging','abandoned') AND o.recovery_evidence=1 AND o.valid_eof=1 AND o.scan_started_at>?1-604800) OR ({}) OR EXISTS(SELECT 1 FROM n_snapshot_ref r WHERE r.page_key={alias}.object_key AND ({})) OR EXISTS(SELECT 1 FROM n_feed f WHERE f.feed_id={alias}.feed_id AND f.lease_id={alias}.lease_id AND f.lease_until>?1)",root(&format!("{alias}.object_key")),root("r.manifest_key"))
}
pub async fn collect(db: &D1Database, bucket: &Bucket) -> Result<()> {
    collect_bounded(db, bucket, 50, None).await.map(|_| ())
}
/// Scheduled cleanup bounds object count and wall time without changing fences.
pub async fn collect_bounded(
    db: &D1Database,
    bucket: &Bucket,
    limit: usize,
    budget: Option<&Budget>,
) -> Result<usize> {
    // Retention must make progress even when scratch exhausted the object
    // budget. The existing bounded D1 batches and deletion predicates remain.
    if !control(db, "cleanup").await? {
        return Ok(0);
    }
    let t = now();
    // History expiry never races a new interest: the eligibility projection and
    // no-interest timestamp are checked again in the pointer transaction.
    let expired = retention_sql::NO_INTEREST_EXPIRED;
    db.batch(vec![
        statement(db,&format!("UPDATE n_observation SET drain_complete=1,recovery_evidence=0 WHERE feed_id IN({expired})"),&[json!(t)])?,
        statement(db,&format!("DELETE FROM n_episode_release WHERE feed_id IN({expired})"),&[json!(t)])?,
        statement(db,&format!("UPDATE n_feed SET snapshot_key=NULL,observation_generation=0,semantic_digest=NULL,etag=NULL,last_modified=NULL,validator_url=NULL,validator_at=NULL,publish_token=NULL,lease_id=NULL,lease_until=NULL,baseline_at=NULL,credible_release_at=NULL,credible_cadence=NULL,retry_at=0,poll_failures=0 WHERE feed_id IN({expired})"),&[json!(t)])?,
    ]).await?;
    // Source payloads stop at expiry; compact outcomes last seven more days.
    run(db,"UPDATE n_outbox SET state='expired',payload_json='{}' WHERE rowid IN(SELECT rowid FROM n_outbox WHERE source='feed_polling' AND expires_at<=?1 AND state='pending' LIMIT 1000)",&[json!(t)]).await?;
    run(db,"UPDATE n_outbox SET payload_json='{}' WHERE rowid IN(SELECT rowid FROM n_outbox WHERE source='feed_polling' AND expires_at<=?1 AND state<>'pending' AND payload_json<>'{}' LIMIT 1000)",&[json!(t)]).await?;
    run(db,"DELETE FROM n_outbox WHERE rowid IN(SELECT rowid FROM n_outbox WHERE source='feed_polling' AND expires_at<=?1-604800 AND state<>'pending' LIMIT 1000)",&[json!(t)]).await?;
    run(
        db,
        "DELETE FROM n_episode_release WHERE rowid IN(SELECT rowid FROM n_episode_release WHERE expires_at<=?1-604800 LIMIT 1000)",
        &[json!(t)],
    )
    .await?;
    run(db,"DELETE FROM n_burst WHERE rowid IN(SELECT rowid FROM n_burst WHERE NOT EXISTS(SELECT 1 FROM n_episode_release r WHERE r.presentation_key=n_burst.presentation_key) LIMIT 1000)",&[]).await?;
    let live = live("s");
    let candidates = if budget.is_some_and(Budget::expired) {
        vec![]
    } else {
        rows(db,&format!("SELECT object_key FROM n_snapshot s WHERE s.state IN('reserved','uploaded','referenced','gc_claimed') AND s.gc_after<=?1 AND NOT({live}) ORDER BY s.gc_after,s.object_key LIMIT {}",limit.min(200)),&[json!(t)]).await?
    };
    let selected = candidates.len();
    for row in candidates {
        if budget.is_some_and(Budget::expired) {
            break;
        }
        let key = string(&row, "object_key");
        if run(db,&format!("UPDATE n_snapshot AS s SET state='gc_claimed' WHERE object_key=?2 AND state IN('reserved','uploaded','referenced','gc_claimed') AND gc_after<=?1 AND NOT({live})"),&[json!(now()),json!(key)]).await?==0 {continue;}
        if first(db,&format!("SELECT object_key FROM n_snapshot s WHERE object_key=?2 AND state='gc_claimed' AND NOT({live})"),&[json!(now()),json!(key)]).await?.is_none(){continue;}
        // A failed delete keeps gc_claimed and is retried by the next sweep.
        if bucket.delete(key).await.is_ok() {
            run(
                db,
                "UPDATE n_snapshot SET state='deleted' WHERE object_key=?1 AND state='gc_claimed'",
                &[json!(key)],
            )
            .await?;
        }
    }
    run(db, retention_sql::RETIRE_OBSERVATIONS, &[json!(t)]).await?;
    run(db, retention_sql::RETIRE_SNAPSHOT_REFS, &[]).await?;
    run(db, retention_sql::RETIRE_SNAPSHOTS, &[]).await?;
    Ok(selected)
}
