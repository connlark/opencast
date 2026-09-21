//! Claim-before-delete protects every live manifest, including unfinished drains.
use crate::delivery::{db::*, wire::string};
use serde_json::json;
use worker::{Bucket, D1Database, Result};

pub(crate) fn live(alias: &str) -> String {
    // A reused page is protected by *any* live manifest, not only its original
    // upload lease. Abandoned recovery evidence has its own seven-day grace.
    let root = |key: &str| {
        format!("EXISTS(SELECT 1 FROM n_feed WHERE snapshot_key={key}) OR EXISTS(SELECT 1 FROM n_observation WHERE snapshot_key={key} AND state='published' AND drain_complete=0)")
    };
    format!("EXISTS(SELECT 1 FROM n_observation o WHERE o.lease_id={alias}.lease_id AND o.state IN('staging','abandoned') AND o.recovery_evidence=1 AND o.valid_eof=1 AND o.scan_started_at>?1-604800) OR ({}) OR EXISTS(SELECT 1 FROM n_snapshot_ref r WHERE r.page_key={alias}.object_key AND ({})) OR EXISTS(SELECT 1 FROM n_feed f WHERE f.feed_id={alias}.feed_id AND f.lease_id={alias}.lease_id AND f.lease_until>?1)",root(&format!("{alias}.object_key")),root("r.manifest_key"))
}
pub async fn collect(db: &D1Database, bucket: &Bucket) -> Result<()> {
    collect_bounded(db, bucket, 50).await.map(|_| ())
}
/// Queue cleanup can chain bounded batches, independent of the cron's lifetime.
pub async fn collect_bounded(db: &D1Database, bucket: &Bucket, limit: usize) -> Result<usize> {
    if !control(db, "cleanup").await? {
        return Ok(0);
    }
    let t = now();
    // History expiry never races a new interest: the eligibility projection and
    // no-interest timestamp are checked again in the pointer transaction.
    let expired="SELECT feed_id FROM n_feed f WHERE no_interest_since<=?1-2592000 AND NOT EXISTS(SELECT 1 FROM n_interest j WHERE j.feed_id=f.feed_id AND j.enabled=1) AND (f.lease_id IS NULL OR f.lease_until<=?1) ORDER BY no_interest_since,feed_id LIMIT 20";
    db.batch(vec![
        statement(db,&format!("UPDATE n_observation SET drain_complete=1,recovery_evidence=0 WHERE feed_id IN({expired})"),&[json!(t)])?,
        statement(db,&format!("DELETE FROM n_episode_release WHERE feed_id IN({expired})"),&[json!(t)])?,
        statement(db,&format!("UPDATE n_feed SET snapshot_key=NULL,observation_generation=0,semantic_digest=NULL,etag=NULL,last_modified=NULL,publish_token=NULL,lease_id=NULL,lease_until=NULL,baseline_at=NULL,credible_release_at=NULL,credible_cadence=NULL,retry_at=0,poll_failures=0 WHERE feed_id IN({expired})"),&[json!(t)])?,
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
    let candidates=rows(db,&format!("SELECT object_key FROM n_snapshot s WHERE s.state IN('reserved','uploaded','referenced','gc_claimed') AND s.gc_after<=?1 AND NOT({live}) ORDER BY s.gc_after,s.object_key LIMIT {}",limit.min(200)),&[json!(t)]).await?;
    let selected = candidates.len();
    for row in candidates {
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
    run(db,"DELETE FROM n_observation WHERE observation_id IN(SELECT o.observation_id FROM n_observation o WHERE o.scan_started_at<=?1-604800 AND (o.state<>'published' OR o.drain_complete=1) AND NOT EXISTS(SELECT 1 FROM n_feed f WHERE f.snapshot_key=o.snapshot_key OR (f.lease_id=o.lease_id AND f.lease_until>?1)) AND NOT EXISTS(SELECT 1 FROM n_episode_release r WHERE r.observation_id=o.observation_id) AND NOT EXISTS(SELECT 1 FROM n_outbox x WHERE x.observation_id=o.observation_id) LIMIT 1000)",&[json!(t)]).await?;
    run(db,"DELETE FROM n_snapshot_ref WHERE manifest_key IN(SELECT object_key FROM n_snapshot s WHERE state='deleted' AND NOT EXISTS(SELECT 1 FROM n_observation o WHERE o.snapshot_key=s.object_key) LIMIT 1000)",&[]).await?;
    run(db,"DELETE FROM n_snapshot WHERE object_key IN(SELECT object_key FROM n_snapshot s WHERE state='deleted' AND NOT EXISTS(SELECT 1 FROM n_snapshot_ref r WHERE r.manifest_key=s.object_key OR r.page_key=s.object_key) AND NOT EXISTS(SELECT 1 FROM n_observation o WHERE o.snapshot_key=s.object_key) LIMIT 2000)",&[]).await?;
    Ok(selected)
}
