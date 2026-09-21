use super::{
    db::*,
    wire::{int, string, TOMBSTONE_SECONDS},
};
use serde::Serialize;
use serde_json::json;
use worker::{D1Database, Env, Result};

pub async fn enqueue(
    env: &Env,
    binding: &str,
    source: &str,
    id: &str,
    generation: i64,
) -> Result<()> {
    // A struct serializes as a JS object. serde_json::Value maps become JS Map
    // through serde-wasm-bindgen, which Queue JSON encoding would erase to {}.
    #[derive(Serialize)]
    struct Wakeup<'a> {
        schema_version: u8,
        environment: String,
        source: &'a str,
        id: &'a str,
        generation: i64,
    }
    env.queue(binding)?
        .send(Wakeup {
            schema_version: 1,
            environment: lane(env),
            source,
            id,
            generation,
        })
        .await
}
pub async fn failed(
    db: &D1Database,
    kind: &str,
    source: &str,
    id: &str,
    lease: &str,
) -> Result<()> {
    if kind == "event" {
        run(db,"UPDATE n_event SET failures=failures+1,next_attempt_at=?3+300,lease_id=NULL,lease_until=NULL WHERE source=?1 AND event_id=?2 AND fanout_complete=0 AND lease_id=?4",&[json!(source),json!(id),json!(now()),json!(lease)]).await?;
    } else {
        run(db,"UPDATE n_delivery SET failures=failures+1,state=CASE WHEN failures>=9 THEN 'poisoned' WHEN state='leased' THEN 'uncertain' ELSE state END,next_attempt_at=?2+300,lease_id=NULL,lease_until=NULL WHERE delivery_id=?1 AND state IN('pending','leased','uncertain') AND lease_id=?3",&[json!(id),json!(now()),json!(lease)]).await?;
    }
    worker::console_warn!("notification handling failure kind={}", kind);
    Ok(())
}
pub async fn reconcile(env: &Env) -> Result<()> {
    let db = env.d1("APP_ATTEST_DB")?;
    let t = now();
    run(&db,"UPDATE n_delivery SET state='uncertain',last_reason='lease_expired',lease_id=NULL,lease_until=NULL,next_attempt_at=?1 WHERE delivery_id IN(SELECT delivery_id FROM n_delivery WHERE state='leased' AND lease_until<=?1 ORDER BY lease_until LIMIT 100)",&[json!(t)]).await?;
    run(&db,"UPDATE n_delivery SET state='expired',terminal_at=?1,last_reason='expired',lease_id=NULL,lease_until=NULL WHERE delivery_id IN(SELECT delivery_id FROM n_delivery WHERE state IN('pending','uncertain','leased','poisoned') AND expires_at<=?1 ORDER BY expires_at LIMIT 100)",&[json!(t)]).await?;
    run(&db,"UPDATE n_event SET fanout_complete=1,terminal_at=?1,envelope_json='{}',lease_id=NULL,lease_until=NULL WHERE rowid IN(SELECT rowid FROM n_event WHERE fanout_complete=0 AND expires_at<=?1 ORDER BY expires_at LIMIT 100)",&[json!(t)]).await?;
    for row in rows(&db,"SELECT source,event_id FROM n_event WHERE fanout_complete=0 AND failures<10 AND next_attempt_at<=?1 AND expires_at>?1 AND (lease_id IS NULL OR lease_until<=?1) ORDER BY next_attempt_at LIMIT 100",&[json!(t)]).await? {
        if enqueue(env,"EVENT_QUEUE",string(&row,"source"),string(&row,"event_id"),1).await.is_err(){worker::console_warn!("notification event enqueue failed");}
    }
    // Independent bounded scans reserve capacity for each lane during catch-up.
    for (sources, binding, switch) in [
        ("'feed_polling'", "EPISODE_DELIVERY_QUEUE", "episode_send"),
        (
            "'ad_analysis','remote_transcription'",
            "JOB_DELIVERY_QUEUE",
            "job_send",
        ),
    ] {
        if !permitted(env, &db, switch).await? {
            continue;
        }
        let paused_clause = if binding == "EPISODE_DELIVERY_QUEUE" {
            " AND NOT EXISTS(SELECT 1 FROM n_feed f WHERE f.feed_id=n_delivery.interest_key AND f.send_paused=1)"
        } else {
            ""
        };
        let work=rows(&db,&format!("SELECT delivery_id,source,interest_generation FROM n_delivery WHERE source IN({sources}) AND state IN('pending','uncertain') AND failures<10 AND next_attempt_at<=?1 AND expires_at>?1{paused_clause} ORDER BY next_attempt_at LIMIT 100"),&[json!(t)]).await?;
        for row in work {
            if enqueue(
                env,
                binding,
                string(&row, "source"),
                string(&row, "delivery_id"),
                int(&row, "interest_generation"),
            )
            .await
            .is_err()
            {
                worker::console_warn!("notification delivery enqueue failed");
            }
        }
    }
    // Terminal receipts keep only immutable digests/IDs. Source replay cannot
    // extend expiry; the ingress rejects old timestamps even after receipt GC.
    run(&db,"UPDATE n_event SET terminal_at=?1,envelope_json='{}' WHERE rowid IN(SELECT e.rowid FROM n_event e WHERE e.fanout_complete=1 AND e.terminal_at IS NULL AND (e.source<>'legacy' OR e.expires_at<=?1) AND NOT EXISTS(SELECT 1 FROM n_delivery d WHERE d.source=e.source AND d.event_id=e.event_id AND d.state IN('pending','leased','uncertain','poisoned')) LIMIT 100)",&[json!(t)]).await?;
    // The keyed deletion fence has a fixed seven-day privacy lifetime; pruning
    // it is user erasure, independent of the periodic cleanup feature switch.
    run(&db,"DELETE FROM n_deleted_install WHERE fence IN(SELECT fence FROM n_deleted_install WHERE expires_at<=?1 LIMIT 100)",&[json!(t)]).await?;
    if permitted(env, &db, "cleanup").await? {
        for e in rows(&db,"SELECT source,event_id FROM n_event WHERE terminal_at<?1 ORDER BY terminal_at LIMIT 20",&[json!(t-TOMBSTONE_SECONDS)]).await? {
            let args=[e["source"].clone(),e["event_id"].clone()];
            db.batch(vec![
                statement(&db,"DELETE FROM n_delivery_member WHERE source=?1 AND event_id=?2",&args)?,
                statement(&db,"DELETE FROM n_delivery WHERE source=?1 AND event_id=?2 AND state NOT IN('pending','leased','uncertain','poisoned')",&args)?,
                statement(&db,"DELETE FROM n_group_member WHERE source=?1 AND event_id=?2",&args)?,
                statement(&db,"DELETE FROM n_event WHERE source=?1 AND event_id=?2 AND NOT EXISTS(SELECT 1 FROM n_delivery WHERE source=?1 AND event_id=?2)",&args)?,
            ]).await?;
        }
    }
    if permitted(env, &db, "cleanup").await? {
        run(&db,"DELETE FROM n_legacy_bridge WHERE rowid IN(SELECT rowid FROM n_legacy_bridge WHERE expires_at<=?1 LIMIT 100)",&[json!(t)]).await?;
        run(&db,"DELETE FROM n_requester_ticket WHERE ticket_digest IN(SELECT ticket_digest FROM n_requester_ticket WHERE expires_at<=?1 LIMIT 100)",&[json!(t)]).await?;
        run(&db,"DELETE FROM n_job_interest WHERE rowid IN(SELECT rowid FROM n_job_interest j WHERE register_before<?1 AND NOT EXISTS(SELECT 1 FROM n_event WHERE interest_id=j.interest_id) AND NOT EXISTS(SELECT 1 FROM n_delivery WHERE interest_key=j.interest_id) LIMIT 100)",&[json!(t-TOMBSTONE_SECONDS)]).await?;
        // Later observation passes own history/snapshot GC. Only prune empty
        // identities here, after 30 days with no interested installations.
        let unused="SELECT feed_id FROM n_feed f WHERE no_interest_since<?1 AND NOT EXISTS(SELECT 1 FROM n_interest WHERE feed_id=f.feed_id AND enabled=1) AND NOT EXISTS(SELECT 1 FROM n_event WHERE feed_id=f.feed_id) AND NOT EXISTS(SELECT 1 FROM n_delivery WHERE interest_key=f.feed_id) AND NOT EXISTS(SELECT 1 FROM n_snapshot WHERE feed_id=f.feed_id) AND NOT EXISTS(SELECT 1 FROM n_observation WHERE feed_id=f.feed_id) ORDER BY no_interest_since LIMIT 100";
        db.batch(vec![
            statement(
                &db,
                &format!("DELETE FROM n_interest WHERE feed_id IN({unused})"),
                &[json!(t - TOMBSTONE_SECONDS)],
            )?,
            statement(
                &db,
                &format!("DELETE FROM n_legacy_bridge WHERE feed_id IN({unused})"),
                &[json!(t - TOMBSTONE_SECONDS)],
            )?,
            statement(
                &db,
                &format!("DELETE FROM n_feed WHERE feed_id IN({unused})"),
                &[json!(t - TOMBSTONE_SECONDS)],
            )?,
        ])
        .await?;
    }
    let work=rows(&db,"SELECT state,COUNT(*) AS count,MIN(next_attempt_at) AS oldest_due FROM n_delivery WHERE state IN('pending','uncertain','leased','poisoned') GROUP BY state",&[]).await?;
    let events=first(&db,"SELECT COUNT(*) AS count,MIN(next_attempt_at) AS oldest_due,SUM(CASE WHEN failures>=10 THEN 1 ELSE 0 END) AS poisoned FROM n_event WHERE fanout_complete=0",&[]).await?;
    let circuit = first(
        &db,
        "SELECT paused,reason,updated_at FROM n_circuit WHERE lane='apns'",
        &[],
    )
    .await?;
    worker::console_log!(
        "{}",
        json!({"event":"notification_reconciliation","delivery":work,"fanout":events,"circuit":circuit})
    );
    Ok(())
}

/// Re-enqueue due episode deliveries after an operator resumes a feed. The
/// durable rows remain the source of truth; this only restores queue wakeups
/// that were intentionally suppressed while `send_paused=1`.
pub async fn requeue_feed(env: &Env, db: &D1Database, feed_id: &str) -> Result<()> {
    let t = now();
    for row in rows(db, "SELECT delivery_id,source,interest_generation FROM n_delivery WHERE interest_key=?1 AND source='feed_polling' AND state IN('pending','uncertain') AND failures<10 AND next_attempt_at<=?2 AND expires_at>?2 AND NOT EXISTS(SELECT 1 FROM n_feed f WHERE f.feed_id=n_delivery.interest_key AND f.send_paused=1) ORDER BY next_attempt_at LIMIT 100", &[json!(feed_id), json!(t)]).await? {
        if enqueue(env, "EPISODE_DELIVERY_QUEUE", string(&row, "source"), string(&row, "delivery_id"), int(&row, "interest_generation")).await.is_err() {
            worker::console_warn!("notification delivery requeue failed");
        }
    }
    Ok(())
}
