use super::{
    db::*,
    fanout, recovery, send,
    wire::{self, int, string, Event},
};
use futures_util::StreamExt;
use serde::Deserialize;
use serde_json::{json, Value};
use worker::{D1Database, Env, Method, Request, Response, Result};

pub fn response(status: u16, value: Value) -> Result<Response> {
    let mut r = Response::from_json(&value)?.with_status(status);
    r.headers_mut().set("Cache-Control", "no-store")?;
    Ok(r)
}
pub fn error(status: u16, code: &str) -> Result<Response> {
    response(status, json!({"schema_version":1,"error":code}))
}

pub async fn handle(mut req: Request, env: Env, capability: &str) -> Result<Response> {
    if req.method() != Method::Post {
        return error(405, "method_not_allowed");
    }
    let limit = if capability == "queue" {
        2048
    } else {
        wire::EVENT_LIMIT
    };
    let mut bytes = vec![];
    let mut stream = req.stream()?;
    while let Some(chunk) = stream.next().await {
        let chunk = chunk?;
        if bytes.len() + chunk.len() > limit {
            return error(413, "payload_too_large");
        }
        bytes.extend(chunk);
    }
    let value = match wire::parse(&bytes) {
        Ok(v) => v,
        Err(e) => return error(400, e),
    };
    let db = env.d1("APP_ATTEST_DB")?;
    if capability == "queue" {
        return queue(&db, &env, value).await;
    }
    match req.path().as_str() {
        "/v1/events" => {
            let event: Event = match serde_json::from_value(value) {
                Ok(v) => v,
                Err(_) => return error(400, "invalid_request"),
            };
            if let Err(e) = event.validate(capability, &lane(&env), now()) {
                return error(
                    if e == "event_expired" {
                        410
                    } else if e.ends_with("mismatch") {
                        403
                    } else {
                        400
                    },
                    e,
                );
            }
            accept(&db, &env, event).await
        }
        "/v1/interests/register" if capability != "feed_polling" => {
            register(&db, &env, capability, value).await
        }
        "/v1/interests/cancel" if capability != "feed_polling" => {
            cancel(&db, &env, capability, value).await
        }
        _ => error(404, "not_found"),
    }
}

