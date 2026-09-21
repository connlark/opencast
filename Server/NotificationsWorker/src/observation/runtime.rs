use super::{
    scan::{Finished, Observer},
    store::{fault, Bound, Store},
};
use crate::{
    delivery::{
        db::*,
        wire::{self, string},
    },
    feed_transport::{fetch_feed, FeedFetchOutcome},
    rss::{self, scan::EpisodeSink},
};
use serde::Deserialize;
use serde_json::json;
use std::{cell::Cell, rc::Rc, time::Duration};
use worker::*;

#[derive(Default)]
pub struct ObserverSink {
    pub observer: Option<Observer>,
    pub origin: Option<crate::polling::origin::Session>,
    // Survives dropping a timed-out storage future; never blame its publisher.
    pub storage_pending: bool,
    // The scan's first-observed bound and where to record it. It outlives the
    // observer, which a finishing scan consumes, and is spent at most once.
    evidence: Option<(D1Database, Bound)>,
    // A publisher request was sent. Before that the scan has seen nothing.
    reached: bool,
}
impl EpisodeSink for ObserverSink {
    async fn item(
        &mut self,
        episode: &rss::ParsedEpisode,
        raw: Option<&str>,
    ) -> std::result::Result<(), rss::RSSParseError> {
        let Some(observer) = self.observer.as_mut() else {
            return Ok(());
        };
        self.storage_pending = true;
        let result = observer.item(episode, raw).await;
        self.storage_pending = false;
        result
    }
}
impl ObserverSink {
    fn scanning(
        db: D1Database,
        store: Store,
        origin: Option<crate::polling::origin::Session>,
    ) -> Self {
        Self {
            evidence: Some((db, store.bound())),
            observer: Some(Observer::new(store)),
            origin,
            storage_pending: false,
            reached: false,
        }
    }
    /// Called immediately before each publisher request is sent. Until then a
    /// cancellation, deferral or failure has seen nothing and bounds nothing.
    pub fn requesting(&mut self) {
        self.reached = true;
        if let Some(observer) = self.observer.as_mut() {
            observer.store.reached_publisher();
        }
    }

