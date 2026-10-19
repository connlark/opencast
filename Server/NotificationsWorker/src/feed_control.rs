//! Private operations for the current queued engine. No ownership transfers.
use crate::database::slice_f::{self as storage, FeedAction, Operation};
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

pub async fn handle(
    mut request: Request,
    env: Env,
    db: crate::database::Authority,
) -> Result<Response> {
    if request.method() != Method::Post {
        return Response::error("method_not_allowed", 405);
    }
    let path = request.path();
    if !matches!(
        path.as_str(),
        "/identity" | "/inspect" | "/pause" | "/pause-sends" | "/resume" | "/resume-sends"
    ) {
        return Response::error("not_found", 404);
    }
    // The operator's nonmutating identity readback: one read, no gate lock.
    if path == "/identity" {
        return Response::from_json(&crate::database::identity::readback(&db).await?);
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

    if path == "/inspect" {
        let row = storage::execute(
            &db,
            Operation::InspectFeed {
                feed: command.feed_id.clone(),
            },
        )
        .await?
        .first();
        return match row {
            Some(row) if int(&row, "epoch") == command.expected_epoch => Response::from_json(&row),
            _ => Response::error("stale_authority", 409),
        };
    }
    let action = match path.as_str() {
        "/pause" => FeedAction::Pause,
        "/pause-sends" => FeedAction::PauseSends,
        "/resume-sends" => FeedAction::ResumeSends,
        _ => FeedAction::Resume,
    };
    let changed = storage::execute(
        &db,
        Operation::ChangeFeed {
            feed: command.feed_id.clone(),
            epoch: command.expected_epoch,
            now: now(),
            action,
        },
    )
    .await?
    .count();
    if changed == 1 && path == "/resume-sends" {
        crate::delivery::recovery::requeue_feed(&env, &db, &command.feed_id).await?;
    }
    Response::from_json(&json!({"changed":changed,"epoch":command.expected_epoch,"action":path}))
        .map(|r| r.with_status(if changed == 1 { 200 } else { 409 }))
}
