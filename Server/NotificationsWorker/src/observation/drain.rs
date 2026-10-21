//! A bounded durable cursor separates source publication from event ingress.
use super::{
    scan::Candidate,
    snapshot::{checksum, Manifest},
    store::fault,
};
use crate::database::slice_d::{self as storage, Operation};
use crate::delivery::{
    db::*,
    wire::{self, int, string},
};
use serde_json::{json, Value};
use worker::{Bucket, Env, Method, Request, RequestInit, Result};

pub async fn page(
    db: &crate::database::Authority,
    bucket: &Bucket,
    feed_id: &str,
    lane: &str,
) -> Result<()> {
    let t = now();
    let Some(observation) = storage::execute(
        db,
        Operation::ReadDrain {
            feed: feed_id.to_owned(),
        },
    )
    .await?
    .first() else {
        mature(db, feed_id, lane).await?;
        return Ok(());
    };
    let key = string(&observation, "snapshot_key");
    // A page OFFSET inside this observation's manifest, never a page identity.
    db.note(|witness, _| {
        witness.checkpoint_start("drain", None, Some(int(&observation, "candidate_cursor")))
    });
    let r2 = db.timer().span(crate::storage_witness::Category::R2);
    let bytes = bucket
        .get(key)
        .execute()
        .await?
        .ok_or_else(|| fault("snapshot_missing"))?
        .body()
        .ok_or_else(|| fault("snapshot_missing"))?
        .bytes()
        .await?;
    r2.end();
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
    let r2 = db.timer().span(crate::storage_witness::Category::R2);
    let bytes = bucket
        .get(&page.key)
        .execute()
        .await?
        .ok_or_else(|| fault("candidate_missing"))?
        .body()
        .ok_or_else(|| fault("candidate_missing"))?
        .bytes()
        .await?;
    r2.end();
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
        records.push(serde_json::from_value(json!({"episode_id":candidate.episode_id,"event_id":event_id,"presentation_key":presentation_key,"first_observed_at":candidate.first_observed_at,"eligible_at":candidate.eligible_at,"expires_at":candidate.eligible_at+86400,"reason":candidate.reason,"fingerprint":candidate.fingerprint,"published_at":candidate.published_at,"metadata":display,"state":state}))?);
    }
    // The target is recorded before the write is awaited, so a delivery
    // dropped mid-write keeps it as attempted, its outcome unknown.
    db.note(|witness, _| witness.checkpoint_attempt("drain", None, Some(offset as i64)));
    let drained = storage::execute(
        db,
        Operation::Drain {
            feed: feed_id.into(),
            observation: observation_id.into(),
            generation,
            epoch,
            cursor: cursor as i64,
            next: offset as i64,
            records,
        },
    )
    .await;
    db.note(|witness, _| witness.checkpoint_end());
    drained?;
    mature(db, feed_id, lane).await?;
    Ok(())
}

async fn mature(db: &crate::database::Authority, feed_id: &str, lane: &str) -> Result<()> {
    let t = now();
    let rows = storage::execute(
        db,
        Operation::ReadMatureReleases {
            feed: feed_id.to_owned(),
            now: (t),
        },
    )
    .await?
    .rows();
    for row in rows {
        let event_id = string(&row, "event_id");
        let epoch = int(&row, "owner_epoch");
        if int(&row, "expires_at") <= t {
            storage::execute(
                db,
                Operation::ExpireRelease {
                    event: event_id.to_owned(),
                    epoch: (epoch),
                },
            )
            .await?
            .count();
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
        storage::execute(
            db,
            Operation::OutboxRelease {
                event: event_id.into(),
                epoch,
                observation: serde_json::from_value(row["observation_id"].clone())?,
                digest: wire::digest(&event),
                occurred_at: serde_json::from_value(row["first_observed_at"].clone())?,
                expires_at: serde_json::from_value(row["expires_at"].clone())?,
                now: t,
                payload: event,
            },
        )
        .await?;
    }
    Ok(())
}

pub async fn outbox(db: &crate::database::Authority, env: &Env, feed_id: &str) -> Result<()> {
    mature(db, feed_id, &lane(env)).await?;
    let due = storage::execute(
        db,
        Operation::ReadDueOutbox {
            feed: feed_id.to_owned(),
            now: (now()),
        },
    )
    .await?
    .rows();
    for row in due {
        let event_id = string(&row, "event_id");
        if int(&row, "expires_at") <= now() {
            storage::execute(
                db,
                Operation::ExpireOutbox {
                    event: event_id.to_owned(),
                },
            )
            .await?
            .count();
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
        // The POST and its reply body, never the storage work that follows.
        db.note(|witness, _| witness.context.posts.get_or_insert_with(Default::default).n += 1);
        let posted = db.timer().span(crate::storage_witness::Category::Service);
        let result = service.fetch_request(request).await;
        match result {
            Ok(mut response) if response.status_code() == 200 || response.status_code() == 202 => {
                let receipt: Value = response.json().await?;
                posted.end();
                if string(&receipt, "event_id") != event_id
                    || !wire::uuid(string(&receipt, "receipt_id"))
                    || !["accepted", "duplicate", "suppressed"]
                        .contains(&string(&receipt, "disposition"))
                {
                    db.note(|witness, _| {
                        witness
                            .context
                            .posts
                            .get_or_insert_with(Default::default)
                            .retried += 1
                    });
                    storage::execute(
                        db,
                        Operation::RetryOutbox {
                            event: event_id.to_owned(),
                            next: (now() + 60),
                        },
                    )
                    .await?
                    .count();
                    continue;
                }

                db.note(|witness, _| {
                    witness
                        .context
                        .posts
                        .get_or_insert_with(Default::default)
                        .accepted += 1
                });
                storage::execute(
                    db,
                    Operation::AcceptOutbox {
                        event: event_id.to_owned(),
                        receipt: serde_json::from_value(receipt["receipt_id"].clone())?,
                    },
                )
                .await?
                .count();
            }
            Ok(response) if response.status_code() == 409 => {
                posted.end();
                storage::execute(
                    db,
                    Operation::ConflictOutbox {
                        event: event_id.to_owned(),
                    },
                )
                .await?
                .count();
            }
            _ => {
                posted.end();
                db.note(|witness, _| {
                    witness
                        .context
                        .posts
                        .get_or_insert_with(Default::default)
                        .retried += 1
                });
                storage::execute(
                    db,
                    Operation::RetryOutbox {
                        event: event_id.to_owned(),
                        next: (now() + 60),
                    },
                )
                .await?
                .count();
            }
        }
    }
    Ok(())
}
