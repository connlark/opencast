use super::{
    body::{Body, Scratch},
    scan::{Finished, Observer, Probe, ProbeFinished},
    scratch::{self, Spill},
    store::{fault, Bound, Store},
};
use crate::{
    delivery::{
        db::*,
        wire::{self, string},
    },
    feed_fetch::{FeedFetchError, NotModifiedProof},
    feed_transport::{fetch_feed, FeedFetchOutcome},
    rss::{self, scan::EpisodeSink},
};
use serde::Deserialize;
use serde_json::json;
use std::{cell::Cell, rc::Rc, time::Duration};
use worker::*;

/// What a scan's parser feeds.
pub enum Stage {
    /// The probe of a scan whose digest is bound to its snapshot: the exact
    /// identity and fingerprint sets only, the body retained.
    Probe(Probe),
    /// The full observation: a single pass, or the replay over the retained body.
    Full(Observer),
}
impl Stage {
    pub fn store(&self) -> &Store {
        match self {
            Stage::Probe(probe) => &probe.store,
            Stage::Full(observer) => &observer.store,
        }
    }
    fn store_mut(&mut self) -> &mut Store {
        match self {
            Stage::Probe(probe) => &mut probe.store,
            Stage::Full(observer) => &mut observer.store,
        }
    }
}

#[derive(Default)]
pub struct ObserverSink {
    pub observer: Option<Stage>,
    pub origin: Option<crate::polling::origin::Session>,
    // Survives dropping a timed-out storage future; never blame its publisher.
    // Shared with the body's reader, whose part uploads and range reads are
    // storage too.
    pub storage_pending: Rc<Cell<bool>>,
    pub timings: crate::polling::timing::Timings,
    /// The probe's complete body, from its EOF until it is discarded, or
    /// replayed and deleted. Kept here, like the observer's spool, so every
    /// end of the scan cleans it up.
    pub body: Option<Body>,
    /// The body's scratch upload while the probe still reads it: a deadline drops
    /// the reader, never this handle.
    pub spill: Spill,
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
        let Some(stage) = self.observer.as_mut() else {
            return Ok(());
        };
        self.storage_pending.set(true);
        let _span = crate::polling::timing::Span::new(self.timings.sink.clone(), None);
        let result = match stage {
            Stage::Probe(probe) => probe.item(episode, raw).await,
            Stage::Full(observer) => observer.item(episode, raw).await,
        };
        self.storage_pending.set(false);
        result
    }
}
impl ObserverSink {
    /// A feed whose published digest is bound to its snapshot can prove an
    /// unchanged body from hashes alone, so it probes first. Any other (a
    /// baseline, or a digest left by an old binary or expiry) can never be
    /// proved unchanged and runs the full observation once.
    fn scanning(
        db: D1Database,
        store: Store,
        origin: Option<crate::polling::origin::Session>,
    ) -> Self {
        Self {
            evidence: Some((db, store.bound())),
            observer: Some(if store.has_bound_digest() {
                Stage::Probe(Probe::new(store))
            } else {
                Stage::Full(Observer::new(store))
            }),
            origin,
            ..Default::default()
        }
    }
    /// A 200 may settle on its strong ETag only for a feed whose published
    /// digest is bound to its snapshot; any other keeps parsing and repairing.
    pub fn etag_shortcut_eligible(&self) -> bool {
        self.observer
            .as_ref()
            .is_some_and(|stage| stage.store().has_bound_digest())
    }
    /// A probe retains its body for a possible full observation; the storage
    /// its reader needs for a body past the in-isolate buffer.
    pub fn retention(&self) -> Option<Scratch> {
        let Some(Stage::Probe(probe)) = self.observer.as_ref() else {
            return None;
        };
        Some(Scratch {
            bucket: probe.store.bucket.clone(),
            feed_id: probe.store.feed_id.clone(),
            storage: self.storage_pending.clone(),
            sink: self.timings.sink.clone(),
        })
    }
    /// Called immediately before each publisher request is sent. Until then a
    /// cancellation, deferral or failure has seen nothing and bounds nothing.
    pub fn requesting(&mut self) {
        self.reached = true;
        if let Some(stage) = self.observer.as_mut() {
            stage.store_mut().reached_publisher();
        }
    }

