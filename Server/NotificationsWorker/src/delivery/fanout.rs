use super::{
    db::*,
    recovery,
    wire::{self, int, string, Event},
};
use serde_json::json;
use worker::{D1Database, Env, Result};

pub async fn page(db: &D1Database, env: &Env, source: &str, event_id: &str) -> Result<()> {
    if source == "feed_polling" && super::grouping::page(db, env, event_id).await? {
        return Ok(());
    }
    let t = now();
    let lease = id();
    let result = async {
    if run(db,"UPDATE n_event SET lease_id=?3,lease_until=?4+60 WHERE source=?1 AND event_id=?2 AND fanout_complete=0 AND failures<10 AND expires_at>?4 AND next_attempt_at<=?4 AND (lease_id IS NULL OR lease_until<=?4)",&[json!(source),json!(event_id),json!(lease),json!(t)]).await?==0{return Ok(());}
    let Some(row) = first(
        db,
        "SELECT * FROM n_event WHERE source=?1 AND event_id=?2 AND lease_id=?3",
        &[json!(source), json!(event_id), json!(lease)],
    )
    .await?
    else {
        return Ok(());
    };
    let event: Event = serde_json::from_str(string(&row, "envelope_json"))?;
    let cursor = string(&row, "fanout_cursor");
    let episode = event.kind == "episode";
    let key = if episode {
        string(&event.routing, "feed_id")
    } else {
        string(&event.routing, "interest_id")
    };
    let recipients = if episode {
        rows(db,"SELECT j.install_id,j.generation,i.epoch FROM n_interest j JOIN n_install i ON i.install_id=j.install_id WHERE j.feed_id=?1 AND j.enabled=1 AND i.enabled=1 AND j.install_id>?3 AND CASE WHEN ?4 IN('undated','anomalous_date') THEN j.activated_at<=?2 AND j.absence_generation<?5 AND j.absence_at>=j.activated_at AND j.absence_at<=?2 WHEN ?4 IN('recent','future') THEN j.activated_at<=?6 AND j.activated_at<=?7 ELSE j.activated_at<=?2 END ORDER BY j.install_id,j.generation LIMIT 100",&[json!(key),json!(event.occurred_at),json!(cursor),event.data["decision_reason"].clone(),event.routing["observation_generation"].clone(),json!(event.eligible_at),event.data["published_at"].clone()]).await?
    } else {
        rows(db,"SELECT j.install_id,j.generation,i.epoch FROM n_job_interest j JOIN n_install i ON i.install_id=j.install_id AND i.epoch=j.install_epoch WHERE j.interest_id=?1 AND j.state='registered' AND i.enabled=1 AND i.job_capable=1 AND j.install_id>?2 AND j.run_id=?3 AND j.generation=?4",&[json!(key),json!(cursor),event.routing["run_id"].clone(),event.routing["interest_generation"].clone()]).await?
    };
    let t = now();
    let mut writes = vec![];
    let mut delivery_ids = vec![];
    for recipient in &recipients {
        let install = string(recipient, "install_id");
        let generation = int(recipient, "generation");
        let epoch = int(recipient, "epoch");
        let delivery = wire::hash(&[
            "delivery-v1",
            &lane(env),
            event_id,
            install,
            &epoch.to_string(),
            key,
            &generation.to_string(),
        ]);
        let args = vec![
            json!(delivery),
            json!(event_id),
            json!(install),
            json!(epoch),
            json!(key),
            json!(generation),
            json!(event.expires_at),
            json!(t),
            json!(id()),
            json!(source),
            json!(lease),
            json!(event.routing["owner_epoch"]),
            json!(cursor),
            event.routing["episode_id"].clone(),
            event.data["fingerprint"].clone(),
            event.routing["run_id"].clone(),
        ];
        // Each insert carries the same live page fence. A zero-row claim cannot
        // be followed by an unconditional insert, even inside a successful batch.
        let eligibility = if episode {
            "EXISTS(SELECT 1 FROM n_interest j JOIN n_feed f ON f.feed_id=j.feed_id WHERE j.install_id=?3 AND j.feed_id=?5 AND j.generation=?6 AND j.enabled=1 AND f.epoch=?12) AND NOT EXISTS(SELECT 1 FROM n_legacy_bridge b WHERE b.install_id=?3 AND b.feed_id=?5 AND b.expires_at>?8 AND b.identity_key IN('episode:'||?14,'fingerprint:v2:'||?15))"
        } else {
            "EXISTS(SELECT 1 FROM n_job_interest j WHERE j.install_id=?3 AND j.interest_id=?5 AND j.generation=?6 AND j.state='registered' AND j.run_id=?16)"
        };
        writes.push(statement(db,&format!("INSERT INTO n_delivery(delivery_id,presentation_id,install_id,install_epoch,interest_key,interest_generation,state,expires_at,next_attempt_at,apns_id,collapse_id,source,event_id,owner_epoch) SELECT ?1,?2,?3,?4,?5,?6,'pending',?7,?8,?9,?1,?10,?2,?12 WHERE EXISTS(SELECT 1 FROM n_event WHERE source=?10 AND event_id=?2 AND lease_id=?11 AND lease_until>?8 AND COALESCE(fanout_cursor,'')=?13 AND fanout_complete=0) AND EXISTS(SELECT 1 FROM n_install WHERE install_id=?3 AND epoch=?4 AND enabled=1) AND {eligibility} ON CONFLICT DO NOTHING"),&args[..if episode {15} else {16}])?);
        writes.push(statement(db,"INSERT INTO n_delivery_member(delivery_id,source,event_id,install_id,install_epoch,interest_generation) SELECT delivery_id,source,event_id,install_id,install_epoch,interest_generation FROM n_delivery WHERE delivery_id=?1 AND EXISTS(SELECT 1 FROM n_event WHERE source=?2 AND event_id=?3 AND lease_id=?4) ON CONFLICT DO NOTHING",&[json!(delivery),json!(source),json!(event_id),json!(lease)])?);
        delivery_ids.push((delivery, generation));
    }
    let last = recipients
        .last()
        .map(|r| string(r, "install_id"))
        .unwrap_or(cursor);
    writes.push(statement(db,"UPDATE n_event SET fanout_cursor=?4,fanout_complete=?5,lease_id=NULL,lease_until=NULL,next_attempt_at=?6,failures=0 WHERE source=?1 AND event_id=?2 AND lease_id=?3 AND lease_until>?6 AND COALESCE(fanout_cursor,'')=?7",&[json!(source),json!(event_id),json!(lease),json!(last),json!(recipients.len()<100),json!(t),json!(cursor)])?);
    db.batch(writes).await?;
    let queue = if episode {
        "EPISODE_DELIVERY_QUEUE"
    } else {
        "JOB_DELIVERY_QUEUE"
    };
    for (id, generation) in delivery_ids {
        let _ = recovery::enqueue(env, queue, source, &id, generation).await;
    }
    if recipients.len() == 100 {
        let _ = recovery::enqueue(env, "EVENT_QUEUE", source, event_id, 1).await;
    }
    Ok(())
    }.await;
    if result.is_err() {
        recovery::failed(db, "event", source, event_id, &lease).await?;
    }
    result
}
