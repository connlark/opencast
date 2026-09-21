//! A bounded durable cursor separates source publication from event ingress.
use super::{
    scan::Candidate,
    snapshot::{checksum, Manifest},
    store::fault,
};
use crate::delivery::{
    db::*,
    wire::{self, int, string},
};
use serde_json::{json, Value};
use worker::{Bucket, D1Database, Env, Method, Request, RequestInit, Result};

pub async fn page(db: &D1Database, bucket: &Bucket, feed_id: &str, lane: &str) -> Result<()> {
    let t = now();
    let Some(observation)=first(db,"SELECT o.*,s.sha256,s.bytes FROM n_observation o JOIN n_snapshot s ON s.object_key=o.snapshot_key JOIN n_feed f ON f.feed_id=o.feed_id WHERE o.feed_id=?1 AND o.state='published' AND o.drain_complete=0 AND f.epoch=o.owner_epoch AND f.no_interest_since IS NULL ORDER BY o.generation LIMIT 1",&[json!(feed_id)]).await? else {
        mature(db,feed_id,lane).await?;
        return Ok(());
    };
    let key = string(&observation, "snapshot_key");
    let bytes = bucket
        .get(key)
        .execute()
        .await?
        .ok_or_else(|| fault("snapshot_missing"))?
        .body()
        .ok_or_else(|| fault("snapshot_missing"))?
        .bytes()
        .await?;
    if checksum(&bytes) != string(&observation, "sha256") {
        return Err(fault("snapshot_integrity"));
    }
    let manifest: Manifest = serde_json::from_slice(&bytes)?;
    let cursor = int(&observation, "candidate_cursor") as usize;
    let mut offset = 0;
    let page = manifest
        .candidate_pages
        .iter()
        .find(|p| {
            let start = offset;
            offset += p.count;
            start == cursor
        })
        .ok_or_else(|| fault("candidate_cursor"))?;
    let bytes = bucket
        .get(&page.key)
        .execute()
        .await?
        .ok_or_else(|| fault("candidate_missing"))?
        .body()
        .ok_or_else(|| fault("candidate_missing"))?
        .bytes()
        .await?;
    if checksum(&bytes) != page.sha256 || bytes.len() != page.bytes {
        return Err(fault("candidate_integrity"));
    }
    let candidates: Vec<Candidate> = serde_json::from_slice(&bytes)?;
    if candidates.len() != page.count {
        return Err(fault("candidate_count"));
    }
    let observation_id = string(&observation, "observation_id");
    let epoch = int(&observation, "owner_epoch");
    let generation = int(&observation, "generation");
    let metadata: Value = serde_json::from_str(string(&observation, "metadata_json"))?;
    let fence=format!("EXISTS(SELECT 1 FROM n_observation o JOIN n_feed f ON f.feed_id=o.feed_id WHERE o.observation_id='{}' AND o.state='published' AND o.candidate_cursor={} AND f.epoch=o.owner_epoch AND f.no_interest_since IS NULL)",observation_id,cursor);
    let mut records = vec![];
    for candidate in candidates {
        let event_id = wire::hash(&["episode-v1", lane, feed_id, &candidate.episode_id]);
        let future = candidate.reason == super::policy::Reason::Future;
        let presentation_key = if future {
            wire::hash(&[
                "future-group-v1",
                observation_id,
                &candidate.eligible_at.to_string(),
            ])
        } else {
            observation_id.into()
        };
        let mut display = serde_json::to_value(&candidate)?;
        display["feed"] = metadata.clone();
        let state = if candidate.eligible_at + 86400 <= t {
            "expired"
        } else if future {
            "pending_future"
        } else {
            "ready"
        };
        records.push(json!({"episode_id":candidate.episode_id,"event_id":event_id,"presentation_key":presentation_key,"first_observed_at":candidate.first_observed_at,"eligible_at":candidate.eligible_at,"expires_at":candidate.eligible_at+86400,"reason":candidate.reason,"fingerprint":candidate.fingerprint,"published_at":candidate.published_at,"metadata":display,"state":state}));
    }
    db.batch(vec![
        statement(db,&format!("INSERT INTO n_episode_release(feed_id,episode_id,observation_id,generation,owner_epoch,event_id,presentation_key,first_observed_at,eligible_at,expires_at,reason,fingerprint,published_at,metadata_json,state,disposition) SELECT ?1,json_extract(value,'$.episode_id'),?2,?3,?4,json_extract(value,'$.event_id'),json_extract(value,'$.presentation_key'),json_extract(value,'$.first_observed_at'),json_extract(value,'$.eligible_at'),json_extract(value,'$.expires_at'),json_extract(value,'$.reason'),json_extract(value,'$.fingerprint'),json_extract(value,'$.published_at'),json_extract(value,'$.metadata'),json_extract(value,'$.state'),CASE WHEN json_extract(value,'$.state')='expired' THEN 'expired' ELSE 'eligible_pending' END FROM json_each(?5) WHERE {fence} ON CONFLICT DO NOTHING"),&[json!(feed_id),json!(observation_id),json!(generation),json!(epoch),json!(records)])?,
        statement(db,&format!("UPDATE n_observation SET candidate_cursor=?2,drain_complete=(?2=candidate_count) WHERE observation_id=?1 AND {fence}"),&[json!(observation_id),json!(offset)])?,
    ]).await?;
    mature(db, feed_id, lane).await?;
    Ok(())
}

