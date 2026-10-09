//! Bounded publisher transport shared by queued observations and their tests.
use crate::deadline::fetch_with_deadline;
use crate::feed_fetch::{
    feed_response_disposition, same_origin, strong_etag_unchanged, FeedFetchError,
    FeedResponseDisposition, NotModifiedProof, StoredValidators, FEED_USER_AGENT,
};
use crate::feed_stream::{FeedFetchCancellation, FeedStream};
use crate::observation::body::{Body, Retained};
use crate::{feed_admission, feed_resource, rss, storage};
use std::{cell::Cell, rc::Rc, time::Duration};
use worker::{Delay, Fetch, Headers, Method, Request, RequestInit, RequestRedirect};
const MAX_FEED_REDIRECTS: usize = 5;

pub(crate) struct FetchedFeed {
    pub(crate) parsed: std::result::Result<rss::scan::ScannedFeed, rss::RSSParseError>,
    pub(crate) etag: Option<String>,
    pub(crate) last_modified: Option<String>,
    /// The hop that answered 200: the resource its validators describe.
    pub(crate) url: String,
    /// A probe's complete body, retained for the full observation.
    pub(crate) body: Option<Body>,
}

pub(crate) enum FeedFetchOutcome {
    NotModified(NotModifiedProof),
    Fetched(Box<FetchedFeed>),
}

