use super::{
    db::*,
    fanout, recovery, send,
    wire::{self, int, string, Event},
};
use crate::database::slice_f::{self as storage, Admission, Operation};
use futures_util::StreamExt;
use serde::Deserialize;
use serde_json::{json, Value};
use worker::{Env, Method, Request, Response, Result};

pub fn response(status: u16, value: Value) -> Result<Response> {
    let mut r = Response::from_json(&value)?.with_status(status);
    r.headers_mut().set("Cache-Control", "no-store")?;
    Ok(r)
}
pub fn error(status: u16, code: &str) -> Result<Response> {
    response(status, json!({"schema_version":1,"error":code}))
}

pub async fn handle(
    mut req: Request,
    env: Env,
    capability: &str,
    db: crate::database::Authority,
) -> Result<Response> {
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

async fn accept(db: &crate::database::Authority, env: &Env, event: Event) -> Result<Response> {
    let v = event.value();
    let digest = wire::digest(&v);
    let t = now();
    if let Some(existing) = storage::execute(
        db,
        Operation::ReadEvent {
            source: event.source.clone(),
            event: event.event_id.clone(),
        },
    )
    .await?
    .first()
    {
        return receipt(&existing, &digest, true);
    }
    let episode = event.kind == "episode";
    if episode && !crate::database::permitted(env, db, "episode_activation").await? {
        return error(503, "activation_disabled");
    }
    let routing = &event.routing;
    let mut disposition = "accepted";
    if !episode {
        let interest = storage::execute(
            db,
            Operation::ReadInterest {
                interest: string(routing, "interest_id").into(),
            },
        )
        .await?
        .first();
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
    let admission = Admission {
        source: event.source.clone(),
        event: event.event_id.clone(),
        kind: event.kind.clone(),
        digest: digest.clone(),
        occurred_at: event.occurred_at,
        eligible_at: event.eligible_at,
        expires_at: event.expires_at,
        receipt: id(),
        envelope_json: v.to_string(),
        now: t,
        disposition: disposition.into(),
        feed: routing["feed_id"].as_str().map(str::to_owned),
        interest: routing["interest_id"].as_str().map(str::to_owned),
        epoch: routing["owner_epoch"].as_i64(),
        observation: routing["observation_id"].as_str().map(str::to_owned),
        observation_generation: routing["observation_generation"].as_i64(),
        interest_generation: routing["interest_generation"].as_i64(),
        run_id: routing["run_id"].as_str().map(str::to_owned),
    };
    storage::execute(db, Operation::AdmitEvent { admission }).await?;
    let Some(saved) = storage::execute(
        db,
        Operation::ReadEvent {
            source: event.source.clone(),
            event: event.event_id.clone(),
        },
    )
    .await?
    .first() else {
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
async fn register(
    db: &crate::database::Authority,
    env: &Env,
    producer: &str,
    v: Value,
) -> Result<Response> {
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
    let registration = storage::Registration {
        interest: r.interest_id.clone(),
        generation: r.interest_generation,
        producer: r.producer.clone(),
        operation_id: r.operation_id.clone(),
        requester_ref: r.requester_ref.clone(),
        grant_digest: r.grant_digest.clone(),
        run_id: r.run_id.clone(),
        job_handle: r.job_handle.clone(),
        accepted_at: r.accepted_at,
        now: now(),
        receipt: id(),
    };
    storage::execute(db, Operation::RegisterInterest { registration }).await?;
    let Some(i) = storage::execute(
        db,
        Operation::ReadInterest {
            interest: r.interest_id.clone(),
        },
    )
    .await?
    .first() else {
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
async fn cancel(
    db: &crate::database::Authority,
    env: &Env,
    producer: &str,
    v: Value,
) -> Result<Response> {
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
    let cancellation = storage::Cancellation {
        interest: c.interest_id.clone(),
        generation: c.interest_generation,
        producer: producer.into(),
        run_id: c.run_id.clone(),
        grant_digest: c.grant_digest.clone(),
        operation_id: c.operation_id.clone(),
        requester_ref: c.requester_ref.clone(),
        reason: c.reason.clone(),
        receipt: id(),
    };
    let changed = storage::execute(db, Operation::CancelInterest { cancellation })
        .await?
        .count();
    if changed == 0 {
        return error(409, "grant_binding_conflict");
    }
    storage::execute(
        db,
        Operation::SuppressDeliveries {
            interest: c.interest_id.clone(),
            now: now(),
        },
    )
    .await?;
    let Some(i) = storage::execute(
        db,
        Operation::ReadInterest {
            interest: c.interest_id.clone(),
        },
    )
    .await?
    .first() else {
        return error(410, "interest_revoked");
    };
    response(
        200,
        json!({"schema_version":1,"interest_id":c.interest_id,"interest_generation":c.interest_generation,"state":i["state"],"receipt_id":i["receipt_id"],"local_fallback_safe":int(&i,"local_fallback_safe")==1}),
    )
}

async fn queue(db: &crate::database::Authority, env: &Env, v: Value) -> Result<Response> {
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