async fn accept(db: &D1Database, env: &Env, event: Event) -> Result<Response> {
    let v = event.value();
    let digest = wire::digest(&v);
    let t = now();
    let args = [json!(event.source), json!(event.event_id)];
    if let Some(existing) = first(
        db,
        "SELECT * FROM n_event WHERE source=?1 AND event_id=?2",
        &args,
    )
    .await?
    {
        return receipt(&existing, &digest, true);
    }
    let episode = event.kind == "episode";
    if episode && !permitted(env, db, "episode_activation").await? {
        return error(503, "activation_disabled");
    }
    let routing = &event.routing;
    let mut disposition = "accepted";
    if !episode {
        let interest = first(
            db,
            "SELECT * FROM n_job_interest WHERE interest_id=?1",
            &[routing["interest_id"].clone()],
        )
        .await?;
        match interest {
            None => disposition = "suppressed",
            Some(i) => {
                if string(&i, "producer") != event.source
                    || string(&i, "operation_id") != string(routing, "operation_id")
                    || int(&i, "generation") != int(routing, "interest_generation")
                    || (!(string(&i, "state") == "cancelled"
                        && string(&i, "reason") == "attachment_rejected"
                        && i["run_id"].is_null())
                        && (string(&i, "run_id") != string(routing, "run_id")
                            || string(&i, "job_handle") != string(&event.data, "job_handle")))
                {
                    return error(409, "grant_binding_conflict");
                }
                if string(&i, "state") != "registered" {
                    disposition = "suppressed";
                }
            }
        }
    }
    let args = vec![
        json!(event.source),
        json!(event.event_id),
        json!(event.kind),
        json!(digest),
        json!(event.occurred_at),
        json!(event.eligible_at),
        json!(event.expires_at),
        json!(id()),
        json!(v.to_string()),
        json!(t),
        json!(disposition),
        routing["feed_id"].clone(),
        routing["interest_id"].clone(),
        routing["owner_epoch"].clone(),
        routing["observation_id"].clone(),
        routing["observation_generation"].clone(),
        routing["interest_generation"].clone(),
        routing["run_id"].clone(),
    ];
    let gate = if episode {
        "EXISTS(SELECT 1 FROM n_feed f JOIN n_observation o ON o.feed_id=f.feed_id WHERE f.feed_id=?12 AND f.epoch=?14 AND o.owner_epoch=f.epoch AND o.observation_id=?15 AND o.generation=?16 AND o.state='published') AND EXISTS(SELECT 1 FROM n_control WHERE name='episode_activation' AND enabled=1)"
    } else {
        "1"
    };
    // Eligibility is resolved inside the INSERT, so capability loss, opt-out or
    // deletion between the preceding read and this write produces a durable
    // suppressed receipt rather than a false producer conflict.
    let disposition = if episode {
        "?11"
    } else {
        "CASE WHEN ?11='suppressed' OR NOT EXISTS(SELECT 1 FROM n_job_interest j JOIN n_install i ON i.install_id=j.install_id AND i.epoch=j.install_epoch WHERE j.interest_id=?13 AND j.generation=?17 AND j.run_id=?18 AND j.state='registered' AND i.enabled=1 AND i.job_capable=1) THEN 'suppressed' ELSE 'accepted' END"
    };
    run(db,&format!("WITH admission AS (SELECT {disposition} AS disposition) INSERT INTO n_event(source,event_id,schema_version,kind,payload_digest,occurred_at,eligible_at,expires_at,receipt_id,envelope_json,next_attempt_at,disposition,feed_id,interest_id,owner_epoch,fanout_complete,terminal_at) SELECT ?1,?2,1,?3,?4,?5,?6,?7,?8,CASE WHEN disposition='suppressed' THEN '{{}}' ELSE ?9 END,?10,disposition,?12,?13,?14,CASE WHEN disposition='suppressed' THEN 1 ELSE 0 END,CASE WHEN disposition='suppressed' THEN ?10 ELSE NULL END FROM admission WHERE {gate} ON CONFLICT(source,event_id) DO NOTHING"),&args[..if episode {16} else {18}]).await?;
    let Some(saved) = first(
        db,
        "SELECT * FROM n_event WHERE source=?1 AND event_id=?2",
        &args[..2],
    )
    .await?
    else {
        return error(409, "stale_authority");
    };
    // A failed enqueue must not lose an accepted receipt. Reconciler repairs it.
    if int(&saved, "fanout_complete") == 0 {
        let _ = recovery::enqueue(env, "EVENT_QUEUE", &event.source, &event.event_id, 1).await;
    }
    receipt(&saved, &digest, false)
}
fn receipt(row: &Value, digest: &str, duplicate: bool) -> Result<Response> {
    if string(row, "payload_digest") != digest {
        worker::console_warn!("notification event_conflict");
        return error(409, "event_conflict");
    }
    response(
        200,
        json!({"schema_version":1,"event_id":row["event_id"],"receipt_id":row["receipt_id"],"disposition":if string(row,"disposition")=="suppressed" {"suppressed"} else if duplicate {"duplicate"} else {"accepted"}}),
    )
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Registration {
    schema_version: u32,
    environment: String,
    producer: String,
    grant_digest: String,
    operation_id: String,
    interest_id: String,
    interest_generation: i64,
    requester_ref: String,
    run_id: String,
    job_handle: String,
    accepted_at: i64,
}
async fn register(db: &D1Database, env: &Env, producer: &str, v: Value) -> Result<Response> {
    let r: Registration = match serde_json::from_value(v) {
        Ok(r) => r,
        Err(_) => return error(400, "invalid_request"),
    };
    if r.schema_version != 1
        || !wire::hex_id(&r.grant_digest)
        || !wire::hex_id(&r.interest_id)
        || !wire::uuid(&r.run_id)
        || !wire::uuid(&r.operation_id)
        || r.job_handle.is_empty()
        || r.job_handle.len() > 256
        || r.requester_ref.is_empty()
        || r.requester_ref.len() > 256
        || r.interest_generation < 1
    {
        return error(400, "invalid_request");
    }
    if r.producer != producer || r.environment != lane(env) {
        return error(403, "environment_mismatch");
    }
    let args = vec![
        json!(r.interest_id),
        json!(r.interest_generation),
        json!(r.producer),
        json!(r.operation_id),
        json!(r.requester_ref),
        json!(r.grant_digest),
        json!(r.run_id),
        json!(r.job_handle),
        json!(r.accepted_at),
        json!(now()),
        json!(id()),
    ];
    run(db,"UPDATE n_job_interest SET run_id=?7,job_handle=?8,accepted_at=?9,receipt_id=COALESCE(receipt_id,?11),state=CASE WHEN state='seen' THEN 'seen' ELSE 'registered' END WHERE interest_id=?1 AND generation=?2 AND producer=?3 AND operation_id=?4 AND requester_ref=?5 AND grant_digest=?6 AND state IN('issued','registered','seen') AND (run_id IS NULL OR (run_id=?7 AND job_handle=?8 AND accepted_at=?9)) AND ?9>=issued_at AND ?9<accept_before AND ?9<=?10 AND ?10<register_before AND EXISTS(SELECT 1 FROM n_install i WHERE i.install_id=n_job_interest.install_id AND i.epoch=n_job_interest.install_epoch AND i.enabled=1 AND i.job_capable=1)",&args).await?;
    let Some(i) = first(
        db,
        "SELECT * FROM n_job_interest WHERE interest_id=?1",
        &args[..1],
    )
    .await?
    else {
        return error(410, "interest_revoked");
    };
    if string(&i, "producer") != producer
        || string(&i, "requester_ref") != r.requester_ref
        || string(&i, "grant_digest") != r.grant_digest
        || string(&i, "operation_id") != r.operation_id
        || int(&i, "generation") != r.interest_generation
    {
        return error(409, "grant_binding_conflict");
    }
    if !["registered", "seen"].contains(&string(&i, "state")) {
        return error(410, "interest_revoked");
    }
    if string(&i, "run_id") != r.run_id
        || string(&i, "job_handle") != r.job_handle
        || int(&i, "accepted_at") != r.accepted_at
    {
        return error(409, "grant_binding_conflict");
    }
    response(
        200,
        json!({"schema_version":1,"interest_id":r.interest_id,"interest_generation":r.interest_generation,"run_id":r.run_id,"state":i["state"],"receipt_id":i["receipt_id"]}),
    )
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Cancellation {
    schema_version: u32,
    environment: String,
    producer: String,
    interest_id: String,
    interest_generation: i64,
    run_id: Option<String>,
    reason: String,
    grant_digest: Option<String>,
    operation_id: Option<String>,
    requester_ref: Option<String>,
}
async fn cancel(db: &D1Database, env: &Env, producer: &str, v: Value) -> Result<Response> {
    let c: Cancellation = match serde_json::from_value(v) {
        Ok(v) => v,
        Err(_) => return error(400, "invalid_request"),
    };
    if c.schema_version != 1
        || !wire::hex_id(&c.interest_id)
        || c.interest_generation < 1
        || !["cancelled", "superseded", "rejected"].contains(&c.reason.as_str())
    {
        return error(400, "invalid_request");
    }
    if c.producer != producer || c.environment != lane(env) {
        return error(403, "environment_mismatch");
    }
    let args = vec![
        json!(c.interest_id),
        json!(c.interest_generation),
        json!(producer),
        json!(c.run_id),
        json!(c.grant_digest),
        json!(c.operation_id),
        json!(c.requester_ref),
        json!(c.reason),
        json!(id()),
    ];
    let changed=run(db,"UPDATE n_job_interest SET state=CASE WHEN state IN('seen','revoked','superseded','cancelled') THEN state WHEN ?8='superseded' THEN 'superseded' ELSE 'cancelled' END,reason=CASE WHEN ?8='rejected' THEN 'attachment_rejected' ELSE ?8 END,local_fallback_safe=CASE WHEN attempt_started_at IS NULL THEN 1 ELSE 0 END,receipt_id=COALESCE(receipt_id,?9) WHERE interest_id=?1 AND generation=?2 AND producer=?3 AND ((?8='rejected' AND grant_digest=?5 AND operation_id=?6 AND requester_ref=?7 AND (run_id IS NULL OR run_id=?4)) OR (?8<>'rejected' AND run_id=?4))",&args).await?;
    if changed == 0 {
        return error(409, "grant_binding_conflict");
    }
    run(db,"UPDATE n_delivery SET state='suppressed',terminal_at=?2,lease_id=NULL,lease_until=NULL,last_reason='interest_cancelled' WHERE interest_key=?1 AND state IN('pending','leased','uncertain','poisoned')",&[json!(c.interest_id),json!(now())]).await?;
    let Some(i) = first(
        db,
        "SELECT * FROM n_job_interest WHERE interest_id=?1",
        &args[..1],
    )
    .await?
    else {
        return error(410, "interest_revoked");
    };
    response(
        200,
        json!({"schema_version":1,"interest_id":c.interest_id,"interest_generation":c.interest_generation,"state":i["state"],"receipt_id":i["receipt_id"],"local_fallback_safe":int(&i,"local_fallback_safe")==1}),
    )
}

async fn queue(db: &D1Database, env: &Env, v: Value) -> Result<Response> {
    #[derive(Deserialize)]
    #[serde(deny_unknown_fields)]
    struct Message {
        schema_version: u32,
        environment: String,
        source: String,
        id: String,
        generation: i64,
    }
    #[derive(Deserialize)]
    #[serde(deny_unknown_fields)]
    struct Envelope {
        queue: String,
        message: Message,
    }
    let e: Envelope = match serde_json::from_value(v) {
        Ok(v) => v,
        Err(_) => return error(400, "invalid_queue_message"),
    };
    let m = e.message;
    if m.schema_version != 1
        || m.environment != lane(env)
        || !wire::hex_id(&m.id)
        || m.generation < 1
        || !["feed_polling", "ad_analysis", "remote_transcription"].contains(&m.source.as_str())
    {
        return error(400, "invalid_queue_message");
    }
    let suffix = format!("-{}", lane(env));
    if e.queue == format!("opencast-notification-event{suffix}") && m.generation == 1 {
        fanout::page(db, env, &m.source, &m.id).await?;
    } else if e.queue
        == format!(
            "opencast-notification-{}{suffix}",
            if m.source == "feed_polling" {
                "episode"
            } else {
                "job"
            }
        )
    {
        send::deliver(db, env, &m.source, &m.id, m.generation).await?;
    } else {
        return error(400, "wrong_queue");
    }
    response(200, json!({"ok":true}))
}