async fn mature(db: &D1Database, feed_id: &str, lane: &str) -> Result<()> {
    let t = now();
    let rows=rows(db,"SELECT r.* FROM n_episode_release r JOIN n_feed f ON f.feed_id=r.feed_id JOIN n_observation o ON o.observation_id=r.observation_id WHERE r.feed_id=?1 AND r.state IN('ready','pending_future') AND r.eligible_at<=?2 AND o.drain_complete=1 AND f.epoch=r.owner_epoch AND f.no_interest_since IS NULL ORDER BY r.eligible_at,r.episode_id LIMIT 100",&[json!(feed_id),json!(t)]).await?;
    for row in rows {
        let event_id = string(&row, "event_id");
        let epoch = int(&row, "owner_epoch");
        let fence="EXISTS(SELECT 1 FROM n_episode_release r JOIN n_feed f ON f.feed_id=r.feed_id WHERE r.event_id=?1 AND r.state IN('ready','pending_future') AND f.epoch=r.owner_epoch AND f.epoch=?2 AND f.no_interest_since IS NULL)";
        if int(&row, "expires_at") <= t {
            run(db,&format!("UPDATE n_episode_release SET state='expired',disposition='expired' WHERE event_id=?1 AND {fence}"),&[json!(event_id),json!(epoch)]).await?;
            continue;
        }
        let c: Value = serde_json::from_str(string(&row, "metadata_json"))?;
        let mut data = json!({"feed_url":c["feed"]["feed_url"],"podcast_title":c["feed"]["podcast_title"],"episode_title":c["title"],"first_observed_at":row["first_observed_at"],"decision_reason":row["reason"]});
        for (target, value) in [
            ("fingerprint", &c["fingerprint"]),
            ("published_at", &c["published_at"]),
            ("episode_summary", &c["summary"]),
            ("episode_artwork_url", &c["artwork"]),
            ("artwork_url", &c["feed"]["artwork_url"]),
            ("episode_duration_seconds", &c["duration"]),
        ] {
            if !value.is_null() {
                data[target] = value.clone();
            }
        }
        let event = json!({"schema_version":1,"environment":lane,"source":"feed_polling","event_id":event_id,"kind":"episode","occurred_at":row["first_observed_at"],"eligible_at":row["eligible_at"],"expires_at":row["expires_at"],"routing":{"feed_id":feed_id,"observation_id":row["observation_id"],"observation_generation":row["generation"],"owner_epoch":epoch,"episode_id":row["episode_id"]},"data":data});
        db.batch(vec![
            statement(db,&format!("INSERT INTO n_outbox(source,event_id,observation_id,payload_digest,occurred_at,expires_at,next_attempt_at,state,payload_json) SELECT 'feed_polling',?1,?3,?4,?5,?6,?7,'pending',?8 WHERE {fence} ON CONFLICT DO NOTHING"),&[json!(event_id),json!(epoch),row["observation_id"].clone(),json!(wire::digest(&event)),row["first_observed_at"].clone(),row["expires_at"].clone(),json!(t),event])?,
            statement(db,&format!("UPDATE n_episode_release SET state='outboxed' WHERE event_id=?1 AND {fence}"),&[json!(event_id),json!(epoch)])?,
        ]).await?;
    }
    Ok(())
}

pub async fn outbox(db: &D1Database, env: &Env, feed_id: &str) -> Result<()> {
    mature(db, feed_id, &lane(env)).await?;
    let due=rows(db,"SELECT x.* FROM n_outbox x JOIN n_observation o ON o.observation_id=x.observation_id JOIN n_feed f ON f.feed_id=o.feed_id WHERE o.feed_id=?1 AND f.epoch=o.owner_epoch AND x.state='pending' AND x.next_attempt_at<=?2 ORDER BY x.next_attempt_at,x.event_id LIMIT 10",&[json!(feed_id),json!(now())]).await?;
    for row in due {
        let event_id = string(&row, "event_id");
        if int(&row, "expires_at") <= now() {
            run(db,"UPDATE n_outbox SET state='expired',payload_json='{}' WHERE source='feed_polling' AND event_id=?1 AND state='pending'",&[json!(event_id)]).await?;
            continue;
        }
        // No endpoint is derived from feed metadata; only the named private binding.
        let service = env
            .service("NOTIFICATION_EVENTS")
            .map_err(|_| fault("notification_events_binding_missing"))?;
        let mut init = RequestInit::new();
        init.with_method(Method::Post)
            .with_body(Some(worker::wasm_bindgen::JsValue::from_str(string(
                &row,
                "payload_json",
            ))));
        let request = Request::new_with_init("https://notification.invalid/v1/events", &init)?;
        let result = service.fetch_request(request).await;
        match result {
            Ok(mut response) if response.status_code() == 200 || response.status_code() == 202 => {
                let receipt: Value = response.json().await?;
                if string(&receipt, "event_id") != event_id
                    || !wire::uuid(string(&receipt, "receipt_id"))
                    || !["accepted", "duplicate", "suppressed"]
                        .contains(&string(&receipt, "disposition"))
                {
                    run(db,"UPDATE n_outbox SET next_attempt_at=?2 WHERE source='feed_polling' AND event_id=?1 AND state='pending'",&[json!(event_id),json!(now()+60)]).await?;
                    continue;
                }

                run(db,"UPDATE n_outbox SET state='accepted',receipt_id=?2 WHERE source='feed_polling' AND event_id=?1 AND state='pending'",&[json!(event_id),receipt["receipt_id"].clone()]).await?;
            }
            Ok(response) if response.status_code() == 409 => {
                run(db,"UPDATE n_outbox SET state='conflict' WHERE source='feed_polling' AND event_id=?1 AND state='pending'",&[json!(event_id)]).await?;
            }
            _ => {
                run(db,"UPDATE n_outbox SET next_attempt_at=?2 WHERE source='feed_polling' AND event_id=?1 AND state='pending'",&[json!(event_id),json!(now()+60)]).await?;
            }
        }
    }
    Ok(())
}