pub(crate) async fn fetch_feed(
    source_url: &str,
    etag: Option<&str>,
    last_modified: Option<&str>,
    feed: &storage::FeedSource,
    invocation_bytes: Rc<Cell<usize>>,
    observer: &mut crate::observation::runtime::ObserverSink,
) -> std::result::Result<FeedFetchOutcome, FeedFetchError> {
    let mut current_url = source_url.to_string();
    let original_url = url::Url::parse(source_url).map_err(|_| FeedFetchError::FetchFailed)?;

    for redirect_count in 0..=MAX_FEED_REDIRECTS {
        let parsed_current_url =
            url::Url::parse(&current_url).map_err(|_| FeedFetchError::FetchFailed)?;
        if let Some(origin) = observer.origin.as_mut() {
            observer.storage_pending.set(true);
            let admitted = origin.acquire(&parsed_current_url).await;
            observer.storage_pending.set(false);
            admitted?;
        }
        // From here a publisher request exists: only now can this scan's end
        // bound what a retry may first observe.
        observer.requesting();
        let headers = Headers::new();
        // UA-less fetches trip host WAFs into 403 -> six-hour backoff; one
        // unconditional identity serves both the poll and admission paths.
        headers
            .set("user-agent", FEED_USER_AGENT)
            .map_err(|_| FeedFetchError::FetchFailed)?;
        if same_origin(&parsed_current_url, &original_url) {
            if let Some(etag) = etag {
                headers
                    .set("if-none-match", etag)
                    .map_err(|_| FeedFetchError::FetchFailed)?;
            }
            if let Some(last_modified) = last_modified {
                headers
                    .set("if-modified-since", last_modified)
                    .map_err(|_| FeedFetchError::FetchFailed)?;
            }
        }

        let mut init = RequestInit::new();
        init.with_method(Method::Get)
            .with_headers(headers)
            .with_redirect(RequestRedirect::Manual);
        let request =
            Request::new_with_init(&current_url, &init).map_err(|_| FeedFetchError::FetchFailed)?;
        let cancellation = FeedFetchCancellation::default();
        let signal = cancellation.signal();
        let publisher_span = observer.timings.publisher_span();
        let response = fetch_with_deadline(
            async {
                Fetch::Request(request)
                    .send_with_signal(&signal)
                    .await
                    .map_err(|_| FeedFetchError::FetchFailed)
            },
            Delay::from(Duration::from_secs(feed_resource::INACTIVITY_SECONDS)),
            FeedFetchError::FetchFailed,
        )
        .await?;
        drop(publisher_span);
        let status = response.status_code();

        if let Some(origin) = observer.origin.as_mut() {
            observer.storage_pending.set(true);
            let recorded = origin.response(status, response.headers()).await;
            observer.storage_pending.set(false);
            recorded.map_err(|_| FeedFetchError::StorageFailed)?;
        }

        match feed_response_disposition(status) {
            FeedResponseDisposition::NotModified => {
                // A new or cross-origin request cannot validate a scan it
                // never completed. Keep admission failures visible in health.
                if !same_origin(&parsed_current_url, &original_url)
                    || (etag.is_none() && last_modified.is_none())
                {
                    return Err(FeedFetchError::UnexpectedNotModified);
                }
                return Ok(FeedFetchOutcome::NotModified(NotModifiedProof::Status));
            }
            FeedResponseDisposition::Redirect => {
                if redirect_count == MAX_FEED_REDIRECTS {
                    return Err(FeedFetchError::TooManyRedirects);
                }
                let location = response
                    .headers()
                    .get("location")
                    .map_err(|_| FeedFetchError::FetchFailed)?
                    .ok_or(FeedFetchError::MissingRedirectLocation)?;
                let next = parsed_current_url
                    .join(&location)
                    .map_err(|_| FeedFetchError::InvalidRedirect)?;
                feed_admission::admit_feed_url(next.as_str())
                    .map_err(|_| FeedFetchError::InvalidRedirect)?;
                current_url = next.to_string();
                continue;
            }
            FeedResponseDisposition::Other => {}
        }
        if !(200..300).contains(&status) {
            return Err(FeedFetchError::HTTPStatus(status));
        }

        let etag = response
            .headers()
            .get("etag")
            .map_err(|_| FeedFetchError::FetchFailed)?;
        let last_modified = response
            .headers()
            .get("last-modified")
            .map_err(|_| FeedFetchError::FetchFailed)?;
        // A repeated strong ETag of this exact resource, parsed within the
        // trust window, proves the published snapshot as a 304 would. The
        // body is never read: dropping the response and its cancellation
        // aborts the request, exactly as the 304 return above.
        if observer.etag_shortcut_eligible()
            && strong_etag_unchanged(
                &StoredValidators {
                    etag: feed.etag.as_deref(),
                    last_modified: feed.last_modified.as_deref(),
                    url: feed.validator_url.as_deref(),
                    at: feed.validator_at,
                },
                etag.as_deref(),
                last_modified.as_deref(),
                &current_url,
                crate::delivery::db::now(),
            )
        {
            return Ok(FeedFetchOutcome::NotModified(NotModifiedProof::StrongETag));
        }
        let decoded_bytes = Rc::new(Cell::new(0usize));
        let stream = FeedStream::new(&response, invocation_bytes.clone(), decoded_bytes.clone())
            .map_err(|_| FeedFetchError::StorageFailed)?;
        let stream = if observer.origin.is_some() {
            stream.with_inactivity(crate::polling::policy::INACTIVITY_SECONDS)
        } else {
            stream
        };
        let publisher_span = observer.timings.publisher_span();
        observer.timings.passes.set(1);
        // A probe keeps every byte it parses, so a changed digest can be
        // observed in full from this response; nothing else is buffered.
        let (parsed, body) = match observer.retention() {
            Some(scratch) => {
                let mut retained = Retained::new(stream, observer.spill.clone(), scratch);
                match rss::scan::scan_rss_with_sink(&mut retained, &feed.feed_url, observer).await {
                    Ok(parsed) => match retained.into_body() {
                        Ok(body) => (Ok(parsed), Some(body)),
                        Err(_) => (
                            Err(rss::RSSParseError::ResourceLimit(
                                "observation_stage_failed",
                            )),
                            None,
                        ),
                    },
                    Err(error) => (Err(error), None),
                }
            }
            None => (
                rss::scan::scan_rss_with_sink(stream, &feed.feed_url, observer).await,
                None,
            ),
        };

        drop(publisher_span);
        return Ok(FeedFetchOutcome::Fetched(Box::new(FetchedFeed {
            parsed,
            etag,
            last_modified,
            url: current_url,
            body,
        })));
    }

    Err(FeedFetchError::TooManyRedirects)
}
