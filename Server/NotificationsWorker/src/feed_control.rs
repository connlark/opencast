//! Private operations for the current queued engine. No ownership transfers.
use crate::delivery::{
    db::*,
    wire::{self, int},
};
use futures_util::StreamExt;
use serde::Deserialize;
use serde_json::json;
use worker::*;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Command {
    feed_id: String,
    expected_epoch: i64,
}

pub async fn handle(mut request: Request, env: Env) -> Result<Response> {
    if request.method() != Method::Post {
        return Response::error("method_not_allowed", 405);
    }
    let path = request.path();
    if !matches!(
        path.as_str(),
        "/inspect" | "/pause" | "/pause-sends" | "/resume" | "/resume-sends"
    ) {
        return Response::error("not_found", 404);
    }
    let mut bytes = vec![];
    let mut stream = request.stream()?;
    while let Some(chunk) = stream.next().await {
        let chunk = chunk?;
        if bytes.len() + chunk.len() > 1024 {
            return Response::error("payload_too_large", 413);
        }
        bytes.extend(chunk);
    }
    let command: Command = match wire::parse(&bytes)
        .ok()
        .and_then(|v| serde_json::from_value(v).ok())
    {
        Some(c) => c,
        None => return Response::error("invalid_command", 400),
    };
    if !wire::hex_id(&command.feed_id) || command.expected_epoch < 1 {
        return Response::error("invalid_command", 400);
    }
    let db = env.d1("APP_ATTEST_DB")?;
    if path == "/inspect" {
        let row = first(&db, "SELECT epoch,admission_paused,send_paused,dispatch_until,lease_until,observation_generation,poll_failures,handling_failures,last_poll_outcome,due_at,retry_at FROM n_feed WHERE feed_id=?1", &[json!(command.feed_id)]).await?;
        return match row {
            Some(row) if int(&row, "epoch") == command.expected_epoch => Response::from_json(&row),
            _ => Response::error("stale_authority", 409),
        };
    }
    let assignment = match path.as_str() {
        "/pause" => "admission_paused=1",
        "/pause-sends" => "send_paused=1",
        "/resume-sends" => "send_paused=0",
        _ => "admission_paused=0,lease_id=NULL,lease_until=NULL",
    };
    // Never clear a live poll lease/reservation on resume. Pauses retain the
    // epoch, validators, snapshot and immutable delivery identities.
    let gate = if path == "/resume" {
        " AND (lease_id IS NULL OR lease_until<=?3) AND dispatch_until<=?3"
    } else {
        ""
    };
    let changed = run(
        &db,
        &format!("UPDATE n_feed SET {assignment} WHERE feed_id=?1 AND epoch=?2 AND ?3>=0{gate}"),
        &[
            json!(command.feed_id),
            json!(command.expected_epoch),
            json!(now()),
        ],
    )
    .await?;
    if changed == 1 && path == "/resume-sends" {
        crate::delivery::recovery::requeue_feed(&env, &db, &command.feed_id).await?;
    }
    Response::from_json(&json!({"changed":changed,"epoch":command.expected_epoch,"action":path}))
        .map(|r| r.with_status(if changed == 1 { 200 } else { 409 }))
}