    /// The scan ended without a committed success: it failed, was truncated,
    /// lost its deadline, or died in storage after its body was read. It
    /// publishes nothing and keeps no scratch. If it reached the publisher its
    /// start survives as the bound a retry may not renew; a claimed scan
    /// already has that row, and a success committed since rejects the insert.
    pub async fn failed(&mut self) -> Result<()> {
        let mut owed = self.reached;
        if let Some(mut observer) = self.observer.take() {
            observer.discard().await;
            owed = observer.store.owes_bound();
        }
        match self.evidence.take() {
            Some((db, bound)) if owed => bound.record(&db).await,
            _ => Ok(()),
        }
    }
    /// An origin deferral is this service's own throttle, on any hop. It is
    /// not a publisher failure and leaves nothing (a scan that never reached the publisher).
    pub async fn deferred(&mut self) {
        self.evidence = None;
        if let Some(mut observer) = self.observer.take() {
            observer.discard().await;
        }
    }
}
fn enabled(env: &Env, name: &str) -> bool {
    env.var(name)
        .map(|v| v.to_string() == "true")
        .unwrap_or(false)
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Command {
    feed_id: String,
}
/// Only the private adapter can grant this capability. The adapter passes an
/// explicit environment with storage and the private FeedEvents producer binding,
/// without APNs credentials.
pub async fn handle(mut request: Request, env: Env) -> Result<Response> {
    if request.method() != Method::Post {
        return Response::error("method_not_allowed", 405);
    }
    if !enabled(&env, "NOTIFICATION_FEED_OBSERVATION") {
        return Response::error("observation_disabled", 503);
    }
    // Bound the private reference envelope too; it never accepts source URLs.
    use futures_util::StreamExt;
    let mut body = vec![];
    let mut stream = request.stream()?;
    while let Some(chunk) = stream.next().await {
        let chunk = chunk?;
        if body.len() + chunk.len() > 1024 {
            return Response::error("payload_too_large", 413);
        }
        body.extend(chunk);
    }
    let command: Command = serde_json::from_value(wire::parse(&body).map_err(fault)?)?;
    if !wire::hex_id(&command.feed_id) {
        return Response::error("invalid_feed_id", 400);
    }
    execute(&request.path(), &command.feed_id, env, None).await
}
pub(crate) async fn execute(
    path: &str,
    feed_id: &str,
    env: Env,
    poll: Option<crate::polling::Fence>,
) -> Result<Response> {
    let command = Command {
        feed_id: feed_id.into(),
    };
    let db = env.d1("APP_ATTEST_DB")?;
    match path {
        "/prepare" => {
            let Some(_permit) = scan_permit(poll.is_some()).await else {
                return Response::error("scan_busy", 429);
            };
            let progress = super::prepare::step_fenced(
                env.d1("APP_ATTEST_DB")?,
                env.bucket("FEED_SNAPSHOTS")?,
                &command.feed_id,
                poll,
            )
            .await?;
            let published = progress == Some(true);
            return Response::from_json(&json!({
                "result":if published {"published"} else if progress.is_some() {"staged"} else {"idle"},
                "published":published,"pending":progress.is_some(),
                "settled":published && settled(&db, &command.feed_id).await?,
            }));
        }
        "/stats" => {
            return Response::from_json(
                &json!({"wasm_memory_bytes":crate::runtime_diagnostics::current().wasm_memory_bytes}),
            )
        }
        "/drain" => {
            super::drain::page(
                &db,
                &env.bucket("FEED_SNAPSHOTS")?,
                &command.feed_id,
                &lane(&env),
            )
            .await?;
            return Response::ok("drained");
        }
        "/outbox" => {
            super::drain::outbox(&db, &env, &command.feed_id).await?;
            return Response::ok("outbox");
        }
        "/gc" => {
            if !enabled(&env, "NOTIFICATION_CLEANUP") {
                return Response::error("cleanup_disabled", 503);
            }
            super::gc::collect(&db, &env.bucket("FEED_SNAPSHOTS")?).await?;
            return Response::ok("collected");
        }
        "/scan" => {}
        _ => return Response::error("not_found", 404),
    }
    let Some(_permit) = scan_permit(poll.is_some()).await else {
        return Response::error("scan_busy", 429);
    };
    let Some(authority) = first(
        &db,
        "SELECT canonical_url,etag,last_modified FROM n_feed WHERE feed_id=?1",
        &[json!(command.feed_id)],
    )
    .await?
    else {
        return Response::error("unknown_feed", 404);
    };
    let Some(mut feed) =
        crate::storage::feed_source(&db, string(&authority, "canonical_url")).await?
    else {
        return Response::error("unknown_feed", 404);
    };
    // Reads only. Neither admission nor a failed fetch can create conservative
    // observation evidence: no complete RSS body has been seen.
    let Some(store) = Store::deferred(
        env.d1("APP_ATTEST_DB")?,
        env.bucket("FEED_SNAPSHOTS")?,
        &command.feed_id,
        poll.clone(),
    )
    .await?
    else {
        return Response::error("observation_not_claimed", 409);
    };
    let origin = poll.clone().map(|p| {
        crate::polling::origin::Session::new(env.d1("APP_ATTEST_DB").expect("validated DB"), p)
    });
    feed.etag = authority["etag"].as_str().map(str::to_string);
    feed.last_modified = authority["last_modified"].as_str().map(str::to_string);
    let mut sink = ObserverSink::scanning(env.d1("APP_ATTEST_DB")?, store, origin);
    let result = scan(&env, &db, &command.feed_id, &feed, poll.as_ref(), &mut sink).await;
    if result.is_err() {
        // The scan died outside its own handling, possibly after its observer
        // was spent. Its start still bounds what a retry may first observe.
        sink.failed().await?;
    }
    result
}

/// One complete scan. Every publisher-facing failure is settled here; an `Err`
/// is handling trouble, which the caller bounds and the Queue redelivers.
async fn scan(
    env: &Env,
    db: &D1Database,
    feed_id: &str,
    feed: &crate::storage::FeedSource,
    poll: Option<&crate::polling::Fence>,
    sink: &mut ObserverSink,
) -> Result<Response> {
    let outcome = crate::deadline::fetch_with_deadline(
        fetch_feed(
            &feed.source_url,
            feed.etag.as_deref(),
            feed.last_modified.as_deref(),
            feed,
            Rc::new(Cell::new(0)),
            sink,
        ),
        Delay::from(Duration::from_secs(if poll.is_some() {
            crate::polling::policy::SCAN_DEADLINE_SECONDS
        } else {
            crate::feed_resource::SCAN_DEADLINE_SECONDS
        })),
        crate::feed_fetch::FeedFetchError::FetchFailed,
    )
    .await;
    let outcome = outcome.map_err(|error| {
        if error == crate::feed_fetch::FeedFetchError::FetchFailed && sink.storage_pending {
            crate::feed_fetch::FeedFetchError::StorageFailed
        } else {
            error
        }
    });
    let outcome = match outcome {
        Ok(outcome) => outcome,
        Err(error) => {
            let deferred = error == crate::feed_fetch::FeedFetchError::OriginDeferred;
            if deferred {
                sink.deferred().await;
            } else {
                sink.failed().await?;
            }
            let storage = error == crate::feed_fetch::FeedFetchError::StorageFailed;
            console_log!(
                "{}",
                json!({"event":"poll_outcome","outcome":if storage {"storage_error"} else if deferred {"origin_deferred"} else {"upstream_error"},"reason":error.code()})
            );
            if error == crate::feed_fetch::FeedFetchError::FetchFailed {
                if let Some(origin) = sink.origin.as_mut() {
                    // Network failure/deadline applies to the publisher origin
                    // as well as this feed; parse/resource rejection does not.
                    origin.response(599, &Headers::new()).await?;
                }
            }
            if let Some(poll) = poll.filter(|_| !storage) {
                if deferred {
                    let until = sink.origin.as_ref().and_then(|o| o.cooldown_until);
                    return Response::from_json(
                        &json!({"result":"origin_deferred","published":false,"cooldown_until":until}),
                    );
                }
                crate::polling::fetch_failed(env, poll, error.code()).await?;
                return Response::from_json(
                    &json!({"result":"publisher_failed","published":false}),
                );
            }
            return Err(fault("observation_fetch_failed"));
        }
    };
    // The publisher's connection is finished: free its origin slot before any
    // storage work, which is bounded by the scan lease rather than the fetch.
    drop(sink.origin.take());
    if let FeedFetchOutcome::Fetched(fetched) = &outcome {
        if let Err(error) = &fetched.parsed {
            sink.failed().await?;
            let storage = error.code() == "observation_stage_failed";
            console_log!(
                "{}",
                json!({"event":"poll_outcome","outcome":if storage {"storage_error"} else {"invalid_scan"},"reason":error.code()})
            );
            // A failed scratch write is internal handling trouble, not
            // a publisher outage (including failures during the body).
            if let Some(poll) = poll.filter(|_| !storage) {
                crate::polling::fetch_failed(env, poll, error.code()).await?;
                return Response::from_json(
                    &json!({"result":"publisher_failed","published":false}),
                );
            }
            return Err(fault(error.code()));
        }
    }
    let observer = sink
        .observer
        .take()
        .ok_or_else(|| fault("observation_sink_lost"))?;
    let observation = observer.store.observation_id.clone();
    let result = match outcome {
        FeedFetchOutcome::NotModified => {
            let settle = poll.map(|p| p.settle(now(), "not_modified", None, None, None));
            let applied = observer
                .store
                .unchanged(
                    feed.etag.as_deref(),
                    feed.last_modified.as_deref(),
                    None,
                    settle.as_ref(),
                )
                .await?;
            json!({"result":"not_modified","published":applied,"settled":applied})
        }
        FeedFetchOutcome::Fetched(fetched) => {
            let parsed = fetched.parsed.map_err(|error| fault(error.code()))?;
            match observer
                .finish(
                    &parsed,
                    &feed.feed_url,
                    fetched.etag.as_deref(),
                    fetched.last_modified.as_deref(),
                )
                .await?
            {
                Finished::Unchanged(applied) => {
                    json!({"result":"unchanged","published":applied,"settled":applied})
                }
                Finished::Unclaimed => {
                    return Response::error("observation_not_claimed", 409);
                }
                Finished::Staged => json!({"result":"staged","published":false}),
                Finished::Published(true) => {
                    json!({"result":"published","published":true,"candidates":0,"settled":settled(db, feed_id).await?})
                }
                Finished::Published(false) => json!({"result":"lost_fence","published":false}),
            }
        }
    };
    let mut result = result;
    result["observation_id"] = json!(observation);
    Response::from_json(&result)
}

/// A publication with nothing left to drain settled its own generation.
async fn settled(db: &D1Database, feed_id: &str) -> Result<bool> {
    Ok(first(
        db,
        "SELECT 1 FROM n_feed WHERE feed_id=?1 AND dispatch_until=0",
        &[json!(feed_id)],
    )
    .await?
    .is_some())
}

// Waiting futures own no scan buffers or cross-request I/O. Short contention
// resolves within the invocation; long scans use a bounded queue retry.
async fn scan_permit(wait: bool) -> Option<Vec<crate::feed_scan_admission::FeedScanPermit>> {
    for attempt in 0..=30 {
        if let Some(permit) = crate::feed_scan_admission::FeedScanPermit::try_acquire_exclusive() {
            return Some(permit);
        }
        if !wait || attempt == 30 {
            return None;
        }
        Delay::from(Duration::from_millis(100)).await;
    }
    None
}