    /// The scan ended without a committed success: it failed, was truncated,
    /// lost its deadline, or died in storage after its body was read. It
    /// publishes nothing and keeps no scratch. If it reached the publisher its
    /// start survives as the bound a retry may not renew; a claimed scan
    /// already has that row, and a success committed since rejects the insert.
    pub async fn failed(&mut self) -> Result<()> {
        let mut owed = self.reached;
        if let Some(stage) = self.observer.take() {
            owed = match stage {
                Stage::Probe(probe) => probe.store.owes_bound(),
                Stage::Full(mut observer) => {
                    observer.discard().await;
                    observer.store.owes_bound()
                }
            };
        }
        self.discard_body().await;
        match self.evidence.take() {
            Some((db, bound)) if owed => bound.record(&db).await,
            _ => Ok(()),
        }
    }
    /// An origin deferral is this service's own throttle, on any hop. It is
    /// not a publisher failure and leaves nothing (a scan that never reached the publisher).
    pub async fn deferred(&mut self) {
        self.evidence = None;
        if let Some(Stage::Full(mut observer)) = self.observer.take() {
            observer.discard().await;
        }
        self.discard_body().await;
    }
    /// The retained body is not needed: drop it, abort its upload, or delete
    /// its completed object.
    pub async fn discard_body(&mut self) {
        if let Some(body) = self.body.take() {
            body.discard().await;
        }
        // A reader dropped mid-body leaves its upload only here.
        scratch::abort(&self.spill).await;
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
            let Some(acquisition) = scan_permit(poll.is_some(), "prepare").await else {
                return Response::error("scan_busy", 429);
            };
            if acquisition.reclaimed > 0 {
                crate::polling::stat(&db, "permit_reclaims").await?;
            }
            let _permit = acquisition.permits;
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
    let Some(acquisition) = scan_permit(poll.is_some(), "scan").await else {
        // Queue-owned polls add the outcome after this response so the
        // refusal is counted once. Direct observation callers still get the
        // isolate-local diagnostic here.
        if poll.is_none() {
            let view = crate::feed_scan_admission::FeedScanPermit::view();
            console_log!(
                "{}",
                json!({"event":"poll_outcome","outcome":"scan_busy","active_permits":view.active_permits,"oldest_permit_age_seconds":view.oldest_permit_age_seconds,"holder_step":view.holder_step,"isolate":view.isolate})
            );
        }
        return Response::error("scan_busy", 429);
    };
    if acquisition.reclaimed > 0 {
        crate::polling::stat(&db, "permit_reclaims").await?;
    }
    let _permit = acquisition.permits;
    let Some(authority) = first(
        &db,
        "SELECT canonical_url,etag,last_modified,validator_url,validator_at FROM n_feed WHERE feed_id=?1",
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
    feed.validator_url = authority["validator_url"].as_str().map(str::to_string);
    feed.validator_at = authority["validator_at"].as_i64();
    let mut sink = ObserverSink::scanning(env.d1("APP_ATTEST_DB")?, store, origin);
    sink.timings = poll.as_ref().map(|p| p.timings.clone()).unwrap_or_default();
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
///
/// A probing scan (bound digest) parses its 200 once into hashes while
/// retaining the body; an unchanged digest settles there (`"passes":1`). Only a
/// changed digest runs the full observation, over the same retained bytes and
/// never a second request (`"passes":2`). Any other scan is one full pass.
async fn scan(
    env: &Env,
    db: &D1Database,
    feed_id: &str,
    feed: &crate::storage::FeedSource,
    poll: Option<&crate::polling::Fence>,
    sink: &mut ObserverSink,
) -> Result<Response> {
    let deadline = || {
        Delay::from(Duration::from_secs(if poll.is_some() {
            crate::polling::policy::SCAN_DEADLINE_SECONDS
        } else {
            crate::feed_resource::SCAN_DEADLINE_SECONDS
        }))
    };
    let outcome = crate::deadline::fetch_with_deadline(
        fetch_feed(
            &feed.source_url,
            feed.etag.as_deref(),
            feed.last_modified.as_deref(),
            feed,
            Rc::new(Cell::new(0)),
            sink,
        ),
        deadline(),
        FeedFetchError::FetchFailed,
    )
    .await;
    let mut outcome = match outcome.map_err(|error| storage_failed(error, sink)) {
        Ok(outcome) => outcome,
        Err(error) => return fetch_error(env, poll, sink, error).await,
    };
    // The publisher's connection is finished: free its origin slot before any
    // storage work, which is bounded by the scan lease rather than the fetch.
    drop(sink.origin.take());
    if let FeedFetchOutcome::Fetched(fetched) = &mut outcome {
        sink.body = fetched.body.take();
        if let Err(error) = &fetched.parsed {
            return scan_error(env, poll, sink, error.code()).await;
        }
    }
    let stage = sink
        .observer
        .take()
        .ok_or_else(|| fault("observation_sink_lost"))?;
    let observation = stage.store().observation_id.clone();
    let result = match outcome {
        FeedFetchOutcome::NotModified(proof) => {
            let settle = poll.map(|p| p.settle(now(), "not_modified", None, None, None));
            let applied = stage
                .store()
                .unchanged(
                    feed.etag.as_deref(),
                    feed.last_modified.as_deref(),
                    None,
                    None,
                    settle.as_ref(),
                )
                .await?;
            let mut result = json!({"result":"not_modified","published":applied,"settled":applied});
            // Settled exactly as a 304; only the log says how it was proved.
            if proof == NotModifiedProof::StrongETag {
                sink.timings.via.set(Some("strong_etag"));
                result["via"] = json!("strong_etag");
            }
            result
        }
        FeedFetchOutcome::Fetched(fetched) => {
            let parsed = fetched.parsed.map_err(|error| fault(error.code()))?;
            let (etag, modified) = (fetched.etag.as_deref(), fetched.last_modified.as_deref());
            let (observer, parsed) = match stage {
                Stage::Full(observer) => (observer, parsed),
                Stage::Probe(probe) => match probe.finish(etag, modified, &fetched.url).await? {
                    ProbeFinished::Unchanged(applied) => {
                        sink.discard_body().await;
                        let mut result =
                            json!({"result":"unchanged","published":applied,"settled":applied});
                        result["passes"] = json!(sink.timings.passes.get());
                        result["observation_id"] = json!(observation);
                        return Response::from_json(&result);
                    }
                    ProbeFinished::Changed(store) => {
                        sink.observer = Some(Stage::Full(Observer::new(*store)));
                        match replay(sink, &feed.feed_url, deadline()).await {
                            Err(error) => return fetch_error(env, poll, sink, error).await,
                            Ok(Err(error)) => {
                                return scan_error(env, poll, sink, error.code()).await
                            }
                            Ok(Ok(parsed)) => match sink.observer.take() {
                                Some(Stage::Full(observer)) => (observer, parsed),
                                _ => return Err(fault("observation_sink_lost")),
                            },
                        }
                    }
                },
            };
            let finished = observer
                .finish(&parsed, &feed.feed_url, etag, modified, &fetched.url)
                .await?;
            if let Some(body) = sink.body.take() {
                body.delete_object().await;
            }
            let mut result = match finished {
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
            };
            result["passes"] = json!(sink.timings.passes.get());
            result
        }
    };
    let mut result = result;
    result["observation_id"] = json!(observation);
    Response::from_json(&result)
}

/// A timed-out step that was waiting on storage is not the publisher's fault.
fn storage_failed(error: FeedFetchError, sink: &ObserverSink) -> FeedFetchError {
    if error == FeedFetchError::FetchFailed && sink.storage_pending.get() {
        FeedFetchError::StorageFailed
    } else {
        error
    }
}

/// The replay: the full observation over the first response's retained body. No
/// publisher request: the bytes come from the isolate or the completed scratch
/// upload. Its spool writes run under the scan deadline as the in-fetch parse's
/// do, and a deadline while storage is pending is a storage failure.
async fn replay(
    sink: &mut ObserverSink,
    feed_url: &str,
    deadline: Delay,
) -> std::result::Result<
    std::result::Result<rss::scan::ScannedFeed, rss::RSSParseError>,
    FeedFetchError,
> {
    sink.timings.passes.set(2);
    let Some(mut body) = sink.body.take() else {
        return Err(FeedFetchError::StorageFailed);
    };
    let storage = sink.storage_pending.clone();
    let replayed = crate::deadline::fetch_with_deadline(
        async {
            storage.set(true);
            let completed = body.complete().await;
            storage.set(false);
            completed.map_err(|_| FeedFetchError::StorageFailed)?;
            let reader = body
                .reader(storage.clone())
                .map_err(|_| FeedFetchError::StorageFailed)?;
            Ok(rss::scan::scan_rss_with_sink(reader, feed_url, sink).await)
        },
        deadline,
        FeedFetchError::FetchFailed,
    )
    .await;
    body.release_bytes();
    sink.body = Some(body);
    replayed.map_err(|error| storage_failed(error, sink))
}

/// The scan ended before a complete body: transport, deadline, origin or
/// storage trouble. Never after the probe, which leaves no publisher to defer to.
async fn fetch_error(
    env: &Env,
    poll: Option<&crate::polling::Fence>,
    sink: &mut ObserverSink,
    error: FeedFetchError,
) -> Result<Response> {
    let deferred = error == FeedFetchError::OriginDeferred;
    if deferred {
        sink.deferred().await;
    } else {
        sink.failed().await?;
    }
    let storage = error == FeedFetchError::StorageFailed;
    console_log!(
        "{}",
        json!({"event":"poll_outcome","outcome":if storage {"storage_error"} else if deferred {"origin_deferred"} else {"upstream_error"},"reason":error.code()})
    );
    if error == FeedFetchError::FetchFailed {
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
        return Response::from_json(&json!({"result":"publisher_failed","published":false}));
    }
    Err(fault("observation_fetch_failed"))
}

/// The complete body was rejected, or its observation failed in storage.
async fn scan_error(
    env: &Env,
    poll: Option<&crate::polling::Fence>,
    sink: &mut ObserverSink,
    code: &'static str,
) -> Result<Response> {
    sink.failed().await?;
    let storage = code == "observation_stage_failed";
    console_log!(
        "{}",
        json!({"event":"poll_outcome","outcome":if storage {"storage_error"} else {"invalid_scan"},"reason":code})
    );
    // A failed scratch write is internal handling trouble, not
    // a publisher outage (including failures during the body).
    if let Some(poll) = poll.filter(|_| !storage) {
        crate::polling::fetch_failed(env, poll, code).await?;
        return Response::from_json(&json!({"result":"publisher_failed","published":false}));
    }
    Err(fault(code))
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
async fn scan_permit(
    wait: bool,
    step: &'static str,
) -> Option<crate::feed_scan_admission::ExclusiveAcquisition> {
    for attempt in 0..=30 {
        if let Some(acquisition) =
            crate::feed_scan_admission::FeedScanPermit::try_acquire_exclusive(step)
        {
            return Some(acquisition);
        }
        if !wait || attempt == 30 {
            return None;
        }
        Delay::from(Duration::from_millis(100)).await;
    }
    None
}
